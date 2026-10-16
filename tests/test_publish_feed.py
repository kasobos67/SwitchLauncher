# SPDX-License-Identifier: GPL-3.0-or-later
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('publisher', Path(__file__).parents[1] / 'tools/publish_feed.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def make_zip(path, version='1.003.007', feed=None, extra=None):
    manifest = {'schema': 1, 'id': 'switch-ui', 'version': version, 'host_contract': 'launcher-v1.0',
                'api': {'major': 1, 'min_minor': 1}, 'state_schema': 1,
                'required_capabilities': ['updates.launcher-packs.v1'],
                'updates': {'feed': feed or p.feed_url()}, 'entry': 'main.lua', 'font': 'font.pefont',
                'assets': {'icons': 'icons.tga'}}
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('switch-ui/manifest.json', json.dumps(manifest))
        archive.writestr('switch-ui/main.lua', 'return {}')
        archive.writestr('switch-ui/font.pefont', b'font fixture')
        archive.writestr('switch-ui/icons.tga', b'image fixture')
        if extra:
            archive.writestr(*extra)
    return path


def entry(version):
    return {'version': version, 'url': 'https://github.com/' + p.REPOSITORY + '/releases/download/v' + version + '/SwitchLauncher-' + version + '.zip',
            'sha256': 'a' * 64, 'bytes': 100, 'host_contract': 'launcher-v1.0',
            'api': {'major': 1, 'min_minor': 1}, 'required_capabilities': [], 'state_schema': 1, 'min_app': p.MIN_APP}


class FakeGitHub:
    def __init__(self, archive, tag='v1.003.007'):
        self.archive = archive
        self.private = False
        self.branch = False
        self.raw = None
        self.sha = 'first'
        self.writes = 0
        self.conflict = False
        self.release = {'id': 7, 'tag_name': tag, 'draft': False, 'body': 'Release notes'}
        self.assets = [{'name': archive.name, 'state': 'uploaded', 'size': archive.stat().st_size,
                        'browser_download_url': entry(tag[1:])['url'],
                        'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]

    def request(self, method, path, body=None):
        prefix = '/repos/' + p.REPOSITORY
        if path == prefix:
            return {'private': self.private, 'default_branch': 'main'}
        if '/releases/tags/' in path:
            return self.release
        if '/releases/7/assets' in path:
            return self.assets
        if '/git/ref/heads/main' in path:
            return {'object': {'sha': 'main-sha'}}
        if '/git/ref/heads/' + p.BRANCH in path:
            if not self.branch:
                raise p.ApiError(404, 'No branch')
            return {'object': {'sha': 'feed-sha'}}
        if method == 'POST' and path.endswith('/git/refs'):
            self.branch = True
            return {}
        if '/contents/launcher-updates.json' in path:
            if method == 'GET':
                if self.raw is None:
                    raise p.ApiError(404, 'No feed')
                return {'encoding': 'base64', 'content': base64.b64encode(self.raw).decode(),
                        'sha': self.sha, 'size': len(self.raw)}
            if method == 'PUT':
                if self.conflict:
                    self.conflict = False
                    self.raw = p.merge_feed({'schema': 1, 'id': 'switch-ui', 'releases': []}, entry('1.003.006'))
                    self.sha = 'concurrent'
                    raise p.ApiError(409, 'Concurrent update')
                if self.raw is not None and body.get('sha') != self.sha:
                    raise p.ApiError(409, 'Stale SHA')
                self.raw = base64.b64decode(body['content'])
                self.sha += '-next'
                self.writes += 1
                return {}
        raise AssertionError((method, path))

    def fetch(self, url, destination):
        if url != entry(self.release['tag_name'][1:])['url']:
            raise AssertionError(url)
        shutil.copy2(self.archive, destination)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = make_zip(self.root / 'SwitchLauncher-1.003.007.zip')

    def tearDown(self):
        self.temporary.cleanup()

    def test_versioned_archive_metadata(self):
        item = p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())
        self.assertEqual(item['version'], '1.003.007')
        self.assertEqual(item['sha256'], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertEqual(item['bytes'], self.archive.stat().st_size)
        self.assertEqual(item['url'], entry('1.003.007')['url'])

    def test_tag_mismatch_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'tag and manifest'):
            p.inspect_archive(self.archive, 'v1.003.008', p.feed_url())

    def test_feed_migration_is_rejected(self):
        make_zip(self.archive, feed='https://example.com/another-feed.json')
        with self.assertRaisesRegex(ValueError, 'permanent feed'):
            p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())

    def test_unsafe_archive_entries_are_rejected(self):
        for name in ['switch-ui/../outside', '/absolute', 'switch-ui/C:drive', 'other/main.lua']:
            with self.subTest(name=name):
                make_zip(self.archive, extra=(name, 'bad'))
                with self.assertRaisesRegex(ValueError, 'resource path'):
                    p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())
        link = zipfile.ZipInfo('switch-ui/link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        make_zip(self.archive, extra=(link, '/tmp/outside'))
        with self.assertRaisesRegex(ValueError, 'Links'):
            p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())

    def test_duplicate_zip_entries_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            make_zip(self.archive, extra=('switch-ui/main.lua', 'duplicate'))
        with self.assertRaisesRegex(ValueError, 'Duplicate archive'):
            p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())

    def test_merge_preserves_older_versions_and_sorts_numerically(self):
        first = {'schema': 1, 'id': 'switch-ui', 'releases': [entry('1.003.010')]}
        result = json.loads(p.merge_feed(first, entry('1.003.009')))
        self.assertEqual([r['version'] for r in result['releases']], ['1.003.010', '1.003.009'])

    def test_published_archive_cannot_be_changed_in_place(self):
        previous = {'schema': 1, 'id': 'switch-ui', 'releases': [entry('1.003.007')]}
        changed = entry('1.003.007');changed['sha256'] = 'b' * 64
        with self.assertRaisesRegex(ValueError, 'Publish a new version'):
            p.merge_feed(previous, changed)

    def test_duplicate_numeric_versions_are_rejected(self):
        previous = {'schema': 1, 'id': 'switch-ui', 'releases': [entry('1.003.007'), entry('1.3.7')]}
        with self.assertRaisesRegex(ValueError, 'Duplicate existing'):
            p.merge_feed(previous, entry('1.003.008'))

    def test_feed_retains_latest_64_versions(self):
        previous = {'schema': 1, 'id': 'switch-ui', 'releases': [entry('1.003.' + str(i)) for i in range(64)]}
        result = json.loads(p.merge_feed(previous, entry('1.003.64')))
        self.assertEqual(len(result['releases']), 64)
        self.assertEqual(result['releases'][0]['version'], '1.003.64')
        self.assertEqual(result['releases'][-1]['version'], '1.003.1')

    def test_first_publication_and_idempotent_rerun(self):
        api = FakeGitHub(self.archive)
        self.assertTrue(p.publish(api, 'v1.003.007', api.fetch)['changed'])
        self.assertTrue(api.branch)
        self.assertEqual(json.loads(api.raw)['releases'][0]['version'], '1.003.007')
        self.assertFalse(p.publish(api, 'v1.003.007', api.fetch)['changed'])
        self.assertEqual(api.writes, 1)

    def test_concurrent_feed_update_preserves_both_releases(self):
        api = FakeGitHub(self.archive);api.conflict = True
        item = p.inspect_archive(self.archive, 'v1.003.007', p.feed_url())
        self.assertTrue(p.commit_feed(api, item, pause=lambda _: None))
        self.assertEqual([r['version'] for r in json.loads(api.raw)['releases']], ['1.003.007', '1.003.006'])

    def test_private_repo_draft_missing_asset_and_wrong_digest_do_not_write(self):
        for failure in ['private', 'draft', 'prerelease', 'asset', 'digest', 'size']:
            with self.subTest(failure=failure):
                api = FakeGitHub(self.archive)
                if failure == 'private':api.private = True
                elif failure == 'draft':api.release['draft'] = True
                elif failure == 'prerelease':api.release['prerelease'] = True
                elif failure == 'asset':api.assets = []
                elif failure == 'digest':api.assets[0]['digest'] = 'sha256:' + '0' * 64
                else:api.assets[0]['size'] = p.MAX_ARCHIVE + 1
                with self.assertRaises(ValueError):p.publish(api, 'v1.003.007', api.fetch)
                self.assertEqual(api.writes, 0)


if __name__ == '__main__':
    unittest.main()
