#!/usr/bin/env python3
"""Verify compressed park chunks through the running static download server."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import zlib
from compact_codec import CompactCodec

p = argparse.ArgumentParser()
p.add_argument('server')
p.add_argument('--output', type=Path)
a = p.parse_args()
base = a.server.rstrip('/')


def get(path, headers=None):
    with urlopen(Request(base + path, headers=headers or {}), timeout=60) as response:
        return response.status, response.read()


def verified(raw, entry):
    assert len(raw) == entry['byteCount']
    assert hashlib.sha256(raw).hexdigest() == entry['sha256']


catalog = json.loads(get('/adaptive-catalog.json')[1])
results = []
for entry in catalog['sources']:
    prefix = '/' + entry['id'] + '/'
    raw = get(prefix + 'adaptive.json')[1]
    verified(raw, entry)
    m = json.loads(raw)
    assert m['id'] == entry['id'] and m['requiredReader'] in ['rme1-zlib-v1','rat1-zlib-v1']
    codec=CompactCodec() if m['requiredReader']=='rat1-zlib-v1' else None
    assert b'/Volumes/' not in raw and b'/Users/' not in raw
    chunks = m['chunks']
    chosen = sorted(set([0, len(chunks)//2, len(chunks)-1,
                         min(range(len(chunks)), key=lambda k: chunks[k]['byteCount']),
                         max(range(len(chunks)), key=lambda k: chunks[k]['byteCount'])]))
    checked = []
    for index in chosen:
        c = chunks[index]
        raw = get(prefix + c['path'])[1]
        verified(raw, c)
        data = zlib.decompress(raw)
        if codec:
            assert len(data)==c['topologyByteCount'] and hashlib.sha256(data).hexdigest()==c['topologySHA256']
            data=codec.decode(data)
        assert len(data) == c['decodedByteCount']
        assert hashlib.sha256(data).hexdigest() == c['decodedSHA256']
        magic, nv, nt, width, grid, scale, offset = struct.unpack('<4s4I2f', data[:28])
        assert (magic, nv, nt, width, grid) == (b'RME1', c['vertices'], c['triangles'], c['indexWidth'], 513)
        assert len(data) == 28 + nv*6 + nt*3*width
        status, partial = get(prefix + c['path'], {'Range': 'bytes=0-31'})
        assert status == 206 and partial == raw[:32]
        checked.append(dict(id=c['id'], bytes=len(raw), decodedBytes=len(data)))
    for path, info in m['assets'].items():
        verified(get(prefix + path)[1], info)
    for private in ['manifest.json', 'REPORT.md', '.publish.lock']:
        try:
            get(prefix + private)
            raise AssertionError('Private build file was served')
        except HTTPError as error:
            assert error.code == 404
    results.append(dict(id=m['id'], checkedChunks=checked, byteRangeDelivery=True,
                        totalChunks=len(chunks), totalMeshBytes=m['byteCount'],
                        coveragePercent=100*(1-m['uncoveredParkAreaKm2']/m['parkAreaKm2'])))
assert get('/health')[0] == 200
normal = json.loads(get('/catalog.json')[1])
assert not set(c['id'] for c in catalog['sources']) & set(c['id'] for c in normal['sources'])
try:
    urlopen(Request(base + '/adaptive-catalog.json', data=b'no', method='POST'))
    raise AssertionError('Server accepted a write')
except HTTPError as error:
    assert error.code == 403
report = dict(server=base, parks=results, normalCatalogueSeparate=True, writesRefused=True)
if a.output:
    a.output.write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
