#!/usr/bin/env python3
"""Build selectable zones from existing OSM park boundaries and source cells.

No map assets are rebuilt. Sections intersecting park boundaries
go to the park with greatest overlap. Margins follow the section grid; these
are download areas, not legal park boundaries. Each source has one owner.
Requires shapely (also used by the terrain pipeline).
"""
import argparse
import hashlib
import json
from pathlib import Path
from shapely.geometry import box, shape

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
    ownership, park_cells = {}, [[] for _ in PARKS]
    for cell in cells.values():
        polygon = rectangle(cell)
        intersections = [g.intersection(polygon).area if g.intersects(polygon) else 0 for g in geometries]
        if max(intersections) > 1e-12:
            owner = max(range(len(PARKS)), key=lambda i: intersections[i])
            ownership[cell['id']] = owner
            park_cells[owner].append(cell)
    zones = []
    def add(ident, name, label, cells, **metadata):
        zones.append(dict(id=ident, name=name, mapLabel=label,
            cells=sorted(cells, key=lambda c:c['id']), **metadata))
    for (ident, name, label, folder, art), members in zip(PARKS, park_cells):
        assert members, ident
        group = 'park-'+ident
        metadata = dict(parkID=group, parkName=name, artwork=art,
            subtitle='National park area · includes map sections along the boundary')
        # Large parks get four smaller choices; compact parks remain one tap.
        if len(members) > 24:
            quadrants = split(members)
            for suffix, direction, short in DIRECTIONS:
                if quadrants[suffix]:
                    add(group+'-'+suffix, name+' · '+direction, label+'\n'+short, quadrants[suffix], **metadata)
        else:
            add(group, name, label, members, **metadata)
    short_labels = {'eryri-anglesey': 'NORTH\nWALES', 'south-lakes': 'SOUTH\nCUMBRIA',
        'north-lakes': 'NORTH\nCUMBRIA', 'peak-district': 'PEAK\nFRINGES',
        'bannau-mid-wales': 'MID\nWALES', 'pembrokeshire-ceredigion':'WEST\nWALES',
        'yorkshire-dales':'DALES\nFRINGES', 'cairngorms':'HIGHLAND\nFRINGES',
        'north-york-moors':'MOOR\nFRINGES', 'broads-east-coast':'EAST\nCOAST'}
    names = {'eryri-anglesey':'North Wales coast', 'south-lakes':'South Cumbria',
        'north-lakes':'North Cumbria', 'peak-district':'Peak District surroundings',
        'yorkshire-dales':'Dales surroundings', 'cairngorms':'Cairngorms surroundings',
        'north-york-moors':'North York Moors surroundings'}
    for ident, members in surroundings.items():
        remaining = [c for c in members if c['id'] not in ownership]
        if not remaining:
            continue
        name = names.get(ident, area_names[ident])
        label = short_labels.get(ident, name.upper().replace(' & ', '\n& ').replace(' ', '\n'))
        if len(remaining) > 24:
            for suffix, direction, short in DIRECTIONS:
                part = split(remaining)[suffix]
                if part:
                    add('area-'+ident+'-'+suffix, name+' · '+direction, label+'\n'+short, part,
                        subtitle='Surrounding countryside & coast', artwork='countryside')
        else:
            add('area-'+ident, name, label, remaining, subtitle='Surrounding countryside & coast', artwork='countryside')
    assigned = [cell['id'] for z in zones for cell in z['cells']]
    assert len(set(assigned)) == len(assigned) == len(cells)
    assert set(assigned) == set(cells)
    return dict(schemaVersion=2, description='Park-first download zones. Source sections have one owner; park margins follow the section grid.',
                boundarySources=provenance, regions=zones)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--grid', type=Path, default=Path('ridge v3/Resources/uk-pack-regions.json'))
    parser.add_argument('--output', type=Path, default=Path('ridge v3/Resources/uk-download-zones.json'))
    args = parser.parse_args()
    result = build(json.loads(args.grid.read_text()), args.source_root)
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
