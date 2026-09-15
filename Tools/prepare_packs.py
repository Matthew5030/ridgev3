#!/usr/bin/env python3
"""Build finite offline Ridge areas from already processed precision products.

Requires numpy and Pillow. Never processes raw LiDAR and never changes source data.
Starter build: python prepare_packs.py --starters
Custom rectangle (parent grid inside one z10 tile):
  python prepare_packs.py --id my-area --name 'My area' --tile 500 333 \
      --parent 4 1 --shape 3 3 --output Tools/PreparedPacks/my-area.ridgepack
Use --child 3 3 --shape 1 1 for a single genuine 1 m precision child.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sys
import urllib.request
import zipfile

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OLD = Path('/Users/matthewbilella/Desktop/ProjectFatRidge')
PRECISION = Path('/Volumes/MLB_EXT_4TB/Project Ridge External/ridge-precision/england-wales-precision/products/england-wales-precision/2026.09.02-1')
BUNDLE = ROOT / 'ridge v3/Resources/RidgeData.bundle'
VERSION = '2026.09.13-1'
NO_DATA = -32768


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n')


def checked_bytes(path, expected):
    raw = path.read_bytes()
    if len(raw) != expected['byteCount'] or digest(raw) != expected['sha256']:
        raise ValueError(f'Source checksum mismatch: {path}')
    return raw


def tile_bounds(x, y):
    lat = lambda yy: math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * yy / 1024))))
    return dict(minLongitude=x / 1024 * 360 - 180, maxLongitude=(x + 1) / 1024 * 360 - 180,
                minLatitude=lat(y + 1), maxLatitude=lat(y))


def contains(b, lon, lat):
    return b['minLongitude'] <= lon <= b['maxLongitude'] and b['minLatitude'] <= lat <= b['maxLatitude']


def union_bounds(bounds):
    return {key: (min if key.startswith('min') else max)(b[key] for b in bounds) for key in bounds[0]}


def pixels(b, coord, size):
    return ((coord[0] - b['minLongitude']) / (b['maxLongitude'] - b['minLongitude']) * (size - 1),
            (b['maxLatitude'] - coord[1]) / (b['maxLatitude'] - b['minLatitude']) * (size - 1))


def spacing_meters(b, n, height=None):
    lat = (b['minLatitude'] + b['maxLatitude']) / 2
    return dict(eastWest=math.radians(b['maxLongitude'] - b['minLongitude']) * 6371008.8 * math.cos(math.radians(lat)) / (n - 1),
                northSouth=math.radians(b['maxLatitude'] - b['minLatitude']) * 6371008.8 / ((height or n) - 1))


def terrain_sources(precision_root, tile, parent, shape, child):
    tile_dir = precision_root / f'tiles/10/{tile[0]}/{tile[1]}'
    manifest_path = tile_dir / 'manifest.json'
    document = json.loads(manifest_path.read_bytes())
    complete = json.loads((tile_dir / 'COMPLETE.json').read_bytes())
    if digest(manifest_path.read_bytes()) != complete['manifestSHA256']:
        raise ValueError('Precision manifest checksum mismatch')
    parents = {(p['parentX'], p['parentY']): p for p in document['parents']}
    pieces, provenance = [], []
    for yy in range(shape[1]):
        row = []
        for xx in range(shape[0]):
            px, py = parent[0] + xx, parent[1] + yy
            record = parents.get((px, py))
            if not record or record['status'] != 'available':
                raise ValueError(f'Missing complete LiDAR coverage at parent {px},{py}; choose a smaller rectangle')
            base = tile_dir / f'parents/c{px:02d}-{py:02d}'
            if child:
                if shape != [1, 1]: raise ValueError('A child selection must have --shape 1 1')
                record = next(c for c in record['precisionChildren'] if (c['subchunkX'], c['subchunkY']) == tuple(child))
                lods = record['lods']
            else:
                lods = record['baseLODs']
            finest = min(lods, key=lambda l: l['nominalSpacingMetres'])
            path = base / finest['path']
            raw = checked_bytes(path, finest)
            meta = finest['terrain']
            array = np.frombuffer(raw, dtype='<i2').reshape(meta['height'], meta['width'])
            row.append((array, meta['bounds']))
            provenance.append(dict(path=str(path), sha256=digest(raw), byteCount=len(raw),
                                   nominalSpacing=finest['nominalSpacingMetres'], actualSpacing=finest['actualSpacingMetres']))
        pieces.append(row)
    side = pieces[0][0][0].shape[0]
    result = np.full((shape[1] * (side - 1) + 1, shape[0] * (side - 1) + 1), NO_DATA, dtype='<i2')
    for yy, row in enumerate(pieces):
        for xx, (array, bounds) in enumerate(row):
            if xx and not np.array_equal(row[xx - 1][0][:, -1], array[:, 0]): raise ValueError('East/west source seam mismatch')
            if yy and not np.array_equal(pieces[yy - 1][xx][0][-1, :], array[0, :]): raise ValueError('North/south source seam mismatch')
            result[yy * (side - 1):yy * (side - 1) + side, xx * (side - 1):xx * (side - 1) + side] = array
    return result, union_bounds([b for row in pieces for _, b in row]), (1 if child else 4), document['source'], provenance


def geom_coords(value):
    if isinstance(value, list) and len(value) >= 2 and isinstance(value[0], (int, float)):
        yield value
    elif isinstance(value, list):
        for child in value: yield from geom_coords(child)


def intersects_geometry(bounds, geometry):
    coords = list(geom_coords(geometry['coordinates']))
    if not coords: return False
    return not (max(c[0] for c in coords) < bounds['minLongitude'] or min(c[0] for c in coords) > bounds['maxLongitude']
                or max(c[1] for c in coords) < bounds['minLatitude'] or min(c[1] for c in coords) > bounds['maxLatitude'])


def read_map(old, tile, bounds, heights):
    folder = old / f'mapping/build/public/tiles/10/{tile[0]}/{tile[1]}'
    descriptor = json.loads((folder / 'descriptor.json').read_bytes())
    archive = folder / Path(descriptor['archiveURL']).name
    raw = archive.read_bytes()
    if len(raw) != descriptor['archiveSizeBytes'] or digest(raw) != descriptor['archiveSHA256']:
        raise ValueError('OSM tile archive checksum mismatch')
    with zipfile.ZipFile(archive) as z:
        semantic = json.loads(z.read('map-data.ridgemap'))
        source_graph = json.loads(z.read('routing/graph.json'))
    features = [f for f in semantic['features'] if intersects_geometry(bounds, f['geometry'])]
    def height(lon, lat):
        u, v = pixels(bounds, [lon, lat], 2)
        x = min(heights.shape[1] - 1, max(0, round(u * (heights.shape[1] - 1))))
        y = min(heights.shape[0] - 1, max(0, round(v * (heights.shape[0] - 1))))
        h = int(heights[y, x])
        return None if h == NO_DATA else h * .1
    nodes, allowed = [], set()
    for n in source_graph['nodes']:
        if contains(bounds, n['longitude'], n['latitude']):
            z = height(n['longitude'], n['latitude'])
            if z is not None:
                nodes.append(dict(id=n['id'], coordinate=dict(latitude=n['latitude'], longitude=n['longitude']), elevation=round(z, 1)))
                allowed.add(n['id'])
    # Keep only existing edges with both endpoints inside: never fabricate a connector across the edge.
    edges = [dict(from_=e['from'], to=e['to'], distance=e['distanceMeters'], bidirectional=e['bidirectional'],
                  access=e['access'], kind=e['pathType']) for e in source_graph['edges'] if e['from'] in allowed and e['to'] in allowed]
    for e in edges: e['from'] = e.pop('from_')
    connected = {n for e in edges for n in [e['from'], e['to']]}
    nodes = [n for n in nodes if n['id'] in connected]
    places = []
    for f in features:
        g, props = f['geometry'], f['properties']
        if g['type'] == 'Point' and props.get('name') and contains(bounds, *g['coordinates']):
            lon, lat = g['coordinates'][:2]
            places.append(dict(id=f['id'], name=props['name'], coordinate=dict(latitude=lat, longitude=lon), kind=f['kind'],
                               elevation=props.get('elevationMeters', height(lon, lat))))
    return features, dict(nodes=nodes, edges=edges), places, dict(path=str(archive), sha256=digest(raw), byteCount=len(raw))


def dashed(draw, points, fill, width, dash=10, gap=6):
    phase = 0.
    for a, b in zip(points, points[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1e-5: continue
        position = 0.
        while position < length:
            in_dash = phase < dash
            step = min(length - position, (dash if in_dash else dash + gap) - phase)
            if in_dash:
                end = position + step
                draw.line([(a[0] + dx * position / length, a[1] + dy * position / length),
                           (a[0] + dx * end / length, a[1] + dy * end / length)], fill=fill, width=width)
            position += step
            phase = (phase + step) % (dash + gap)


def contour_segments(heights, interval=10):
    h = heights.astype(np.float32) * .1
    a, b, c, d = h[:-1, :-1], h[:-1, 1:], h[1:, 1:], h[1:, :-1]
    valid = (a > -3000) & (b > -3000) & (c > -3000) & (d > -3000)
    low, high = np.minimum.reduce([a, b, c, d]), np.maximum.reduce([a, b, c, d])
    values = h[h > -3000]
    for level in range(math.ceil(float(values.min()) / interval) * interval, math.ceil(float(values.max()) / interval) * interval, interval):
        yy, xx = np.where(valid & (low <= level) & (high > level))
        segments = []
        for y, x in zip(yy, xx):
            z = [a[y, x], b[y, x], c[y, x], d[y, x]]
            corners = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)]
            points = []
            for i in range(4):
                j = (i + 1) % 4
                if (z[i] <= level < z[j]) or (z[j] <= level < z[i]):
                    f = (level - z[i]) / (z[j] - z[i])
                    points.append((corners[i][0] + (corners[j][0] - corners[i][0]) * f, corners[i][1] + (corners[j][1] - corners[i][1]) * f))
            if len(points) == 2: segments.append(points)
            elif len(points) == 4: segments.extend([points[:2], points[2:]])
        yield level, segments


def render_texture(features, heights, bounds, side, style_scale=1):
    if style_scale not in (1, 2): raise ValueError('Map style scale must be 1 or 2')
    image = Image.new('RGB', (side, side), '#ede9d9')
    draw = ImageDraw.Draw(image)
    fills = {'openLand':'#e3e3ce', 'accessLand':'#e3ddd6', 'woodland':'#c8d8bc', 'water':'#a8cbd1', 'building':'#9d9485'}
    def draw_fill(geometry, color):
        typ, coords = geometry['type'], geometry['coordinates']
        if typ == 'Polygon':
            draw.polygon([pixels(bounds, p, side) for p in coords[0]], fill=color)
            for hole in coords[1:]: draw.polygon([pixels(bounds, p, side) for p in hole], fill='#ede9d9')
        elif typ == 'MultiPolygon':
            for p in coords: draw_fill(dict(type='Polygon', coordinates=p), color)
    for kind in ['openLand', 'accessLand', 'woodland', 'water', 'building']:
        for f in features:
            if f['kind'] == kind: draw_fill(f['geometry'], fills[kind])
    # Gentle baked terrain relief is derived from the same heightfield; no satellite images.
    h = heights.astype(np.float32) * .1
    valid = h > -3000
    working = np.where(valid, h, 0)
    space = spacing_meters(bounds, heights.shape[1], heights.shape[0])
    gy, gx = np.gradient(working, space['northSouth'], space['eastWest'])
    light = np.clip((-gx + gy) / np.sqrt(1 + gx * gx + gy * gy), -.8, .8)
    shade = np.asarray(Image.fromarray(light.astype('float32')).resize((side, side), Image.Resampling.BILINEAR))
    rgb = np.asarray(image).astype(np.float32)
    rgb *= (1 + shade * .11)[..., None]
    image = Image.fromarray(np.clip(rgb, 0, 255).astype('uint8'))
    draw = ImageDraw.Draw(image)
    # 10 m contours, 50 m index contours. Grid decimation only for cartographic rendering.
    step = max(1, (heights.shape[0] - 1) // 768)
    contour_grid = heights[::step, ::step]
    sx, sy = (side - 1) / (contour_grid.shape[1] - 1), (side - 1) / (contour_grid.shape[0] - 1)
    for level, segments in contour_segments(contour_grid):
        for points in segments:
            draw.line([(float(x * sx), float(y * sy)) for x, y in points], fill='#a79a80' if level % 50 == 0 else '#c5b99f', width=(2 if level % 50 == 0 else 1) * style_scale)
    line_colors = {'water':'#76adb8', 'majorRoad':'#d8a979', 'minorRoad':'#b5a68b', 'track':'#9b8d70',
                   'footpath':'#ab6471', 'bridleway':'#866891', 'unknownPath':'#a49b95', 'boundary':'#ada79f'}
    def draw_line(geometry, kind):
        typ, coords = geometry['type'], geometry['coordinates']
        if typ == 'MultiLineString':
            for p in coords: draw_line(dict(type='LineString', coordinates=p), kind)
        elif typ == 'LineString':
            points = [pixels(bounds, p, side) for p in coords]
            width = {'majorRoad':7, 'minorRoad':5, 'water':2, 'track':3}.get(kind, 3) * style_scale
            if kind in ['footpath','bridleway','track','unknownPath','boundary']:
                dashed(draw, points, line_colors[kind], width, dash=10 * style_scale, gap=6 * style_scale)
            else:
                if kind.endswith('Road'): draw.line(points, fill='#fffdf3', width=width + 3 * style_scale, joint='curve')
                draw.line(points, fill=line_colors[kind], width=width, joint='curve')
    for kind in line_colors:
        for f in features:
            if f['kind'] == kind: draw_line(f['geometry'], kind)
    return image


def prepare(args, tile, parent, shape, child, region_id, name, subtitle, summary, output):
    print(f'Preparing {region_id}: tile={tile}, parent={parent}, shape={shape}, child={child}', flush=True)
    heights, bounds, finest, source, terrain_evidence = terrain_sources(args.precision, tile, parent, shape, child)
    features, graph, places, map_evidence = read_map(args.old, tile, bounds, heights)
    stage = output.with_name(output.name + '.staging')
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    levels = []
    for spacing in [1, 2, 4, 8, 16, 32]:
        if spacing < finest: continue
        grid = heights[::spacing // finest, ::spacing // finest]
        data = grid.astype('<i2').tobytes()
        file = f'terrain-{spacing}m.bin'
        (stage / file).write_bytes(data)
        levels.append(dict(spacing=spacing, width=grid.shape[1], height=grid.shape[0], file=file, byteCount=len(data), sha256=digest(data)))
    graph_raw = (json.dumps(graph, separators=(',', ':')) + '\n').encode()
    (stage / 'graph.json').write_bytes(graph_raw)
    side = 2048 if child else 4096
    image = render_texture(features, heights, bounds, side)
    textures = []
    partitions = 1 if child else 2
    tile_side = side // partitions
    for y in range(partitions):
        for x in range(partitions):
            crop = image.crop((x * tile_side, y * tile_side, (x + 1) * tile_side, (y + 1) * tile_side))
            file = f'map-{x}-{y}.png'
            crop.save(stage / file, optimize=True)
            raw = (stage / file).read_bytes()
            lat_step = (bounds['maxLatitude'] - bounds['minLatitude']) / partitions
            lon_step = (bounds['maxLongitude'] - bounds['minLongitude']) / partitions
            tb = dict(minLatitude=bounds['maxLatitude'] - (y + 1) * lat_step, maxLatitude=bounds['maxLatitude'] - y * lat_step,
                      minLongitude=bounds['minLongitude'] + x * lon_step, maxLongitude=bounds['minLongitude'] + (x + 1) * lon_step)
            textures.append(dict(file=file, width=tile_side, height=tile_side, byteCount=len(raw), sha256=digest(raw), bounds=tb))
    sources = [dict(name=source['name'], attribution=source['attribution'], license=source['license'], url=source.get('sourcePage',source.get('url',''))),
               dict(name='OpenStreetMap', attribution='© OpenStreetMap contributors', license='Open Database License 1.0', url='https://www.openstreetmap.org/copyright')]
    manifest = dict(schemaVersion=1, id=region_id, name=name, subtitle=subtitle, summary=summary, bounds=bounds, sourceResolution=1,
                    heightScale=.1, noDataValue=NO_DATA, levels=levels, textures=textures, graphFile='graph.json', graphSHA256=digest(graph_raw),
                    graphByteCount=len(graph_raw), places=places, sources=sources, defaultSpacing=4 if child else 8, version=VERSION,
                    verticalDatum='EGM96 / EPSG:5773, as recorded by the prepared source; original LiDAR ODN / EPSG:5701')
    write_json(stage / 'pack.json', manifest)
    evidence = dict(terrain=terrain_evidence, map=map_evidence, bounds=bounds, actualSpacing={str(l['spacing']):spacing_meters(bounds,l['width'],l['height']) for l in levels},
                    heightMinimumMeters=float(heights[heights != NO_DATA].min()) * .1,
                    heightMaximumMeters=float(heights[heights != NO_DATA].max()) * .1, noDataSamples=int((heights == NO_DATA).sum()),
                    graphNodeCount=len(graph['nodes']), graphEdgeCount=len(graph['edges']), featureKinds=dict(Counter(f['kind'] for f in features)))
    write_json(ROOT / f'Tools/reports/{region_id}-source.json', evidence)
    preview = image.copy(); preview.thumbnail((1024,1024)); preview.save(ROOT / f'Tools/reports/{region_id}-preview.jpg', quality=92)
    if output.exists(): shutil.rmtree(output)
    stage.rename(output)
    print(json.dumps(dict(id=region_id, bytes=sum(p.stat().st_size for p in output.iterdir()), levels=[(l['spacing'],l['width'],l['height']) for l in levels],
                          nodes=len(graph['nodes']), edges=len(graph['edges']), places=len(places), noData=evidence['noDataSamples'])), flush=True)
    return manifest


def cached_json(name):
    path = ROOT / 'Tools/source-cache' / name
    if not path.exists():
        path.parent.mkdir(parents=True,exist_ok=True)
        url = 'https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/' + name
        with urllib.request.urlopen(url,timeout=60) as response: path.write_bytes(response.read())
    return json.loads(path.read_bytes())


def build_atlas(args, regions):
    world = cached_json('ne_110m_admin_0_countries.geojson')
    detailed = cached_json('ne_10m_admin_0_countries.geojson')
    land = []
    for document, uk_only in [(world,False),(detailed,True)]:
        for feature in document['features']:
            is_british = feature['properties']['ADM0_A3'] in ['GBR','IRL']
            if is_british != uk_only: continue
            g = feature['geometry']
            polygons = g['coordinates'] if g['type']=='MultiPolygon' else [g['coordinates']]
            for polygon in polygons:
                # Exterior rings are sufficient for context; lakes are deliberately absent from selector.
                ring = [[round(p[0],5),round(p[1],5)] for p in polygon[0]]
                land.append(ring)
    places = []
    cities = [('London',51.5072,-.1276),('Edinburgh',55.9533,-3.1883),('Cardiff',51.4816,-3.1791),('Belfast',54.5973,-5.9301),
              ('Manchester',53.4808,-2.2426),('Glasgow',55.8642,-4.2518),('Inverness',57.4778,-4.2247),('Aberdeen',57.1497,-2.0943),
              ('Bristol',51.4545,-2.5879),('Newcastle',54.9783,-1.6178),('Keswick',54.6013,-3.1347),('Sheffield',53.3811,-1.4701),
              ('Llanberis',53.1194,-4.1291),('Betws-y-Coed',53.0920,-3.8010),('Fort William',56.8198,-5.1052),('Plymouth',50.3755,-4.1427),
              ('Dublin',53.3498,-6.2603),('Norwich',52.6309,1.2974),('Birmingham',52.4862,-1.8904),('York',53.9600,-1.0873)]
    for i,(name,lat,lon) in enumerate(cities): places.append(dict(id=f'atlas-place-{i}',name=name,coordinate=dict(latitude=lat,longitude=lon),kind='settlement'))
    for region in regions:
        places.extend(p for p in region['places'] if p['kind']=='peak')
    places = list({p['id']:p for p in places}.values())
    run = args.precision.parents[2] / 'run/state.json'
    coverage = []
    if run.exists():
        for tile, value in json.loads(run.read_bytes())['tiles'].items():
            match = re.fullmatch(r'z10-x(\d+)-y(\d+)',tile)
            if match:
                coverage.append(dict(id=tile,bounds=tile_bounds(*map(int,match.groups())),status=value['status']))
    write_json(BUNDLE / 'atlas.json',dict(land=land,places=places,coverage=coverage))
    write_json(ROOT / 'Tools/reports/atlas-source.json',dict(sources=[dict(name=p.name,sha256=digest(p.read_bytes()),byteCount=p.stat().st_size) for p in (ROOT/'Tools/source-cache').glob('*.geojson')],
               license='Natural Earth public domain',url='https://www.naturalearthdata.com/about/terms-of-use/',coverageSource=str(run),
               coverageNote='Prepared source availability, not a claim that source cells are installed or downloadable by this app.',
               landRings=len(land),coverageCounts=dict(Counter(c['status'] for c in coverage))))
    print('Atlas:',(BUNDLE/'atlas.json').stat().st_size,'bytes;',len(land),'rings;',len(coverage),'source coverage cells',flush=True)


def validate_pack(folder):
    m=json.loads((folder/'pack.json').read_bytes())
    arrays=[]
    for level in m['levels']:
        raw=checked_bytes(folder/level['file'],level)
        assert len(raw)==level['width']*level['height']*2
        a=np.frombuffer(raw,dtype='<i2').reshape(level['height'],level['width'])
        arrays.append((level['spacing'],a))
    finest,a=arrays[0]
    for spacing,b in arrays: assert np.array_equal(a[::spacing//finest,::spacing//finest],b)
    for texture in m['textures']:
        checked_bytes(folder/texture['file'],texture)
        assert Image.open(folder/texture['file']).size==(texture['width'],texture['height'])
    graph=json.loads(checked_bytes(folder/m['graphFile'],dict(byteCount=m['graphByteCount'],sha256=m['graphSHA256'])))
    ids={n['id'] for n in graph['nodes']}
    assert len(ids)==len(graph['nodes'])
    assert all(e['from'] in ids and e['to'] in ids and e['distance']>0 for e in graph['edges'])
    assert all(contains(m['bounds'],n['coordinate']['longitude'],n['coordinate']['latitude']) for n in graph['nodes'])
    print('Verified',m['id'],flush=True)


def main():
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--old',type=Path,default=OLD);p.add_argument('--precision',type=Path,default=PRECISION)
    p.add_argument('--starters',action='store_true');p.add_argument('--verify',type=Path)
    p.add_argument('--id');p.add_argument('--name');p.add_argument('--tile',nargs=2,type=int,default=[500,333])
    p.add_argument('--parent',nargs=2,type=int,default=[4,1]);p.add_argument('--shape',nargs=2,type=int,default=[3,3])
    p.add_argument('--child',nargs=2,type=int);p.add_argument('--output',type=Path)
    args=p.parse_args()
    if args.verify: validate_pack(args.verify);return
    if args.starters:
        specs=[('snowdon-horseshoe','Yr Wyddfa','The Snowdon horseshoe',[4,1],[3,3],None,
                'Crib Goch, Glaslyn and the highest summit in Wales. A complete, finite relief map from prepared Welsh LiDAR and OpenStreetMap.'),
               ('ogwen-valley','Ogwen Valley','Tryfan & the Glyderau',[6,0],[2,2],None,
                'Explore the ridges above Llyn Ogwen, Tryfan and the Glyderau. Path access and difficult mountain terrain require your own judgement.'),
               ('snowdon-summit','Summit study','Yr Wyddfa · one metre detail',[4,2],[1,1],[3,3],
                'A compact, genuine 1 m LiDAR study of the summit. All six terrain resolutions fit within a deliberately small landscape.')]
        regions=[]
        for region_id,name,subtitle,parent,shape,child,summary in specs:
            output=BUNDLE/'regions'/region_id
            regions.append(prepare(args,[500,333],parent,shape,child,region_id,name,subtitle,summary,output))
            validate_pack(output)
            copy=ROOT/'Tools/PreparedPacks'/f'{region_id}.ridgepack'
            if copy.exists():shutil.rmtree(copy)
            shutil.copytree(output,copy)
        write_json(BUNDLE/'catalog.json',regions)
        build_atlas(args,regions)
    else:
        if not args.id or not args.name or not args.output:p.error('Use --starters, --verify, or specify --id --name --output')
        if not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}',args.id):p.error('id must be lowercase letters, digits and hyphens')
        if min(args.shape)<1 or max(args.shape)>4:p.error('shape axes must be 1..4 to bound preparation memory')
        prepare(args,args.tile,args.parent,args.shape,args.child,args.id,args.name,'Prepared offline area','Prepared from source-backed LiDAR and OpenStreetMap.',args.output)
        validate_pack(args.output)


if __name__=='__main__':main()
