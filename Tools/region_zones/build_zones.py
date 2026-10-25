#!/usr/bin/env python3
"""Build selectable zones from existing OSM park boundaries and source cells.

No map assets are rebuilt. Compact areas partition source sections; national
parks are separate grouped downloads sharing the same cached assets. Selection
shapes follow the coastline without carving out missing terrain tiles.
Requires shapely (also used by the terrain pipeline).
"""
import argparse
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from shapely.geometry import box, shape, Polygon, Point
from shapely.ops import unary_union

PARKS = [
    ('eryri', 'Eryri', 'ERYRI', 'eryri-park', 'wales'),
    ('lake-district', 'Lake District', 'LAKES', 'lake-district', 'lakes-dales'),
    ('peak-district', 'Peak District', 'PEAKS', 'peak-district', 'midlands'),
    ('bannau', 'Bannau Brycheiniog', 'BANNAU', 'bannau-brycheiniog', 'wales'),
    ('yorkshire-dales', 'Yorkshire Dales', 'DALES', 'yorkshire-dales', 'lakes-dales'),
    ('cairngorms', 'Cairngorms', 'CAIRNGORMS', 'cairngorms', 'west-highlands'),
    ('loch-lomond', 'Loch Lomond & the Trossachs', 'LOMOND', 'loch-lomond-and-the-trossachs', 'lowlands'),
    ('northumberland', 'Northumberland', 'NORTHUMBERLAND', 'northumberland', 'north-east'),
    ('north-york-moors', 'North York Moors', 'MOORS', 'north-york-moors', 'north-east'),
    ('dartmoor', 'Dartmoor', 'DARTMOOR', 'dartmoor', 'south-west'),
    ('exmoor', 'Exmoor', 'EXMOOR', 'exmoor', 'south-west'),
    ('pembrokeshire', 'Pembrokeshire Coast', 'PEMBROKE', 'pembrokeshire-coast', 'wales'),
    ('south-downs', 'South Downs', 'DOWNS', 'south-downs', 'south-east'),
    ('new-forest', 'New Forest', 'NEW\nFOREST', 'new-forest', 'south-east'),
    ('broads', 'The Broads', 'BROADS', 'the-broads', 'east-anglia'),
]


def centre(cell):
    b = cell['bounds']
    return ((b['minLongitude']+b['maxLongitude'])/2, (b['minLatitude']+b['maxLatitude'])/2)


def rectangle(cell):
    b = cell['bounds']
    return box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude'])


def build(grid, source_root):
    divisions = json.loads(Path(__file__).with_name('surrounding-areas.json').read_text())
    groups = {g['id']: g['cells'] for g in grid['regions']}
    cells = {}
    # Publication cells contain a 48 x 48 tile grid, served in 16 x 16 sections.
    for division in divisions:
        for parent in groups[division['group']]:
            b = parent['bounds']
            dx = (b['maxLongitude']-b['minLongitude'])/3
            dy = (b['maxLatitude']-b['minLatitude'])/3
            for row in range(3):
                for col in range(3):
                    ident = f"world-{parent['id']}-c{col*16:02d}-r{row*16:02d}"
                    cell = dict(id=ident, bounds=dict(minLongitude=b['minLongitude']+col*dx,
                        maxLongitude=b['minLongitude']+(col+1)*dx,
                        minLatitude=b['maxLatitude']-(row+1)*dy, maxLatitude=b['maxLatitude']-row*dy))
                    cells[ident] = cell
    catalog = json.loads((source_root/'world-v1-2026-10-04/catalog.json').read_text())
    for source in catalog['sources']:
        assert source['id'] in cells, source['id']
        assert all(abs(v-cells[source['id']]['bounds'][k]) < 1e-8 for k, v in source['bounds'].items())
    geometries, provenance = [], []
    for ident, name, label, folder, art in PARKS:
        path = source_root/(folder+'-adaptive-0p5')/'boundary.geojson'
        raw = path.read_bytes()
        feature = json.loads(raw)
        geometry = shape(feature['geometry'])
        assert geometry.is_valid, ident
        geometries.append(geometry)
        provenance.append(dict(id=ident, sha256=hashlib.sha256(raw).hexdigest(), **feature['properties']))
    # Map areas are compact blocks of existing source sections, independent
    # of park boundaries. Park downloads are a separate, overlapping index;
    # their shared assets are already deduplicated by the downloader.
    parks = []
    for (ident, name, label, folder, art), geometry in zip(PARKS, geometries):
        members = [c for c in cells.values() if geometry.intersection(rectangle(c)).area > 1e-12]
        parks.append(dict(id='park-'+ident, name=name, mapLabel=label.replace('\n', ' '),
            parkID='park-'+ident, parkName=name, artwork=art,
            subtitle='National park · includes map sections along the boundary',
            cells=sorted(members,key=lambda c:c['id'])))
    land = unary_union([Polygon(r).buffer(0) for r in json.loads(Path('ridge v3/Resources/RidgeData.bundle/atlas.json').read_text())['land']])
    # Use published walking-map sheet footprints as anchors. Each existing
    # source section has exactly one owner, including sections in sheet overlaps.
    reference_path=Path(__file__).with_name('sheet-reference.json')
    reference=json.loads(reference_path.read_text())
    sheets=[s for s in reference['sheets'] if not shape(s['geometry']).buffer(0).is_empty]
    shapes=[shape(sheet['geometry']).buffer(0) for sheet in sheets]
    bounds=[g.bounds for g in shapes]
    groups=defaultdict(list)
    for cell in cells.values():
        rect=rectangle(cell);cx,cy=centre(cell)
        candidates=[i for i,(w,s,e,n) in enumerate(bounds)
                    if w<rect.bounds[2] and e>rect.bounds[0] and s<rect.bounds[3] and n>rect.bounds[1]]
        footprint=rect.intersection(land)
        if footprint.is_empty: footprint=rect
        def score(i):
            w,s,e,n=bounds[i]
            dx=(cx-(w+e)/2)/max(0.01,(e-w)/2)
            dy=(cy-(s+n)/2)/max(0.01,(n-s)/2)
            # Prefer a sheet containing the land in this section; within the
            # overlap use proximity to its centre for a compact shared boundary.
            overlap=shapes[i].intersection(footprint).area/footprint.area
            return (3*(1-overlap)+math.hypot(dx,dy),sheets[i]['id'])
        if not candidates:
            # Offshore bins still retain ownership for catalogue completeness.
            candidates=sorted(range(len(sheets)),key=lambda i:
                ((cx-shapes[i].centroid.x)*math.cos(math.radians(cy)))**2+
                (cy-shapes[i].centroid.y)**2)[:4]
        owner=min(candidates,key=score)
        groups[owner].append(cell)
    zones=[]
    short_names={
        'explorer-ol1':('Dark Peak','DARK\nPEAK'),
        'explorer-ol24':('White Peak','WHITE\nPEAK'),
        'explorer-ol4':('North Western Lakes','NW\nLAKES'),
        'explorer-ol5':('North Eastern Lakes','NE\nLAKES'),
        'explorer-ol6':('South Western Lakes','SW\nLAKES'),
        'explorer-ol7':('South Eastern Lakes','SE\nLAKES'),
        'explorer-ol17':('Snowdon & Conwy Valley','SNOWDON &\nCONWY'),
        'explorer-ol18':('Harlech, Porthmadog & Bala','HARLECH &\nBALA'),
    }
    map_labels={
        '262':'ANGLESEY\nWEST','263':'ANGLESEY\nEAST',
        '253':'LLŶN\nWEST','254':'LLŶN\nEAST',
        '359':'OBAN &\nKERRERA','376':'NORTH LORN',
        '407':'DUNVEGAN','408':'TROTTERNISH','410':'PORTREE',
        '411':'CUILLIN','412':'SLEAT','461':'EAST\nMAINLAND',
        '462':'HOY','463':'WEST\nMAINLAND','464':'WESTRAY','465':'SANDAY',
        '466':'SHETLAND\nSOUTH','467':'SHETLAND\nCENTRAL',
        '468':'SHETLAND\nNE','469':'SHETLAND\nNW','470':'UNST & YELL',
        'ol2':'SOUTHERN\nDALES','ol30':'NORTHERN\nDALES',
        'ol26':'WESTERN\nMOORS','ol27':'EASTERN\nMOORS'}
    for owner,members in sorted(groups.items()):
        sheet=sheets[owner]
        name=re.sub(r'\s*National Park\s*',' ',sheet['name'],flags=re.I).strip()
        name=re.sub(r'\s+',' ',name)
        # Keep the full geographic title in the inspector, with its leading
        # locality on the map. Never expose stock numbers or generic N/NE bins.
        label=re.split(r',| & | - | / ',name)[0].strip()
        label=label.removeprefix('The ') if hasattr(label,'removeprefix') else label
        words=label.upper().split()
        if len(label)>10 and len(words)>1:
            cut=min(range(1,len(words)),key=lambda i:abs(len(' '.join(words[:i]))-len(' '.join(words[i:]))))
            label=' '.join(words[:cut])+'\n'+' '.join(words[cut:])
        else: label=label.upper()
        name,label=short_names.get(sheet['id'],(name,label))
        label=map_labels.get(sheet['id'].removeprefix('explorer-'),label)
        footprint=unary_union([rectangle(c) for c in members]).intersection(land)
        overlaps=[g.intersection(footprint).area for g in geometries]
        park=max(range(len(PARKS)),key=lambda i:overlaps[i]) if max(overlaps)>0 else None
        metadata=dict(artwork='countryside')
        if park is not None:
            metadata=dict(parkID='park-'+PARKS[park][0],parkName=PARKS[park][1],artwork=PARKS[park][4])
        zones.append(dict(id='sheet-'+sheet['id'],name=name,mapLabel=label,
            cells=sorted(members,key=lambda c:c['id']),subtitle='Walking area · clipped at the coast',**metadata))
    assert len({z['name'] for z in zones})==len(zones)
    assert len({z['mapLabel'] for z in zones})==len(zones)
    assigned=[c['id'] for z in zones for c in z['cells']]
    assert len(set(assigned))==len(assigned)==len(cells)
    return dict(schemaVersion=3,description='Non-overlapping walking areas based on published map-sheet coverage.',
                sheetReference=dict(source=reference['source'],sha256=hashlib.sha256(reference_path.read_bytes()).hexdigest()),
                boundarySources=provenance,regions=zones,parks=parks)


def add_map_footprints(result, source_root, atlas_path):
    """Coastal selection shapes, deliberately independent of fine tile gaps.

    Downloading still uses the published manifest's actual terrain tiles.
    The bundled atlas supplies the same Natural Earth coastline as the base map.
    """
    raw = atlas_path.read_bytes()
    land = unary_union([Polygon(r).buffer(0) for r in json.loads(raw)['land']])
    removed = 0
    for zone in result['regions']+result['parks']:
        blocks = [rectangle(c) for c in zone['cells']]
        raw_area = unary_union(blocks)
        clipped = raw_area.intersection(land)
        polygons = [clipped] if clipped.geom_type == 'Polygon' else [g for g in getattr(clipped, 'geoms', []) if g.geom_type == 'Polygon']
        polygons = sorted([p for p in polygons if not p.is_empty and p.area > 1e-12], key=lambda p:(-p.area, p.bounds))
        zone['mapShapes'] = [dict(rings=[list(p.exterior.coords)]+[list(r.coords) for r in p.interiors]) for p in polygons]
        removed += raw_area.area-clipped.area
        if not polygons:
            zone['labelBounds'] = None
            continue
        # Find a spacious rectangle fully inside the footprint. Lettering never
        # sits in a bay just because the storage area's centre falls offshore.
        candidates = [p.representative_point() for p in polygons]
        candidates += [Point(centre(c)) for c in zone['cells'] if clipped.contains(Point(centre(c)))]
        lines = zone['mapLabel'].split('\n')
        aspect = (max(map(len, lines))*0.72+0.5)/(len(lines)*1.2+0.4)
        best, best_area = None, 0
        west, south, east, north = clipped.bounds
        for point in candidates:
            ratio = aspect/max(0.2, math.cos(math.radians(point.y)))
            low, high = 0, min(north-south, (east-west)/ratio)
            for _ in range(20):
                height = (low+high)/2
                rect = box(point.x-height*ratio/2, point.y-height/2, point.x+height*ratio/2, point.y+height/2)
                if clipped.covers(rect):
                    low = height
                else:
                    high = height
            area = low*low*ratio
            if area > best_area:
                best_area = area
                best = dict(minLongitude=point.x-low*ratio/2, maxLongitude=point.x+low*ratio/2,
                            minLatitude=point.y-low/2, maxLatitude=point.y+low/2)
        assert best is not None, zone['id']
        zone['labelBounds'] = best
    result['mapFootprintSource'] = dict(atlasSHA256=hashlib.sha256(raw).hexdigest(),
        coastline='Bundled Natural Earth atlas',
        description='Coastal geographic selection areas. Individual missing terrain tiles do not cut holes in the selection map.')
    print(f'Coastal selection shapes: {removed:.2f} square degrees of sea omitted')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--grid', type=Path, default=Path('ridge v3/Resources/uk-pack-regions.json'))
    parser.add_argument('--output', type=Path, required=True, help='Explicit legacy output path; the app now uses install_large_areas.py')
    args = parser.parse_args()
    result = build(json.loads(args.grid.read_text()), args.source_root)
    add_map_footprints(result, args.source_root, Path('ridge v3/Resources/RidgeData.bundle/atlas.json'))
    args.output.write_text(json.dumps(result, separators=(',', ':'), ensure_ascii=False)+'\n')
    catalog = json.loads((args.source_root/'world-v1-2026-10-04/catalog.json').read_text())
    sources = {s['id']: s for s in catalog['sources']}
    print(f"{len(result['regions'])} zones, {sum(len(z['cells']) for z in result['regions'])} unique source cells")
    for z in result['regions']:
        if z.get('parkID') in ('park-eryri', 'park-lake-district', 'park-peak-district'):
            members = [sources[c['id']] for c in z['cells'] if c['id'] in sources]
            total = sum(s.get('downloadBytes', 0)+s.get('routing', {}).get('byteCount', 0) for s in members)
            print(z['name'], len(members), f'{total/1e6:.0f} MB upper estimate')


if __name__ == '__main__':
    main()
