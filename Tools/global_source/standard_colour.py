"""Colour only new standard tiles; retain downloads as checked geographic windows."""
import argparse,base64,concurrent.futures,functools,hashlib,json,sys,time,urllib.parse,urllib.request,zlib
from pathlib import Path
from common import atomic,rawjson,digest,reserve
from standard_storage import parent_lock
TOOLS=Path(__file__).resolve().parents[1];sys.path.insert(0,str(TOOLS/'world_source'))
import batch_ground_colour as colour
from pack_sections import build as pack_section,assets as section_assets

@functools.lru_cache(maxsize=4096)
def colour_destination(root,folder):
    config=root/'storage-config.json'
    if not config.exists():return folder,False
    target=Path(json.loads(config.read_bytes())['destination'])/'sources'/folder.name
    target.mkdir(parents=True,exist_ok=True)
    return target,folder.resolve()!=target.resolve()

def colour_asset(root,folder,name,data):
    directory,linked=colour_destination(root,folder);target=directory/name
    atomic(target,data)
    if linked:
        temporary=folder/(name+'.external-link');temporary.unlink(missing_ok=True);temporary.symlink_to(target);temporary.replace(folder/name)


def discover(root,originals,plan):
    cache=root/'imagery';cache.mkdir(exist_ok=True);assets=cache/'assets'
    if not assets.exists():assets.symlink_to(originals/'assets',target_is_directory=True)
    candidates=cache/'candidates.json'
    if not candidates.exists():
        items={i['id']:i for i in json.loads((originals/'candidates.json').read_bytes())}
        # Supplemental areas omitted by the original LiDAR-only imagery plan.
        for bbox in [(-9.5,57,1,61.5),(-9,53.8,-7.3,55.5)]:
            query=dict(collections='sentinel-2-l2a',bbox=','.join(map(str,bbox)),datetime='2025-05-01T00:00:00Z/2025-09-01T00:00:00Z',limit=100,query=json.dumps({'eo:cloud_cover':{'lt':65}}))
            url='https://earth-search.aws.element84.com/v1/search?'+urllib.parse.urlencode(query);seen=set();page=0
            while url:
                if url in seen:raise ValueError('STAC pagination repeated')
                seen.add(url)
                with urllib.request.urlopen(url,timeout=90) as response:data=json.load(response)
                for item in data['features']:items[item['id']]=item
                url=next((x['href'] for x in data.get('links',[]) if x['rel']=='next'),None);page+=1
                if page%10==0:print('Cached STAC discovery pages',page,'items',len(items),flush=True)
        atomic(candidates,rawjson(list(items.values())))
    selected=colour.choose_scenes(json.loads(candidates.read_bytes()),[s for r in plan['parents'] for s in r['sources']])
    fingerprint=hashlib.sha256(rawjson(['standard-ground-v1',.0002,[(s['item']['id'],s['weight']) for s in selected]])).hexdigest()
    result=dict(fingerprint=fingerprint,selected=selected,sourceGridResolutionDegrees=.0002,sourceOriginalCache=str(originals),remoteWindowCache='RGB/SCL/valid arrays and SHA-256 receipts retained per requested area; no paid API')
    atomic(cache/'scene-plan.json',rawjson(result));return result

def parent(root,row,scene_plan):
    with parent_lock(root,row['id']):return parent_unlocked(root,row,scene_plan)

def parent_unlocked(root,row,scene_plan):
    marker=root/'coloured'/(row['id']+'.json')
    if marker.exists():return
    entries=json.loads((root/'completed'/(row['id']+'.json')).read_bytes());cache=root/'imagery';bounds,_,_,_=colour.parent_grid('world-'+row['id'])
    scenes=[s for s in scene_plan['selected'] if colour.overlap(bounds,s['item']['bbox'])]
    mosaic=colour.mosaic(cache,'world-'+row['id'],scenes,scene_plan['fingerprint'],window_reserve_gib=3,full_uk=True) if scenes else None
    for entry in entries:
        folder=root/'world'/Path(entry['path']).parent;done=folder/'standard-colour-complete.json'
        if done.exists():continue
        manifest=json.loads((folder/'world.json').read_bytes());samples=colour.source_samples(mosaic,manifest) if mosaic else None
        old_pack=entry['pack'];old_maps=[];changed=0;covered=0;total=0
        # Keep a small repair journal; source elevation/vector originals remain
        # reconstructible and no previously published asset is removed.
        before=folder/'standard-before-colour.json'
        if before.exists():
            journal=json.loads(before.read_bytes());manifest=journal['manifest'];entry=journal['entry'];old_pack=entry['pack'];atomic(folder/'world.json',rawjson(manifest))
        else:atomic(before,rawjson(dict(manifest=manifest,entry=entry)))
        for tile in manifest['tiles']:
            if tile.get('terrainQuality')!='standard':continue
            if samples is None:continue
            x,y=tile['column']*colour.CORE,tile['row']*colour.CORE;patch=samples[y:y+colour.CORE+2*colour.BORDER,x:x+colour.CORE+2*colour.BORDER]
            core=patch[colour.BORDER:-colour.BORDER,colour.BORDER:-colour.BORDER,3];covered+=int((core>0).sum());total+=core.size
            if not patch[...,3].any():continue
            previous=tile['map'];packed=(folder/previous['file']).read_bytes();assert hashlib.sha256(packed).hexdigest()==previous['sha256'];vector=json.loads(zlib.decompress(packed));assert 'groundColour' not in vector
            vector['groundColour']=dict(version=1,width=patch.shape[1],height=patch.shape[0],border=colour.BORDER,rgba=base64.b64encode(patch.tobytes()).decode());data=rawjson(vector);packed=zlib.compress(data,6);sha=hashlib.sha256(packed).hexdigest();name=tile['id']+'-ground-'+sha[:16]+'.map';colour_asset(root,folder,name,packed)
            check=json.loads(zlib.decompress(packed));check.pop('groundColour');original=json.loads(zlib.decompress((folder/previous['file']).read_bytes()));assert check==original
            tile['map']=dict(file=name,byteCount=len(packed),sha256=sha,decodedByteCount=len(data));old_maps.append(previous['file']);changed+=1
        if changed:
            credit=dict(name='Copernicus Sentinel-2',attribution='Contains modified Copernicus Sentinel data 2025. Satellite-guided illustrative ground colours.',license='Copernicus Sentinel data terms',url='https://dataspace.copernicus.eu/explore-data/data-collections/sentinel-data/sentinel-2')
            manifest['sources']=[s for s in manifest['sources'] if s['name']!=credit['name']]+[credit]
            manifest['revision']+='-standard-ground-'+scene_plan['fingerprint'][:12]
            atomic(folder/'world.json',rawjson(manifest));storage=root/'storage-config.json';pack_folder=Path(json.loads(storage.read_bytes())['destination'])/'sources'/entry['id'] if storage.exists() else None;entry['pack']=pack_section(root/'world',entry,output_folder=pack_folder);entry['downloadBytes']=sum(a['byteCount'] for a in section_assets(manifest,entry))
        provenance=dict(sourceID=entry['id'],fingerprint=scene_plan['fingerprint'],tilesWithColour=changed,strength=.66,processedImageryGridResolutionDegrees=.0002,usablePercent=100*covered/max(1,total),retainedLiDARMapsUnchanged=True)
        atomic(folder/'ground-colour-provenance.json',rawjson(provenance));atomic(folder/'standard-complete.json',rawjson(entry));atomic(done,rawjson(provenance))
        if changed:
            if old_pack['file']!=entry['pack']['file']:
                old_path=folder/old_pack['file'];relocated=old_path.resolve() if old_path.is_symlink() else None
                old_path.unlink(missing_ok=True)
                storage=root/'storage-config.json'
                if relocated is not None and storage.exists():
                    destination=Path(json.loads(storage.read_bytes())['destination'])
                    if relocated.is_relative_to(destination):relocated.unlink(missing_ok=True)
            for name in old_maps:
                p=folder/name
                if not p.is_symlink():p.unlink(missing_ok=True)
    # Sources already completed before a resume retain their updated descriptor.
    entries=[json.loads((root/'world'/Path(e['path']).parent/'standard-complete.json').read_bytes()) for e in entries]
    atomic(root/'completed'/(row['id']+'.json'),rawjson(entries));atomic(marker,rawjson(dict(parent=row['id'],sources=len(entries),scenes=len(scenes))))
    print('COLOURED',row['id'],len(entries),'sources',flush=True)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--originals',type=Path,required=True);p.add_argument('--workers',type=int,default=2);a=p.parse_args()
    colour.RESOLUTION=.0002 # Retain observed material variation at bounded storage.
    plan=json.loads((a.root/'plan.json').read_bytes());scene_plan=discover(a.root,a.originals,plan);pending={r['id']:r for r in plan['parents']};failures={};retry_after={}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:
        active={}
        while pending or active:
            for ident,row in list(pending.items()):
                if (a.root/'coloured'/(ident+'.json')).exists():pending.pop(ident);continue
                if len(active)>=a.workers:break
                if time.time()<retry_after.get(ident,0):continue
                if (a.root/'completed'/(ident+'.json')).exists():active[pool.submit(parent,a.root,row,scene_plan)]=ident;pending.pop(ident)
            if active:
                done,_=concurrent.futures.wait(active,timeout=5,return_when=concurrent.futures.FIRST_COMPLETED)
                for job in done:
                    ident=active.pop(job)
                    try:job.result();failures.pop(ident,None)
                    except Exception as error:
                        failures[ident]=str(error)
                        if 'GiB free' in str(error):
                            pending[ident]=next(r for r in plan['parents'] if r['id']==ident);retry_after[ident]=time.time()+60
                        else:print('COLOUR FAILURE',ident,repr(error),flush=True)
            else:time.sleep(5)
            atomic(a.root/'colour-status.json',rawjson(dict(completed=len(list((a.root/'coloured').glob('*.json'))) if (a.root/'coloured').exists() else 0,total=len(plan['parents']),active=list(active.values()),failures=failures)))
        if failures:raise RuntimeError('Some imagery preparation failed; source windows and completed sections retained')

if __name__=='__main__':main()
