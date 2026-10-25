"""Relocate checked assets losslessly, retaining stable cache paths."""
import argparse,contextlib,fcntl,json,shutil,subprocess,time
from pathlib import Path
from common import atomic,rawjson,digest


@contextlib.contextmanager
def parent_lock(root,ident,blocking=True):
    folder=root/'parent-locks';folder.mkdir(exist_ok=True)
    with (folder/ident).open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|(0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:yield False;return
        try:yield True
        finally:fcntl.flock(lock,fcntl.LOCK_UN)


def relocate(file,target,receipt):
    size=file.stat().st_size
    while shutil.disk_usage(target.parent).free<2*1024**3+size:time.sleep(5)
    sha=digest(file)
    if target.exists():
        if target.stat().st_size!=size or digest(target)!=sha:raise ValueError('Relocation destination differs: '+str(target))
    else:
        temporary=target.with_name(target.name+'.incoming')
        subprocess.run(['/usr/bin/ditto','--hfsCompression',str(file),str(temporary)],check=True)
        if temporary.stat().st_size!=size or digest(temporary)!=sha:raise ValueError('Relocated data checksum mismatch')
        temporary.replace(target)
    temporary=file.with_name(file.name+'.external-link');temporary.unlink(missing_ok=True);temporary.symlink_to(target);temporary.replace(file)
    receipt.write(json.dumps(dict(path=str(file),destination=str(target),sha256=sha,byteCount=size))+'\n');receipt.flush()
    return size


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--destination',type=Path,required=True);args=parser.parse_args();args.destination.mkdir(parents=True,exist_ok=True)
    geometry_scanned=set()
    atomic(args.root/'storage-config.json',rawjson(dict(destination=str(args.destination.resolve()))))
    plan=json.loads((args.root/'plan.json').read_bytes());pending={r['id']:r for r in plan['parents']};count=total=0
    journal=args.root/'storage-relocation.jsonl'
    if journal.exists():
        for line in journal.read_text().splitlines():
            row=json.loads(line);count+=1;total+=row['byteCount']
    with journal.open('a') as receipt:
        while pending:
            advanced=False
            for ident,row in list(pending.items()):
                with parent_lock(args.root,ident,blocking=False) as acquired:
                    if not acquired:continue
                    coloured=(args.root/'coloured'/(ident+'.json')).exists()
                    # Geometry outputs become immutable source by source. Moving the
                    # large overview/graph now prevents a geometry/imagery deadlock.
                    # Mutable world metadata and packs wait until colouring finishes.
                    for source in row['sources']:
                        folder=args.root/'world/sources'/source['id']
                        if not coloured and source['id'] in geometry_scanned:continue
                        if not (folder/'standard-complete.json').exists():continue
                        target=args.destination/'sources'/source['id'];target.mkdir(parents=True,exist_ok=True)
                        if folder.resolve()==target.resolve():
                            geometry_scanned.add(source['id']);continue
                        for file in folder.iterdir():
                            immutable=(file.suffix=='.ridgepack' or file.suffix=='.json') and file.name not in {'world.json','standard-complete.json'}
                            if not coloured and not immutable:continue
                            if file.is_symlink() or not file.is_file():continue
                            if file.suffix not in {'.json','.ridgepack'} or file.stat().st_size<65536:continue
                            total+=relocate(file,target/file.name,receipt);count+=1;advanced=True
                        geometry_scanned.add(source['id'])
                    if coloured:
                        pending.pop(ident);advanced=True
                        print('RELOCATED',ident,'files',count,'bytes',total,flush=True)
                    if advanced:
                        atomic(args.root/'storage-status.json',rawjson(dict(completedParents=len(plan['parents'])-len(pending),totalParents=len(plan['parents']),relocatedFiles=count,logicalBytesRelocated=total,externalFreeBytes=shutil.disk_usage(args.destination).free)))
            if not advanced:time.sleep(5)
    atomic(args.root/'STORAGE-COMPLETE.json',rawjson(dict(relocatedFiles=count,logicalBytesRelocated=total,destination=str(args.destination))))

if __name__=='__main__':main()
