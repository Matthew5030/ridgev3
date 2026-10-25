#!/usr/bin/env python3
"""Upgrade only a local fixture's overview; retain all existing adaptive meshes.
For published sources, prepare a new versioned directory before running this.
"""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('--pack',type=Path,required=True);p.add_argument('--world',type=Path,required=True);a=p.parse_args()
m=json.loads((a.pack/'pack.json').read_bytes());lod=next(l for l in m['levels'] if l['spacing']==1)
raw=(a.pack/lod['file']).read_bytes();assert hashlib.sha256(raw).hexdigest()==lod['sha256']
h=np.frombuffer(raw,dtype='<i2').reshape(lod['height'],lod['width'])
coarse=h[::8,::8].astype(float)*m['heightScale'];coarse=np.where(h[::8,::8]==m['noDataValue'],0,coarse)
# Decimetre source precision; do not publish floating-point serialization noise.
coarse=np.round(coarse,1)
data=json.dumps(dict(width=coarse.shape[1],height=coarse.shape[0],heights=coarse.ravel().tolist()),separators=(',',':'),allow_nan=False).encode()
name='overview-8m.json';(a.world/name).write_bytes(data)
index=json.loads((a.world/'world.json').read_bytes());index['overview']=dict(file=name,byteCount=len(data),sha256=hashlib.sha256(data).hexdigest());index['revision']='2026-10-04-v2'
(a.world/'world.json').write_text(json.dumps(index,separators=(',',':')))
print(f'Overview: {coarse.shape}, {len(data):,} bytes. Adaptive files unchanged.')
