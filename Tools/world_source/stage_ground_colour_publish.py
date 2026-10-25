#!/usr/bin/env python3
"""Stage a prepared colour source and all affected immutable download archives.

No publication: output is a new catalogue tree for validation before installation.
Unchanged sources are read-only references to the existing published tree.
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from pack_sections import build as section, raw
from pack_region import build as region


def stage(world, prepared, output):
    if output.exists():
        raise ValueError('Staging output must be a new directory')
    original = (world / 'catalog.json').read_bytes()
    catalog = json.loads(original)
    manifest = json.loads((prepared / 'world.json').read_bytes())
    target = next(s for s in catalog['sources'] if s['id'] == manifest['id'])
    old_folder = world / Path(target['path']).parent
    before = (old_folder / 'world.json').read_bytes()
    provenance = json.loads((prepared / 'ground-colour-provenance.json').read_bytes())
    if hashlib.sha256(before).hexdigest() != provenance['inputManifestSHA256']:
        raise ValueError('Published source has changed since colour preparation')
    output.mkdir(parents=True)
    (output / 'sources').mkdir()
    folder = output / Path(target['path']).parent
    shutil.copytree(prepared, folder)
    if target.get('routing'):
        shutil.copyfile(old_folder / target['routing']['file'], folder / target['routing']['file'])
    for source in catalog['sources']:
        if source['id'] != target['id']:
            (output / Path(source['path']).parent).symlink_to((world / Path(source['path']).parent).resolve(), target_is_directory=True)
    target['pack'] = section(output, target)
    target['downloadBytes'] += provenance['addedMapBytes']
    catalog['revision'] += '-ground-v1'
    (output / 'catalog.json').write_bytes(raw(catalog))
    affected = [a for a in catalog.get('regionArchives', []) if target['id'] in a['sourceIDs']]
    # Preserve the exact published membership, including shared park sections.
    zones = output / 'affected-regions.json'
    zones.write_bytes(raw(dict(regions=[dict(id=a['id'], cells=[dict(id=s) for s in a['sourceIDs']]) for a in affected])))
    for archive in affected:
        result = region(output, zones, archive['id'], publish=True)
        print(archive['id'], result['asset']['byteCount'], flush=True)
    (output / 'catalog.before.json').write_bytes(original)
    (output / 'world.before.json').write_bytes(before)
    return dict(sourceID=target['id'], affectedRegions=[a['id'] for a in affected], section=target['pack'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--world', type=Path, required=True)
    parser.add_argument('--prepared', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(stage(args.world, args.prepared, args.output), indent=2), flush=True)
