#!/usr/bin/env python3
"""Recover omitted EA input without changing the original Welsh selection.

Selection uses verified survey polygons for every missing native child, rather
than the first country rectangle containing its parent centre. Original WCS
responses and native samples are kept gzip-compressed with SHA-256 receipts.
"""
import argparse, concurrent.futures, fcntl, gzip, hashlib, json, math, shutil, sys, time
import urllib.request, urllib.parse
from pathlib import Path
import numpy as np
import rasterio
from rasterio.io import MemoryFile
from pyproj import datadir, Transformer
from pyproj.transformer import TransformerGroup
from shapely.geometry import box, shape
from survey_coverage import SurveyCoverage


def sha(data): return hashlib.sha256(data).hexdigest()
def raw(value): return json.dumps(value,separators=(',',':'),allow_nan=False).encode()
def atomic(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp');tmp.write_bytes(data);tmp.replace(path)
def emit(**fields): print(json.dumps(dict(time=time.time(),**fields)),flush=True)


def child_bounds(bounds,x,y):
    w,s,e,n=[bounds[k] for k in ('minLongitude','minLatitude','maxLongitude','maxLatitude')]
    return dict(minLongitude=w+x/48*(e-w),maxLongitude=w+(x+1)/48*(e-w),
                minLatitude=n-(y+1)/48*(n-s),maxLatitude=n-y/48*(n-s))


def validate_response(data):
    if not data.startswith((b'II*\0',b'MM\0*')):raise ValueError('EA did not return a GeoTIFF')
    with MemoryFile(data) as mem:
        with mem.open() as ds:
            if ds.crs.to_epsg()!=27700 or ds.res!=(1.,1.):raise ValueError('Expected genuine 1 m EA source')
            # A truncated TIFF can have a valid header and georeferencing.
            # Decode every block before accepting the original response.
            ds.read(1)


def missing_candidates(row,selected,survey,land,ownership):
    coverage=survey.for_bounds(row['bounds'])
    if coverage.is_empty:return []
    found=[]
    for y in range(48):
        for x in range(48):
            px,py,cx,cy=x//4,y//4,x%4,y%4
            ident=f"{row['id']}-c{px:02d}-{py:02d}-p{cx:02d}-{cy:02d}"
            if ident in selected:continue
            b=child_bounds(row['bounds'],x,y)
            if not land.intersects(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])):continue
            envelope=survey.envelope(b)
            if any(owner.intersects(envelope) for owner in ownership):continue
            if coverage.covers(envelope):found.append(dict(id=ident,bounds=b,parentX=px,parentY=py,childX=cx,childY=cy))
    return found


def make_plan(a):
    path=a.cache/'plan.json'
    plan_raw=(a.previous/'plan.json').read_bytes();base=json.loads(plan_raw)
    config_raw=(a.mapping/'config/england-wales-precision.json').read_bytes();config=json.loads(config_raw)
    sampler=a.mapping/'scripts/build_snowdon_pyramid.py'
    identity=dict(previousPlanSHA256=sha(plan_raw),configSHA256=sha(config_raw),samplerSHA256=sha(sampler.read_bytes()),
                  surveyIndexSHA256=sha((a.coverage/'index.json').read_bytes()),
                  coordinateGrids={p.name:sha(p.read_bytes()) for p in sorted(a.grids.glob('*.tif'))})
    if path.exists():
        plan=json.loads(path.read_bytes())
        if plan['identity']!=identity:raise ValueError('Preparation inputs changed; use a new cache revision')
        return plan
    survey=SurveyCoverage(a.coverage,a.grids)
    land=shape(json.loads((a.previous/'boundary.geojson').read_bytes())['geometry'])
    policy=json.loads((a.previous/'source-policy.json').read_bytes())
    rows=[]
    for row in base['partitions']:
        manifests=[json.loads(Path(m['path']).read_bytes()) for m in row['sourceManifests']]
        if not any(m.get('sourceKey')=='wales' for m in manifests):continue
        prior=json.loads((a.previous/'selection'/(row['id']+'.json')).read_bytes())
        ownership=[box(*r['bounds']) for r in policy['rules'] if (Path(r['sourceRoot'])/f"tiles/10/{row['id'].split('-x')[1].split('-')[0]}/{row['id'].split('-y')[1]}/manifest.json").exists()]
        chunks=missing_candidates(row,{c['id'] for c in prior['chunks']},survey,land,ownership)
        if chunks:
            rows.append(dict(id=row['id'],bounds=row['bounds'],existingChunks=len(prior['chunks']),chunks=chunks))
            emit(event='planned',section=row['id'],missingEnglishCandidates=len(chunks))
    rows.sort(key=lambda r:(r['id'] not in ['z10-x504-y336','z10-x504-y337'],r['id']))
    plan=dict(version='england-border-repair-v1',identity=identity,source=config['sources']['england'],
              officialSurveyCoverage=survey.provenance,sections=rows,candidateChunks=sum(len(r['chunks']) for r in rows),
              policy='Keep every previously selected child. For omitted children, require the complete EA survey footprint plus 2 m support. Preserve existing explicit source-ownership exclusions.')
    atomic(path,raw(plan));emit(event='plan-complete',sections=len(rows),candidateChunks=plan['candidateChunks'])
    return plan


def fetch_parent(a,source,row,px,py):
    b=row['bounds'];w,s,e,n=[b[k] for k in ('minLongitude','minLatitude','maxLongitude','maxLatitude')]
    bounds=dict(minLongitude=w+px/12*(e-w),maxLongitude=w+(px+1)/12*(e-w),
                minLatitude=n-(py+1)/12*(n-s),maxLatitude=n-py/12*(n-s))
    project=Transformer.from_crs(4326,27700,always_xy=True)
    es,ns=[],[]
    for lon in [bounds['minLongitude'],(bounds['minLongitude']+bounds['maxLongitude'])/2,bounds['maxLongitude']]:
        for lat in [bounds['minLatitude'],(bounds['minLatitude']+bounds['maxLatitude'])/2,bounds['maxLatitude']]:
            ee,nn=project.transform(lon,lat);es.append(ee);ns.append(nn)
    params=[('service','WCS'),('version','2.0.1'),('request','GetCoverage'),('coverageId',source['coverageID']),('format','image/tiff'),
            ('subset',f'E({math.floor(min(es))-4},{math.ceil(max(es))+4})'),('subset',f'N({math.floor(min(ns))-4},{math.ceil(max(ns))+4})')]
    url=source['endpoint']+'?'+urllib.parse.urlencode(params)
    file=a.cache/'wcs'/row['id']/f'c{px:02d}-{py:02d}.tif.gz';receipt=file.with_suffix('.json')
    if file.exists() and receipt.exists():
        record=json.loads(receipt.read_bytes());data=gzip.decompress(file.read_bytes())
        if record['url']!=url or sha(data)!=record['sha256'] or len(data)!=record['byteCount']:raise ValueError('Cached EA response changed')
        try:validate_response(data)
        except rasterio.errors.RasterioIOError:
            rejected=a.cache/'rejected-wcs'/row['id'];rejected.mkdir(parents=True,exist_ok=True)
            tag=str(time.time_ns());file.rename(rejected/(file.name+'.'+tag));receipt.rename(rejected/(receipt.name+'.'+tag))
            emit(event='truncated-response-quarantined',section=row['id'],parent=f'c{px:02d}-{py:02d}')
        else:
            if not record.get('rasterValidated'):
                record['rasterValidated']=True;atomic(receipt,raw(record))
            return data,record
    for attempt in range(4):
        try:
            if shutil.disk_usage(a.cache).free<2*1024**3:raise RuntimeError('Terrain cache has less than 2 GiB free; completed downloads retained')
            request=urllib.request.Request(url,headers={'User-Agent':'Ridge-English-LiDAR-repair/1.0'})
            with urllib.request.urlopen(request,timeout=90) as response:data=response.read()
            validate_response(data)
            packed=gzip.compress(data,compresslevel=6,mtime=0)
            record=dict(url=url,sha256=sha(data),byteCount=len(data),compressedSHA256=sha(packed),compressedByteCount=len(packed),source=source,rasterValidated=True)
            atomic(file,packed);atomic(receipt,raw(record));return data,record
        except Exception:
            if attempt==3:raise
            time.sleep(2**attempt)


def prepare_section(a,plan,row):
    sys.path.insert(0,str(a.mapping))
    from scripts.build_snowdon_pyramid import source_samples
    from scripts.precision_tile_builder import terrain_metadata
    groups={}
    for c in row['chunks']:groups.setdefault((c['parentX'],c['parentY']),[]).append(c)
    x,y=int(row['id'].split('-x')[1].split('-')[0]),int(row['id'].split('-y')[1])
    root=a.cache/'native'/f'tiles/10/{x}/{y}';root.mkdir(parents=True,exist_ok=True)
    if a.archive_only and (root/'COMPLETE.json').exists():
        if json.loads((root/'COMPLETE.json').read_bytes())['manifestSHA256']!=sha((root/'manifest.json').read_bytes()):raise ValueError('Native manifest changed')
        emit(event='native-section-reused',section=row['id']);return
    project=Transformer.from_crs(4326,27700,always_xy=True);vertical=Transformer.from_crs(7405,9707,always_xy=True)
    parents=[];done=0
    def parent(job):
        (px,py),candidates=job;pid=f'c{px:02d}-{py:02d}';children=[];pending=[]
        for c in candidates:
            archive=a.cache/'native-archive'/row['id']/(c['id']+'.bin.gz')
            receipt=archive.with_suffix('.json')
            if archive.exists() and receipt.exists():
                child=json.loads(receipt.read_bytes());data=gzip.decompress(archive.read_bytes())
                if sha(data)!=child['lods'][0]['sha256']:raise ValueError('Native archive checksum')
                if not a.archive_only:atomic(root/'parents'/pid/child['lods'][0]['path'],data)
                children.append(child)
            else:pending.append(c)
        if pending:
            data,evidence=fetch_parent(a,plan['source'],row,px,py)
            with MemoryFile(data) as mem:
                with mem.open() as ds:
                    for c in pending:
                        cid=f"p{c['childX']:02d}-{c['childY']:02d}"
                        values=source_samples(ds,c['bounds'],project,vertical,samples=513)
                        child=dict(id=cid,bounds=c['bounds'],status='unavailable',lods=[],reasonCode='noCompleteEnglishLidarCoverage')
                        if values is not None:
                            data=values.tobytes();path=f'precision/{cid}/lod-1m.bin';archive=a.cache/'native-archive'/row['id']/(c['id']+'.bin.gz')
                            child=dict(id=cid,bounds=c['bounds'],status='available',sourceEvidence=dict(responseSHA256=evidence['sha256'],url=evidence['url']),
                                       lods=[dict(nominalSpacingMetres=1,path=path,byteCount=len(data),sha256=sha(data),terrain=terrain_metadata(c['bounds'],513),compressedArchive=str(archive))])
                            atomic(archive,gzip.compress(data,compresslevel=6,mtime=0));atomic(archive.with_suffix('.json'),raw(child))
                            if not a.archive_only:atomic(root/'parents'/pid/path,data)
                        children.append(child)
        emit(event='native-parent',section=row['id'],parent=pid,complete=sum(bool(c['lods']) for c in children),candidates=len(candidates))
        return dict(id=pid,parentX=px,parentY=py,status='available',precisionChildren=children)
    with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
        parents=list(pool.map(parent,sorted(groups.items(),key=lambda j:(j[0][1],j[0][0]))))
    parents.sort(key=lambda p:(p['parentY'],p['parentX']))
    count=sum(bool(c['lods']) for p in parents for c in p['precisionChildren'])
    source=dict(plan['source'],preparation='Original sampler on integer-aligned 1 m WCS subsets; official footprint checked per child; original responses and native samples retained compressed.')
    manifest=dict(schemaVersion=1,productID=plan['version'],productVersion='2026.10.20-1',tileID=row['id'],z=10,x=x,y=y,bounds=row['bounds'],sourceKey='england',source=source,parents=parents,availablePrecisionChunkCount=count)
    payload=raw(manifest);atomic(root/'manifest.json',payload);atomic(root/'COMPLETE.json',raw(dict(manifestSHA256=sha(payload))))
    emit(event='native-section-complete',section=row['id'],complete=count,candidates=len(row['chunks']))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['previous','mapping','coverage','grids','cache']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--plan-only',action='store_true');p.add_argument('--archive-only',action='store_true');p.add_argument('--tile',action='append');p.add_argument('--workers',type=int,default=4)
    a=p.parse_args();a.cache.mkdir(parents=True,exist_ok=True)
    datadir.append_data_dir(str(a.grids))
    if not TransformerGroup(7405,9707,always_xy=True).best_available:raise ValueError('Local official vertical/coordinate grids are required')
    with (a.cache/'.prepare.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);plan=make_plan(a)
        if a.plan_only:return
        rows=[row for row in plan['sections'] if not a.tile or row['id'] in a.tile];done=[]
        try:
            for row in rows:
                atomic(a.cache/'preparation-status.json',raw(dict(state='running',current=row['id'],completed=done,total=len(rows))))
                prepare_section(a,plan,row);done.append(row['id'])
            atomic(a.cache/'preparation-status.json',raw(dict(state='complete',completed=done,total=len(rows))))
        except BaseException as error:
            atomic(a.cache/'preparation-status.json',raw(dict(state='failed',current=row['id'],completed=done,total=len(rows),error=repr(error))))
            raise


if __name__=='__main__':main()
