#!/usr/bin/env python3
"""Losslessly repack an existing RME1 download under a new immutable RAT1 ID."""
import argparse
import concurrent.futures
import fcntl
import json
import re
from pathlib import Path
import time
import zlib
from compact_codec import CompactCodec
from publish_adaptive import atomic_json, digest, publish_catalog


def repack(source, directory, workers=4):
    original=(source/'adaptive.json').read_bytes();m=json.loads(original)
    if m['requiredReader']!='rme1-zlib-v1':raise ValueError('Expected legacy RME1 compressed source')
    geometry_id=m.get('geometrySourceID',m['id']);identifier=geometry_id+'-compact-v1'
    if not re.fullmatch(r'[a-zA-Z0-9_-]+',identifier):raise ValueError('Unsafe source identifier')
    if set(m['assets'])!={'boundary.geojson','coverage-gaps.geojson'}:raise ValueError('Unexpected source assets')
    out=directory/identifier;out.mkdir(parents=True,exist_ok=True)
    with (out/'.publish.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if (out/'adaptive.json').exists():
            existing=json.loads((out/'adaptive.json').read_text())
            if existing['repackedFrom']['sha256']!=digest(original):raise ValueError('Published revision is immutable')
            publish_catalog(directory);return out
        codec=CompactCodec();started=time.monotonic()
        def convert(c):
            if not re.fullmatch(r'[a-zA-Z0-9_-]+',c['id']) or c['path']!=f"mesh-{c['id']}.rmesh.zlib":raise ValueError('Unsafe chunk path')
            compressed=(source/c['path']).read_bytes()
            if len(compressed)!=c['byteCount'] or digest(compressed)!=c['sha256']:raise ValueError('Original download checksum')
            raw=zlib.decompress(compressed)
            if len(raw)!=c['decodedByteCount'] or digest(raw)!=c['decodedSHA256']:raise ValueError('Original mesh checksum')
            topology=codec.encode(raw) # Rejects unless original RME1 reconstructs byte-for-byte.
            data=zlib.compress(topology,6)
            if zlib.decompress(data)!=topology:raise ValueError('Compression round-trip')
            result=dict(c,path=f"mesh-{c['id']}.rat.zlib",byteCount=len(data),sha256=digest(data),
                        topologyByteCount=len(topology),topologySHA256=digest(topology))
            path=out/result['path'];temporary=path.with_suffix('.tmp')
            if not path.exists() or digest(path.read_bytes())!=result['sha256']:
                temporary.write_bytes(data);temporary.replace(path)
            return result
        chunks=[]
        with concurrent.futures.ThreadPoolExecutor(workers) as pool:
            for chunk in pool.map(convert,m['chunks']):
                chunks.append(chunk)
                if len(chunks)%500==0:print(f'{identifier}: {len(chunks)}/{len(m["chunks"])}',flush=True)
        for filename,entry in m['assets'].items():
            data=(source/filename).read_bytes()
            if len(data)!=entry['byteCount'] or digest(data)!=entry['sha256']:raise ValueError('Boundary checksum')
            (out/filename).write_bytes(data)
        result=dict(m,id=identifier,geometrySourceID=geometry_id,requiredReader='rat1-zlib-v1',
                    storage='independent-zlib-rat1',payloadFormat='RAT1',chunks=chunks,
                    byteCount=sum(c['byteCount'] for c in chunks),
                    topologyByteCount=sum(c['topologyByteCount'] for c in chunks),
                    legacyDownloadByteCount=m['byteCount'],
                    encoderSourceSHA256=digest(Path(__file__).with_name('compact_mesh.cpp').read_bytes()),
                    repackedFrom=dict(id=m['id'],sha256=digest(original)),
                    repackSeconds=round(time.monotonic()-started,3))
        atomic_json(out/'adaptive.json',result)
        print(json.dumps(dict(id=identifier,legacyBytes=m['byteCount'],compactBytes=result['byteCount'],
                             exactMeshReconstruction=True,seconds=result['repackSeconds'])),flush=True)
    publish_catalog(directory)
    return out


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('directory',type=Path)
    p.add_argument('--workers',type=int,default=4);a=p.parse_args()
    if not 1<=a.workers<=16:p.error('Use 1–16 workers')
    repack(a.source,a.directory,a.workers)
