#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Publish verified release metadata to a stable launcher feed branch."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen
import zipfile

REPOSITORY = 'kasobos67/SwitchLauncher'
BRANCH = 'update-feed'
IDENTIFIER = 'switch-ui'
ASSET_PREFIX = 'SwitchLauncher'
MIN_APP = '1.003.000'
MAX_ARCHIVE = 128 * 1024**2
MAX_FEED = 256 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}', value),
            'Version must have three numeric components')
    return tuple(map(int, value.split('.')))


def feed_url(repository=REPOSITORY):
    return f'https://raw.githubusercontent.com/{repository}/{BRANCH}/launcher-updates.json'


class ApiError(RuntimeError):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


class GitHub:
    def __init__(self, token):
        require(bool(token), 'GH_TOKEN is required')
        self.token = token

    def request(self, method, path, body=None):
        prefix = '/repos/' + REPOSITORY
        require(path == prefix or path.startswith(prefix + '/'), 'Unexpected API repository')
        encoded = None if body is None else json.dumps(body).encode()
        request = Request('https://api.github.com' + path, data=encoded, method=method, headers={
            'Authorization': 'Bearer ' + self.token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'SwitchLauncher-feed-publisher',
            'Content-Type': 'application/json',
        })
        try:
            with urlopen(request, timeout=60) as response:
                raw = response.read(2 * 1024**2 + 1)
                require(len(raw) <= 2 * 1024**2, 'API response exceeded limit')
                return json.loads(raw)
        except HTTPError as error:
            # Error bodies and authentication headers are deliberately not logged.
            raise ApiError(error.code, f'GitHub API returned HTTP {error.code} for {method} {path}') from None


def download(url, destination):
    require(url.startswith('https://github.com/' + REPOSITORY + '/releases/download/'), 'Unexpected release download URL')
    request = Request(url, headers={'User-Agent': 'SwitchLauncher-feed-publisher'})
    size = 0
    with urlopen(request, timeout=120) as response, destination.open('wb') as output:
        require(response.geturl().startswith('https://'), 'Download redirected away from HTTPS')
        while chunk := response.read(64 * 1024):
            size += len(chunk)
            require(size <= MAX_ARCHIVE, 'Release ZIP exceeds 128 MiB')
            output.write(chunk)


def inspect_archive(path, tag, expected_feed, repository=REPOSITORY):
    expected_version = tag.removeprefix('v')
    version(expected_version)
    require(tag == 'v' + expected_version, 'Use release tags such as v1.003.009')
    require(0 < path.stat().st_size <= MAX_ARCHIVE, 'Invalid archive size')
    names = set()
    expanded = 0
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= 4096, 'Invalid archive file count')
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            require(name.startswith(IDENTIFIER + '/') and not name.startswith('/') and
                    all(part not in ('.', '..', '') for part in name.rstrip('/').split('/')) and
                    len(parts) <= 21 and len(name.encode()) <= 240 and
                    not any(ord(c) < 32 or ord(c) == 127 or c in ':\\' for c in name),
                    'Invalid archive resource path')
            require(name not in names, 'Duplicate archive path')
            names.add(name)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR) and not stat.S_ISLNK(mode), 'Links and special files are forbidden')
            require(not entry.flag_bits & 1 and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                    'Unsupported or encrypted archive entry')
            require(entry.file_size <= 64 * 1024**2, 'Resource exceeds 64 MiB')
            expanded += entry.file_size
            require(expanded <= 256 * 1024**2, 'Archive expands beyond 256 MiB')
        manifest_name = IDENTIFIER + '/manifest.json'
        require(manifest_name in names and archive.getinfo(manifest_name).file_size <= 64 * 1024, 'Missing or oversized manifest')
        manifest = json.loads(archive.read(manifest_name))
        require(manifest.get('schema') == 1 and manifest.get('id') == IDENTIFIER, 'Wrong launcher identity')
        require(manifest.get('version') == expected_version, 'Release tag and manifest version differ')
        require(manifest.get('updates', {}).get('feed') == expected_feed, 'Pack has the wrong permanent feed address')
        api = manifest.get('api', {})
        require(api.get('major') == 1 and type(api.get('min_minor')) is int and api['min_minor'] >= 0,
                'Unsupported runtime API metadata')
        require(manifest.get('host_contract') == 'launcher-v1.0', 'Unsupported host contract')
        state = manifest.get('state_schema', 1)
        require(type(state) is int and 1 <= state <= 2147483647, 'Invalid state schema')
        capabilities = manifest.get('required_capabilities', [])
        require(isinstance(capabilities, list) and all(isinstance(c, str) for c in capabilities), 'Invalid capabilities')
        resources = [manifest['entry'], manifest['font'], *manifest['assets'].values()]
        for resource in resources:
            require(isinstance(resource, str) and IDENTIFIER + '/' + resource in names, 'Missing required resource')
        require(archive.testzip() is None, 'Archive CRC check failed')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        'version': expected_version,
        'host_contract': manifest['host_contract'],
        'api': api,
        'required_capabilities': capabilities,
        'state_schema': state,
        'url': f'https://github.com/{repository}/releases/download/{quote(tag, safe="")}/{ASSET_PREFIX}-{expected_version}.zip',
        'sha256': digest,
        'bytes': path.stat().st_size,
        'min_app': MIN_APP,
    }


def merge_feed(previous, release):
    require(previous.get('schema') == 1 and previous.get('id') == IDENTIFIER, 'Existing feed belongs to another launcher')
    releases = previous.get('releases')
    require(isinstance(releases, list) and len(releases) <= 64, 'Invalid existing feed')
    indexed = {}
    for item in releases:
        key = version(item['version'])
        require(key not in indexed, 'Duplicate existing release version')
        indexed[key] = item
    key = version(release['version'])
    if key in indexed:
        existing = indexed[key]
        require(all(existing.get(field) == release.get(field) for field in (
            'url', 'sha256', 'bytes', 'host_contract', 'api', 'required_capabilities', 'state_schema', 'min_app')),
            'Published version has changed. Publish a new version instead of replacing its ZIP.')
    indexed[key] = release
    # Preserve the newest 64 entries, including older host-compatible releases.
    result = {'schema': 1, 'id': IDENTIFIER, 'releases': [indexed[k] for k in sorted(indexed, reverse=True)[:64]]}
    encoded = (json.dumps(result, indent=2, ensure_ascii=False) + '\n').encode()
    require(len(encoded) <= MAX_FEED, 'Feed exceeds 256 KiB')
    return encoded


def ensure_branch(api):
    prefix = '/repos/' + REPOSITORY
    try:
        api.request('GET', prefix + '/git/ref/heads/' + BRANCH)
        return
    except ApiError as error:
        if error.status != 404:
            raise
    repo = api.request('GET', prefix)
    require(not repo.get('private'), 'The repository must be public')
    head = api.request('GET', prefix + '/git/ref/heads/' + quote(repo['default_branch'], safe=''))
    try:
        api.request('POST', prefix + '/git/refs', {'ref': 'refs/heads/' + BRANCH, 'sha': head['object']['sha']})
    except ApiError as error:
        if error.status != 422:
            raise
        # A simultaneous publication may have created the branch first.
        api.request('GET', prefix + '/git/ref/heads/' + BRANCH)


def commit_feed(api, release, pause=time.sleep):
    ensure_branch(api)
    path = '/repos/' + REPOSITORY + '/contents/launcher-updates.json'
    for attempt in range(6):
        try:
            current = api.request('GET', path + '?ref=' + BRANCH)
        except ApiError as error:
            if error.status != 404:
                raise
            current = None
        if current:
            require(current.get('encoding') == 'base64' and current.get('size', MAX_FEED + 1) <= MAX_FEED,
                    'Existing feed is oversized or unreadable')
            raw = base64.b64decode(current['content'])
            require(len(raw) <= MAX_FEED, 'Existing feed exceeds 256 KiB')
            previous = json.loads(raw)
        else:
            raw = b''
            previous = {'schema': 1, 'id': IDENTIFIER, 'releases': []}
        updated = merge_feed(previous, release)
        if updated == raw:
            return False
        body = {'message': 'Publish SwitchLauncher ' + release['version'], 'branch': BRANCH,
                'content': base64.b64encode(updated).decode()}
        if current:
            body['sha'] = current['sha']
        try:
            api.request('PUT', path, body)
            return True
        except ApiError as error:
            if error.status not in (409, 422) or attempt == 5:
                raise
            # Retry against the new blob SHA without losing another release's entry.
            pause(attempt + 1)
    raise RuntimeError('Feed update retry limit reached')


def publish(api, tag, fetch=download):
    version(tag.removeprefix('v'))
    require(tag.startswith('v'), 'Use a versioned release tag such as v1.003.009')
    prefix = '/repos/' + REPOSITORY
    repo = api.request('GET', prefix)
    require(not repo.get('private'), 'The repository must be public')
    release = api.request('GET', prefix + '/releases/tags/' + quote(tag, safe=''))
    require(not release.get('draft'), 'Publish the release before updating its feed')
    require(not release.get('prerelease'), 'Prereleases are excluded from the stable update feed')
    require(release.get('tag_name') == tag, 'Unexpected release tag')
    filename = ASSET_PREFIX + '-' + tag[1:] + '.zip'
    assets = api.request('GET', prefix + '/releases/' + str(release['id']) + '/assets?per_page=100')
    matches = [asset for asset in assets if asset.get('name') == filename and asset.get('state') == 'uploaded']
    require(len(matches) == 1, 'Attach ' + filename + ' to the release before publishing, then retry this workflow')
    asset = matches[0]
    require(type(asset.get('size')) is int and 0 < asset['size'] <= MAX_ARCHIVE, 'Invalid uploaded asset size')
    expected_url = f'https://github.com/{REPOSITORY}/releases/download/{quote(tag, safe="")}/{filename}'
    require(asset.get('browser_download_url') == expected_url, 'Release asset has an unexpected download address')
    with tempfile.TemporaryDirectory(prefix='launcher-publisher-') as temporary:
        path = Path(temporary) / filename
        fetch(expected_url, path)
        require(path.stat().st_size == asset['size'], 'Downloaded asset size differs from GitHub metadata')
        entry = inspect_archive(path, tag, feed_url())
    if asset.get('digest'):
        require(asset['digest'] == 'sha256:' + entry['sha256'], 'Downloaded asset checksum differs from GitHub metadata')
    notes = release.get('body') or ''
    entry['notes'] = notes.encode()[:8192].decode('utf-8', errors='ignore')
    changed = commit_feed(api, entry)
    return {'version': entry['version'], 'feed': feed_url(), 'changed': changed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    require(os.environ.get('GITHUB_REPOSITORY', REPOSITORY) == REPOSITORY, 'This publisher is configured for ' + REPOSITORY)
    result = publish(GitHub(os.environ.get('GH_TOKEN', '')), args.tag)
    print(json.dumps(result, indent=2))
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a', encoding='utf-8') as output:
            output.write(f"Published **SwitchLauncher {result['version']}** to the [stable feed]({result['feed']}).\n")


if __name__ == '__main__':
    try:
        main()
    except (ApiError, ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from None
