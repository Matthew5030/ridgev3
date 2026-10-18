#!/usr/bin/env python3
"""Draft larger download groups; never replaces app resources or publishes packs."""
import argparse
import hashlib
import json
import math
import re
import unicodedata
from pathlib import Path
from shapely.geometry import Polygon
from shapely.ops import unary_union
from build_zones import rectangle, add_map_footprints

ROOT = Path(__file__).resolve().parents[2]

def slug(name):
    name=unicodedata.normalize('NFKD',name).encode('ascii','ignore').decode().lower()
    return re.sub('[^a-z0-9]+','-',name).strip('-')

def caption(name):
    words=name.upper().split()
    if len(name)<=15 or len(words)<2:return name.upper()
    cut=min(range(1,len(words)),key=lambda i:abs(len(' '.join(words[:i]))-len(' '.join(words[i:]))))
    return ' '.join(words[:cut])+'\n'+' '.join(words[cut:])

def draft(current,config):
    """Partition the source grid with straight cuts around protected park cores.

    Each mainland leaf is a rectangle before coastline clipping. Unlike nearest
    anchor assignment, this cannot produce inland holes, tendrils or enclaves.
    Islands retain their own groups. Park downloads include all original edge
    sections as well as their displayed block; shared edge files can be reused.
    """
    areas={a['id']:a for a in current['regions']}
    cells={c['id']:c for a in current['regions'] for c in a['cells']}
    xs=sorted({c['bounds']['minLongitude'] for c in cells.values()})
    ys=sorted({c['bounds']['minLatitude'] for c in cells.values()})
    xi={v:i for i,v in enumerate(xs)};yi={v:i for i,v in enumerate(ys)}
    xy={i:(xi[c['bounds']['minLongitude']],yi[c['bounds']['minLatitude']]) for i,c in cells.items()}
    # Keep named island groups independent from mainland rectangular cuts.
    island_owner={};islands={}
    park_cells={c['id'] for p in current['parks'] for c in p['cells']}
    for item in config['islands']:
        ident='area-'+slug(item['name'])
        islands[ident]=dict(id=ident,name=item['name'],kind='island',cells=[])
        for ref in item['areas']:
            for c in areas[ref]['cells']:
                if c['id'] not in park_cells:island_owner.setdefault(c['id'],ident)
    for ident,owner in island_owner.items():islands[owner]['cells'].append(cells[ident])
    def envelope(ids):
        pts=[xy[i] for i in ids]
        return (min(p[0] for p in pts),min(p[1] for p in pts),max(p[0] for p in pts),max(p[1] for p in pts))
    seeds=[]
    for p in current['parks']:
        b=envelope(c['id'] for c in p['cells'])
        seeds.append(dict(name=p['name'],id=p['id'],park=p,
                          point=((b[0]+b[2])/2,(b[1]+b[3])/2),footprint=b,
                          protected=(b[0]+1,b[1]+1,b[2]-1,b[3]-1)))
    for items in config['groups'].values():
        for item in items:
            if 'area-'+slug(item['name']) in islands:continue
            refs=[c['id'] for ref in item['anchors'] for c in areas[ref]['cells']]
            pts=[xy[i] for i in refs]
            point=tuple(sum(p[axis] for p in pts)/len(pts) for axis in (0,1))
            # A park block includes the nearby countryside: don't carve a thin
            # extra region out of its bounding rectangle just for another name.
            if any(s['footprint'][0]<=point[0]<=s['footprint'][2] and s['footprint'][1]<=point[1]<=s['footprint'][3] for s in seeds if 'protected' in s):continue
            seeds.append(dict(name=item['name'],id='area-'+slug(item['name']),point=point))
    mainland=[i for i in cells if i not in island_owner]
    leaves=[]
    def partition(ids,local_seeds):
        bounds=envelope(ids)
        best=None
        for axis in (0,1):
            for cut in range(bounds[axis]+1,bounds[axis+2]+1):
                left=[s for s in local_seeds if s['point'][axis]<cut-.5]
                right=[s for s in local_seeds if s['point'][axis]>=cut-.5]
                if not left or not right:continue
                if any(s['protected'][axis]<cut<=s['protected'][axis+2] for s in local_seeds if 'protected' in s):continue
                child=[[],[]]
                for i in ids:child[xy[i][axis]>=cut].append(i)
                if not all(child):continue
                boxes=[envelope(c) for c in child]
                # Avoid narrow corridors and microscopic leftover parcels.
                if any(min(b[2]-b[0]+1,b[3]-b[1]+1)<3 for b in boxes):continue
                aspect=sum(max((b[2]-b[0]+1)/(b[3]-b[1]+1),(b[3]-b[1]+1)/(b[2]-b[0]+1)) for b in boxes)
                balance=abs(len(left)-len(right))/len(local_seeds)
                # Prefer a shared cut midway between neighbouring place anchors.
                separation=min(s['point'][axis] for s in right)-max(s['point'][axis] for s in left)
                midpoint=(min(s['point'][axis] for s in right)+max(s['point'][axis] for s in left))/2
                score=aspect+balance*3+abs(cut-.5-midpoint)*.12-separation*.03
                candidate=(score,axis,cut,child,left,right)
                if best is None or candidate[:3]<best[:3]:best=candidate
        if best:
            _,_,_,child,left,right=best
            partition(child[0],left);partition(child[1],right)
        else:leaves.append((ids,local_seeds,bounds))
    # Remove tiny coastal remnants, then recut the partition itself. Simply
    # gluing a sliver to a neighbour would reintroduce stepped/interlocking edges.
    land=unary_union([Polygon(s['rings'][0],s['rings'][1:]) for a in current['regions'] for s in a['mapShapes']])
    land_km2={i:rectangle(c).intersection(land).area*111.32**2*math.cos(math.radians((c['bounds']['minLatitude']+c['bounds']['maxLatitude'])/2)) for i,c in cells.items()}
    while True:
        leaves.clear()
        partition(mainland,seeds)
        small={s['id'] for ids,local,_ in leaves if not any('park' in s for s in local)
               and sum(land_km2[i] for i in ids)<200 for s in local}
        if not small:break
        remaining=[s for s in seeds if s['id'] not in small]
        if not remaining:raise ValueError('No regional anchors remain')
        seeds=remaining
    result=list(islands.values())
    for ids,local_seeds,b in leaves:
        parks=[s for s in local_seeds if 'park' in s]
        if parks:
            name=' & '.join(s['name'] for s in parks)
            ident=parks[0]['id'] if len(parks)==1 else 'area-'+slug(name)
            group=dict(id=ident,name=name,kind='park',parkIDs=[s['id'] for s in parks])
        else:
            mid=((b[0]+b[2])/2,(b[1]+b[3])/2)
            seed=min(local_seeds,key=lambda s:sum((s['point'][a]-mid[a])**2 for a in (0,1)))
            group=dict(id=seed['id'],name=seed['name'],kind='surrounding',parkIDs=[])
        group['cells']=[cells[i] for i in ids]
        group['gridRectangle']=list(b)
        result.append(group)
    # A straight cut can give a Scottish block a detached sliver of Cumbria
    # across the Solway. Give such mainland fragments to the area they actually
    # join on land. True islands (no shared land border) remain untouched.
    footprints={g['id']:unary_union([rectangle(c) for c in g['cells']]).intersection(land) for g in result}
    def components(geom):
        return [geom] if geom.geom_type=='Polygon' else [p for p in getattr(geom,'geoms',[]) if p.geom_type=='Polygon']
    main={i:max(components(f),key=lambda p:p.area) for i,f in footprints.items() if not f.is_empty}
    transfers=[];by_id={g['id']:g for g in result}
    for g in result:
        if g['kind']=='island' or g['id'] not in main:continue
        for fragment in components(footprints[g['id']]):
            if fragment.area>=main[g['id']].area*.25:continue
            neighbours=[(fragment.boundary.intersection(main[n['id']].boundary).length,n['id'])
                        for n in result if n['id']!=g['id'] and n['kind']!='island' and n['id'] in main]
            shared,target=max(neighbours,default=(0,None))
            if shared<1e-8:continue
            moved=[c for c in g['cells'] if rectangle(c).intersection(fragment).area>1e-10]
            if any(rectangle(c).intersection(land).difference(fragment).area>1e-10 for c in moved):continue
            moved_ids={c['id'] for c in moved}
            g['cells']=[c for c in g['cells'] if c['id'] not in moved_ids]
            by_id[target]['cells'].extend(moved)
            transfers.append(dict(source=g['id'],target=target,cells=sorted(moved_ids)))
    parks_by_id={p['id']:p for p in current['parks']}
    for g in result:
        if g['kind']=='park':
            downloads={c['id']:c for c in g['cells']}
            downloads.update({c['id']:c for p in g['parkIDs'] for c in parks_by_id[p]['cells']})
            g['downloadCells']=sorted(downloads.values(),key=lambda c:c['id'])
    result=[g for g in result if g['cells']]
    for g in result:
        g['cells'].sort(key=lambda c:c['id'])
        g['landAreaKm2']=sum(land_km2[c['id']] for c in g['cells'])
        g['mapLabel']=caption(g['name'])
        g['subtitle']='Draft download area · coast-clipped block'
    assert len({g['name'] for g in result})==len(result)
    return dict(schemaVersion=3,description='Preview only: simple coast-clipped blocks with parks kept together.',
                boundarySources=current['boundarySources'],regions=result,parks=[],
                draft=True,coastalTransfers=transfers,baseZoneCount=len(current['regions']),
                anchorSHA256=hashlib.sha256(json.dumps(config,sort_keys=True).encode()).hexdigest())

def analyse(result,catalog):
    sources={s['id']:s for s in catalog['sources']}
    for g in result['regions']:
        polygons=[Polygon(s['rings'][0],s['rings'][1:]) for s in g['mapShapes']]
        land=unary_union(polygons)
        source_ids=[c['id'] for c in g.get('downloadCells',g['cells']) if c['id'] in sources]
        members=[sources[i] for i in source_ids]
        missing=[]
        for c in g['cells']:
            source=sources.get(c['id'])
            if source is None:missing.append(rectangle(c))
            else:
                for b in source.get('missingTerrain',[]):missing.append(rectangle({'bounds':b}))
        gaps=unary_union(missing).intersection(land) if missing else Polygon()
        gap_polygons=[gaps] if gaps.geom_type=='Polygon' else [p for p in getattr(gaps,'geoms',[]) if p.geom_type=='Polygon']
        g['missingShapes']=[dict(rings=[list(p.exterior.coords)]+[list(r.coords) for r in p.interiors]) for p in gap_polygons if not p.is_empty]
        g['stats']=dict(sectionCount=len(members),tileCount=sum(s['tileCount'] for s in members),
                       sectionBytes=sum(s['pack']['byteCount'] for s in members),
                       availability='unavailable' if not members or land.is_empty or gaps.area>=land.area-1e-10 else 'partial' if gaps.area>1e-10 else 'available')
        exact=next((a for a in catalog.get('regionArchives',[]) if a['id']==g['id'] and set(a['sourceIDs'])==set(source_ids)),None)
        g['stats']['archiveBytes']=exact['asset']['byteCount'] if exact else None
        g['stats']['estimateBytes']=exact['asset']['byteCount'] if exact else math.ceil(g['stats']['sectionBytes']*1.01)
        g['stats']['oversize']=g['stats']['estimateBytes']>1_000_000_000 or len(members)>128
    result['summary']=dict(areas=sum(bool(g['mapShapes']) for g in result['regions']),
        parks=sum(g['kind']=='park' for g in result['regions']),
        publishedSections=len({c['id'] for g in result['regions'] for c in g['cells'] if c['id'] in sources}),
        totalSectionBytes=sum(s['pack']['byteCount'] for s in sources.values()),
        unavailable=sum(g['stats']['availability']=='unavailable' and bool(g['mapShapes']) for g in result['regions']),
        oversize=[g['name'] for g in result['regions'] if g['stats']['oversize']])

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'Artifacts/larger-regions-preview')
    a=p.parse_args()
    current=json.loads((ROOT/'ridge v3/Resources/uk-download-zones.json').read_text())
    config=json.loads(Path(__file__).with_name('large-area-anchors.json').read_text())
    result=draft(current,config)
    add_map_footprints(result,a.source_root,ROOT/'ridge v3/Resources/RidgeData.bundle/atlas.json')
    raw_catalog=(a.source_root/'world-v1-2026-10-04/catalog.json').read_bytes()
    catalog=json.loads(raw_catalog)
    result['catalogueSnapshot']=dict(revision=catalog.get('revision'),sha256=hashlib.sha256(raw_catalog).hexdigest())
    analyse(result,catalog)
    a.output.mkdir(parents=True,exist_ok=True)
    (a.output/'regions.json').write_text(json.dumps(result,separators=(',',':'),ensure_ascii=False)+'\n')
    # The preview is fully local; no third-party map or tile requests.
    template=Path(__file__).with_name('large-area-preview.html').read_text()
    payload=json.dumps({'proposed':result,'current':current},separators=(',',':'),ensure_ascii=False).replace('</','<\\/')
    (a.output/'index.html').write_text(template.replace('__REGION_DATA__',payload))
    print(json.dumps(result['summary'],indent=2))
    for g in sorted(result['regions'],key=lambda g:-g['stats']['estimateBytes'])[:15]:
        print(g['name'],g['stats']['sectionCount'],round(g['stats']['estimateBytes']/1e6),'MB',g['stats']['availability'])

if __name__=='__main__':main()
