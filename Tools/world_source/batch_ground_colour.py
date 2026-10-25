#!/usr/bin/env python3
"""Resumable UK colour preparation. Keeps raw RGB/SCL windows in a durable cache.

The live catalogue is never edited here. Unchanged assets in staging are symlinks
and are only read. Publication is a separate, checksum-verified step.
"""
import argparse, base64, collections, concurrent.futures, datetime, fcntl, hashlib, json, math, os, re, shutil, threading, time, zlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_bounds, from_origin
from rasterio.windows import Window
from rasterio.vrt import WarpedVRT
from rasterio.warp import reproject
from prepare_ground_colour import palette, raw
from pack_sections import build as build_section, atomic

VERSION = 'uk-ground-v4'
RESOLUTION = .0001  # One common geographic grid across all parents, ~11 m N/S.
CORE, BORDER, HALO = 48, 7, 40
lock = threading.Lock()


def log(**fields):
    with lock: print(json.dumps(dict(time=time.strftime('%Y-%m-%dT%H:%M:%S'), **fields)), flush=True)


def bbox(b):
    return [b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude']]


def overlap(a,b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def choose_scenes(candidates, regions):
    groups = collections.defaultdict(list)
    for item in candidates:
        if not any(overlap(item['bbox'], bbox(s['bounds'])) for s in regions): continue
        p = item['properties']
        groups[(p['mgrs:utm_zone'], p['mgrs:latitude_band'], p['mgrs:grid_square'])].append(item)
    result=[]
    target=datetime.date(2025,7,12)
    for key, items in sorted(groups.items()):
        def score(i):
            p=i['properties']; days=abs((datetime.date.fromisoformat(p['datetime'][:10])-target).days)
            missing=float(p.get('s2:nodata_pixel_percentage',0))
            unavailable=missing+(100-missing)*float(p['eo:cloud_cover'])/100
            return (int(unavailable//10), days, unavailable, i['id'])
        # Avoid selecting two processing versions of one day's acquisition.
        dates=set(); chosen=[]
        for item in sorted(items,key=score):
            date=item['properties']['datetime'][:10]
            if date not in dates: chosen.append(item); dates.add(date)
            if len(chosen)==3:break
        for rank,item in enumerate(chosen):result.append(dict(item=item,weight=1/(1+3*rank)))
    return result


def parent_grid(parent):
    x,y=map(int,re.search(r'x(\d+)-y(\d+)',parent).groups())
    west=x/1024*360-180; east=(x+1)/1024*360-180
    north=math.degrees(math.atan(math.sinh(math.pi*(1-2*y/1024))))
    south=math.degrees(math.atan(math.sinh(math.pi*(1-2*(y+1)/1024))))
    left=math.floor(west/RESOLUTION)-HALO; right=math.ceil(east/RESOLUTION)+HALO
    bottom=math.floor(south/RESOLUTION)-HALO; top=math.ceil(north/RESOLUTION)+HALO
    bounds=[left*RESOLUTION,bottom*RESOLUTION,right*RESOLUTION,top*RESOLUTION]
    width,height=right-left,top-bottom
    return bounds,width,height,from_bounds(*bounds,width,height)


def window(cache, parent, item, bounds, width, height, transform, reserve_gib=None, full_uk=False):
    folder=cache/'windows'/parent;folder.mkdir(parents=True,exist_ok=True)
    identity=hashlib.sha256(raw([item['id'],item['assets']['visual']['href'],item['assets']['scl']['href'],bounds,width,height,'full-UK-VRT-exact-v1' if full_uk else 'shared-UK-VRT-exact-v1'])).hexdigest()
    file=folder/(item['id']+'-'+identity[:12]+'.npz')
    if file.exists():
        receipt_file=file.with_suffix('.json')
        if full_uk and receipt_file.exists():
            receipt=json.loads(receipt_file.read_bytes())
            if hashlib.sha256(file.read_bytes()).hexdigest()!=receipt['sha256']:raise ValueError('Cached satellite window checksum mismatch')
        with np.load(file) as saved:
            rgb,scl,valid=saved['rgb'],saved['scl'],saved['valid']
        if rgb.shape!=(height,width,3) or scl.shape!=(height,width) or valid.shape!=(height,width):raise ValueError('Invalid cached window: '+str(file))
        # A crash can follow the NPZ rename but precede its receipt. ZIP CRCs
        # and shape checks validate that completed window without a new fetch.
        if full_uk and not receipt_file.exists():
            atomic(receipt_file,raw(dict(sceneID=item['id'],bounds=bounds,crs='EPSG:4326',width=width,height=height,identity=identity,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),resampling='bilinear RGB, nearest SCL',raw=True,receiptRecovered=True)))
        return rgb,scl,valid
    local = {kind: cache/'assets'/(item['id']+'-'+kind+'.tif') for kind in ['visual','scl']}
    # Local originals produce no retained crop window. Reserve bounded mosaic
    # scratch space; remote window caching still needs the larger allowance.
    if reserve_gib is None:reserve_gib=2 if all(path.exists() for path in local.values()) else 12
    if shutil.disk_usage(cache).free<reserve_gib*1024**3:raise RuntimeError(f'Satellite cache volume has less than {reserve_gib} GiB free; retaining all completed downloads')
    urls = {kind: str(path) if path.exists() else item['assets'][kind]['href'] for kind,path in local.items()}
    # A single virtual raster frame makes GDAL's warp blocks line up across
    # neighbouring parents. Near-exact coordinate transformation avoids SCL
    # boundary shifts between windows. Only the requested window enters memory.
    west,north=(-12,64) if full_uk else (-7,58)
    options=dict(crs='EPSG:4326',transform=from_origin(west,north,RESOLUTION,RESOLUTION),width=round(16/RESOLUTION) if full_uk else 95000,height=round(16/RESOLUTION) if full_uk else 90000,tolerance=1e-9)
    read_window=Window(round((bounds[0]-west)/RESOLUTION),round((north-bounds[3])/RESOLUTION),width,height)
    if read_window.col_off<0 or read_window.row_off<0 or read_window.col_off+width>95000 or read_window.row_off+height>90000:
        raise ValueError('Source lies outside the shared UK imagery grid')
    for attempt in range(4):
        try:
            with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN='EMPTY_DIR',CPL_VSIL_CURL_ALLOWED_EXTENSIONS='.tif',GDAL_HTTP_TIMEOUT='45',GDAL_HTTP_MAX_RETRY='2',GDAL_HTTP_RETRY_DELAY='2',GDAL_CACHEMAX=128*1024*1024):
                with rasterio.open(urls['visual']) as dataset:
                    with WarpedVRT(dataset,**options,resampling=Resampling.bilinear) as vrt:
                        rgb=vrt.read([1,2,3],window=read_window).transpose(1,2,0);valid=vrt.dataset_mask(window=read_window)>0
                with rasterio.open(urls['scl']) as dataset:
                    with WarpedVRT(dataset,**options,resampling=Resampling.nearest) as vrt:scl=vrt.read(1,window=read_window)
            # Original GeoTIFFs are already permanent and reusable at any bounds.
            if all(path.exists() for path in local.values()):return rgb,scl,valid
            temporary=file.with_suffix('.tmp.npz');np.savez_compressed(temporary,rgb=rgb,scl=scl,valid=valid);temporary.replace(file)
            metadata=dict(sceneID=item['id'],bounds=bounds,crs='EPSG:4326',width=width,height=height,identity=identity,sha256=hashlib.sha256(file.read_bytes()).hexdigest(),resampling='bilinear RGB, nearest SCL',raw=True)
            atomic(file.with_suffix('.json'),raw(metadata))
            log(event='cached',parent=parent,scene=item['id'],bytes=file.stat().st_size)
            return rgb,scl,valid
        except Exception:
            if attempt==3:raise
            time.sleep(2**attempt)


def mosaic(cache, parent, scenes, fingerprint, window_reserve_gib=None, full_uk=False):
    folder=cache/'mosaics'/fingerprint[:16];folder.mkdir(parents=True,exist_ok=True)
    file=folder/(parent+'.tif')
    if file.exists():return file
    bounds,w,h,transform=parent_grid(parent)
    selected=[s for s in scenes if overlap(bounds,s['item']['bbox'])]
    if not selected:raise ValueError('No satellite candidates for '+parent)
    total=np.zeros((h,w,3),np.float32);weights=np.zeros((h,w),np.float32);records=[]
    for scene in selected:
        item=scene['item'];rgb,scl,valid=window(cache,parent,item,bounds,w,h,transform,reserve_gib=window_reserve_gib,full_uk=full_uk)
        usable=valid & np.isin(scl,[4,5,6])
        # Cloud buffer plus a gradual confidence ramp avoids hard scene joins.
        mask=255-np.asarray(Image.fromarray(np.uint8(~usable)*255).filter(ImageFilter.MaxFilter(7)))
        feather=np.asarray(Image.fromarray(mask).filter(ImageFilter.GaussianBlur(6)),dtype=np.float32)/255
        weight=(mask>0)*feather*scene['weight']
        encoded=rgb.astype(np.float32)/255
        linear=np.where(encoded<=.04045,encoded/12.92,((encoded+.055)/1.055)**2.4)
        total+=linear*weight[...,None];weights+=weight
        records.append(dict(id=item['id'],date=item['properties']['datetime'],weight=scene['weight'],usablePixels=int(np.count_nonzero(mask))))
        del rgb,scl,valid,usable,mask,feather,weight,encoded,linear
    linear=total/np.maximum(weights[...,None],1e-10)
    encoded=np.where(linear<=.0031308,linear*12.92,1.055*np.maximum(linear,0)**(1/2.4)-.055)
    rgb=np.uint8(np.clip(encoded,0,1)*255+.5)
    del total,linear,encoded
    colour=palette(rgb)
    # Fade missing-observation edges. This alpha is independent of the 66% style.
    usable=weights>0
    confidence=np.asarray(Image.fromarray(np.uint8(usable)*255).filter(ImageFilter.GaussianBlur(2)))
    alpha=np.where(usable,confidence,0).astype(np.uint8)
    rgba=np.dstack([colour,alpha]).transpose(2,0,1)
    temporary=file.with_suffix('.tmp.tif')
    with rasterio.open(temporary,'w',driver='GTiff',width=w,height=h,count=4,dtype='uint8',crs='EPSG:4326',transform=transform,compress='deflate',tiled=True) as output:output.write(rgba)
    temporary.replace(file)
    atomic(file.with_suffix('.json'),raw(dict(version=VERSION,parent=parent,bounds=bounds,gridResolutionDegrees=RESOLUTION,scenes=records,usablePercent=float(usable.mean()*100),fingerprint=fingerprint)))
    log(event='mosaic',parent=parent,usablePercent=round(float(usable.mean()*100),3),scenes=len(selected))
    return file


def source_samples(file,manifest):
    b=bbox(manifest['bounds']);cols,rows=manifest['columns'],manifest['rows']
    w,h=cols*CORE,rows*CORE;dx=(b[2]-b[0])/w;dy=(b[3]-b[1])/h
    transform=from_bounds(b[0]-BORDER*dx,b[1]-BORDER*dy,b[2]+BORDER*dx,b[3]+BORDER*dy,w+2*BORDER,h+2*BORDER)
    with rasterio.open(file) as dataset:
        # Reproject premultiplied linear colour and alpha together: invalid cloud
        # pixels cannot leak their RGB into a neighbouring valid sample.
        bounds_window=rasterio.windows.from_bounds(b[0]-BORDER*dx,b[1]-BORDER*dy,b[2]+BORDER*dx,b[3]+BORDER*dy,transform=dataset.transform)
        left=max(0,math.floor(bounds_window.col_off)-2);top=max(0,math.floor(bounds_window.row_off)-2)
        right=min(dataset.width,math.ceil(bounds_window.col_off+bounds_window.width)+2)
        bottom=min(dataset.height,math.ceil(bounds_window.row_off+bounds_window.height)+2)
        read_window=Window(left,top,right-left,bottom-top)
        values=dataset.read(window=read_window).transpose(1,2,0).astype(np.float32)/255
        linear=np.where(values[...,:3]<=.04045,values[...,:3]/12.92,((values[...,:3]+.055)/1.055)**2.4)
        values[...,:3]=linear*values[...,3,None]
        result=np.zeros((4,h+2*BORDER,w+2*BORDER),np.float32)
        reproject(values.transpose(2,0,1),result,src_transform=dataset.window_transform(read_window),src_crs=dataset.crs,dst_transform=transform,dst_crs='EPSG:4326',resampling=Resampling.bilinear)
    result=result.transpose(1,2,0);a=result[...,3]
    linear=result[...,:3]/np.maximum(a[...,None],1e-10)
    result[...,:3]=np.where(linear<=.0031308,linear*12.92,1.055*np.maximum(linear,0)**(1/2.4)-.055)
    return np.uint8(np.clip(result,0,1)*255+.5)


def prepare_source(world,stage,region,mosaic_file,fingerprint):
    source=world/Path(region['path']).parent;output=stage/Path(region['path']).parent
    receipt=output/'ground-batch-receipt.json'
    before=(source/'world.json').read_bytes();input_hash=hashlib.sha256(before).hexdigest()
    if receipt.exists():
        result=json.loads(receipt.read_bytes())
        if result['fingerprint']==fingerprint and result['inputManifestSHA256']==input_hash:return result
        raise ValueError('Prepared source differs from this plan: '+region['id'])
    output.mkdir(parents=True,exist_ok=True);manifest=json.loads(before);samples=source_samples(mosaic_file,manifest)
    assets=[manifest['overview'],region.get('routing') or manifest['graph'],manifest['graph']]
    for tile in manifest['tiles']:assets.extend(tile[k] for k in ['mesh','background'] if k in tile)
    for asset in assets:
        name=asset.get('file',asset.get('path'))
        if Path(name).name!=name:raise ValueError('Unsafe source path')
        target=output/name
        if not target.exists():target.symlink_to((source/name).resolve())
    added=0;covered=0;total=0;coloured=0
    for tile in manifest['tiles']:
        asset=tile['map'];compressed=(source/asset['file']).read_bytes()
        if len(compressed)!=asset['byteCount'] or hashlib.sha256(compressed).hexdigest()!=asset['sha256']:raise ValueError('Damaged source map')
        decoded=zlib.decompress(compressed)
        if len(decoded)!=asset['decodedByteCount']:raise ValueError('Invalid decoded map size')
        value=json.loads(decoded);old_vectors={k:v for k,v in value.items() if k!='groundColour'}
        value.pop('groundColour',None);x,y=tile['column']*CORE,tile['row']*CORE
        patch=samples[y:y+CORE+2*BORDER,x:x+CORE+2*BORDER]
        core=patch[BORDER:-BORDER,BORDER:-BORDER,3];covered+=int(np.count_nonzero(core));total+=core.size
        if np.any(patch[...,3]):
            value['groundColour']=dict(version=1,width=patch.shape[1],height=patch.shape[0],border=BORDER,rgba=base64.b64encode(patch.tobytes()).decode());coloured+=1
        decoded=raw(value)
        if len(decoded)>8_000_000:raise ValueError('Decoded map exceeds app budget')
        data=zlib.compress(decoded,6);digest=hashlib.sha256(data).hexdigest();name=tile['id']+'-ground-'+digest[:16]+'.map'
        atomic(output/name,data);added+=len(data)-asset['byteCount']
        tile['map']=dict(file=name,byteCount=len(data),sha256=digest,decodedByteCount=len(decoded))
        # Independent round-trip verifies source vector payload preservation.
        readback=json.loads(zlib.decompress((output/name).read_bytes()));readback.pop('groundColour',None)
        if readback!=old_vectors:raise ValueError('Vector payload changed')
    credit=dict(name='Copernicus Sentinel-2',attribution='Contains modified Copernicus Sentinel data 2025. Satellite-guided illustrative ground colours.',license='Copernicus Sentinel data terms',url='https://dataspace.copernicus.eu/explore-data/data-collections/sentinel-data/sentinel-2')
    manifest['sources']=[s for s in manifest['sources'] if s['name']!=credit['name']]+[credit]
    manifest['revision']+='-'+VERSION+'-'+fingerprint[:12]
    atomic(output/'world.json',raw(manifest));atomic(output/'world.before.json',before)
    metadata=json.loads(mosaic_file.with_suffix('.json').read_bytes())
    report=dict(sourceID=region['id'],fingerprint=fingerprint,inputManifestSHA256=input_hash,addedMapBytes=added,usablePercent=100*covered/max(1,total),tiles=len(manifest['tiles']),tilesWithColour=coloured,sceneIDs=[s['id'] for s in metadata['scenes']],strength=.66,grid=f'Shared 0.0001 degree geographic mosaic; {CORE} samples per cell; {BORDER}-sample gutters',attribution=credit['attribution'])
    atomic(output/'ground-colour-provenance.json',raw(report))
    pack=build_section(stage,region);report['pack']=pack
    atomic(receipt,raw(report));log(event='section',source=region['id'],usablePercent=round(report['usablePercent'],3),packBytes=pack['byteCount'])
    return report


def run(args):
    args.cache.mkdir(parents=True,exist_ok=True);args.stage.mkdir(parents=True,exist_ok=True)
    guard=(args.stage/'.batch.lock').open('w');fcntl.flock(guard,fcntl.LOCK_EX|fcntl.LOCK_NB)
    snapshot=args.stage/'catalog.before.json'
    current=(args.world/'catalog.json').read_bytes()
    if snapshot.exists() and snapshot.read_bytes()!=current:raise ValueError('Live catalogue changed since staging began')
    if not snapshot.exists():atomic(snapshot,current)
    catalog=json.loads(current);candidates=json.loads(args.candidates.read_bytes())
    selected=choose_scenes(candidates,catalog['sources'])
    fingerprint=hashlib.sha256(raw([VERSION,RESOLUTION,CORE,BORDER,HALO,[(s['item']['id'],s['weight']) for s in selected]])).hexdigest()
    plan=dict(version=VERSION,fingerprint=fingerprint,sourceCount=len(catalog['sources']),sceneCount=len(selected),selected=selected)
    atomic(args.cache/'scene-plan.json',raw(plan));atomic(args.cache/'candidates.json',args.candidates.read_bytes());atomic(args.stage/'plan.json',raw(plan))
    groups=collections.defaultdict(list)
    for region in catalog['sources']:groups[region['id'].split('-c')[0]].append(region)
    if args.parent:groups={k:v for k,v in groups.items() if k in args.parent}
    log(event='plan',parents=len(groups),sources=sum(map(len,groups.values())),scenes=len(selected),cache=str(args.cache))
    finished=[];failed=[]
    def work(parent,regions):
        file=mosaic(args.cache,parent,selected,fingerprint)
        return [prepare_source(args.world,args.stage,region,file,fingerprint) for region in regions]
    def ready(parent):
        if not args.local_only:return True
        if (args.cache/'mosaics'/fingerprint[:16]/(parent+'.tif')).exists():return True
        bounds,_,_,_=parent_grid(parent)
        needed=[s['item'] for s in selected if overlap(bounds,s['item']['bbox'])]
        return all((args.cache/'assets'/(item['id']+'-'+kind+'.tif')).exists() for item in needed for kind in ['visual','scl'])
    remaining=dict(groups);active={};last_status=0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        while remaining or active:
            for parent in list(remaining):
                if len(active)>=args.workers:break
                if ready(parent):active[pool.submit(work,parent,remaining.pop(parent))]=parent
            done,_=concurrent.futures.wait(active,timeout=5,return_when=concurrent.futures.FIRST_COMPLETED) if active else (set(),set())
            if not active:time.sleep(5)
            for job in done:
                parent=active.pop(job)
                try:finished.extend(job.result())
                except Exception as error:
                    failed.append(dict(parent=parent,error=repr(error)));log(event='failed',parent=parent,error=repr(error))
            if done or time.time()-last_status>30:
                state=dict(version=VERSION,completedSources=len(finished),totalSources=sum(map(len,groups.values())),runningParents=list(active.values()),waitingParents=len(remaining),failed=failed,updated=time.time(),minimumUsablePercent=min((x['usablePercent'] for x in finished),default=0))
                atomic(args.stage/'status.json',raw(state));last_status=time.time()
                log(event='progress',completedSources=len(finished),runningParents=len(active),waitingParents=len(remaining),failed=len(failed))
            if args.local_only and remaining and not active:
                status_file=args.cache/'download-status.json'
                if status_file.exists():
                    download=json.loads(status_file.read_bytes())
                    if download['completed']+len(download['errors'])==download['total'] and download['errors']:
                        raise RuntimeError('Original imagery downloads failed; retry the cache download to resume preparation')
    if failed:raise RuntimeError(str(len(failed))+' parents failed; all completed work and downloads retained')
    if args.parent:return
    by_id={x['sourceID']:x for x in finished}
    for region in catalog['sources']:
        result=by_id[region['id']];region['pack']=result['pack'];region['downloadBytes']=region.get('downloadBytes',0)+result['addedMapBytes']
    catalog['revision']+='-'+VERSION+'-'+fingerprint[:12]
    atomic(args.stage/'catalog.json',raw(catalog));atomic(args.stage/'results.json',raw(finished))
    log(event='prepared',sources=len(finished),minimumUsablePercent=min(x['usablePercent'] for x in finished),addedMapBytes=sum(x['addedMapBytes'] for x in finished))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['world','stage','cache','candidates']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--local-only',action='store_true');p.add_argument('--workers',type=int,default=2);p.add_argument('--parent',action='append')
    run(p.parse_args())
