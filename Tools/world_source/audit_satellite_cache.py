#!/usr/bin/env python3
"""Verify every selected original's stored checksum and raster metadata, offline."""
import argparse,concurrent.futures,hashlib,json
from pathlib import Path
import rasterio
from pack_sections import atomic,raw


def audit(cache,workers=4):
    assets=json.loads((cache/'asset-sizes.json').read_bytes())
    def verify(asset):
        file=cache/'assets'/(asset['id']+'-'+asset['kind']+'.tif')
        receipt=json.loads(file.with_suffix('.json').read_bytes())
        if file.stat().st_size!=asset['bytes'] or receipt['url']!=asset['url']:raise ValueError('Asset identity mismatch: '+str(file))
        digest=hashlib.sha256()
        with file.open('rb') as stream:
            while chunk:=stream.read(1024*1024):digest.update(chunk)
        if digest.hexdigest()!=receipt['sha256']:raise ValueError('Cached image checksum mismatch: '+str(file))
        with rasterio.open(file) as dataset:
            if dataset.crs is None or dataset.count!=(3 if asset['kind']=='visual' else 1):raise ValueError('Unexpected satellite raster')
            shape=[dataset.width,dataset.height];crs=str(dataset.crs)
        return dict(scene=asset['id'],kind=asset['kind'],sha256=receipt['sha256'],bytes=asset['bytes'],shape=shape,crs=crs)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:checked=list(pool.map(verify,assets))
    result=dict(verifiedFiles=len(checked),bytes=sum(x['bytes'] for x in checked),networkRequests=0,assets=checked)
    atomic(cache/'verification.json',raw(result));print(json.dumps({k:v for k,v in result.items() if k!='assets'},indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cache',type=Path,required=True);p.add_argument('--workers',type=int,default=4);a=p.parse_args();audit(a.cache,a.workers)
