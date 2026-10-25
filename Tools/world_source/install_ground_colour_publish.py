#!/usr/bin/env python3
"""Install a verified colour staging tree; retain old immutable assets for rollback.

Run only after the server accepts cNN-rNN-ground-<16 hex>.map URLs and serves
world.json with Cache-Control: no-cache. Backups are written before metadata.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from pack_sections import atomic


def digest_stream(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def install(world, staged, backup):
    before = (staged / 'catalog.before.json').read_bytes()
    if (world / 'catalog.json').read_bytes() != before:
        raise ValueError('Live catalogue changed; restage before publishing')
    old_catalog = json.loads(before)
    new_catalog = json.loads((staged / 'catalog.json').read_bytes())
    changed = [s for s in new_catalog['sources'] if s != next(o for o in old_catalog['sources'] if o['id'] == s['id'])]
    if len(changed) != 1:
        raise ValueError('Expected exactly one updated source')
    source = changed[0]; relative = Path(source['path']).parent
    if (world / source['path']).read_bytes() != (staged / 'world.before.json').read_bytes():
        raise ValueError('Live source changed; restage before publishing')
    manifest = json.loads((staged / source['path']).read_bytes())
    objects = [(relative / t['map']['file'], t['map']) for t in manifest['tiles']]
    objects.append((relative / source['pack']['file'], source['pack']))
    affected = [a for a in new_catalog.get('regionArchives', []) if source['id'] in a['sourceIDs']]
    objects += [(Path('region-packs') / a['asset']['file'], a['asset']) for a in affected]
    # Verify all new objects before installing any live metadata.
    for path, asset in objects:
        file = staged / path
        with file.open('rb') as stream:
            digest = digest_stream(stream)
        if file.stat().st_size != asset['byteCount'] or digest != asset['sha256']:
            raise ValueError('Damaged staged object: ' + str(path))
    backup.mkdir(parents=True, exist_ok=False)
    (backup / 'catalog.json').write_bytes(before)
    (backup / 'world.json').write_bytes((staged / 'world.before.json').read_bytes())
    (backup / 'source-path.txt').write_text(source['path'] + '\n')
    for path, asset in objects:
        destination = world / path
        if destination.exists():
            with destination.open('rb') as stream:
                if digest_stream(stream) != asset['sha256']:
                    raise ValueError('Immutable object collision: ' + str(path))
        else:
            temporary = destination.with_suffix(destination.suffix + '.ground-tmp')
            shutil.copyfile(staged / path, temporary)
            temporary.replace(destination)
    for name in ['ground-colour-provenance.json', 'ground-colour-scene.json', 'section-pack-v1.json']:
        atomic(world / relative / name, (staged / relative / name).read_bytes())
    # All old objects remain available to in-flight and cached old manifests.
    if (world / 'catalog.json').read_bytes() != before:
        raise ValueError('Catalogue changed during installation; objects installed, metadata untouched')
    atomic(world / source['path'], (staged / source['path']).read_bytes())
    atomic(world / 'catalog.json', (staged / 'catalog.json').read_bytes())
    for archive in affected:
        path = Path('region-packs') / (archive['id'] + '.json')
        atomic(world / path, (staged / path).read_bytes())
    print('Published', source['id'], 'and', len(affected), 'containing region archives; rollback metadata:', backup)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', type=Path, required=True)
    parser.add_argument('--staged', type=Path, required=True)
    parser.add_argument('--backup', type=Path, required=True)
    args = parser.parse_args()
    install(args.world, args.staged, args.backup)
