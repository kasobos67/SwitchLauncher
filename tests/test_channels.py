# SPDX-License-Identifier: GPL-3.0-or-later
import base64
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

from tools import build_release as builder
from tools import publish_feed as publisher
from tools.channels import config
import test_build_release as fixtures


class ChannelGitHub:
    """Separate remote branches with recorded writes; no network or credentials."""
    def __init__(self, archive, channel):
        self.archive = archive
        self.channel = channel
        self.selected = config(channel)
        self.version = '1.003.009'
        self.tag = self.selected.tag_prefix + self.version
        self.release = {'id': 9, 'tag_name': self.tag, 'draft': False,
                        'prerelease': self.selected.prerelease, 'body': 'Channel fixture'}
        self.url = f'https://github.com/{publisher.REPOSITORY}/releases/download/{self.tag}/{archive.name}'
        self.assets = [{'name': archive.name, 'state': 'uploaded', 'size': archive.stat().st_size,
                        'browser_download_url': self.url,
                        'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]
        self.branches = {}
        self.writes = []
        self.conflict = False

    def request(self, method, path, body=None):
        prefix = '/repos/' + publisher.REPOSITORY
        if path == prefix:
            return {'private': False, 'default_branch': 'main'}
        if path == prefix + '/releases/tags/' + self.tag:
            return self.release
        if path == prefix + '/releases/9/assets?per_page=100':
            return self.assets
        if path == prefix + '/git/ref/heads/main':
            return {'object': {'sha': 'main-head'}}
        if path == prefix + '/git/ref/heads/' + self.selected.feed_branch:
            if self.selected.feed_branch not in self.branches:
                raise publisher.ApiError(404, 'No branch')
            return {'object': {'sha': 'feed-head'}}
        if method == 'POST' and path == prefix + '/git/refs':
            self.assert_branch(body['ref'].removeprefix('refs/heads/'))
            self.branches[self.selected.feed_branch] = None
            return {}
        if method == 'GET' and path == prefix + '/contents/launcher-updates.json?ref=' + self.selected.feed_branch:
            raw = self.branches.get(self.selected.feed_branch)
            if raw is None:
                raise publisher.ApiError(404, 'No feed')
            return {'encoding': 'base64', 'size': len(raw), 'sha': str(len(raw)),
                    'content': base64.b64encode(raw).decode()}
        if method == 'PUT' and path == prefix + '/contents/launcher-updates.json':
            self.assert_branch(body['branch'])
            if self.conflict:
                self.conflict = False
                item = publisher.inspect_archive(self.archive, self.tag,
                           publisher.feed_url(channel=self.channel), channel=self.channel)
                item['version'] = '1.003.008'
                item['url'] = item['url'].replace('1.003.009', '1.003.008')
                self.branches[body['branch']] = publisher.merge_feed(
                    {'schema': 1, 'id': self.selected.id, 'releases': []}, item, self.channel)
                raise publisher.ApiError(409, 'Concurrent update')
            self.branches[body['branch']] = base64.b64decode(body['content'])
            self.writes.append(body['branch'])
            return {}
        raise AssertionError((method, path))

    def assert_branch(self, branch):
        if branch != self.selected.feed_branch:
            raise AssertionError('Publisher wrote to the other channel: ' + branch)

    def fetch(self, url, destination):
        if url != self.url:
            raise AssertionError(url)
        shutil.copy2(self.archive, destination)


class ChannelTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.PackageTests()
        self.fixture.setUp()
        self.root = self.fixture.root
        self.output = self.fixture.output

    def tearDown(self):
        self.fixture.tearDown()

    def build(self, channel):
        return builder.package(self.root, self.output, channel=channel)

    def test_test_pack_identity_feed_name_and_assets(self):
        stable = self.build('stable')
        test = self.build('test')
        with zipfile.ZipFile(stable) as a, zipfile.ZipFile(test) as b:
            manifest = json.loads(b.read('switch-ui-test/manifest.json'))
            self.assertEqual(manifest['id'], 'switch-ui-test')
            self.assertEqual(manifest['name'], 'Switch UI Test')
            self.assertEqual(manifest['updates']['feed'], publisher.feed_url(channel='test'))
            self.assertIn(b'PACK_NAME = "Switch UI Test"', b.read('switch-ui-test/main.lua'))
            self.assertEqual({n.removeprefix('switch-ui/') for n in a.namelist()},
                             {n.removeprefix('switch-ui-test/') for n in b.namelist()})
            for name in a.namelist():
                if '/assets/' in name or name.endswith('loading.json'):
                    self.assertEqual(a.read(name), b.read(name.replace('switch-ui/', 'switch-ui-test/', 1)))
            old = json.loads(a.read('switch-ui/manifest.json'))
            for key in ['api', 'state_schema', 'host_contract', 'required_capabilities']:
                self.assertEqual(old[key], manifest[key])

    def test_test_source_builds_test_by_default_and_can_promote_to_stable(self):
        manifest = self.fixture.manifest
        manifest['id'] = 'switch-ui-test'
        manifest['updates']['feed'] = publisher.feed_url(channel='test')
        self.fixture.write_manifest()
        self.assertEqual(builder.package(self.root, self.output).name, 'SwitchLauncher-Test-1.003.009.zip')
        with zipfile.ZipFile(self.build('stable')) as zipped:
            self.assertEqual(json.loads(zipped.read('switch-ui/manifest.json'))['updates']['feed'], publisher.feed_url())

    def test_feed_and_tags_cannot_be_crossed(self):
        stable, test = self.build('stable'), self.build('test')
        for channel, wrong_tag in [('stable', 'test-v1.003.009'), ('test', 'v1.003.009')]:
            with self.subTest(channel=channel), self.assertRaises(ValueError):
                publisher.tag_version(wrong_tag, channel)
        with self.assertRaises(ValueError):
            publisher.inspect_archive(test, 'v1.003.009', publisher.feed_url())
        with self.assertRaises(ValueError):
            publisher.inspect_archive(stable, 'test-v1.003.009', publisher.feed_url(channel='test'), channel='test')
        with self.assertRaises(ValueError):
            publisher.inspect_archive(test, 'test-v1.003.009', publisher.feed_url(), channel='test')

    def test_test_feed_rejects_stable_identity(self):
        test = self.build('test')
        item = publisher.inspect_archive(test, 'test-v1.003.009', publisher.feed_url(channel='test'), channel='test')
        with self.assertRaisesRegex(ValueError, 'another launcher'):
            publisher.merge_feed({'schema': 1, 'id': 'switch-ui', 'releases': []}, item, 'test')

    def test_both_publishers_write_only_their_feed_and_rerun_cleanly(self):
        for channel in ['stable', 'test']:
            with self.subTest(channel=channel):
                api = ChannelGitHub(self.build(channel), channel)
                self.assertTrue(publisher.publish(api, api.tag, api.fetch, channel)['changed'])
                raw = api.branches[config(channel).feed_branch]
                self.assertEqual(json.loads(raw)['id'], config(channel).id)
                self.assertFalse(publisher.publish(api, api.tag, api.fetch, channel)['changed'])
                self.assertEqual(api.writes, [config(channel).feed_branch])

    def test_test_release_must_be_published_prerelease_with_correct_archive(self):
        for fault in ['draft', 'not-prerelease', 'wrong-pack', 'bad-digest']:
            with self.subTest(fault=fault):
                api = ChannelGitHub(self.build('test'), 'test')
                if fault == 'draft': api.release['draft'] = True
                elif fault == 'not-prerelease': api.release['prerelease'] = False
                elif fault == 'wrong-pack': shutil.copy2(self.build('stable'), api.archive)
                else: api.assets[0]['digest'] = 'sha256:' + '0' * 64
                with self.assertRaises(ValueError):
                    publisher.publish(api, api.tag, api.fetch, 'test')
                self.assertEqual(api.writes, [])

    def test_test_feed_conflict_preserves_other_test_release(self):
        api = ChannelGitHub(self.build('test'), 'test')
        api.conflict = True
        item = publisher.inspect_archive(api.archive, api.tag, publisher.feed_url(channel='test'), channel='test')
        publisher.commit_feed(api, item, pause=lambda _: None, channel='test')
        self.assertEqual([r['version'] for r in json.loads(api.branches['test-update-feed'])['releases']],
                         ['1.003.009', '1.003.008'])

    def test_published_test_version_is_immutable(self):
        api = ChannelGitHub(self.build('test'), 'test')
        publisher.publish(api, api.tag, api.fetch, 'test')
        item = json.loads(api.branches['test-update-feed'])['releases'][0]
        item['sha256'] = 'a' * 64
        with self.assertRaisesRegex(ValueError, 'new version'):
            publisher.commit_feed(api, item, channel='test')
        self.assertEqual(api.writes, ['test-update-feed'])

    def test_unknown_channel_and_wrong_build_tag_rejected(self):
        with self.assertRaises(ValueError): self.build('beta')
        with self.assertRaises(ValueError): builder.package(self.root, self.output, 'v1.003.009', 'test')


if __name__ == '__main__':
    unittest.main()
