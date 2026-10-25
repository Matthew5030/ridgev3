#!/usr/bin/env python3
"""Validate and optionally publish a completed UK ground-colour staging tree.

Old immutable maps and packs remain available. Metadata backups and per-section
copy receipts make interrupted installation resumable without redownloading data.
"""
import argparse,fcntl,hashlib,json,os,shutil,time
from pathlib import Path
from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor,as_completed
from pack_sections import atomic,raw
from pack_region import build as build_region


def digest(file):
    h=hashlib.sha256()
    with file.open('rb') as stream:
        while chunk:=stream.read(1024*1024):h.update(chunk)
    return h.hexdigest()


def copy_asset(source,destination,asset):
    if destination.exists():
        if destination.stat().st_size!=asset['byteCount'] or digest(destination)!=asset['sha256']:
            raise ValueError('Immutable asset collision: '+str(destination))
        return
    temporary=destination.with_suffix(destination.suffix+'.ground-tmp');h=hashlib.sha256();count=0
    with source.open('rb') as inp,temporary.open('wb') as out:
        while chunk:=inp.read(1024*1024):out.write(chunk);h.update(chunk);count+=len(chunk)
    if count!=asset['byteCount'] or h.hexdigest()!=asset['sha256']:
        raise ValueError('Staged asset checksum mismatch: '+str(source))
    temporary.replace(destination)


def finish_archives(stage,catalog):
    receipt=stage/'archive-rebuild.json'
    if receipt.exists():return json.loads(receipt.read_bytes())
    original=json.loads((stage/'catalog.before.json').read_bytes())
    zones=stage/'published-archive-membership.json'
    zones.write_bytes(raw(dict(regions=[dict(id=a['id'],cells=[dict(id=s) for s in a['sourceIDs']]) for a in original.get('regionArchives',[])])))
    lookup={s['id']:s for s in catalog['sources']};results=[];fallback=[]
    for archive in original.get('regionArchives',[]):
        # Oversized combined archives use the app's existing section downloader.
        total=sum(lookup[s]['pack']['byteCount'] for s in archive['sourceIDs'])
        if total+8_000_012>1024**3:
            fallback.append(archive['id']);continue
        descriptor=build_region(stage,zones,archive['id'],publish=False);results.append(descriptor)
    catalog['regionArchives']=results
    from pack_region import retain_archive_groups
    retain_archive_groups(catalog)
    atomic(stage/'catalog.json',raw(catalog))
    result=dict(archives=results,sectionDownloadsOnly=fallback)
    atomic(receipt,raw(result));return result


def _publish_unlocked(world,stage,backup,do_publish,copy_workers):
    original=(stage/'catalog.before.json').read_bytes()
    current_catalog=(world/'catalog.json').read_bytes()
    if current_catalog!=original:
        if (stage/'publication-report.json').exists() and digest(world/'catalog.json')==json.loads((stage/'publication-report.json').read_bytes())['catalogSHA256']:
            print('This rollout is already published',flush=True);return
        raise ValueError('Live catalogue has changed; refusing to overwrite it')
    old=json.loads(original);catalog=json.loads((stage/'catalog.json').read_bytes());results=json.loads((stage/'results.json').read_bytes())
    old_ids={s['id'] for s in old['sources']};by_id={r['sourceID']:r for r in results}
    if old_ids!=set(by_id) or old_ids!={s['id'] for s in catalog['sources']}:raise ValueError('Incomplete UK preparation')
    if any(r['tilesWithColour']==0 for r in results):raise ValueError('A section has no usable satellite colour; review coverage before publishing')
    total_bytes=0;tile_count=0
    resumed=backup.exists() and (backup/'catalog.json').exists() and (backup/'catalog.json').read_bytes()==original
    for source in catalog['sources']:
        if source['pack']!=by_id[source['id']]['pack']:raise ValueError('Section pack does not match its preparation receipt')
        folder=stage/Path(source['path']).parent;manifest=json.loads((folder/'world.json').read_bytes())
        before=(folder/'world.before.json').read_bytes();previous=json.loads(before)
        if hashlib.sha256(before).hexdigest()!=by_id[source['id']]['inputManifestSHA256']:raise ValueError('Changed preparation input')
        live=(world/source['path']).read_bytes()
        if live!=before and not (resumed and live==(folder/'world.json').read_bytes()):raise ValueError('Live source changed: '+source['id'])
        for key in ('id','bounds','columns','rows','places','overview','graph'):
            if manifest[key]!=previous[key]:raise ValueError('Geographic data changed: '+key)
        if len(manifest['tiles'])!=len(previous['tiles']):raise ValueError('Tile count changed')
        for a,b in zip(manifest['tiles'],previous['tiles']):
            if {k:v for k,v in a.items() if k!='map'}!={k:v for k,v in b.items() if k!='map'}:raise ValueError('Terrain geometry changed')
        tile_count+=len(manifest['tiles']);total_bytes+=sum(t['map']['byteCount'] for t in manifest['tiles'])+source['pack']['byteCount']
    archives=finish_archives(stage,catalog);catalog=json.loads((stage/'catalog.json').read_bytes())
    total_bytes+=sum(a['asset']['byteCount'] for a in archives['archives'])
    report=dict(sections=len(results),tiles=tile_count,tilesWithColour=sum(r['tilesWithColour'] for r in results),minimumUsablePercent=min(r['usablePercent'] for r in results),tileWeightedUsablePercent=sum(r['usablePercent']*r['tiles'] for r in results)/tile_count,newObjectBytes=total_bytes,archives=[a['id'] for a in archives['archives']],sectionDownloadsOnly=archives['sectionDownloadsOnly'],catalogSHA256=digest(stage/'catalog.json'))
    atomic(stage/'publication-plan.json',raw(report));print(json.dumps(report,indent=2),flush=True)
    if not do_publish:return
    state_file=backup/'copy-state.json';completed=set()
    if backup.exists():
        if (backup/'catalog.json').read_bytes()!=original:raise ValueError('Backup belongs to another rollout')
        if state_file.exists():completed=set(json.loads(state_file.read_bytes())['completed'])
    else:
        if shutil.disk_usage(world).free<total_bytes+4*1024**3:raise RuntimeError('Insufficient disk space to retain old assets during rollout')
        backup.mkdir(parents=True);atomic(backup/'catalog.json',original)
    def install_section(source):
        relative=Path(source['path']).parent;folder=stage/relative;destination=world/relative
        manifest=json.loads((folder/'world.json').read_bytes())
        save=backup/source['id'];save.mkdir(exist_ok=True)
        atomic(save/'world.json',(folder/'world.before.json').read_bytes())
        for tile in manifest['tiles']:
            asset=tile['map'];copy_asset(folder/asset['file'],destination/asset['file'],asset)
        copy_asset(folder/source['pack']['file'],destination/source['pack']['file'],source['pack'])
        return source['id']

    remaining=[source for source in catalog['sources'] if source['id'] not in completed]
    with ThreadPoolExecutor(max_workers=copy_workers) as pool:
        futures=[pool.submit(install_section,source) for source in remaining]
        for future in as_completed(futures):
            completed.add(future.result())
            atomic(state_file,raw(dict(completed=sorted(completed),updated=time.time())))
            if len(completed)%25==0:print(json.dumps(dict(event='installed-objects',sections=len(completed),total=len(results))),flush=True)
    for archive in archives['archives']:
        asset=archive['asset'];copy_asset(stage/'region-packs'/asset['file'],world/'region-packs'/asset['file'],asset)
    if (world/'catalog.json').read_bytes()!=original:raise ValueError('Live catalogue changed during copying; metadata left untouched')
    for source in catalog['sources']:
        relative=Path(source['path']).parent;folder=stage/relative
        if (world/source['path']).read_bytes() not in [(folder/'world.before.json').read_bytes(),(folder/'world.json').read_bytes()]:raise ValueError('Live source changed before publication')
    # Every new immutable object is installed before any source metadata changes.
    for source in catalog['sources']:
        relative=Path(source['path']).parent;folder=stage/relative
        for name in ['world.json','ground-colour-provenance.json','section-pack-v1.json']:
            atomic(world/relative/name,(folder/name).read_bytes())
    atomic(world/'catalog.json',(stage/'catalog.json').read_bytes())
    for archive in archives['archives']:
        path=Path('region-packs')/(archive['id']+'.json');atomic(world/path,(stage/path).read_bytes())
    report['published']=True;report['publishedAt']=time.time();report['backup']=str(backup)
    atomic(stage/'publication-report.json',raw(report));print('PUBLISHED ALL '+str(len(results))+' SECTIONS',flush=True)


def publish(world,stage,backup,do_publish,copy_workers=6):
    with ExitStack() as stack:
        if do_publish:
            for name in ['.batch.lock','.section-pack.lock']:
                handle=stack.enter_context((world/name).open('a'))
                fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
        return _publish_unlocked(world,stage,backup,do_publish,copy_workers)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['world','stage','backup']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--publish',action='store_true');p.add_argument('--copy-workers',type=int,default=6);a=p.parse_args();publish(a.world,a.stage,a.backup,a.publish,a.copy_workers)
