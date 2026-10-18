#!/usr/bin/env python3
"""Wrap existing section packs in one indexed region file; no terrain rebuild."""
import argparse
import base64
import hashlib
import json
import struct
import zlib
from pathlib import Path

from pack_sections import atomic, raw


def build(root, zones, region_id, publish=False):
    catalog = json.loads((root / 'catalog.json').read_bytes())
    library = json.loads(zones.read_bytes())
    zone = next(z for z in library['regions'] + library.get('parks', []) if z['id'] == region_id)
    ids = {c['id'] for c in zone['cells']}
    sources = sorted((s for s in catalog['sources'] if s['id'] in ids), key=lambda s: s['id'])
    if not 1 <= len(sources) <= 128:
        raise ValueError('Region has no data or too many sections')
    members, offset = [], 0
    for source in sources:
        manifest = json.loads((root / source['path']).read_bytes())
        if source.get('routing'):
            manifest['graph'] = source['routing']
        data = raw(manifest)
        if len(data) > 16_000_000:
            raise ValueError('Oversized manifest')
        members.append(dict(sourceID=source['id'], offset=offset, asset=source['pack'],
                            manifest=base64.b64encode(zlib.compress(data, 6)).decode(),
                            manifestBytes=len(data)))
        offset += source['pack']['byteCount']
    index = raw(dict(schemaVersion=1, regionID=region_id, members=members))
    if len(index) > 8_000_000 or sum(m['manifestBytes'] for m in members) > 32_000_000:
        raise ValueError('Oversized region index')
    folder = root / 'region-packs'
    folder.mkdir(exist_ok=True)
    temp = folder / (region_id + '.tmp')
    digest = hashlib.sha256()
    try:
        with temp.open('wb') as output:
            header = b'RIDGERG1' + struct.pack('<I', len(index)) + index
            output.write(header)
            digest.update(header)
            for source, member in zip(sources, members):
                path = root / Path(source['path']).parent / member['asset']['file']
                section_digest, count = hashlib.sha256(), 0
                with path.open('rb') as stream:
                    while chunk := stream.read(1024 * 1024):
                        output.write(chunk)
                        digest.update(chunk)
                        section_digest.update(chunk)
                        count += len(chunk)
                if count != member['asset']['byteCount'] or section_digest.hexdigest() != member['asset']['sha256']:
                    raise ValueError('Damaged section pack: ' + source['id'])
        if temp.stat().st_size > 1024 * 1024 * 1024:
            raise ValueError('Region exceeds 1 GiB')
        asset = dict(file='region-' + digest.hexdigest() + '.ridgepack',
                     byteCount=temp.stat().st_size, sha256=digest.hexdigest())
        temp.replace(folder / asset['file'])
        descriptor = dict(id=region_id, asset=asset, sourceIDs=[s['id'] for s in sources])
        atomic(folder / (region_id + '.json'), raw(descriptor))
        if publish:
            current = json.loads((root / 'catalog.json').read_bytes())
            lookup = {s['id']: s for s in current['sources']}
            if any(lookup.get(s['id']) != s for s in sources):
                raise ValueError('Catalogue changed during build')
            archives = {a['id']: a for a in current.get('regionArchives', [])}
            archives[region_id] = descriptor
            current['regionArchives'] = list(archives.values())
            atomic(root / 'catalog.json', raw(current))
        return descriptor
    finally:
        temp.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('zones', type=Path)
    parser.add_argument('--region', required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    print(json.dumps(build(args.root, args.zones, args.region, args.publish)), flush=True)
