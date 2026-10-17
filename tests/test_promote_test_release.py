# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import hashlib
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import zipfile

from tools import build_release as builder, promote_test_release as promotion, publish_feed as publisher
import test_build_release as fixtures


class ReleaseAPI:
    """GET-only fixture. No credentials, network access or repository writes."""
    def __init__(self, archive):
        self.tag = 'test-v1.003.009'
        self.commit = 'a' * 40
        self.tag_object = {'type': 'commit', 'sha': self.commit}
        self.release = {'id': 9, 'tag_name': self.tag, 'prerelease': True, 'draft': False,
                        'target_commitish': 'moving-test-branch'}
        self.releases = [{'tag_name': 'v1.003.008', 'prerelease': False, 'draft': False}]
        self.url = f'https://github.com/{publisher.REPOSITORY}/releases/download/{self.tag}/{archive.name}'
        self.assets = [{'name': archive.name, 'state': 'uploaded', 'size': archive.stat().st_size,
                        'browser_download_url': self.url,
                        'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]
        self.requests = []

    def get(self, path):
        self.requests.append(path)
        prefix = promotion.PREFIX
        if path == prefix:
            return {'private': False}
        if path == prefix + '/releases/tags/' + self.tag:
            return self.release
        if path == prefix + '/releases/9/assets?per_page=100&page=1':
            return self.assets
        if path == prefix + '/releases?per_page=100&page=1':
            return self.releases
        if path == prefix + '/git/ref/tags/' + self.tag:
            return {'object': self.tag_object}
        if path == prefix + '/git/tags/' + 'b' * 40:
            return {'object': {'type': 'commit', 'sha': self.commit}}
        raise AssertionError(path)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.PackageTests()
        self.fixture.setUp()
        self.root, self.output = self.fixture.root, self.fixture.output
        (self.root / 'README.md').write_text('# SwitchLauncher\n\n> **Test branch:** Test installation notice.\n\nCredits.\n', encoding='utf-8')
        self.archive = builder.package(self.root, self.output / 'test', channel='test')
        self.api = ReleaseAPI(self.archive)

    def tearDown(self):
        self.fixture.tearDown()

    def resolve(self, stable_version=None):
        return promotion.resolve(self.api, self.api.tag, stable_version)

    def fetch(self, url, target):
        self.assertEqual(url, self.api.url)
        shutil.copy2(self.archive, target)

    def test_lightweight_tag_uses_commit_not_moving_branch(self):
        self.assertEqual(self.resolve()['commit'], self.api.commit)

    def test_annotated_tag_is_peeled_to_commit(self):
        self.api.tag_object = {'type': 'tag', 'sha': 'b' * 40}
        self.assertEqual(self.resolve()['commit'], self.api.commit)
        self.assertIn(promotion.PREFIX + '/git/tags/' + 'b' * 40, self.api.requests)

    def test_draft_and_non_test_releases_are_rejected(self):
        for field, value in [('draft', True), ('prerelease', False), ('tag_name', 'v1.003.009')]:
            with self.subTest(field=field):
                previous = self.api.release[field]
                self.api.release[field] = value
                with self.assertRaises(ValueError):
                    self.resolve()
                self.api.release[field] = previous

    def test_invalid_inputs_fail_before_api_access(self):
        for tag, version in [('v1.003.009', None), ('test-v1.0.0\ninjected=yes', None),
                             ('test-v1.0.0/../main', None), ('test-v1.003.009', '$(bad)'),
                             ('test-v1.003.009', '1.2.3\nfoo=bar')]:
            with self.subTest(tag=tag, version=version), self.assertRaises(ValueError):
                promotion.resolve(self.api, tag, version)
        self.assertEqual(self.api.requests, [])

    def test_old_or_existing_numeric_stable_versions_are_rejected(self):
        for value in ['1.003.008', '1.3.8', '1.003.007']:
            with self.subTest(version=value), self.assertRaisesRegex(ValueError, 'newer'):
                self.resolve(value)
        self.api.releases.append({'tag_name': 'v1.003.009', 'prerelease': False, 'draft': False})
        with self.assertRaisesRegex(ValueError, 'newer'):
            self.resolve()
        self.assertEqual(self.resolve('1.003.010')['stable_version'], '1.003.010')

    def test_missing_wrong_duplicate_and_oversized_assets_are_rejected(self):
        for fault in ['missing', 'duplicate', 'url', 'size', 'digest']:
            original = copy.deepcopy(self.api.assets)
            if fault == 'missing': self.api.assets = []
            elif fault == 'duplicate': self.api.assets *= 2
            elif fault == 'url': self.api.assets[0]['browser_download_url'] = 'https://example.com/test.zip'
            elif fault == 'size': self.api.assets[0]['size'] = publisher.MAX_ARCHIVE + 1
            else: self.api.assets[0]['digest'] = 'sha256:wrong'
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                self.resolve()
            self.api.assets = original

    def test_tag_must_refer_to_a_commit(self):
        for obj in [{'type': 'tree', 'sha': 'a' * 40}, {'type': 'commit', 'sha': 'moving-branch'}]:
            self.api.tag_object = obj
            with self.assertRaises(ValueError):
                self.resolve()

    def test_build_changes_identity_feed_and_optional_version_only(self):
        result = promotion.build(self.root, self.output / 'promoted', self.resolve('1.003.010'), self.fetch)
        stable = self.output / 'promoted' / result['stable_zip']
        with zipfile.ZipFile(stable) as packed, zipfile.ZipFile(self.archive) as tested:
            manifest = json.loads(packed.read('switch-ui/manifest.json'))
            self.assertEqual(manifest['id'], 'switch-ui')
            self.assertEqual(manifest['name'], 'Switch UI')
            self.assertEqual(manifest['version'], '1.003.010')
            self.assertEqual(manifest['updates']['feed'], publisher.feed_url())
            self.assertIn(b'PACK_NAME = "Switch UI"', packed.read('switch-ui/main.lua'))
            self.assertIn(b'PACK_VERSION = "1.003.010"', packed.read('switch-ui/main.lua'))
            self.assertNotIn(b'**Test branch:**', packed.read('switch-ui/README.md'))
            self.assertIn(b'Credits.', packed.read('switch-ui/README.md'))
            for name in tested.namelist():
                if '/assets/' in name or name.endswith('loading.json'):
                    self.assertEqual(tested.read(name), packed.read(name.replace('switch-ui-test/', 'switch-ui/', 1)))
        self.assertFalse(result['published'])
        self.assertEqual(result['tested_commit'], self.api.commit)
        self.assertEqual(result['stable_zip_sha256'], hashlib.sha256(stable.read_bytes()).hexdigest())
        self.assertEqual(json.loads((self.output/'promoted/promotion.json').read_text()), result)
        # Tested source and ZIP are not edited in place.
        self.assertEqual(json.loads((self.root / 'manifest.json').read_text())['version'], '1.003.009')
        self.assertEqual(hashlib.sha256(self.archive.read_bytes()).hexdigest(), result['test_zip_sha256'])

    def test_build_accepts_test_identity_source(self):
        self.fixture.manifest['id'] = 'switch-ui-test'
        self.fixture.manifest['updates']['feed'] = publisher.feed_url(channel='test')
        self.fixture.write_manifest()
        promotion.build(self.root, self.output / 'promoted', self.resolve(), self.fetch)

    def test_source_zip_mismatch_fails_without_release_artifact(self):
        with (self.root / 'src/ui.lua').open('a') as stream:
            stream.write('-- untested change\n')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            promotion.build(self.root, self.output / 'promoted', self.resolve(), self.fetch)
        self.assertEqual(list((self.output / 'promoted').glob('*.zip')), [])

    def test_github_document_line_ending_normalization_is_allowed(self):
        for name in promotion.DOCUMENTS:
            path = self.root / name
            path.write_bytes(path.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
        self.archive = builder.package(self.root, self.output / 'test', channel='test')
        self.api = ReleaseAPI(self.archive)
        for name in promotion.DOCUMENTS:
            path = self.root / name
            path.write_bytes(path.read_bytes().replace(b'\r\n', b'\n'))
        promotion.build(self.root, self.output / 'promoted', self.resolve(), self.fetch)

    def test_download_digest_and_size_mismatches_are_rejected(self):
        for key, value in [('digest', 'sha256:' + '0' * 64), ('size', self.archive.stat().st_size + 1)]:
            resolution = self.resolve()
            resolution['asset'][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'differs'):
                promotion.build(self.root, self.output / 'promoted', resolution, self.fetch)

    def test_no_github_write_method_exists(self):
        self.assertEqual([n for n in vars(promotion.ReadOnlyGitHub) if not n.startswith('_')], ['get'])
        with patch.object(promotion, 'urlopen') as remote:
            response = remote.return_value.__enter__.return_value
            response.read.return_value = b'{}'
            promotion.ReadOnlyGitHub().get(promotion.PREFIX)
            self.assertEqual(remote.call_args.args[0].get_method(), 'GET')
        with self.assertRaises(ValueError):
            promotion.ReadOnlyGitHub().get('/repos/other/repo')


if __name__ == '__main__':
    unittest.main()
