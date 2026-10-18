#!/usr/bin/env python3
"""Draft larger download groups; never replaces app resources or publishes packs."""
import argparse
import hashlib
import json
import math
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from shapely.geometry import Polygon, shape
from shapely.ops import unary_union
from build_zones import centre, rectangle, add_map_footprints, PARKS

ROOT = Path(__file__).resolve().parents[2]

def slug(name):
    name=unicodedata.normalize('NFKD',name).encode('ascii','ignore').decode().lower()
    return re.sub('[^a-z0-9]+','-',name).strip('-')

def caption(name):
    words=name.upper().split()
    if len(name)<=15 or len(words)<2:return name.upper()
    cut=min(range(1,len(words)),key=lambda i:abs(len(' '.join(words[:i]))-len(' '.join(words[i:]))))
    return ' '.join(words[:cut])+'\n'+' '.join(words[cut:])

def draft(current,grid,config,source_root):
    areas={a['id']:a for a in current['regions']}
    cells={c['id']:c for a in current['regions'] for c in a['cells']}
    parents={c['id']:g['id'] for g in grid['regions'] for c in g['cells']}
    assigned={};groups={}
    def new(ident,name,kind,**extra):
        groups[ident]=dict(id=ident,name=name,mapLabel=caption(name),kind=kind,
                          subtitle='Draft download area · existing source sections',cells=[],**extra)
    park_geometry={'park-'+ident:shape(json.loads((source_root/(folder+'-adaptive-0p5')/'boundary.geojson').read_text())['geometry']) for ident,_,_,folder,_ in PARKS}
    # A few park boundaries touch the same immutable source section. Draw one
    # owner (largest actual park intersection) while keeping both full downloads.
    shared=[]
    for park in current['parks']:
        new(park['id'],park['name'],'park',parkID=park['id'],parkName=park['name'],artwork=park.get('artwork','countryside'),downloadCells=park['cells'])
        for c in park['cells']:
            if c['id'] in assigned:
                old=assigned[c['id']]
                shared.append(dict(section=c['id'],parks=[old,park['id']]))
                assigned[c['id']]=max([old,park['id']],key=lambda p:(park_geometry[p].intersection(rectangle(c)).area,p))
            else:assigned[c['id']]=park['id']
    for island in config['islands']:
        ident='area-'+slug(island['name']);new(ident,island['name'],'island')
        for area in island['areas']:
            for c in areas[area]['cells']:
                assigned.setdefault(c['id'],ident)
    anchors={}
    for group,items in config['groups'].items():
        anchors[group]=[]
        for item in items:
            ident='area-'+slug(item['name'])
            if ident not in groups:new(ident,item['name'],'surrounding')
            points=[]
            for ref in item['anchors']:
                a=areas[ref];b=a['labelBounds']
                if b is None:raise ValueError('Anchor has no land: '+ref)
                points.append(((b['minLongitude']+b['maxLongitude'])/2,(b['minLatitude']+b['maxLatitude'])/2))
            anchors[group].append((ident,points))
    for ident,c in cells.items():
        if ident not in assigned:
            parent=re.sub(r'^world-|\-c\d+-r\d+$','',ident)
            x,y=centre(c)
            def distance(item):
                return (min(((x-px)*math.cos(math.radians(y)))**2+(y-py)**2 for px,py in item[1]),item[0])
            assigned[ident]=min(anchors[parents[parent]],key=distance)[0]
        groups[assigned[ident]]['cells'].append(c)
    result=[g for g in groups.values() if g['cells']]
    for g in result:g['cells'].sort(key=lambda c:c['id'])
    assert len(assigned)==len(cells)
    assert len({g['name'] for g in result})==len(result)
    return dict(schemaVersion=3,description='Preview only: whole parks, island groups and larger surrounding areas.',
                boundarySources=current['boundarySources'],regions=result,parks=[],
                draft=True,sharedParkSections=shared,baseZoneCount=len(current['regions']),
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
    grid=json.loads((ROOT/'ridge v3/Resources/uk-pack-regions.json').read_text())
    config=json.loads(Path(__file__).with_name('large-area-anchors.json').read_text())
    result=draft(current,grid,config,a.source_root)
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
