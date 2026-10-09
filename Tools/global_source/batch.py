#!/usr/bin/env python3
"""Local, resumable global baseline builder. No cloud writes or paid APIs.

Example: python batch.py --root '/Volumes/MLB_EXT_4TB/Ridge Global/v1' --region switzerland
Use --all-regions to queue Geofabrik leaf extracts; disk reserve always applies.
Only wholly covered cells publish. Border/coastal/missing-DEM cells are reported.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from shapely.geometry import shape, box
from shapely import prepare
from common import atomic, rawjson, download, digest, reserve, bounds, xy, REVISION, DiskReserveError
from osm_index import make_index
from build import build, toolchain
from land import Land


def cells(feature,land=None):
    geometry=shape(feature['geometry'])
    if not geometry.is_valid:raise ValueError('Invalid extract boundary')
    prepare(geometry)
    parts=list(geometry.geoms) if geometry.geom_type=='MultiPolygon' else [geometry]
    candidates=set()
    for part in parts:
        lo,la,hi,ha=part.bounds
        if hi-lo>180 or la < -85 or ha>85:
            raise ValueError('Polar/dateline polygon needs a split before processing')
        x0,y1=xy(lo,la);x1,y0=xy(hi,ha)
        if (x1-x0+1)*(y1-y0+1)>500000:raise ValueError('Extract needs subdivision')
        candidates.update((x,y) for y in range(y0,y1+1) for x in range(x0,x1+1))
        if len(candidates)>500000:raise ValueError('Extract needs subdivision')
    accepted=[];border=0
    for x,y in sorted(candidates):
        b=bounds(x,y);rectangle=box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])
        if land is not None and not land.intersects(rectangle):continue
        if not geometry.intersects(rectangle):continue
        # Match the vector query halo; partial border coverage is not a full pack.
        if geometry.covers(rectangle.buffer(.003)) and (land is None or land.covers(rectangle.buffer(.001))):accepted.append((x,y,b))
        else:border+=1
    # Start near the Matterhorn in Switzerland, otherwise the extract's interior.
    center=max(parts,key=lambda p:p.area).representative_point()
    px,py=xy(7.75,46.02) if feature['properties']['id']=='switzerland' else xy(center.x,center.y)
    accepted.sort(key=lambda v:((v[0]-px)**2+(v[1]-py)**2,v[1],v[0]))
    return accepted,border


def select_regions(index,requested,all_regions):
    features={f['properties']['id']:f for f in index['features']}
    if not all_regions:
        return [features[r] for r in requested]
    parents={f['properties'].get('parent') for f in features.values()}
    def uk(f):
        key=f['properties']['id']
        while key in features:
            if key in {'great-britain','united-kingdom'}:return True
            key=features[key]['properties'].get('parent')
        return False
    eligible=[f for key,f in features.items() if key not in parents and f['properties'].get('urls',{}).get('pbf') and not uk(f)]
    priority=['switzerland','austria','nepal','new-zealand']
    return sorted(eligible,key=lambda f:(priority.index(f['properties']['id']) if f['properties']['id'] in priority else len(priority),f['properties']['id']))


def identity():
    here=Path(__file__).resolve().parent
    files=list(here.glob('*.py'))+[here/'requirements.txt']
    files += [here.parent/'adaptive_terrain'/p for p in ('park_mesh.cpp','compact_mesh.cpp','compact_codec.py')]
    return hashlib.sha256(b''.join(p.name.encode()+p.read_bytes() for p in sorted(files))).hexdigest()


class NativeValidationError(RuntimeError):
    pass


def run(a):
    root=a.root
    if len(root.parts)>2 and root.parts[1]=='Volumes' and not Path('/Volumes',root.parts[2]).is_mount():
        raise SystemExit('External volume is not mounted; no local replacement directory was created')
    root.mkdir(parents=True,exist_ok=True)
    lock=(root/'batch.lock').open('a')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise SystemExit('Another global batch owns this root')
    inputs=root/'input';inputs.mkdir(exist_ok=True)
    output=root/'output';output.mkdir(exist_ok=True)
    snapshot=download('https://download.geofabrik.de/index-v1.json',inputs/'geofabrik-index.json',a.reserve_gib,maximum=10*1024**2)
    regions=select_regions(json.loads(snapshot.read_bytes()),a.region,a.all_regions)
    fingerprint=identity();frozen=root/'builder.json'
    if frozen.exists() and json.loads(frozen.read_bytes())['sha256']!=fingerprint:
        raise SystemExit('Builder changed: use a new output root/version; never mix generations')
    atomic(frozen,rawjson(dict(revision=REVISION,sha256=fingerprint)))
    atomic(root/'plan.json',rawjson(dict(revision=REVISION,regions=[f['properties'] for f in regions],reserveGiB=a.reserve_gib,maximumExtractGiB=a.max_extract_gib,coverage='Only complete interior land cells; deferred borders, coasts and missing DEM are listed in status.json')))
    bins=toolchain(root/'bin');land=Land.load(inputs,a.reserve_gib);started=time.time();current=None;completed=0
    old=json.loads((root/'status.json').read_bytes()) if (root/'status.json').exists() else {}
    reports=old.get('regions',{})
    def status(state):
        atomic(root/'status.json',rawjson(dict(state=state,pid=os.getpid(),updatedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),elapsedSeconds=round(time.time()-started),current=current,completedThisRun=completed,freeGiB=round(shutil.disk_usage(root).free/1024**3,2),reserveGiB=a.reserve_gib,regions=reports)))
    def stop(signum,frame):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop)
    try:
        for feature in regions:
            p=feature['properties'];region=p['id'];current=region
            report=reports.setdefault(region,{})
            try:jobs,border=cells(feature,land)
            except ValueError as error:
                report.update(state='deferred',error=str(error));status('planning');continue
            report.update(totalInteriorSources=len(jobs),deferredBorderOrCoastSources=border)
            country=output/region;country.mkdir(parents=True,exist_ok=True)
            catalog_path=country/'catalog.json'
            catalog=json.loads(catalog_path.read_bytes()) if catalog_path.exists() else dict(schemaVersion=1,revision=REVISION,sources=[])
            entries={s['id']:s for s in catalog['sources']}
            report['completedSources']=len(entries)
            if len(entries)==len(jobs):
                report['state']='complete-interior';continue
            try:
                reserve(root,a.reserve_gib)
                status('downloading-osm');print(f'Preparing {region}: {len(jobs)} landscapes, {border} border/coastal cells deferred',flush=True)
                pbf=download(p['urls']['pbf'],inputs/(region+'.osm.pbf'),a.reserve_gib,maximum=a.max_extract_gib*1024**3)
                md5=download(p['urls']['pbf']+'.md5',inputs/(region+'.osm.pbf.md5'),a.reserve_gib,maximum=4096).read_text().split()[0]
                if digest(pbf,'md5')!=md5:raise ValueError('OSM checksum mismatch; remove only this cached extract and retry')
                status('indexing-osm');index=inputs/(region+'.sqlite');make_index(pbf,index,a.reserve_gib)
                failures=report.setdefault('failedSources',{})
                for x,y,b in jobs:
                    key=f'world-global-z12-x{x}-y{y}';current=f'{region}/{key}'
                    if key in entries:continue
                    if len(entries)>=20000:raise ValueError('Catalogue limit reached: subdivide this extract')
                    reserve(root,a.reserve_gib);status('building')
                    try:
                        record=build(key,b,p['name'],index,country,inputs/'dem',bins,a.workers,a.reserve_gib)
                    except DiskReserveError:raise
                    except Exception as error:
                        failures[key]=f'{type(error).__name__}: {error}'
                        print(f'Deferred {current}: {error}',flush=True);status('building');continue
                    if not entries:
                        status('native-app-validation')
                        test=Path(__file__).resolve().parents[1]/'test_world_batch.sh'
                        with (country/'native-validation.log').open('w') as log:
                            result=subprocess.run(['sh',str(test),str(country/'sources'/key)],stdout=log,stderr=subprocess.STDOUT)
                        if result.returncode:
                            raise NativeValidationError(f'App reader rejected {current}; see {country / "native-validation.log"}')
                    entries[key]=record;failures.pop(key,None)
                    catalog['sources']=sorted(entries.values(),key=lambda s:s['id'])
                    atomic(catalog_path,rawjson(catalog))
                    completed+=1;report.update(completedSources=len(entries),downloadBytes=sum(s['downloadBytes'] for s in entries.values()))
                    print(f'Published {current}: {record["downloadBytes"]/1024**2:.1f} MiB',flush=True);status('building')
                    if a.limit_sources and completed>=a.limit_sources:status('paused-source-limit');return
                report['state']='complete-interior' if not failures else 'complete-with-gaps'
            except (DiskReserveError,NativeValidationError):raise
            except Exception as error:
                report['state']='deferred';report['error']=f'{type(error).__name__}: {error}'
                print(f'Deferred {region}: {error}',flush=True)
        status('finished-queue')
    except DiskReserveError:
        status('paused-low-disk');print('Disk reserve reached; restart this command after adding space.',flush=True)
    except NativeValidationError as error:
        status('paused-native-validation');print(str(error),flush=True)
    except KeyboardInterrupt:
        status('paused');print('Stopped safely. Restart the same command to resume.',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--region',action='append',default=[])
    parser.add_argument('--all-regions',action='store_true')
    parser.add_argument('--workers',type=int,default=4)
    parser.add_argument('--reserve-gib',type=float,default=40)
    parser.add_argument('--max-extract-gib',type=float,default=1)
    parser.add_argument('--limit-sources',type=int,default=0)
    a=parser.parse_args()
    if not 1<=a.workers<=16 or a.reserve_gib<10 or a.max_extract_gib<=0 or a.limit_sources<0:parser.error('Invalid resource limits')
    if not a.region and not a.all_regions:a.region=['switzerland']
    run(a)

if __name__=='__main__':main()
