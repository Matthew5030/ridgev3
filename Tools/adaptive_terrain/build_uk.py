#!/usr/bin/env python3
"""Build a frozen UK selection in bounded, independently validated grid sections."""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import time
import zlib
import numpy as np
from shapely.geometry import shape,box,mapping
from compact_codec import CompactCodec
from publish_adaptive import atomic_json,publish

HERE=Path(__file__).resolve().parent


def sha(raw):return hashlib.sha256(raw).hexdigest()


def bbox(b):return box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])


def seed_cache(database,builds,downloads):
    db=sqlite3.connect(database)
    db.execute('CREATE TABLE IF NOT EXISTS cache (id TEXT, sourceSHA TEXT, compilerSHA TEXT, private TEXT, public TEXT, directory TEXT, PRIMARY KEY(id,sourceSHA,compilerSHA))')
    if db.execute('SELECT COUNT(*) FROM cache').fetchone()[0]:return db
    private={}
    for path in list(builds.glob('*/manifest.json'))+list((builds/'scottish-adaptive-builds').glob('*-adaptive-0p5/manifest.json')):
        raw=path.read_bytes();private[sha(raw)]=path
    catalog=json.loads((downloads/'adaptive-catalog.json').read_text())
    for entry in catalog['sources']:
        directory=downloads/entry['id'];index=json.loads((directory/'adaptive.json').read_text())
        path=private.get(index['sourceManifestSHA256'])
        if path is None or index['requiredReader']!='rat1-zlib-v1':continue
        manifest=json.loads(path.read_text());records={c['id']:c for c in manifest['chunks']}
        for c in index['chunks']:
            old=records[c['id']]
            db.execute('INSERT OR IGNORE INTO cache VALUES(?,?,?,?,?,?)',(c['id'],c['sourceSHA256'],index['compilerSHA256'],json.dumps(old),json.dumps(c),str(directory)))
        db.commit();print('Indexed reusable terrain:',entry['id'],flush=True)
    return db


def restore_cache(db,selection,out,compiler_hash,workers):
    tasks=[]
    for c in selection['chunks']:
        row=db.execute('SELECT private,public,directory FROM cache WHERE id=? AND sourceSHA=? AND compilerSHA=?',(c['id'],c['sourceSHA256'],compiler_hash)).fetchone()
        if row:tasks.append((c,row))
    if not tasks:return 0
    codec=CompactCodec();(out/'meshes').mkdir(exist_ok=True)
    def restore(task):
        c,row=task;old,item,directory=json.loads(row[0]),json.loads(row[1]),Path(row[2])
        # Verify the retained input too, rather than trusting a cached filename.
        source=Path(c['source']).read_bytes()
        if len(source)!=c['sourceByteCount'] or sha(source)!=c['sourceSHA256']:raise ValueError('Reusable native source checksum')
        compressed=(directory/item['path']).read_bytes()
        if len(compressed)!=item['byteCount'] or sha(compressed)!=item['sha256']:raise ValueError('Reusable compressed chunk checksum')
        payload=zlib.decompress(compressed)
        if sha(payload)!=item['topologySHA256']:raise ValueError('Reusable topology checksum')
        raw=codec.decode(payload)
        if len(raw)!=old['compactBytes'] or sha(raw)!=old['sha256']:raise ValueError('Reusable mesh checksum')
        mesh=out/'meshes'/f"{c['id']}.rmesh";temporary=mesh.with_suffix('.tmp');temporary.write_bytes(raw);temporary.replace(mesh)
        old.update(c);old['sourceZlibBytes']=item['sourceZlibBytes'];old['sourceZlibLevel']=6
        atomic_json(mesh.with_suffix('.json'),old)
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for start in range(0,len(tasks),64):list(pool.map(restore,tasks[start:start+64]))
    return len(tasks)


def record_outer_edges(db,out,manifest,tile):
    db.execute('CREATE TABLE IF NOT EXISTS edges (key TEXT PRIMARY KEY, heights BLOB, firstOwner TEXT, secondOwner TEXT)')
    for c in manifest['chunks']:
        sides=[];b=c['bounds'];outer=tile['bounds']
        for axis,side,coord in [('x',0,'minLongitude'),('x',512,'maxLongitude'),('y',0,'maxLatitude'),('y',512,'minLatitude')]:
            if round(b[coord],10)==round(outer[coord],10):sides.append((axis,side,coord))
        if not sides:continue
        raw=(out/c['path']).read_bytes()
        if sha(raw)!=c['sha256']:raise ValueError('Outer-edge mesh checksum')
        v=np.frombuffer(raw,dtype=np.dtype([('x','<u2'),('y','<u2'),('h','<i2')]),offset=28,count=c['vertices'])
        for axis,side,coord in sides:
            other='y' if axis=='x' else 'x';edge=np.sort(v[v[axis]==side],order=other)
            if not np.array_equal(edge[other],np.arange(513)):raise ValueError('Incomplete outer edge')
            key=json.dumps([axis,round(b[coord],10),round(b['minLatitude' if axis=='x' else 'minLongitude'],10),round(b['maxLatitude' if axis=='x' else 'maxLongitude'],10)])
            heights=edge['h'].tobytes();old=db.execute('SELECT heights,firstOwner,secondOwner FROM edges WHERE key=?',(key,)).fetchone()
            if old:
                if old[0]!=heights:raise ValueError(f"Cross-section seam mismatch: {old[1]} / {tile['id']}")
                if tile['id']!=old[1]:
                    if old[2] not in (None,tile['id']):raise ValueError('More than two owners for an outer edge')
                    db.execute('UPDATE edges SET secondOwner=? WHERE key=?',(tile['id'],key))
            else:db.execute('INSERT INTO edges VALUES(?,?,?,NULL)',(key,heights,tile['id']))
    db.commit()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build',type=Path,required=True);p.add_argument('--downloads',type=Path,required=True)
    p.add_argument('--work',type=Path,required=True);p.add_argument('--compiler',type=Path,required=True)
    p.add_argument('--reuse-builds',type=Path);p.add_argument('--reuse-downloads',type=Path)
    p.add_argument('--background',type=Path,required=True)
    p.add_argument('--workers',type=int,default=10);p.add_argument('--limit',type=int)
    a=p.parse_args()
    if not 1<=a.workers<=16:p.error('Use 1–16 workers')
    a.build.mkdir(parents=True,exist_ok=True);a.downloads.mkdir(parents=True,exist_ok=True);a.work.mkdir(parents=True,exist_ok=True)
    lock=(a.build/'.run.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    raw_plan=(a.build/'plan.json').read_bytes();plan=json.loads(raw_plan);compiler_hash=sha(a.compiler.read_bytes())
    background_raw=a.background.read_bytes();background=json.loads(background_raw)
    if background['requiredReader']!='int16-heightfield-zlib-v1':raise ValueError('Expected separately labelled coarse background')
    if a.background.parent.parent.resolve()!=a.downloads.parent.resolve():raise ValueError('Background must share the download root')
    background_reference=dict(path='/'+a.background.parent.name+'/'+a.background.name,sha256=sha(background_raw),byteCount=len(background_raw),terrainBytes=background['byteCount'],requiredReader=background['requiredReader'],quality=background['quality'])
    imported_path=a.build/'imported-sections.json'
    if imported_path.exists() and json.loads(imported_path.read_bytes())['compilerSHA256']!=compiler_hash:raise ValueError('Imported sections use a different compiler')
    identity=dict(planSHA256=sha(raw_plan),compilerSHA256=compiler_hash,backgroundSHA256=sha(background_raw))
    identity_path=a.build/'build-inputs.json'
    if identity_path.exists() and json.loads(identity_path.read_text())!=identity:raise ValueError('Changed frozen build inputs: use a new build directory')
    atomic_json(identity_path,identity)
    tooling=a.build/'tooling-history.json';history=json.loads(tooling.read_text()) if tooling.exists() else []
    record={name:sha((HERE/name).read_bytes()) for name in ['build_uk.py','build_park.py','verify_park.py','publish_adaptive.py','compact_mesh.cpp','survey_coverage.py','plan_uk.py']}
    if not history or history[-1]!=record:history.append(record);atomic_json(tooling,history)
    selection_hashes_path=a.build/'selection-checksums.json'
    if selection_hashes_path.exists():selection_hashes=json.loads(selection_hashes_path.read_text())
    else:
        selection_hashes={t['id']:sha((a.build/'selection'/(t['id']+'.json')).read_bytes()) for t in plan['partitions']}
        atomic_json(selection_hashes_path,selection_hashes)
    uk=shape(json.loads((a.build/'boundary.geojson').read_text())['geometry'])
    cache=seed_cache(a.build/'reuse.sqlite',a.reuse_builds,a.reuse_downloads) if a.reuse_builds and a.reuse_downloads else None
    edges=sqlite3.connect(a.build/'outer-edges.sqlite')
    status_path=a.build/'status.json';status=json.loads(status_path.read_text()) if status_path.exists() else dict(partitions={})
    catalog_path=a.downloads/'catalog.json'
    catalog=json.loads(catalog_path.read_text()) if catalog_path.exists() else dict(schemaVersion=1,id=plan['id'],name='United Kingdom adaptive terrain',contentKind='adaptive-terrain-grid',requiredReader='rat1-zlib-range-v1',surfaceToleranceMetres=.5,sourceSpacingMetres=1,scope='Prepared detailed terrain only; explicit gaps remain. Separate from normal app catalogue.',partitions=[])
    catalog['background']=background_reference
    catalog['officialSurveyCoverage']=plan['officialSurveyCoverage']
    catalog['sourceSelectionPolicy']=plan.get('sourceSelectionPolicy',{})
    catalog['totalGridSections']=len(plan['partitions'])
    catalog['expectedDetailedSections']=sum(t['chunkCount']>0 for t in plan['partitions'])
    catalog['quality']='0.5 m maximum measured surface error against prepared 1 m samples; not absolute survey accuracy. Official EA footprints exclude unsupported detail. Coarse background is a separate layer.'
    available={item['id']:item for item in catalog['partitions']}
    started=time.monotonic();done_now=0
    def save_catalog():
        catalog['partitions']=sorted(available.values(),key=lambda c:c['id']);catalog['chunkCount']=sum(c['chunks'] for c in available.values());catalog['meshBytes']=sum(c['meshBytes'] for c in available.values())
        catalog['buildComplete']=len(available)==sum(t['chunkCount']>0 for t in plan['partitions'])
        atomic_json(catalog_path,catalog);atomic_json(status_path,status)
    def command(name,args,out):
        with (out/(name.removesuffix('.py')+'.log')).open('w') as log:
            subprocess.run([sys.executable,str(HERE/name),*map(str,args)],check=True,stdout=log,stderr=subprocess.STDOUT)
    for tile in plan['partitions']:
        key=tile['id']
        if not tile['chunkCount']:
            status['partitions'][key]=dict(status='unavailable',chunks=0);continue
        if key in available:continue
        if a.limit is not None and done_now>=a.limit:break
        if shutil.disk_usage(a.work).free<3*1024**3 or shutil.disk_usage(a.downloads).free<30*1024**3:raise ValueError('Insufficient free space for another bounded section')
        out=a.work/key;out.mkdir(exist_ok=True);archive=a.build/'partitions'/key;archive.mkdir(parents=True,exist_ok=True)
        selection_raw=(a.build/'selection'/(key+'.json')).read_bytes()
        if sha(selection_raw)!=selection_hashes[key]:raise ValueError('Frozen partition selection changed')
        selection=json.loads(selection_raw);selection['sourceRoots']=plan['sourceRoots'];atomic_json(out/'selection.json',selection)
        feature=dict(type='Feature',properties=dict(collectionID=key,displayName=f'UK terrain {key}'),geometry=mapping(uk.intersection(bbox(tile['bounds']))))
        atomic_json(out/'input-boundary.geojson',feature)
        phase=time.monotonic();status['currentPartition']=key;status['partitions'][key]=dict(status='building',chunks=tile['chunkCount']);save_catalog()
        print('Building',key,tile['chunkCount'],'chunks',flush=True)
        try:
            # A crash after publishing but before the catalogue update must
            # recover the original manifest, not rebuild timing metadata.
            existing=a.downloads/(key+'-adaptive-0p5')/'adaptive.json'
            if existing.exists():
                raw_index=existing.read_bytes();index=json.loads(raw_index)
                saved=archive/'manifest.json' if (archive/'manifest.json').exists() else out/'manifest.json'
                if not saved.exists() or sha(saved.read_bytes())!=index['sourceManifestSHA256']:raise ValueError('Cannot recover published section without its matching private manifest')
                container=existing.parent/index['container']['path'];h=hashlib.sha256()
                with container.open('rb') as f:
                    for data in iter(lambda:f.read(4*1024*1024),b''):h.update(data)
                if h.hexdigest()!=index['container']['sha256']:raise ValueError('Published section container checksum')
                manifest=json.loads(saved.read_text());reused=0
                wanted=sha(json.dumps([{k:c[k] for k in ['id','bounds','sourceSHA256']} for c in sorted(selection['chunks'],key=lambda c:c['id'])],sort_keys=True).encode())
                if manifest['sourceSelectionSHA256']!=wanted or manifest['compilerSHA256']!=compiler_hash:raise ValueError('Recovered publication does not match frozen selection')
                for name in ['manifest.json','validation.json','boundary.geojson','coverage-gaps.geojson']:
                    source=saved.parent/name
                    if source.exists() and source.resolve()!=(out/name).resolve():shutil.copyfile(source,out/name)
            else:
                reused=restore_cache(cache,selection,out,compiler_hash,a.workers) if cache else 0
                command('build_park.py',['--source',plan['sourceRoots'][0],'--boundary',out/'input-boundary.geojson','--selection-manifest',out/'selection.json','--output',out,'--compiler',a.compiler,'--workers',a.workers],out)
                command('verify_park.py',[out],out)
                manifest=json.loads((out/'manifest.json').read_text());record_outer_edges(edges,out,manifest,tile)
                # Keep the exact private identity durable before exposing bytes.
                for name in ['manifest.json','validation.json','selection.json','boundary.geojson','coverage-gaps.geojson']:
                    shutil.copyfile(out/name,archive/name)
                with (out/'publish.log').open('w') as log:
                    subprocess.run([sys.executable,str(HERE/'publish_adaptive.py'),str(out),str(a.downloads),'--workers',str(a.workers),'--codec','rat1','--pack','--no-catalog'],stdout=log,stderr=subprocess.STDOUT,check=True)
            directory=a.downloads/manifest['id'];raw_index=(directory/'adaptive.json').read_bytes();index=json.loads(raw_index)
            if index['sourceManifestSHA256']!=sha((out/'manifest.json').read_bytes()):raise ValueError('Published manifest mismatch')
            for name in ['manifest.json','validation.json','selection.json','input-boundary.geojson','boundary.geojson','coverage-gaps.geojson','plan.json','build_park.log','verify_park.log','publish.log']:
                if (out/name).exists():shutil.copyfile(out/name,archive/name)
            if sha((archive/'manifest.json').read_bytes())!=index['sourceManifestSHA256']:raise ValueError('Archived manifest mismatch')
            available[key]=dict(id=key,path=f"{manifest['id']}/adaptive.json",byteCount=len(raw_index),sha256=sha(raw_index),bounds=tile['bounds'],chunks=len(index['chunks']),meshBytes=index['byteCount'],decodedBytes=index['decodedByteCount'],expandedGeometryBytes=index['expandedGeometryBytes'],coveragePercent=100*(1-index['uncoveredParkAreaKm2']/index['parkAreaKm2']))
            status['partitions'][key]=dict(status='published',chunks=len(index['chunks']),reusedChunks=reused,seconds=round(time.monotonic()-phase,2),meshBytes=index['byteCount'],triangles=index['triangles'],withinSectionSeams=index['validation']['sharedEdgesChecked'])
            save_catalog();shutil.rmtree(out/'meshes',ignore_errors=True);done_now+=1
            print(json.dumps(dict(partition=key,**status['partitions'][key],publishedPartitions=len(available))),flush=True)
        except BaseException as error:
            status['partitions'][key]=dict(status='failed',error=str(error));atomic_json(status_path,status);raise
    status.pop('currentPartition',None);status['complete']=len(available)==sum(t['chunkCount']>0 for t in plan['partitions']);status['lastRunSeconds']=round(time.monotonic()-started,1)
    try:status['crossSectionSeams']=edges.execute('SELECT COUNT(*) FROM edges WHERE secondOwner IS NOT NULL').fetchone()[0]
    except sqlite3.OperationalError:status['crossSectionSeams']=0
    save_catalog();print('Build complete:',status['complete'],flush=True)


if __name__=='__main__':main()
