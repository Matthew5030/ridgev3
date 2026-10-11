#!/usr/bin/env python3
"""Bundle verified coarse UK elevation, aligned with the 48-cell detailed grid."""
import argparse, hashlib, json, math, struct, zlib
from pathlib import Path

def build(source, output):
    manifest = json.loads(source.read_text())
    output.mkdir(parents=True, exist_ok=True)
    parts = []
    for part in manifest['partitions']:
        compressed = (source.parent / part['path']).read_bytes()
        assert len(compressed) == part['byteCount'] and hashlib.sha256(compressed).hexdigest() == part['sha256']
        raw = zlib.decompress(compressed)
        assert hashlib.sha256(raw).hexdigest() == part['decodedSHA256']
        heights = struct.unpack('<'+'h'*(513*513), raw)
        samples = []
        for y in range(49):
            py = y*512/48; iy = int(py); jy = min(512,iy+1); ty = py-iy
            for x in range(49):
                px=x*512/48; ix=int(px); jx=min(512,ix+1); tx=px-ix
                h=[heights[iy*513+ix], heights[iy*513+jx], heights[jy*513+ix], heights[jy*513+jx]]
                samples.append(-32768 if -32768 in h else round(h[0]*(1-tx)*(1-ty)+h[1]*tx*(1-ty)+h[2]*(1-tx)*ty+h[3]*tx*ty))
        data=struct.pack('<'+'h'*len(samples),*samples)
        name=part['id']+'.bin'; (output/name).write_bytes(data)
        parts.append(dict(id=part['id'],bounds=part['bounds'],file=name,sha256=hashlib.sha256(data).hexdigest()))
    result=dict(schemaVersion=1,side=49,scaleMetres=.1,noDataValue=-32768,parts=parts,source=manifest['source'],sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest())
    (output/'index.json').write_text(json.dumps(result,separators=(',',':'))+'\n')
    print(f'{len(parts)} verified height pages; {sum(p.stat().st_size for p in output.iterdir())} bytes')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args();build(a.source,a.output)
