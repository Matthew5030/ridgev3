#!/usr/bin/env python3
"""Carry completed, unchanged grid sections into a new immutable UK build plan.
Run only after the earlier worker has stopped. Nothing in the old revision is
changed, and every imported container and selection identity is checked.
"""
import argparse,fcntl,hashlib,json,shutil,sqlite3
from pathlib import Path
from publish_adaptive import atomic_json


def sha(data):return hashlib.sha256(data).hexdigest()


def selection_hash(selection):
    return sha(json.dumps([{k:c[k] for k in ['id','bounds','sourceSHA256']} for c in sorted(selection['chunks'],key=lambda c:c['id'])],sort_keys=True).encode())


def copy_directory(source,destination):
    destination.mkdir(parents=True,exist_ok=True)
    for path in source.iterdir():
        if not path.is_file():raise ValueError('Expected a flat published/archive section')
        target=destination/path.name
        if target.exists():
            if sha(target.read_bytes())!=sha(path.read_bytes()):raise ValueError('Different existing imported file')
        else:
            # Hard links retain exact immutable bytes without duplicating payloads.
            try:target.hardlink_to(path)
            except OSError:shutil.copyfile(path,target)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--previous-build',type=Path,required=True);p.add_argument('--previous-downloads',type=Path,required=True)
    p.add_argument('--build',type=Path,required=True);p.add_argument('--downloads',type=Path,required=True);a=p.parse_args()
    if (a.build/'build-inputs.json').exists():raise ValueError('Import before starting the new build')
    locks=[]
    for root in [a.previous_build,a.build]:
        root.mkdir(parents=True,exist_ok=True);f=(root/'.run.lock').open('w');fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB);locks.append(f)
    plan=json.loads((a.build/'plan.json').read_bytes());old_plan=json.loads((a.previous_build/'plan.json').read_bytes())
    if any(plan[k]!=old_plan[k] for k in ['boundarySHA256','worldGridSHA256']):raise ValueError('World grid or boundary changed')
    old_identity=json.loads((a.previous_build/'build-inputs.json').read_bytes());catalog=json.loads((a.previous_downloads/'catalog.json').read_bytes());old_status=json.loads((a.previous_build/'status.json').read_bytes())
    if old_identity['planSHA256']!=sha((a.previous_build/'plan.json').read_bytes()):raise ValueError('Previous frozen plan mismatch')
    status=dict(partitions={});imported=[];skipped=[];a.downloads.mkdir(parents=True,exist_ok=True)
    for entry in catalog['partitions']:
        key=entry['id'];selection=json.loads((a.build/'selection'/(key+'.json')).read_bytes());archive=a.previous_build/'partitions'/key
        raw=(archive/'manifest.json').read_bytes();manifest=json.loads(raw);index_raw=(a.previous_downloads/entry['path']).read_bytes();index=json.loads(index_raw)
        if sha(raw)!=index['sourceManifestSHA256'] or sha(index_raw)!=entry['sha256']:raise ValueError('Previous publication identity mismatch')
        if selection_hash(selection)!=manifest['sourceSelectionSHA256']:
            skipped.append(key);continue
        if manifest['compilerSHA256']!=old_identity['compilerSHA256']:raise ValueError('Compiler mismatch')
        validation=json.loads((archive/'validation.json').read_bytes())
        if validation['manifestSHA256']!=sha(raw) or validation['maxSeamHeightDifferenceMetres']!=0:raise ValueError('Previous validation mismatch')
        source_directory=(a.previous_downloads/entry['path']).parent;container=source_directory/index['container']['path'];h=hashlib.sha256()
        with container.open('rb') as f:
            for data in iter(lambda:f.read(4*1024*1024),b''):h.update(data)
        if h.hexdigest()!=index['container']['sha256'] or container.stat().st_size!=index['container']['byteCount']:raise ValueError('Container checksum mismatch')
        copy_directory(source_directory,a.downloads/source_directory.name);copy_directory(archive,a.build/'partitions'/key)
        status['partitions'][key]={**old_status['partitions'][key], 'importedFrom':old_plan['id']};imported.append(key)
        if len(imported)%25==0:print('Imported verified sections:',len(imported),flush=True)
    # Retain only seam evidence owned by the imported, unchanged sections.
    database=a.build/'outer-edges.sqlite'
    if database.exists():database.unlink()
    old_db=sqlite3.connect(a.previous_build/'outer-edges.sqlite');db=sqlite3.connect(database);old_db.backup(db);old_db.close()
    accepted=set(imported)
    for key,first,second in db.execute('SELECT key,firstOwner,secondOwner FROM edges').fetchall():
        if first not in accepted:
            if second in accepted:db.execute('UPDATE edges SET firstOwner=?,secondOwner=NULL WHERE key=?',(second,key))
            else:db.execute('DELETE FROM edges WHERE key=?',(key,))
        elif second not in accepted:db.execute('UPDATE edges SET secondOwner=NULL WHERE key=?',(key,))
    db.commit();db.close()
    catalog['partitions']=[entry for entry in catalog['partitions'] if entry['id'] in accepted]
    catalog['chunkCount']=sum(entry['chunks'] for entry in catalog['partitions']);catalog['meshBytes']=sum(entry['meshBytes'] for entry in catalog['partitions'])
    catalog['id']=plan['id'];catalog['buildComplete']=False;catalog['officialSurveyCoverage']=plan['officialSurveyCoverage'];catalog['expectedDetailedSections']=sum(t['chunkCount']>0 for t in plan['partitions'])
    atomic_json(a.downloads/'catalog.json',catalog);atomic_json(a.build/'status.json',status)
    atomic_json(a.build/'imported-sections.json',dict(previousID=old_plan['id'],previousCatalogSHA256=sha((a.previous_downloads/'catalog.json').read_bytes()),compilerSHA256=old_identity['compilerSHA256'],sections=imported,changedSelectionsToRebuild=skipped,allContainersHashed=True))
    print('Imported',len(imported),'unchanged, verified sections;',len(skipped),'changed selections will rebuild.',flush=True)


if __name__=='__main__':main()
