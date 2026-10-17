# SPDX-License-Identifier: GPL-3.0-or-later
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile
from tools import build_release as builder
from tools import publish_feed as publisher


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)/'repository'
        self.output = self.root.parent/'dist'
        (self.root/'src').mkdir(parents=True)
        (self.root/'assets/sounds').mkdir(parents=True)
        self.manifest = {'schema':1, 'id':'switch-ui', 'version':'1.003.009',
                         'host_contract':'launcher-v1.0', 'api':{'major':1,'min_minor':1},
                         'state_schema':1, 'entry':'main.lua', 'font':'assets/font.pefont',
                         'assets':{'profiles':'assets/profiles.tga'}, 'sounds':'assets/sounds',
                         'required_capabilities':['updates.launcher-packs.v1'],
                         'updates':{'feed':publisher.feed_url()}}
        self.write_manifest()
        (self.root/'src/motion.lua').write_text('local motion = {}\n')
        (self.root/'src/ui.lua').write_text('local PACK_VERSION = "@PACK_VERSION@"\nlocal PACK_NAME = "Switch UI"\nreturn {}\n')
        (self.root/'assets/profiles.tga.gz').write_bytes(gzip.compress(b'artwork fixture', mtime=0))
        (self.root/'assets/font.pefont').write_bytes(b'font fixture')
        (self.root/'assets/sounds/focus_01.wav').write_bytes(b'audio fixture')
        (self.root/'loading.json').write_text('{"atlas":"assets/profiles.tga"}')
        for name in ['README.md', 'LICENSE', 'ASSET_NOTICES.md']:
            (self.root/name).write_text('Fixture notice')

    def write_manifest(self):
        (self.root/'manifest.json').write_text(json.dumps(self.manifest))

    def tearDown(self):
        self.temporary.cleanup()

    def test_installable_archive_and_checksum(self):
        archive = builder.package(self.root, self.output, 'v1.003.009')
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(zipped.read('switch-ui/assets/profiles.tga'), b'artwork fixture')
            self.assertNotIn('switch-ui/assets/profiles.tga.gz', zipped.namelist())
            self.assertNotIn('switch-ui/src/ui.lua', zipped.namelist())
            self.assertNotIn('switch-ui/tools/build_release.py', zipped.namelist())
            self.assertIn(b'PACK_VERSION = "1.003.009"', zipped.read('switch-ui/main.lua'))
            self.assertIsNone(zipped.testzip())
        checksum = archive.with_name(archive.name+'.sha256').read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256(archive.read_bytes()).hexdigest())

    def test_build_is_reproducible(self):
        first = builder.package(self.root, self.output).read_bytes()
        self.assertEqual(first, builder.package(self.root, self.output).read_bytes())

    def test_mismatched_tag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'tag and manifest'):
            builder.package(self.root, self.output, 'v1.003.010')

    def test_wrong_feed_is_rejected(self):
        self.manifest['updates']['feed'] = 'https://example.com/other-feed.json'
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'permanent update feed'):
            builder.package(self.root, self.output)

    def test_duplicate_asset_is_rejected(self):
        (self.root/'assets/profiles.tga').write_bytes(b'duplicate')
        with self.assertRaisesRegex(ValueError, 'Duplicate packaged'):
            builder.package(self.root, self.output)

    def test_missing_loading_atlas_is_rejected(self):
        (self.root/'loading.json').write_text('{"atlas":"assets/missing.tga"}')
        with self.assertRaisesRegex(ValueError, 'Loading scene'):
            builder.package(self.root, self.output)

    def test_missing_recordings_are_rejected(self):
        shutil.rmtree(self.root/'assets/sounds')
        with self.assertRaisesRegex(ValueError, 'recordings'):
            builder.package(self.root, self.output)

    def test_version_marker_is_required(self):
        (self.root/'src/ui.lua').write_text('return {}')
        with self.assertRaisesRegex(ValueError, 'version marker'):
            builder.package(self.root, self.output)

    def test_missing_required_resource_is_rejected(self):
        (self.root/'assets/font.pefont').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing required resource'):
            builder.package(self.root, self.output)


if __name__ == '__main__':
    unittest.main()
