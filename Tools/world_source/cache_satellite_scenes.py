#!/usr/bin/env python3
"""Durably cache original Sentinel visual/SCL GeoTIFFs, with resumable downloads."""
import argparse, concurrent.futures, fcntl, hashlib, json, os, time, urllib.request
from pathlib import Path
from pack_sections import atomic,raw


def fetch(asset,cache):
    folder=cache/'assets';folder.mkdir(exist_ok=True,parents=True)
    file=folder/(asset['id']+'-'+asset['kind']+'.tif');receipt=file.with_suffix('.json')
    if file.exists() and receipt.exists():
        saved=json.loads(receipt.read_bytes())
        if saved['url']==asset['url'] and file.stat().st_size==saved['bytes']==asset['bytes']:return saved
        raise ValueError('Cached asset identity mismatch: '+str(file))
    partial=file.with_suffix('.part');metadata=file.with_suffix('.part.json')
    if partial.exists() and partial.stat().st_size == asset['bytes']:
        digest=hashlib.sha256()
        with partial.open('rb') as stream:
            while chunk:=stream.read(1024*1024):digest.update(chunk)
        etag=json.loads(metadata.read_bytes()).get('etag') if metadata.exists() else None
        record=dict(asset,etag=etag,sha256=digest.hexdigest())
        atomic(receipt,raw(record));partial.replace(file);metadata.unlink(missing_ok=True)
        return record
    for attempt in range(6):
        try:
            offset=partial.stat().st_size if partial.exists() else 0
            headers={}
            if offset:
                headers['Range']=f'bytes={offset}-'
                if metadata.exists():
                    etag=json.loads(metadata.read_bytes()).get('etag')
                    if etag:headers['If-Range']=etag
            with urllib.request.urlopen(urllib.request.Request(asset['url'],headers=headers),timeout=90) as response:
                if offset and response.status!=206:
                    # A changed object must never be appended to an old partial.
                    partial.rename(partial.with_suffix('.previous-part'));offset=0
                if offset and not response.headers.get('Content-Range','').startswith(f'bytes {offset}-'):
                    raise ValueError('Incorrect resumed range')
                etag=response.headers.get('ETag')
                atomic(metadata,raw(dict(url=asset['url'],etag=etag)))
                with partial.open('ab' if offset else 'wb') as output:
                    while chunk:=response.read(1024*1024):output.write(chunk)
            if partial.stat().st_size!=asset['bytes']:raise ValueError('Incomplete satellite asset')
            digest=hashlib.sha256()
            with partial.open('rb') as stream:
                while chunk:=stream.read(1024*1024):digest.update(chunk)
            record=dict(asset,etag=etag,sha256=digest.hexdigest())
            atomic(receipt,raw(record));partial.replace(file);metadata.unlink(missing_ok=True)
            print(json.dumps(dict(event='saved-original',scene=asset['id'],kind=asset['kind'],bytes=asset['bytes'])),flush=True)
            return record
        except Exception:
            if attempt==5:raise
            time.sleep(min(30,2**attempt))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--cache',type=Path,required=True);p.add_argument('--workers',type=int,default=6)
    a=p.parse_args();a.cache.mkdir(parents=True,exist_ok=True)
    guard=(a.cache/'.download.lock').open('w');fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB)
    assets=json.loads((a.cache/'asset-sizes.json').read_bytes())
    # Prioritise the already approved Snowdon scene and its cloud-gap alternatives.
    priority=['S2C_30UVD_20250712_0_L2A','S2B_30UVD_20250518_0_L2A','S2C_30UVD_20250516_0_L2A']
    plan=json.loads((a.cache/'scene-plan.json').read_bytes())
    tile={s['item']['id']:(s['item']['properties']['mgrs:utm_zone'],s['item']['properties']['mgrs:latitude_band'],s['item']['properties']['mgrs:grid_square']) for s in plan['selected']}
    assets.sort(key=lambda x:(priority.index(x['id']) if x['id'] in priority else 99,tile[x['id']],x['id'],x['kind']))
    done=[];errors=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:
        jobs={pool.submit(fetch,x,a.cache):x for x in assets}
        for job in concurrent.futures.as_completed(jobs):
            try:done.append(job.result())
            except Exception as e:errors.append(dict(asset=jobs[job],error=repr(e)))
            atomic(a.cache/'download-status.json',raw(dict(completed=len(done),total=len(assets),bytes=sum(x['bytes'] for x in done),errors=errors,updated=time.time())))
    if errors:raise RuntimeError(str(len(errors))+' satellite downloads failed; partial files retained')
