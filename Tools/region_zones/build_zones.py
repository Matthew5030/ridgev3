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
from collections import defaultdict, Counter
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
DIRECTIONS = [('nw', 'North West', 'NW'), ('ne', 'North East', 'NE'),
              ('sw', 'South West', 'SW'), ('se', 'South East', 'SE')]


def centre(cell):
    b = cell['bounds']
    return ((b['minLongitude']+b['maxLongitude'])/2, (b['minLatitude']+b['maxLatitude'])/2)


def rectangle(cell):
    b = cell['bounds']
    return box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude'])


def split(cells):
    """Four stable compass areas, without cutting any downloadable section."""
    west = min(c['bounds']['minLongitude'] for c in cells)
    east = max(c['bounds']['maxLongitude'] for c in cells)
    south = min(c['bounds']['minLatitude'] for c in cells)
    north = max(c['bounds']['maxLatitude'] for c in cells)
    result = {d[0]: [] for d in DIRECTIONS}
    for cell in cells:
        x, y = centre(cell)
        result[('n' if y >= (north+south)/2 else 's')+('w' if x < (west+east)/2 else 'e')].append(cell)
    return result


def build(grid, source_root):
    divisions = json.loads(Path(__file__).with_name('surrounding-areas.json').read_text())
    groups = {g['id']: g['cells'] for g in grid['regions']}
    cells, surroundings = {}, {}
    area_names = {}
    # Publication cells contain a 48 x 48 tile grid, served in 16 x 16 sections.
    for division in divisions:
        for ident, name in division['names']:
            area_names[ident] = name
            surroundings[ident] = []
        for parent in groups[division['group']]:
            x, y = centre(parent)
            band = sum((y if division['latitude'] else x) >= cut for cut in division['cuts'])
            owner = division['names'][band][0]
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
                    surroundings[owner].append(cell)
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
    groups = defaultdict(list)
    for cell in cells.values():
        x,y,col,row = map(int,re.search(r'x(\d+)-y(\d+)-c(\d+)-r(\d+)',cell['id']).groups())
        groups[((x*3+col//16)//5, (y*3+row//16)//5)].append(cell)
    footprints = {key:unary_union([rectangle(c) for c in group]).intersection(land) for key,group in groups.items()}
    # A tiny coastal remnant belongs with a neighbour instead of becoming an
    # awkward standalone sliver. Large inland areas retain straight boundaries.
    for key in sorted(list(groups)):
        if key not in groups or not 0 < footprints[key].area < 0.008:
            continue
        neighbours = [k for k in groups if abs(k[0]-key[0])+abs(k[1]-key[1])==1 and footprints[k].area>=0.008]
        if not neighbours:
            continue
        neighbour = min(neighbours,key=lambda k:(footprints[key].distance(footprints[k]),len(groups[k]),k))
        groups[neighbour] += groups.pop(key)
        footprints[neighbour] = footprints[neighbour].union(footprints.pop(key))
    owners = {cell['id']:ident for ident,members in surroundings.items() for cell in members}
    aliases = {
        'eryri-anglesey':'N WALES', 'clwyd-berwyn':'CLWYD', 'south-lakes':'S CUMBRIA', 'north-lakes':'N CUMBRIA',
        'peak-district':'DERBYSHIRE', 'bannau-mid-wales':'MID WALES', 'pembrokeshire-ceredigion':'W WALES',
        'skye-wester-ross':'SKYE & ROSS', 'outer-hebrides':'HEBRIDES', 'caithness-moray':'CAITHNESS',
        'argyll-islay':'ARGYLL', 'mull-small-isles':'MULL', 'lomond-trossachs':'LOMOND', 'fife-lothians':'LOTHIANS',
        'scottish-borders':'BORDERS', 'fermanagh-sperrins':'SPERRINS', 'antrim-down':'ANTRIM',
        'tyne-wear-durham':'DURHAM', 'north-pennines':'PENNINES', 'yorkshire-dales':'DALES',
        'yorkshire-wolds':'WOLDS', 'north-york-moors':'MOORS', 'central-midlands':'MIDLANDS',
        'trent-valley':'TRENT', 'fens-cambridgeshire':'FENS', 'suffolk-west-norfolk':'SUFFOLK',
        'broads-east-coast':'E COAST', 'severn-cotswolds':'COTSWOLDS', 'shropshire-marches':'MARCHES',
        'surrey-south-downs':'SURREY', 'london-weald':'LONDON', 'kent-east-sussex':'KENT',
        'somerset-west-dorset':'SOMERSET', 'cornwall-scilly':'CORNWALL'}
    zones = []
    for (x,y),members in sorted(groups.items()):
        footprint = footprints[(x,y)]
        regional = Counter(owners[c['id']] for c in members).most_common(1)[0][0]
        overlaps = [g.intersection(footprint).area for g in geometries]
        park = max(range(len(PARKS)),key=lambda i:overlaps[i]) if max(overlaps)>0 else None
        # Name an area for a park only when the park occupies a substantial part.
        if park is not None and overlaps[park] >= footprint.area*0.2:
            ident,name,label,folder,art = PARKS[park]
            family='park-'+ident; reference=geometries[park].bounds
            metadata=dict(parkID=family,parkName=name,artwork=art)
        else:
            family=regional;name=area_names[regional];label=aliases.get(regional,name.upper())
            reference=unary_union([rectangle(c) for c in surroundings[regional]]).bounds
            metadata=dict(artwork='countryside')
            # Still offer the relevant whole park from an area touching its edge.
            if park is not None:
                metadata.update(parkID='park-'+PARKS[park][0],parkName=PARKS[park][1])
        area = unary_union([rectangle(c) for c in members])
        cx,cy = area.centroid.x,area.centroid.y
        west,south,east,north = reference
        horizontal = 'W' if cx<west+(east-west)*0.38 else 'E' if cx>west+(east-west)*0.62 else ''
        vertical = 'S' if cy<south+(north-south)*0.38 else 'N' if cy>south+(north-south)*0.62 else ''
        direction=vertical+horizontal or 'CENTRAL'
        zones.append(dict(id=f'area-{x}-{y}',name=name,mapLabel=label.replace('\n',' '),
            cells=sorted(members,key=lambda c:c['id']),subtitle='Map area · clipped at the coast',
            family=family,direction=direction,**metadata))
    # Compass names stay short and unique within a familiar geographic family.
    names = Counter((z['name'],z['direction']) for z in zones)
    seen = Counter()
    long_directions={'NW':'North West','NE':'North East','SW':'South West','SE':'South East','N':'North','S':'South','E':'East','W':'West','CENTRAL':'Central'}
    for zone in zones:
        zone.pop('family')
        key=(zone['name'],zone['direction']); seen[key]+=1
        number=f' {seen[key]}' if names[key]>1 else ''
        zone['name']+=' · '+long_directions[zone['direction']]+number
        zone['mapLabel']+='\n'+zone.pop('direction')+number
    assigned=[c['id'] for z in zones for c in z['cells']]
    assert len(set(assigned))==len(assigned)==len(cells)
    return dict(schemaVersion=3,description='Compact coastal map areas with separate national park downloads.',
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
    parser.add_argument('--output', type=Path, default=Path('ridge v3/Resources/uk-download-zones.json'))
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
