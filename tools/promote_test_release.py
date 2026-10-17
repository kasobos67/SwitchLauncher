#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Prepare a stable ZIP from a published test release. All GitHub access is GET-only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile

try:
    from . import build_release as builder, publish_feed as publisher
    from .channels import config
except ImportError:
    import build_release as builder
    import publish_feed as publisher
    from channels import config

PREFIX = '/repos/' + publisher.REPOSITORY
SHA = re.compile(r'[0-9a-f]{40}')
DOCUMENTS = {'README.md', 'LICENSE', 'ASSET_NOTICES.md'}


class ReadOnlyGitHub:
    def __init__(self, token=''):
        self.token = token

    def get(self, path):
        publisher.require(path == PREFIX or path.startswith(PREFIX + '/'), 'Unexpected API repository')
        headers = {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
                   'User-Agent': 'SwitchLauncher-test-promotion'}
        if self.token:
            headers['Authorization'] = 'Bearer ' + self.token
        request = Request('https://api.github.com' + path, headers=headers, method='GET')
        try:
            with urlopen(request, timeout=60) as response:
                raw = response.read(2 * 1024**2 + 1)
                publisher.require(len(raw) <= 2 * 1024**2, 'API response exceeded limit')
                return json.loads(raw)
        except HTTPError as error:
            raise publisher.ApiError(error.code, f'GitHub API returned HTTP {error.code} for GET {path}') from None


def pages(api, path):
    for page in range(1, 11):
        items = api.get(PREFIX + path + f'?per_page=100&page={page}')
        publisher.require(isinstance(items, list), 'Unexpected GitHub list response')
        yield from items
        if len(items) < 100:
            return
    raise ValueError('Too many GitHub results; narrow the release history before retrying')


def resolve(api, test_tag, stable_version=None):
    test_version = publisher.tag_version(test_tag, 'test')
    stable_version = stable_version or test_version
    destination = publisher.version(stable_version)
    repo = api.get(PREFIX)
    publisher.require(repo.get('private') is False, 'The release repository must be public')
    release = api.get(PREFIX + '/releases/tags/' + quote(test_tag, safe=''))
    publisher.require(release.get('tag_name') == test_tag, 'Unexpected test release tag')
    publisher.require(not release.get('draft') and release.get('prerelease') is True,
                      'Select an already-published test prerelease')
    publisher.require(type(release.get('id')) is int and release['id'] > 0, 'Invalid release ID')
    filename = publisher.asset_name(test_version, 'test')
    matches = [a for a in pages(api, f"/releases/{release['id']}/assets")
               if a.get('name') == filename and a.get('state') == 'uploaded']
    publisher.require(len(matches) == 1, 'The test release must contain exactly one ' + filename)
    asset = matches[0]
    expected_url = f'https://github.com/{publisher.REPOSITORY}/releases/download/{test_tag}/{filename}'
    publisher.require(asset.get('browser_download_url') == expected_url, 'Unexpected test ZIP download address')
    publisher.require(type(asset.get('size')) is int and 0 < asset['size'] <= publisher.MAX_ARCHIVE,
                      'Invalid test ZIP size')
    digest = asset.get('digest')
    publisher.require(not digest or re.fullmatch(r'sha256:[0-9a-f]{64}', digest), 'Unsupported asset checksum')

    # Resolve the immutable tag, never the release's possibly moving target_commitish branch.
    obj = api.get(PREFIX + '/git/ref/tags/' + quote(test_tag, safe=''))['object']
    for _ in range(8):
        publisher.require(isinstance(obj, dict) and SHA.fullmatch(str(obj.get('sha', ''))), 'Invalid tag object')
        if obj.get('type') == 'commit':
            break
        publisher.require(obj.get('type') == 'tag', 'Test tag must point to a commit')
        obj = api.get(PREFIX + '/git/tags/' + obj['sha'])['object']
    else:
        raise ValueError('Test tag nesting limit exceeded')

    stable_versions = []
    for item in pages(api, '/releases'):
        if item.get('draft') or item.get('prerelease'):
            continue
        tag = item.get('tag_name', '')
        if isinstance(tag, str) and re.fullmatch(r'v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}', tag):
            stable_versions.append(publisher.tag_version(tag))
    if stable_versions:
        latest = max(stable_versions, key=publisher.version)
        publisher.require(destination > publisher.version(latest),
                          f'Stable version must be newer than published stable {latest}; use a new version')
    return {'schema': 1, 'repository': publisher.REPOSITORY, 'test_tag': test_tag,
            'test_version': test_version, 'stable_version': stable_version,
            'commit': obj['sha'], 'release_id': release['id'], 'asset': {
                'name': filename, 'size': asset['size'], 'url': expected_url, 'digest': digest}}


def contents(path, identifier):
    with zipfile.ZipFile(path) as archive:
        return {n[len(identifier) + 1:]: archive.read(n) for n in archive.namelist() if not n.endswith('/')}


def verify_tagged_source(root, downloaded, resolution, output):
    rebuilt = builder.package(root, output, resolution['test_tag'], 'test')
    def comparable(path):
        return {name: data.replace(b'\r\n', b'\n') if name in DOCUMENTS else data
                for name, data in contents(path, config('test').id).items()}
    # GitHub's website may normalize CRLF documentation uploaded from Windows to LF.
    # Runtime files, artwork, loading configuration and sounds still match byte for byte.
    publisher.require(comparable(rebuilt) == comparable(downloaded),
                      'Published test ZIP does not match its tagged source. Select a release with matching source and ZIP.')


def clean_readme(text):
    # Remove only the test-branch installation notice; retain project documentation and credits.
    return ''.join(line for line in text.replace('\r\n', '\n').splitlines(keepends=True)
                   if not line.startswith('> **Test branch:**'))


def copy_source(root, target):
    # Copy links as links; the builder must reject them instead of following them outside the checkout.
    shutil.copytree(root, target, symlinks=True,
                    ignore=shutil.ignore_patterns('.git', '__pycache__', 'dist', '*.pyc'))


def build(root, output, resolution, fetch=publisher.download):
    root, output = Path(root).resolve(), Path(output).resolve()
    publisher.require(resolution.get('schema') == 1 and resolution.get('repository') == publisher.REPOSITORY,
                      'Unexpected promotion metadata')
    test_version = publisher.tag_version(resolution['test_tag'], 'test')
    stable_version = resolution['stable_version']
    publisher.version(stable_version)
    publisher.require(SHA.fullmatch(str(resolution.get('commit', ''))), 'Invalid source commit')
    publisher.require(not output.is_relative_to(root), 'Output must be outside the tested checkout')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='switchlauncher-promotion-') as temporary:
        temporary = Path(temporary)
        asset = resolution['asset']
        expected_name = publisher.asset_name(test_version, 'test')
        expected_url = f"https://github.com/{publisher.REPOSITORY}/releases/download/{resolution['test_tag']}/{expected_name}"
        publisher.require(asset['name'] == expected_name and asset['url'] == expected_url, 'Unexpected test asset')
        downloaded = temporary / expected_name
        fetch(expected_url, downloaded)
        publisher.require(downloaded.stat().st_size == asset['size'], 'Test ZIP size differs from GitHub metadata')
        original = publisher.inspect_archive(downloaded, resolution['test_tag'],
                                             publisher.feed_url(channel='test'), channel='test')
        if asset.get('digest'):
            publisher.require(asset['digest'] == 'sha256:' + original['sha256'], 'Test ZIP checksum differs from GitHub metadata')
        verify_tagged_source(root, downloaded, resolution, temporary / 'rebuilt-test')

        source = temporary / 'source'
        copy_source(root, source)
        manifest = json.loads(builder.read_resource(source, source / 'manifest.json'))
        manifest['version'] = stable_version
        manifest['id'], manifest['name'] = config().id, config().name
        manifest['updates']['feed'] = publisher.feed_url()
        (source / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        readme = builder.read_resource(source, source / 'README.md').decode('utf-8')
        (source / 'README.md').write_bytes(clean_readme(readme).encode('utf-8'))
        archive = builder.package(source, temporary / 'stable', 'v' + stable_version, 'stable')

        # Changing channel must not change tested artwork, audio, loading or UI behaviour.
        before, after = contents(downloaded, config('test').id), contents(archive, config().id)
        publisher.require(before.keys() == after.keys(), 'Promotion changed the packaged resource list')
        for name in before:
            if name == 'manifest.json':
                expected = json.loads(before[name])
                expected.update(id=config().id, name=config().name, version=stable_version)
                expected['updates']['feed'] = publisher.feed_url()
                publisher.require(json.loads(after[name]) == expected, 'Promotion changed host or state requirements')
            elif name == 'main.lua':
                code = before[name].decode('utf-8')
                old_name, old_version = 'local PACK_NAME = "Switch UI Test"', f'local PACK_VERSION = "{test_version}"'
                publisher.require(code.count(old_name) == 1 and code.count(old_version) == 1,
                                  'Unsupported test UI identity markers')
                expected = code.replace(old_name, 'local PACK_NAME = "Switch UI"').replace(
                    old_version, f'local PACK_VERSION = "{stable_version}"').encode('utf-8')
                publisher.require(after[name] == expected, 'Promotion changed the tested Lua behaviour')
            elif name == 'README.md':
                publisher.require(after[name] == clean_readme(before[name].decode('utf-8')).encode('utf-8'),
                                  'Unexpected documentation change')
            elif name in DOCUMENTS:
                publisher.require(after[name].replace(b'\r\n', b'\n') == before[name].replace(b'\r\n', b'\n'),
                                  'Promotion changed document ' + name)
            else:
                publisher.require(after[name] == before[name], 'Promotion changed tested resource ' + name)

        stable = publisher.inspect_archive(archive, 'v' + stable_version, publisher.feed_url())
        result = {'repository': publisher.REPOSITORY, 'test_tag': resolution['test_tag'],
                  'tested_commit': resolution['commit'], 'test_zip_sha256': original['sha256'],
                  'stable_tag': 'v' + stable_version, 'stable_zip': archive.name,
                  'stable_zip_sha256': stable['sha256'], 'stable_zip_bytes': stable['bytes'],
                  'stable_feed': publisher.feed_url(), 'published': False,
                  'verification': 'Published test ZIP matches tagged source (documentation line endings normalized); runtime changes limited to pack name and version.'}
        shutil.copy2(archive, output / archive.name)
        shutil.copy2(archive.with_name(archive.name + '.sha256'), output / (archive.name + '.sha256'))
        (output / 'promotion.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    resolving = commands.add_parser('resolve', help='Validate an existing test release and resolve its exact source commit')
    resolving.add_argument('--test-tag', required=True)
    resolving.add_argument('--stable-version', default='')
    resolving.add_argument('--output', type=Path, required=True)
    building = commands.add_parser('build', help='Verify the test source/ZIP and package it for stable')
    building.add_argument('--root', type=Path, required=True)
    building.add_argument('--resolution', type=Path, required=True)
    building.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    publisher.require(os.environ.get('GITHUB_REPOSITORY', publisher.REPOSITORY) == publisher.REPOSITORY,
                      'This action is configured for ' + publisher.REPOSITORY)
    if args.command == 'resolve':
        result = resolve(ReadOnlyGitHub(os.environ.get('GH_TOKEN', '')), args.test_tag, args.stable_version)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        if destination := os.environ.get('GITHUB_OUTPUT'):
            with open(destination, 'a', encoding='utf-8') as stream:
                stream.write(f"commit={result['commit']}\nstable_version={result['stable_version']}\n")
    else:
        result = build(args.root, args.output, json.loads(args.resolution.read_text(encoding='utf-8')))
        if destination := os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(destination, 'a', encoding='utf-8') as stream:
                stream.write(f"## Stable ZIP ready\n\nTest: `{result['test_tag']}`\n\n"
                             f"Tested commit: `{result['tested_commit']}`\n\n"
                             f"Download **SwitchLauncher-{result['stable_tag'][1:]}-release** under Artifacts below. "
                             f"Extract it and attach **{result['stable_zip']}** to a normal **{result['stable_tag']}** release.\n\n"
                             "The existing Publish launcher update feed workflow updates the stable feed after you publish. "
                             "This build did not publish a release or modify a feed, branch or tag.\n")
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (publisher.ApiError, ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from None
