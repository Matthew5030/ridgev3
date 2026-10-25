#!/usr/bin/env python3
"""Check a prepared source against its original, including every shared gutter."""
import argparse
import base64
import hashlib
import json
import zlib
from pathlib import Path


def check(original, prepared):
    before = json.loads((original / 'world.json').read_bytes())
    after = json.loads((prepared / 'world.json').read_bytes())
    for key in ('id', 'bounds', 'columns', 'rows', 'overview', 'graph', 'places'):
        assert before[key] == after[key], key
    assert len(before['tiles']) == len(after['tiles'])
    maps = {}
    for old, new in zip(before['tiles'], after['tiles']):
        assert {k:v for k,v in old.items() if k != 'map'} == {k:v for k,v in new.items() if k != 'map'}
        for key in ('mesh', 'background'):
            if key in new:
                asset = new[key]
                assert hashlib.sha256((prepared / asset['path']).read_bytes()).hexdigest() == asset['sha256']
        decoded = []
        for root, tile in [(original, old), (prepared, new)]:
            asset = tile['map']; data = (root / asset['file']).read_bytes()
            assert len(data) == asset['byteCount'] and hashlib.sha256(data).hexdigest() == asset['sha256']
            unpacked = zlib.decompress(data)
            assert len(unpacked) == asset['decodedByteCount']
            decoded.append(json.loads(unpacked))
        samples = decoded[1].pop('groundColour', None)
        decoded[0].pop('groundColour', None)
        assert decoded[0] == decoded[1], 'Vector geometry changed'
        if samples:
            samples['data'] = base64.b64decode(samples['rgba'], validate=True)
            assert len(samples['data']) == samples['width'] * samples['height'] * 4
            maps[new['column'], new['row']] = samples
    edges = 0
    for (x,y), a in maps.items():
        w,h,b = a['width'],a['height'],a['border']; data = a['data']
        if (x+1,y) in maps:
            right = maps[x+1,y]
            assert (w,h,b) == (right['width'],right['height'],right['border'])
            for row in range(h):
                assert data[(row*w+w-2*b)*4:(row*w+w)*4] == right['data'][row*w*4:(row*w+2*b)*4], 'Horizontal seam'
            edges += 1
        if (x,y+1) in maps:
            below = maps[x,y+1]
            assert data[(h-2*b)*w*4:] == below['data'][:2*b*w*4], 'Vertical seam'
            edges += 1
    print(f'PASS {len(after["tiles"])} tiles: terrain, vectors, paths, places, routing unchanged; {edges} colour gutters match exactly')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original', type=Path)
    parser.add_argument('prepared', type=Path)
    args = parser.parse_args()
    check(args.original, args.prepared)
