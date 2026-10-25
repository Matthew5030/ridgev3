#!/usr/bin/env python3
"""Stage missing English terrain with native sampling, exact joins and old assets.

Runs behind prepare_english_border.py. Existing publication is read-only until
the separately locked publication phase; compressed original input is retained.
"""
import argparse, collections, fcntl, gzip, hashlib, json, os, re, shutil
import subprocess, sys, time, zlib
from functools import lru_cache
from pathlib import Path
from types import SimpleNamespace
from concurrent.futures import ThreadPoolExecutor,as_completed
import numpy as np

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'adaptive_terrain'))
from prepare_english_border import raw,sha,atomic,emit
from compact_codec import CompactCodec


def grid_key(ident):
    x,y,px,py,cx,cy=map(int,re.fullmatch(r'z10-x(\d+)-y(\d+)-c(\d+)-(\d+)-p(\d+)-(\d+)',ident).groups())
    return x*48+px*4+cx,y*48+py*4+cy


def native_root(a,ident):
    x,y=re.fullmatch(r'z10-x(\d+)-y(\d+)',ident).groups()
    return a.cache/f'native/tiles/10/{x}/{y}'


def native_selection(a,row,materialize=True):
    root=native_root(a,row['id']);payload=(root/'manifest.json').read_bytes()
    if sha(payload)!=json.loads((root/'COMPLETE.json').read_bytes())['manifestSHA256']:raise ValueError('Native manifest checksum')
    m=json.loads(payload);chunks=[]
    exclusions=json.loads((a.cache/'seam-exclusions.json').read_bytes()) if (a.cache/'seam-exclusions.json').exists() else {}
    for p in m['parents']:
        for c in p['precisionChildren']:
            if not c['lods']:continue
            ident=f"{row['id']}-{p['id']}-{c['id']}"
            if ident in exclusions:continue
            lod=c['lods'][0];source=root/'parents'/p['id']/lod['path']
            if materialize:
                data=gzip.decompress(Path(lod['compressedArchive']).read_bytes())
                if len(data)!=lod['byteCount'] or sha(data)!=lod['sha256']:raise ValueError('Archived native sample changed')
                if not source.exists():atomic(source,data)
            chunks.append(dict(id=ident,bounds=c['bounds'],source=str(source),sourceSHA256=lod['sha256'],sourceByteCount=lod['byteCount'],compressedArchive=lod['compressedArchive']))
    return dict(id=row['id'],bounds=m['bounds'],chunks=chunks,sourceManifests=[dict(path=str(root/'manifest.json'),sha256=sha(payload))],sourceRoots=[str(a.cache/'native')])


@lru_cache(maxsize=32)
def heights(path,compressed=False):
    data=Path(path).read_bytes()
    if compressed:data=gzip.decompress(data)
    return np.frombuffer(data,'<i2').reshape(513,513)


def audit_native_seams(a,row,new,exclude_incompatible=False):
    key=row['id'];x,y=map(int,re.fullmatch(r'z10-x(\d+)-y(\d+)',key).groups());lookup={}
    for xx in range(x-1,x+2):
        for yy in range(y-1,y+2):
            ident=f'z10-x{xx}-y{yy}';p=a.previous/'selection'/(ident+'.json')
            if p.exists():
                for c in json.loads(p.read_bytes())['chunks']:lookup[grid_key(c['id'])]=(c,False)
            if (native_root(a,ident)/'COMPLETE.json').exists():
                for c in native_selection(a,dict(id=ident),False)['chunks']:lookup[grid_key(c['id'])]=(c,True)
    failures=[];edges=0;corners=0;seen=set()
    def data(c,compressed):
        result=heights(c['compressedArchive'] if compressed else c['source'],compressed)
        return result
    for c in new['chunks']:
        gx,gy=grid_key(c['id']);mine=data(c,True)
        for dx,dy,edge,other in [(1,0,mine[:,-1],lambda v:v[:,0]),(-1,0,mine[:,0],lambda v:v[:,-1]),(0,1,mine[-1,:],lambda v:v[0,:]),(0,-1,mine[0,:],lambda v:v[-1,:]),
                                 (1,1,mine[-1,-1],lambda v:v[0,0]),(-1,1,mine[-1,0],lambda v:v[0,-1]),(1,-1,mine[0,-1],lambda v:v[-1,0]),(-1,-1,mine[0,0],lambda v:v[-1,-1])]:
            neighbour=lookup.get((gx+dx,gy+dy))
            if not neighbour:continue
            n,compressed=neighbour;pair=tuple(sorted([c['id'],n['id']]))
            if pair in seen:continue
            seen.add(pair);delta=np.abs(np.asarray(edge,dtype=np.int32)-np.asarray(other(data(n,compressed)),dtype=np.int32));edges+=1
            if dx and dy:corners+=1
            if delta.max():failures.append(dict(a=c['id'],b=n['id'],contact='corner' if dx and dy else 'edge',repairNeighbour=compressed,maxDeltaMetres=float(delta.max()/10),differentSamples=int(np.count_nonzero(delta))))
    heights.cache_clear()
    report=dict(section=key,edges=edges-corners,corners=corners,failures=failures,maximumSeamDeltaMetres=max((f['maxDeltaMetres'] for f in failures),default=0))
    atomic(a.cache/'seams'/(key+'.json'),raw(report));emit(event='native-seams',section=key,edges=edges-corners,corners=corners,failures=len(failures),maximumSeamDeltaMetres=report['maximumSeamDeltaMetres'])
    if failures:
        if not exclude_incompatible or any(f['repairNeighbour'] for f in failures):raise ValueError('Native seam mismatch; published terrain was not changed')
        path=a.cache/'seam-exclusions.json';exclusions=json.loads(path.read_bytes()) if path.exists() else {}
        for f in failures:exclusions.setdefault(f['a'],[]).append(f)
        atomic(path,raw(exclusions));rejected={f['a'] for f in failures}
        atomic(a.cache/'seams'/(key+'.excluded.json'),raw(report))
        new['chunks'][:]=[c for c in new['chunks'] if c['id'] not in rejected]
        emit(event='incompatible-survey-boundary-excluded',section=key,chunks=len(rejected),maximumDeltaMetres=report['maximumSeamDeltaMetres'])
        audit_native_seams(a,row,new)


def run(a,*command):
    env=dict(os.environ,RIDGE_COMPACT_LIBRARY=str(a.world/'.tools/libridge_compact_mesh.dylib'))
    subprocess.run([str(x) for x in command],check=True,env=env)


def build_fine(a,row,selection):
    work=a.cache/'mesh-work'/row['id'];fine=a.cache/'fine'/f"{row['id']}-adaptive-0p5"
    if (fine/'adaptive.json').exists():return fine
    folder=a.cache/'new-selection';folder.mkdir(exist_ok=True);manifest=folder/(row['id']+'.json');atomic(manifest,raw(selection))
    b=row['bounds'];feature=dict(type='Feature',properties=dict(name=row['id']),geometry=dict(type='Polygon',coordinates=[[[b['minLongitude'],b['minLatitude']],[b['maxLongitude'],b['minLatitude']],[b['maxLongitude'],b['maxLatitude']],[b['minLongitude'],b['maxLatitude']],[b['minLongitude'],b['minLatitude']]]]))
    boundary=a.cache/'boundaries'/(row['id']+'.geojson');atomic(boundary,raw(feature))
    compiler=a.world/'.tools/park_mesh'
    run(a,sys.executable,HERE.parent/'adaptive_terrain/build_park.py','--source',a.cache/'native','--boundary',boundary,'--output',work,'--compiler',compiler,'--workers','6','--id',row['id'],'--name',row['id'],'--selection-manifest',manifest)
    run(a,sys.executable,HERE.parent/'adaptive_terrain/verify_park.py',work)
    from publish_adaptive import publish
    os.environ['RIDGE_COMPACT_LIBRARY']=str(a.world/'.tools/libridge_compact_mesh.dylib')
    publish(work,a.cache/'fine',workers=6,codec='rat1',packed=True,update_catalog=False)
    run(a,sys.executable,HERE.parent/'adaptive_terrain/verify_park.py',work,'--published',fine)
    # These uncompressed meshes are reproducible from the preserved native
    # archive; verified compressed topology remains in the fine container.
    shutil.rmtree(work/'meshes')
    return fine


def combine_fine(a,row,new,fine):
    old=json.loads((a.previous/'selection'/(row['id']+'.json')).read_bytes());old['chunks']+=new['chunks']
    if len({c['id'] for c in old['chunks']})!=len(old['chunks']):raise ValueError('Repair attempted to replace existing native input')
    old['sourceManifests']+=new['sourceManifests'];old['chunkCount']=len(old['chunks'])
    atomic(a.cache/'combined-selection'/(row['id']+'.json'),raw(old))
    dest=a.cache/'fine-combined'/fine.name;dest.mkdir(parents=True,exist_ok=True)
    m=json.loads((fine/'adaptive.json').read_bytes())
    for c in m['chunks']:
        path=dest/c['path']
        if not path.exists():path.symlink_to(fine/c['path'])
    previous=a.world.parent/'uk-adaptive-0p5-v3'/fine.name
    if (previous/'adaptive.json').exists():
        legacy=json.loads((previous/'adaptive.json').read_bytes())
        for c in legacy['chunks']:
            original=c['path'];c['path']='legacy-'+Path(original).name;target=dest/c['path']
            if not target.exists():target.symlink_to(previous/original)
            m['chunks'].append(c)
        m['sourceManifests']+=legacy['sourceManifests']
    atomic(dest/'adaptive.json',raw(m))


def build_world(a,row):
    run(a,sys.executable,HERE/'batch_world.py','--selection',a.cache/'combined-selection','--fine',a.cache/'fine-combined',
        '--public',a.mapping/'build/public','--staged-public',a.archives,'--output',a.cache/'world-base',
        '--reuse-world',a.world,'--region-workers','4','--workers','2','--reserve-gib','3','--section',row['id'])
    state=json.loads((a.cache/'world-base/status.json').read_bytes())
    if state['failures'] or state['deferred']:raise ValueError('World conversion did not complete: '+str(state))
    if state['state'] not in ['complete','complete-with-gaps']:raise ValueError('World conversion stopped before completion')


def invalidate_selection(a,row,selection):
    """Discard private derived sections when survey exclusions refine a plan."""
    path=a.cache/'combined-selection'/(row['id']+'.json')
    expected={c['id'] for c in selection['chunks']}
    if not path.exists():return
    before=json.loads(path.read_bytes());original={c['id'] for c in json.loads((a.previous/'selection'/(row['id']+'.json')).read_bytes())['chunks']}
    if {c['id'] for c in before['chunks']}==expected|original:return
    prefix='world-'+row['id']+'-c'
    for parent in [a.cache/'world-base/sources',a.cache/'world-base/.work',a.cache/'world-stage/sources']:
        if not parent.exists():continue
        for folder in parent.iterdir():
            if folder.name.startswith(prefix):
                if folder.is_symlink():folder.unlink()
                elif folder.is_dir():shutil.rmtree(folder)
    catalog=a.cache/'world-base/catalog.json'
    if catalog.exists():
        value=json.loads(catalog.read_bytes());value['sources']=[s for s in value['sources'] if not s['id'].startswith(prefix)];atomic(catalog,raw(value))
    for folder in ['completed-world','staged-sections']:(a.cache/folder/(row['id']+'.json')).unlink(missing_ok=True)
    emit(event='derived-selection-invalidated',section=row['id'],acceptedNewChunks=len(expected))


def immutable_name(folder,asset,new_name,key='file'):
    old=folder/asset[key];target=folder/new_name
    if old!=target:
        if target.exists():
            if sha(target.read_bytes())!=asset['sha256']:raise ValueError('Immutable staging collision')
        else:old.rename(target)
    asset[key]=new_name


def normalize_sources(a,row):
    base=a.cache/'world-base';catalog=json.loads((base/'catalog.json').read_bytes())
    previous={s['id']:s for s in json.loads((a.world/'catalog.json').read_bytes())['sources']}
    for entry in catalog['sources']:
        if not entry['id'].startswith('world-'+row['id']+'-c'):continue
        folder=base/Path(entry['path']).parent;marker=folder/'english-repair.json'
        if marker.exists():continue
        manifest=json.loads((folder/'world.json').read_bytes());old=previous.get(entry['id'])
        prior=json.loads((a.world/old['path']).read_bytes()) if old else None
        old_tiles={t['id']:t for t in prior['tiles']} if prior else {}
        for tile in manifest['tiles']:
            if tile['id'] in old_tiles:
                retained=old_tiles[tile['id']]
                if tile['mesh']['sha256']!=retained['mesh']['sha256']:raise ValueError('Previously published fine terrain changed')
                # Preserve the exact existing background and cartography too.
                for kind in ['mesh','background','map']:
                    tile[kind]=dict(retained[kind]);name=tile[kind].get('file',tile[kind].get('path'));target=folder/name
                    original=a.world/Path(old['path']).parent/name
                    if target.exists() or target.is_symlink():target.unlink()
                    target.symlink_to(original)
            else:
                for kind in ['mesh','background']:
                    asset=tile[kind];name=tile['id']+'-terrain-'+asset['sha256'][:16]+('.background' if kind=='background' else '')+'.rat.zlib'
                    immutable_name(folder,asset,name,'path')
        for kind in ['overview','graph']:
            asset=manifest[kind];prefix='overview-8m' if kind=='overview' else 'paths'
            immutable_name(folder,asset,prefix+'-'+asset['sha256'][:16]+'.json')
        if prior:manifest['name']=prior['name']
        if not manifest['revision'].endswith('-english-border-20261020'):manifest['revision']+='-english-border-20261020'
        atomic(folder/'world.json',raw(manifest));atomic(marker,raw(dict(existingTilesPreserved=len(old_tiles),newTiles=len(manifest['tiles'])-len(old_tiles))))
    # Reproduce the existing connected OSM endpoint identities for every new
    # section. This graph is independent of terrain mesh density.
    run(a,sys.executable,HERE/'publish_connected_paths.py','--world',base,'--archives',a.archives,'--parent',row['id'])


def colour_sources(a,row):
    import batch_ground_colour as colour
    stage=a.cache/'world-stage';stage.mkdir(exist_ok=True)
    snapshot=stage/'catalog.before.json';live=(a.world/'catalog.json').read_bytes()
    if snapshot.exists() and snapshot.read_bytes()!=live:raise ValueError('Live catalogue changed during repair staging')
    if not snapshot.exists():atomic(snapshot,live)
    base=a.cache/'world-base';catalog=json.loads((base/'catalog.json').read_bytes())
    regions=[r for r in catalog['sources'] if r['id'].startswith('world-'+row['id']+'-c')]
    if not regions:
        atomic(a.cache/'staged-sections'/(row['id']+'.json'),raw([]));return
    plan=json.loads((a.satellite/'scene-plan.json').read_bytes());bounds,_,_,_=colour.parent_grid('world-'+row['id'])
    scenes=[s for s in plan['selected'] if colour.overlap(bounds,s['item']['bbox'])]
    if not all((a.satellite/'assets'/(s['item']['id']+'-'+kind+'.tif')).exists() for s in scenes for kind in ['visual','scl']):raise ValueError('Satellite originals missing from permanent cache')
    mosaic=colour.mosaic(a.satellite,'world-'+row['id'],plan['selected'],plan['fingerprint']);results=[]
    previous={s['id']:s for s in json.loads(live)['sources']}
    for region in regions:
        result=colour.prepare_source(base,stage,region,mosaic,plan['fingerprint'])
        snapshot=stage/Path(region['path']).parent/'live-world.before.json'
        current=a.world/region['path']
        if current.exists() and not snapshot.exists():atomic(snapshot,current.read_bytes())
        merged={**previous.get(region['id'],{}),**region};merged['pack']=result['pack'];merged['downloadBytes']=result['pack']['byteCount']
        results.append(merged)
    atomic(a.cache/'staged-sections'/(row['id']+'.json'),raw(results));emit(event='coloured-section-complete',section=row['id'],sources=len(results))


def finalize_catalog(a):
    stage=a.cache/'world-stage';before=(stage/'catalog.before.json').read_bytes()
    if (a.world/'catalog.json').read_bytes()!=before:raise ValueError('Catalogue changed before repair publication')
    catalog=json.loads(before);entries={s['id']:s for s in catalog['sources']};changed={}
    for file in sorted((a.cache/'staged-sections').glob('*.json')):
        for entry in json.loads(file.read_bytes()):entries[entry['id']]=entry;changed[entry['id']]=entry
    catalog['sources']=list(entries.values());catalog['revision']+='-english-border-20261020'
    # Unchanged source folders are read-only references for regional packaging.
    for entry in catalog['sources']:
        folder=stage/Path(entry['path']).parent
        if entry['id'] not in changed and not folder.exists():
            folder.parent.mkdir(parents=True,exist_ok=True);folder.symlink_to(a.world/Path(entry['path']).parent,target_is_directory=True)
    atomic(stage/'catalog.json',raw(catalog))
    from pack_region import build as pack_region
    zones=json.loads((HERE.parents[1]/'ridge v3/Resources/uk-download-zones.json').read_bytes())
    zone_ids={z['id']:{c['id'] for c in z['cells']} for z in zones['regions']+zones.get('parks',[])}
    archives=[];rebuilt=[]
    newly_available=set(entries)-{s['id'] for s in json.loads(before)['sources']}
    for archive in catalog.get('regionArchives',[]):
        # Preserve published membership, adding only newly available sections
        # belonging to the same declared region. Do not recut unrelated packs.
        ids=sorted((set(archive['sourceIDs'])|(newly_available&zone_ids.get(archive['id'],set())))&entries.keys())
        if set(ids)==set(archive['sourceIDs']) and not set(ids)&changed.keys():archives.append(archive);continue
        if sum(entries[i]['pack']['byteCount'] for i in ids)+8_000_012>1024**3:continue
        path=stage/'repair-archive-membership.json';atomic(path,raw(dict(regions=[dict(id=archive['id'],cells=[dict(id=i) for i in ids])])));
        descriptor=pack_region(stage,path,archive['id'],publish=False);archives.append(descriptor);rebuilt.append(descriptor)
    catalog['regionArchives']=archives;atomic(stage/'catalog.json',raw(catalog))
    atomic(stage/'repair-publication-plan.json',raw(dict(changedSourceIDs=sorted(changed),newSourceIDs=sorted(changed.keys()-{s['id'] for s in json.loads(before)['sources']}),catalogSHA256=sha(raw(catalog)),rebuiltArchives=rebuilt)))
    return catalog,changed,rebuilt


def publication_assets(manifest,entry):
    values=[manifest['overview'],manifest['graph'],entry.get('routing') or manifest['graph'],entry['pack']]
    for tile in manifest['tiles']:values.extend(tile[k] for k in ['mesh','background','map'])
    # Packs deduplicate by checksum; loose URLs still need every filename.
    result={}
    for asset in values:
        name=asset.get('file',asset.get('path'))
        if Path(name).name!=name:raise ValueError('Unsafe publication filename')
        if name in result and result[name]!=asset:raise ValueError('Publication asset name collision')
        result[name]=asset
    return result


def publish_repair(a):
    from publish_uk_ground_colour import copy_asset
    stage=a.cache/'world-stage';receipt=stage/'repair-publication-report.json'
    if receipt.exists():
        report=json.loads(receipt.read_bytes())
        if sha((a.world/'catalog.json').read_bytes())!=report['catalogSHA256']:raise ValueError('Published catalogue changed')
        return
    intent=stage/'repair-publication-intent.json'
    if intent.exists() and sha((a.world/'catalog.json').read_bytes())==json.loads(intent.read_bytes())['catalogSHA256']:
        report=json.loads(intent.read_bytes());report['published']=True;atomic(receipt,raw(report));return
    locks=[]
    try:
        for name in ['.batch.lock','.section-pack.lock']:
            lock=(a.world/name).open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);locks.append(lock)
        catalog,changed,archives=finalize_catalog(a);before=(stage/'catalog.before.json').read_bytes()
        backup=a.world/'terrain-repairs/2026-10-20-english-border';backup.mkdir(parents=True,exist_ok=True)
        if (backup/'catalog.json').exists() and (backup/'catalog.json').read_bytes()!=before:raise ValueError('Repair backup differs')
        atomic(backup/'catalog.json',before)
        old={s['id']:s for s in json.loads(before)['sources']};added=0
        def install_source(item):
            ident,entry=item
            folder=stage/Path(entry['path']).parent;dest=a.world/Path(entry['path']).parent;dest.mkdir(parents=True,exist_ok=True)
            prepared=(folder/'world.json').read_bytes();m=json.loads(prepared)
            original=(folder/'live-world.before.json').read_bytes() if ident in old else None
            previous=json.loads(original) if original else None
            if (dest/'world.json').exists() and (dest/'world.json').read_bytes() not in [original,prepared]:raise ValueError('Live source changed during repair')
            if previous:
                existing={t['id']:t for t in m['tiles']}
                if any(t['id'] not in existing or t['mesh']!=existing[t['id']]['mesh'] or t['background']!=existing[t['id']]['background'] for t in previous['tiles']):raise ValueError('Existing terrain was replaced')
                save=backup/(ident+'.world.json')
                if save.exists() and save.read_bytes()!=original:raise ValueError('Original source backup changed')
                atomic(save,original)
            for name,asset in publication_assets(m,entry).items():copy_asset(folder/name,dest/name,asset)
            return len(m['tiles'])-len(previous['tiles'] if previous else [])
        with ThreadPoolExecutor(max_workers=6) as pool:
            jobs=[pool.submit(install_source,item) for item in changed.items()]
            for index,job in enumerate(as_completed(jobs),1):
                added+=job.result()
                if index%10==0:emit(event='repair-objects-installed',sources=index,total=len(changed))
        for archive in archives:
            asset=archive['asset'];copy_asset(stage/'region-packs'/asset['file'],a.world/'region-packs'/asset['file'],asset)
        if (a.world/'catalog.json').read_bytes()!=before:raise ValueError('Live catalogue changed while installing repair objects')
        if hasattr(a,'expected_added_tiles') and added!=a.expected_added_tiles:raise ValueError('Published tile increase differs from accepted native recovery')
        audit_file=a.cache/'source-cache-audit.json';audit=json.loads(audit_file.read_bytes()) if audit_file.exists() else {}
        exclusions=a.cache/'seam-exclusions.json'
        report=dict(published=True,changedSources=len(changed),addedTerrainTiles=added,sources=len(catalog['sources']),tiles=sum(s['tileCount'] for s in catalog['sources']),catalogSHA256=sha((stage/'catalog.json').read_bytes()),backup=str(backup),publishedAt=time.time(),nativeArraysVerified=audit.get('nativeArraysVerified'),sourceCacheAuditSHA256=sha(audit_file.read_bytes()) if audit_file.exists() else None,excludedIncompatibleChunks=len(json.loads(exclusions.read_bytes())) if exclusions.exists() else 0)
        atomic(intent,raw(report))
        for ident,entry in changed.items():
            folder=stage/Path(entry['path']).parent;dest=a.world/Path(entry['path']).parent
            for name in ['world.json','ground-colour-provenance.json','section-pack-v1.json']:
                atomic(dest/name,(folder/name).read_bytes())
        atomic(a.world/'catalog.json',(stage/'catalog.json').read_bytes())
        atomic(receipt,raw(report));emit(event='PUBLISHED-ENGLISH-REPAIR',**report)
    finally:
        for lock in reversed(locks):lock.close()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['cache','previous','world','mapping','archives','satellite']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--tile',action='append');p.add_argument('--wait-for-native',action='store_true');p.add_argument('--publish',action='store_true');p.add_argument('--publish-only',action='store_true');a=p.parse_args()
    plan=json.loads((a.cache/'plan.json').read_bytes());rows=[r for r in plan['sections'] if not a.tile or r['id'] in a.tile]
    with (a.cache/'.repair.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        for row in rows:
            if a.publish_only:break
            complete=a.cache/'completed-world'/(row['id']+'.json')
            if (native_root(a,row['id'])/'COMPLETE.json').exists():
                review=native_selection(a,row,False);audit_native_seams(a,row,review,exclude_incompatible=True);invalidate_selection(a,row,review)
            if complete.exists():
                normalize_sources(a,row);colour_sources(a,row);continue
            while not (native_root(a,row['id'])/'COMPLETE.json').exists():
                if not a.wait_for_native:raise ValueError('Native section is not ready: '+row['id'])
                status=json.loads((a.cache/'preparation-status.json').read_bytes()) if (a.cache/'preparation-status.json').exists() else {}
                if status.get('state')=='failed':raise ValueError('Native preparation failed: '+str(status))
                emit(event='waiting-for-native',section=row['id']);time.sleep(15)
            emit(event='repair-section',section=row['id'])
            selection=native_selection(a,row);audit_native_seams(a,row,selection,exclude_incompatible=True)
            if not selection['chunks']:
                atomic(complete,raw(dict(section=row['id'],addedChunks=0,completedAt=time.time())));atomic(a.cache/'staged-sections'/(row['id']+'.json'),raw([]));continue
            fine=build_fine(a,row,selection);combine_fine(a,row,selection,fine);build_world(a,row)
            atomic(complete,raw(dict(section=row['id'],addedChunks=len(selection['chunks']),completedAt=time.time())))
            normalize_sources(a,row);colour_sources(a,row)
            # Compressed source responses and native archives are permanent;
            # only the materialized working copies are removed between sections.
            shutil.rmtree(native_root(a,row['id'])/'parents',ignore_errors=True)
            emit(event='world-section-complete',section=row['id'],addedChunks=len(selection['chunks']))
        if a.publish or a.publish_only:
            if a.tile:raise ValueError('Publish the complete repair plan, not only a pilot')
            expected=0
            for row in rows:
                selection=native_selection(a,row,False);audit_native_seams(a,row,selection)
                complete=json.loads((a.cache/'completed-world'/(row['id']+'.json')).read_bytes())
                if complete['addedChunks']!=len(selection['chunks']) or not (a.cache/'staged-sections'/(row['id']+'.json')).exists():raise ValueError('Repair staging does not match final accepted input')
                expected+=len(selection['chunks'])
            a.expected_added_tiles=expected
            audit=json.loads((a.cache/'source-cache-audit.json').read_bytes())
            if audit['planSHA256']!=sha((a.cache/'plan.json').read_bytes()):raise ValueError('Source cache audit belongs to a different repair plan')
            for row in rows:
                if audit['nativeManifestSHA256'][row['id']]!=sha((native_root(a,row['id'])/'manifest.json').read_bytes()):raise ValueError('Native input changed since cache audit')
            publish_repair(a)


if __name__=='__main__':main()
