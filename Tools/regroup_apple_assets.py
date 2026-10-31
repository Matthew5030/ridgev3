#!/usr/bin/env python3
"""Build a full UK publication within the live account's existing 100 pack IDs.

Pack IDs are opaque, stable slots. No Apple asset is archived, deleted or renamed.
Source metadata snapshots and resolved section payloads are read from a verified
preparation plan; original map data is never modified or copied for staging.
"""
import argparse, copy, hashlib, json, sys
from collections import defaultdict
from pathlib import Path
from prepare_apple_assets import group_for, manifest, write_json, digest
LIBRARY_ID = 'ridge-uk-v1-metadata-081-051'


def center(source, axis):
    b = source['bounds']
    return (b['min'+axis] + b['max'+axis]) / 2


def split_bucket(sources):
    total = sum(s['pack']['byteCount'] for s in sources)
    best = None
    for axis in ['Longitude', 'Latitude']:
        ordered = sorted(sources, key=lambda s:(center(s,axis),s['id']))
        left = 0
        for n in range(1,len(ordered)):
            left += ordered[n-1]['pack']['byteCount']
            a,b = center(ordered[n-1],axis),center(ordered[n],axis)
            if a == b: continue
            candidate = (max(left,total-left),axis,(a+b)/2,n,ordered)
            if best is None or candidate[:4] < best[:4]: best = candidate
    if best is None: raise ValueError('Cannot divide a geographic bucket')
    _,axis,cut,n,ordered = best
    return ordered[:n],ordered[n:],{'axis':axis,'cut':cut}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--previous',type=Path,required=True)
    p.add_argument('--slots',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--registry',type=Path,help='Preserve existing geographic cuts and Apple slot assignments on updates')
    a=p.parse_args();previous=a.previous.resolve(strict=True);output=a.output.resolve()
    if (output/'plan.json').exists():raise ValueError('Choose a fresh regrouping output')
    old=json.loads((previous/'plan.json').read_text())
    slots_doc=json.loads(a.slots.read_text())
    slots_doc=slots_doc.get('assets',slots_doc)
    frozen=json.loads(a.registry.read_text()) if a.registry else None
    slots=sorted(x['attributes']['assetPackIdentifier'] for x in slots_doc['data'] if not x['attributes']['archived'])
    if len(slots)!=100 or len(set(slots))!=100 or LIBRARY_ID not in slots:raise ValueError('Expected the 100 verified active Apple slots')
    if not set(slots)<=set(old['groups']):raise ValueError('Unexpected unrelated Apple slot')
    raw=(Path(old['sourceRoot'])/'catalog.json').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=old['sourceCatalogSHA256']:raise ValueError('Source catalogue changed')
    catalog=json.loads(raw);catalog['regionArchives']=[];catalog['regionArchiveGroups']=[]
    catalog['revision']+='-apple-uk-100-v1'
    metadata={};terrain={}
    for files in old['groups'].values():
        for item in files:
            if 'sourceID' in item:terrain[item['sourceID']]=item
            elif item['path'].endswith('/world.json'):metadata[Path(item['path']).parent.name]=item
    expected={s['id'] for s in catalog['sources']}
    if set(metadata)!=expected or set(terrain)!=expected:raise ValueError('Incomplete source preparation')
    meta=defaultdict(list);buckets=defaultdict(list)
    for s in catalog['sources']:
        meta['metadata-'+group_for(s,8,8)].append(s)
        buckets['terrain-'+group_for(s,4,4)].append(s)
    budget=len(slots)-len(meta)-1
    cuts=[]
    if frozen:
        if frozen['libraryPackID']!=LIBRARY_ID or set(frozen['allSlots'])!=set(slots):raise ValueError('The frozen registry does not match this app')
        for cut in frozen['terrainCuts']:
            sources=sorted(buckets.pop(cut['group']),key=lambda x:(center(x,cut['axis']),x['id']))
            left=[x for x in sources if center(x,cut['axis'])<cut['cut']]
            right=[x for x in sources if center(x,cut['axis'])>=cut['cut']]
            if not left or not right:raise ValueError('Source coverage changed; review the geographic registry')
            buckets[cut['group']+'-0']=left;buckets[cut['group']+'-1']=right
        cuts=frozen['terrainCuts']
    while len(buckets)<budget and not frozen:
        key=max((k for k in buckets if len(buckets[k])>1),key=lambda k:(sum(s['pack']['byteCount'] for s in buckets[k]),k))
        left,right,cut=split_bucket(buckets.pop(key))
        cuts.append(dict(group=key,**cut));buckets[key+'-0']=left;buckets[key+'-1']=right
    if len(buckets)!=budget:raise ValueError('Pack budget exceeded')
    pool=[k for k in slots if k!=LIBRARY_ID]
    meta_pool=[k for k in pool if '-metadata-' in k]
    if len(meta_pool)<len(meta):raise ValueError('Not enough metadata slots')
    mapping={k:v for k,v in zip(sorted(meta),meta_pool)}
    remaining=[k for k in pool if k not in mapping.values()]
    remaining.sort(key=lambda k:('-terrain-' not in k,k))
    mapping.update(zip(sorted(buckets),remaining))
    if frozen:
        if set(frozen['packIDs'])!=set(meta)|set(buckets):raise ValueError('Coverage moved outside the frozen registry')
        mapping=frozen['packIDs']
    if set(mapping.values())|{LIBRARY_ID}!=set(slots):raise ValueError('Slot assignment mismatch')
    groups={};sections={};source_meta={};source_terrain={}
    for logical,sources in meta.items():
        slot=mapping[logical];groups[slot]=[copy.deepcopy(metadata[s['id']]) for s in sources]
        for s in sources:source_meta[s['id']]=slot
    for logical,sources in buckets.items():
        slot=mapping[logical];groups[slot]=[copy.deepcopy(terrain[s['id']]) for s in sources]
        for s in sources:source_terrain[s['id']]=slot
    for s in catalog['sources']:
        item=metadata[s['id']];payload=terrain[s['id']]
        sections[s['id']]={'metadataPack':source_meta[s['id']],'terrainPack':source_terrain[s['id']],
                           'metadataPath':item['path'],'metadataSHA256':item['sha256'],
                           'packPath':payload['path'],'pack':s['pack']}
    if any(sum(f['bytes'] for f in files)>4_000_000_000 for files in groups.values()):raise ValueError('Pack exceeds client size bound')
    catalog_file=output/'metadata/world/catalog.json';write_json(catalog_file,catalog)
    library={'schemaVersion':1,'revision':catalog['revision'],'catalogPath':'world/catalog.json',
             'catalogSHA256':digest(catalog_file),'sections':sections,
             'downloadBytes':{k:sum(f['bytes'] for f in files) for k,files in groups.items()}}
    library_file=output/'metadata/RidgeMaps/library.json';write_json(library_file,library)
    groups[LIBRARY_ID]=[{'file':str(f),'path':path,'bytes':f.stat().st_size,'sha256':digest(f)} for f,path in [(catalog_file,'world/catalog.json'),(library_file,'RidgeMaps/library.json')]]
    for key,files in groups.items():manifest(output,key,files,essential=key==LIBRARY_ID)
    plan={k:v for k,v in old.items() if k!='groups'}
    plan.update(libraryPackID=LIBRARY_ID,assetPackCount=len(groups),groups=groups,
                accountPackLimit=100,metadataGroupCount=len(meta),terrainGroupCount=len(buckets),reusedAppleSlots=True,
                maximumTerrainBytes=max(sum(s['pack']['byteCount'] for s in sources) for sources in buckets.values()))
    write_json(output/'registry.json',{'schemaVersion':1,'metadataStride':[8,8],'terrainStride':[4,4],'libraryPackID':LIBRARY_ID,'packIDs':mapping,'terrainCuts':cuts,'allSlots':slots})
    write_json(output/'plan.json',plan)
    assert (Path(old['sourceRoot'])/'catalog.json').read_bytes()==raw
    print(json.dumps({k:v for k,v in plan.items() if k!='groups'},indent=2))


if __name__=='__main__':main()
