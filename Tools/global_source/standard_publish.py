"""Audit completed free UK terrain, then publish immutable links and metadata."""
import argparse,collections,fcntl,hashlib,json,os,sqlite3,time,zlib,sys
from pathlib import Path
from common import atomic,rawjson,digest
from standard_terrain import key
TOOLS=Path(__file__).resolve().parents[1];sys.path.insert(0,str(TOOLS/'world_source'))
from repair_english_border import publication_assets

def audit(root):
    plan=json.loads((root/'plan.json').read_bytes());identity=json.loads((root/'builder.json').read_bytes());assert identity['inputsSHA256']==digest(root/'inputs.json') and identity['planSHA256']==digest(root/'plan.json')
    for record in json.loads((root/'inputs.json').read_bytes())['dem']+json.loads((root/'inputs.json').read_bytes())['geoids']:
        if record.get('missing'):continue
        assert Path(record['path']).stat().st_size==record['byteCount'] and digest(record['path'])==record['sha256']
    unmatched={};corners={};count=0;deferred=[];entries={};contacts=0
    for row in plan['parents']:
        if not (root/'coloured'/(row['id']+'.json')).exists():raise ValueError('Imagery phase not complete: '+row['id'])
        for entry in json.loads((root/'completed'/(row['id']+'.json')).read_bytes()):
            if entry['id'] in entries:raise ValueError('Duplicate prepared source')
            entries[entry['id']]=entry
        proof=json.loads((root/'seams'/(row['id']+'.json')).read_bytes());deferred.extend(proof['deferred'])
        for edge in proof['edges']:
            axis,x,y=edge['key'];k=(axis,x,y);count+=1
            if k in unmatched:
                if unmatched.pop(k)['sha256']!=edge['sha256']:raise ValueError('New/new mesh seam mismatch: '+str(k))
                contacts+=1
            else:unmatched[k]=edge
            ends=[(key(x,y),edge['first']),(key(x+(axis=='h'),y+(axis=='v')),edge['last'])]
            for vertex,h in ends:
                if vertex in corners and corners[vertex]!=h:raise ValueError('Mesh corner mismatch')
                corners[vertex]=h
    standard=sum(e['standardTileCount'] for e in entries.values())
    if count!=standard*4:raise ValueError('Seam audit does not cover every standard tile')
    lidar_contacts=0
    with sqlite3.connect(root/'boundaries.sqlite') as db:
        for (axis,x,y),edge in unmatched.items():
            neighbours=[(key(x-1,y),1),(key(x,y),0)] if axis=='v' else [(key(x,y-1),3),(key(x,y),2)]
            for k,index in neighbours:
                record=db.execute('SELECT payload FROM edges WHERE k=?',(k,)).fetchone()
                if record:
                    data=zlib.decompress(record[0])[index*1026:(index+1)*1026]
                    if hashlib.sha256(data).hexdigest()!=edge['sha256']:raise ValueError('Retained LiDAR mesh seam mismatch')
                    lidar_contacts+=1
        for k,h in db.execute('SELECT k,h FROM corners'):
            if k in corners and corners[k]!=h:raise ValueError('Retained LiDAR corner mismatch')
    report=dict(standardTiles=standard,plannedNativeCells=plan['newNativeCells'],changedSources=len(entries),newSharedEdgesVerified=contacts,retainedLiDARSharedEdgesVerified=lidar_contacts,maximumSeamDifferenceMetres=0,deferredCells=deferred,inputSHA256=identity['inputsSHA256'],sourceCatalogSHA256=plan['sourceCatalogSHA256'])
    atomic(root/'final-audit.json',rawjson(report));return entries,report

def publish(root,world):
    receipt=root/'publication.json'
    if receipt.exists():
        report=json.loads(receipt.read_bytes());assert digest(world/'catalog.json')==report['catalogSHA256'];return report
    # A metadata switch may have finished immediately before interruption.
    intent=root/'publication-intent.json'
    if intent.exists() and digest(world/'catalog.json')==json.loads(intent.read_bytes())['catalogSHA256']:
        report=json.loads(intent.read_bytes());atomic(receipt,rawjson(report));return report
    entries,proof=audit(root);before=(root/'catalog.before.json').read_bytes()
    if (world/'catalog.json').read_bytes()!=before:raise ValueError('Live catalogue changed since planning')
    catalog=json.loads(before);old={s['id']:s for s in catalog['sources']};merged=dict(old);locks=[]
    backup=world/'terrain-repairs/2026-10-20-free-standard';backup.mkdir(parents=True,exist_ok=True)
    if (backup/'catalog.json').exists() and (backup/'catalog.json').read_bytes()!=before:raise ValueError('Publication backup changed')
    atomic(backup/'catalog.json',before)
    try:
        for name in ['.batch.lock','.section-pack.lock']:
            lock=(world/name).open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);locks.append(lock)
        added=0;objects=0
        for index,(ident,entry) in enumerate(sorted(entries.items()),1):
            folder=root/'world'/Path(entry['path']).parent;target=world/Path(entry['path']).parent;m=json.loads((folder/'world.json').read_bytes())
            if ident not in old:
                if target.exists() or target.is_symlink():
                    if not target.is_symlink() or target.resolve()!=folder.resolve():raise ValueError('Unexpected existing source folder')
                else:
                    target.parent.mkdir(parents=True,exist_ok=True);temporary=target.with_name(target.name+'.standard-link');temporary.unlink(missing_ok=True);temporary.symlink_to(folder.resolve(),target_is_directory=True);temporary.replace(target);objects+=1
            else:target.mkdir(parents=True,exist_ok=True)
            if m['id']!=ident or len(m['tiles'])!=entry['tileCount']:raise ValueError('Prepared source does not match catalogue')
            if ident in old:
                original=(folder/'world.before.json').read_bytes();previous=json.loads(original);retained={t['id']:t for t in m['tiles']}
                for tile in previous['tiles']:
                    if retained.get(tile['id'])!=tile:raise ValueError('Retained LiDAR terrain or map changed')
                save=backup/(ident+'.world.json')
                if save.exists() and save.read_bytes()!=original:raise ValueError('Source backup changed')
                atomic(save,original);added+=len(m['tiles'])-len(previous['tiles'])
            else:added+=len(m['tiles'])
            for name,asset in publication_assets(m,entry).items():
                source=folder/name;dest=target/name
                # Pack creation validates every listed loose object; publication
                # independently checks both existing objects and new targets.
                if dest.exists():
                    if dest.stat().st_size!=asset['byteCount'] or digest(dest)!=asset['sha256']:raise ValueError('Immutable live asset collision: '+str(dest))
                else:
                    if source.stat().st_size!=asset['byteCount'] or digest(source)!=asset['sha256']:raise ValueError('Prepared asset checksum mismatch')
                    temporary=dest.with_name(dest.name+'.standard-link');temporary.unlink(missing_ok=True);temporary.symlink_to(source.resolve());temporary.replace(dest);objects+=1
            merged[ident]=entry
            if index%25==0:print('INSTALLED STANDARD ASSETS',index,len(entries),flush=True)
        if added!=proof['standardTiles']:raise ValueError('Published tile increase does not match the audit')
        # Changed child sources invalidate old regional packs. Their old files
        # remain available, while the new catalogue uses section downloads.
        catalog['regionArchives']=[a for a in catalog.get('regionArchives',[]) if not set(a['sourceIDs'])&entries.keys()]
        catalog['sources']=list(merged.values());catalog['revision']+='-uk-standard-v1';data=rawjson(catalog)
        if len(data)>=16_000_000:raise ValueError('Catalogue exceeds app limit')
        if (world/'catalog.json').read_bytes()!=before:raise ValueError('Catalogue changed during asset installation')
        report=dict(published=True,catalogSHA256=hashlib.sha256(data).hexdigest(),sources=len(merged),tiles=sum(s['tileCount'] for s in merged.values()),addedStandardTiles=added,changedSources=len(entries),newSources=len(entries.keys()-old.keys()),linkedObjects=objects,backup=str(backup),supplementalRoot=str(root),publishedAt=time.time(),finalAuditSHA256=digest(root/'final-audit.json'))
        atomic(root/'catalog.after.json',data);atomic(intent,rawjson(report))
        for ident,entry in entries.items():
            if ident not in old:continue # Complete new folders already resolve to immutable staging.
            folder=root/'world'/Path(entry['path']).parent;target=world/Path(entry['path']).parent
            for name in ['world.json','section-pack-v1.json','ground-colour-provenance.json']:
                if (folder/name).exists():atomic(target/name,(folder/name).read_bytes())
        atomic(world/'catalog.json',data);atomic(receipt,rawjson(report));print('PUBLISHED FREE STANDARD TERRAIN',json.dumps(report),flush=True);return report
    finally:
        for lock in reversed(locks):lock.close()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--world',type=Path,required=True);p.add_argument('--audit-only',action='store_true');a=p.parse_args()
    if a.audit_only:audit(a.root)
    else:publish(a.root,a.world)
