#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the installable launcher ZIP from this repository. No Git or network access."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import zipfile

try:
    from . import publish_feed as publisher
    from .channels import config, for_identifier, CHANNELS
except ImportError:
    import publish_feed as publisher
    from channels import config, for_identifier, CHANNELS

MAX_FILE = 64 * 1024**2
MAX_EXPANDED = 256 * 1024**2


def read_resource(root, path):
    root = root.resolve()
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        publisher.require(not current.is_symlink(), 'Source links are not allowed')
    publisher.require(path.resolve().is_relative_to(root) and path.is_file(), 'Invalid source file')
    publisher.require(path.stat().st_size <= MAX_FILE, 'Source file exceeds 64 MiB')
    return path.read_bytes()


def package(root, output, tag=None, channel=None):
    root = Path(root).resolve()
    output = Path(output).resolve()
    publisher.require(not output.is_relative_to(root/'assets') and not output.is_relative_to(root/'src'),
                      'Output cannot be inside the launcher source or artwork')
    manifest = json.loads(read_resource(root, root/'manifest.json'))
    source_channel = for_identifier(manifest.get('id'))
    publisher.require(manifest.get('schema') == 1, 'Wrong launcher identity')
    publisher.require(manifest.get('updates', {}).get('feed') == publisher.feed_url(channel=source_channel),
                      'Wrong permanent update feed')
    channel = source_channel if channel is None else channel
    selected = config(channel)
    manifest['id'] = selected.id
    manifest['name'] = selected.name
    manifest['updates']['feed'] = publisher.feed_url(channel=channel)
    version = manifest['version']
    publisher.version(version)
    publisher.require(tag is None or tag == selected.tag_prefix+version, 'Release tag and manifest version differ')
    ui = read_resource(root, root/'src/ui.lua').decode('utf-8').replace('\r\n', '\n')
    motion = read_resource(root, root/'src/motion.lua').decode('utf-8').replace('\r\n', '\n')
    marker = 'local PACK_VERSION = "@PACK_VERSION@"'
    publisher.require(ui.count(marker) == 1, 'Expected one version marker in src/ui.lua')
    ui = ui.replace(marker, 'local PACK_VERSION = "'+version+'"')
    name_marker = 'local PACK_NAME = "Switch UI"'
    publisher.require(ui.count(name_marker) == 1, 'Expected one pack-name marker in src/ui.lua')
    ui = ui.replace(name_marker, 'local PACK_NAME = '+json.dumps(selected.name))
    payload = {'main.lua': (motion+'\n'+ui).encode()}
    payload['manifest.json'] = (json.dumps(manifest, indent=2)+'\n').encode()
    for name in ['loading.json', 'README.md', 'LICENSE', 'ASSET_NOTICES.md']:
        payload[name] = read_resource(root, root/name)
    for path in sorted((root/'assets').rglob('*')):
        publisher.require(not path.is_symlink(), 'Source links are not allowed')
        if path.is_dir():
            continue
        name = path.relative_to(root).as_posix()
        data = read_resource(root, path)
        if name.endswith('.gz'):
            name = name[:-3]
            with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
                data = compressed.read(MAX_FILE+1)
            publisher.require(len(data) <= MAX_FILE, 'Expanded resource exceeds 64 MiB')
        publisher.require(name not in payload, 'Duplicate packaged resource')
        publisher.require(all(part not in ('', '.', '..') for part in name.split('/')) and
                          len(PurePosixPath(name).parts) <= 20, 'Invalid resource path')
        payload[name] = data
    publisher.require(len(payload) <= 4096 and sum(map(len, payload.values())) <= MAX_EXPANDED,
                      'Launcher exceeds resource limits')
    scene = json.loads(payload['loading.json'])
    publisher.require(scene.get('atlas') in payload, 'Loading scene artwork is missing')
    publisher.require(any(name.startswith(manifest.get('sounds', '')+'/') and name.endswith('.wav')
                          for name in payload), 'Launcher recordings are missing')
    output.mkdir(parents=True, exist_ok=True)
    archive = output/publisher.asset_name(version, channel)
    temporary = archive.with_suffix('.zip.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zipped:
            for name, data in sorted(payload.items()):
                entry = zipfile.ZipInfo(selected.id+'/'+name, date_time=(2026, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                zipped.writestr(entry, data)
        publisher.inspect_archive(temporary, selected.tag_prefix+version, publisher.feed_url(channel=channel), channel=channel)
        temporary.replace(archive)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n', encoding='utf-8')
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--tag', help='Expected release tag, for example v1.003.009')
    parser.add_argument('--channel', choices=CHANNELS, help='Build stable or test; defaults to the manifest identity')
    args = parser.parse_args()
    archive = package(args.root, args.output or args.root/'dist', args.tag, args.channel)
    print(archive)


if __name__ == '__main__':
    main()
