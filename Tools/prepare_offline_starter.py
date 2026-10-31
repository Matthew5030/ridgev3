#!/usr/bin/env python3
"""Prepare reproducible bundled maps from the unchanged published section packs."""
import argparse, copy, hashlib, json, shutil, struct, zlib
from pathlib import Path


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()


def write(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,separators=(',',':'),ensure_ascii=False)+'\n')


def prepare(source,selection,zones,output):
    original=(source/'catalog.json').read_bytes(); catalog=json.loads(original)
    plan=json.loads(selection.read_text()); areas=json.loads(zones.read_text())
    assert hashlib.sha256(original).hexdigest()==plan['catalogSHA256'],'Source catalogue changed; review selection before rebuilding'
    assert sha(zones)==plan['downloadZonesSHA256'],'Download boundaries changed'
    selected={r['id'] for r in plan['selectedRegions']}
    regions=[r for r in areas['regions'] if r['id'] in selected]
    assert len(regions)==len(selected)
    ids={c['id'] for r in regions for c in r.get('downloadCells',r['cells'])}
    sources=[s for s in catalog['sources'] if s['id'] in ids]
    missing=sorted(ids-{s['id'] for s in sources})
    assert missing==plan['unavailableSectionIDs'],'Coverage changed; review it explicitly'
    output.mkdir(parents=True,exist_ok=True)
    index={'schemaVersion':1,'sections':{},'coverage':[],'includedRegions':[{'id':r['id'],'name':r['name']} for r in regions]}
    for n,s in enumerate(sources,1):
        original_metadata=source/s['path']; world=json.loads(original_metadata.read_text()); world['graph']=s['routing']
        pack=s['pack']; path=(original_metadata.parent/pack['file']).resolve(strict=True)
        assert path.stat().st_size==pack['byteCount'] and sha(path)==pack['sha256'],f"Damaged source pack {s['id']}"
        required=[world['overview'],world['graph']]+[t[k] for t in world['tiles'] for k in ('mesh','map','background') if k in t]
        with path.open('rb') as f:
            header=f.read(12); assert header[:8]==b'RIDGEPK1'
            length=struct.unpack('<I',header[8:])[0]; packed=json.loads(f.read(length)); entries={e['sha256']:e for e in packed['entries']}
            assert packed['sourceID']==s['id']
            for asset in required:
                e=entries[asset['sha256']]; assert e['byteCount']==asset['byteCount']
            # Read every entry once now; runtime reads retain the same per-asset checks.
            for e in packed['entries']:
                f.seek(12+length+e['offset']); data=f.read(e['storedByteCount'])
                if e['compressed']:data=zlib.decompress(data)
                assert len(data)==e['byteCount'] and hashlib.sha256(data).hexdigest()==e['sha256']
        dest=output/s['path'];write(dest,world)
        target=dest.parent/pack['file']
        if not target.exists() or target.stat().st_size!=pack['byteCount'] or sha(target)!=pack['sha256']:shutil.copyfile(path,target)
        index['sections'][s['id']]={'metadataPath':s['path'],'metadataSHA256':sha(dest),'packPath':str(Path(s['path']).parent/pack['file']),'pack':pack}
        index['coverage'] += [t['mesh']['bounds'] for t in world['tiles']]
        if n%25==0: print(f'Verified {n}/{len(sources)} sections',flush=True)
    bundled=copy.deepcopy(catalog);bundled['sources']=sources;bundled['regionArchives']=[];bundled['regionArchiveGroups']=[]
    bundled['revision']+='-offline-starter-v1';write(output/'catalog.json',bundled)
    index['catalogSHA256']=sha(output/'catalog.json');write(output/'index.json',index)
    receipt={'schemaVersion':1,'sectionCount':len(sources),'tileCount':len(index['coverage']),'catalogSHA256':index['catalogSHA256'],'regions':index['includedRegions'],'unavailableSectionIDs':missing,'bytes':sum(p.stat().st_size for p in output.rglob('*') if p.is_file()),'sourceDataChanged':False,'allPackAndEntryChecksumsVerified':True}
    write(output.parent/'offline-starter-receipt.json',receipt);print(json.dumps(receipt),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--source',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--selection',type=Path,default=Path('Release/AppStore/offline-starter-plan.json'));p.add_argument('--zones',type=Path,default=Path('ridge v3/Resources/uk-download-zones.json'))
    a=p.parse_args();prepare(a.source,a.selection,a.zones,a.output)
