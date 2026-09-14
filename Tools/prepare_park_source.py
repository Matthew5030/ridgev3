#!/usr/bin/env python3
"""Prepare a bounded-read source for the NORMAL area flow from processed data.

Source files are read-only. Output is resumable and lives outside the app bundle.
Native heights are resampled only in latitude to a uniform WGS84 cell grid; all
coarser levels use nested anchors. Unknown samples remain unknown. The source
catalogue is published last, after terrain, cartography and route validation.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
from functools import lru_cache
import json
import math
import multiprocessing
from pathlib import Path
import time
import zipfile

import numpy as np
from PIL import Image
from shapely.geometry import shape, box
from shapely.strtree import STRtree

import prepare_packs as shared
import prepare_horizon as context

STATE = {}


def bounds_at(column, row):
    b, dx, dy = STATE['bounds'], STATE['dx'], STATE['dy']
    return dict(minLongitude=b['minLongitude'] + column * dx,
                maxLongitude=b['minLongitude'] + (column + 1) * dx,
                maxLatitude=b['maxLatitude'] - row * dy,
                minLatitude=b['maxLatitude'] - (row + 1) * dy)


@lru_cache(maxsize=24)
def source_array(gx, gy):
    record = STATE['native'].get((gx, gy))
    if record is None: return None
    path, level = record
    return np.frombuffer(shared.checked_bytes(path, level), dtype='<i2').reshape(513, 513)


def sample_column(gx, latitudes):
    result = np.full((len(latitudes), 513), shared.NO_DATA, dtype='<i2')
    # Prepared z10 products have uniform latitude within each world tile.
    world_y = np.floor((1 - np.arcsinh(np.tan(np.radians(latitudes))) / np.pi) / 2 * 1024).astype(int)
    for ty in np.unique(world_y):
        b = shared.tile_bounds(gx // 48, int(ty))
        pos = (b['maxLatitude'] - latitudes) / (b['maxLatitude'] - b['minLatitude']) * 48
        cell_y = np.floor(pos + 1e-9).astype(int)
        for cy in np.unique(cell_y[world_y == ty]):
            indices = np.flatnonzero((world_y == ty) & (cell_y == cy))
            array = source_array(gx, int(ty) * 48 + int(cy))
            if array is None: continue
            yy = np.clip((pos[indices] - cy) * 512, 0, 512)
            y0 = np.floor(yy).astype(int); y1 = np.minimum(y0 + 1, 512)
            f = (yy - y0)[:, None]
            a, b = array[y0].astype(float), array[y1].astype(float)
            valid = ((a != shared.NO_DATA) | (f > 1 - 1e-7)) & ((b != shared.NO_DATA) | (f < 1e-7))
            values = np.rint(a * (1 - f) + b * f).astype('<i2')
            result[indices] = np.where(valid, values, shared.NO_DATA)
    return result


def terrain_cell(item):
    column, row = item
    out = STATE['out']; record_path = out / f'cell-{column}-{row}.json'
    if record_path.exists():
        record = json.loads(record_path.read_bytes())
        # Upgrade an interrupted earlier run without rereading 1 m source data.
        four = next((l for l in record['levels'] if l['spacing'] == 4), None)
        if four and len(record['levels']) < 5:
            values = np.frombuffer(shared.checked_bytes(out / four['file'], four), dtype='<i2').reshape(129, 129)
            for spacing in [8, 16, 32]:
                if any(l['spacing'] == spacing for l in record['levels']): continue
                raw = values[::spacing // 4, ::spacing // 4].astype('<i2').tobytes(); file = f'cell-{column}-{row}-{spacing}m.bin'
                (out / file).write_bytes(raw); side = 512 // spacing + 1
                record['levels'].append(dict(spacing=spacing, width=side, height=side, file=file, byteCount=len(raw), sha256=shared.digest(raw)))
            shared.write_json(record_path, record)
        return record
    # Compute shared edges from global row indices, never from rounded bounds.
    latitudes = STATE['bounds']['maxLatitude'] - (row * 512 + np.arange(513)) * STATE['dy'] / 512
    values = sample_column(STATE['gx0'] + column, latitudes)
    complete = bool(np.all(values != shared.NO_DATA))
    record = dict(column=column, row=row, complete=complete, levels=[])
    if np.any(values != shared.NO_DATA):
        for spacing in [1, 4, 8, 16, 32]:
            data = values[::spacing, ::spacing].astype('<i2').tobytes()
            file = f'cell-{column}-{row}-{spacing}m.bin'
            (out / file).write_bytes(data)
            side = 512 // spacing + 1
            record['levels'].append(dict(spacing=spacing, width=side, height=side,
                                         file=file, byteCount=len(data), sha256=shared.digest(data)))
    shared.write_json(record_path, record)
    return record


def map_cell(item):
    column, row = item
    out = STATE['out']; record_path = out / f'map-{column}-{row}.json'
    if record_path.exists(): return json.loads(record_path.read_bytes())
    bounds = bounds_at(column, row)
    # Render a generous gutter so downsampling retains real neighbour pixels.
    pad = 80; side = 1024 + 2 * pad
    expanded = dict(minLongitude=bounds['minLongitude'] - STATE['dx'] * pad / 1024,
                    maxLongitude=bounds['maxLongitude'] + STATE['dx'] * pad / 1024,
                    minLatitude=bounds['minLatitude'] - STATE['dy'] * pad / 1024,
                    maxLatitude=bounds['maxLatitude'] + STATE['dy'] * pad / 1024)
    indices = STATE['tree'].query(box(expanded['minLongitude'], expanded['minLatitude'], expanded['maxLongitude'], expanded['maxLatitude']))
    features = [STATE['features'][i] for i in indices]
    heights = context.resample_map_heights(STATE['coarse'], STATE['bounds'], expanded, 149)
    if not np.any(heights != shared.NO_DATA): heights = np.zeros_like(heights)
    image = shared.render_texture(features, heights, expanded, side)
    native = image.crop((pad - 4, pad - 4, pad + 1028, pad + 1028))
    # Preview has a four-pixel (64 native pixels) geographic gutter.
    preview = image.crop((pad - 64, pad - 64, pad + 1088, pad + 1088)).resize((72, 72), Image.Resampling.LANCZOS)
    result = {}
    for key, im in [('image', native), ('preview', preview)]:
        file = f'map-{column}-{row}-{key}.png'; im.save(out / file, compress_level=3)
        raw = (out / file).read_bytes()
        result[key] = dict(file=file, width=im.width, height=im.height, bounds=bounds,
                           byteCount=len(raw), sha256=shared.digest(raw))
        im.close()
    image.close(); shared.write_json(record_path, result)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--precision', type=Path, default=shared.PRECISION)
    p.add_argument('--old', type=Path, default=shared.OLD)
    p.add_argument('--boundary', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--workers', type=int, default=6)
    a = p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)
    source_id = a.output.name
    if not shared.re.fullmatch(r'[a-zA-Z0-9_-]{1,70}', source_id): raise ValueError('Output folder must be a safe source identifier')
    if (a.output / 'pack.json').exists():
        raise ValueError('This source is already published and immutable. Use a new output folder/identifier for a new revision.')
    started = time.monotonic()
    feature = json.loads(a.boundary.read_bytes()); park = shape(feature['geometry'])
    west, south, east, north = park.bounds
    dx = 360 / 1024 / 48
    reference = shared.tile_bounds(500, 333)
    dy = (reference['maxLatitude'] - reference['minLatitude']) / 48
    gx0 = math.floor((west + 180) / dx); columns = math.ceil((east + 180) / dx) - gx0
    north = reference['maxLatitude'] + math.ceil((north - reference['maxLatitude']) / dy) * dy
    rows = math.ceil((north - south) / dy)
    bounds = dict(minLongitude=gx0 * dx - 180, maxLongitude=(gx0 + columns) * dx - 180,
                  minLatitude=north - rows * dy, maxLatitude=north)
    STATE.update(out=a.output, bounds=bounds, dx=dx, dy=dy, gx0=gx0, columns=columns, rows=rows)
    config = dict(bounds=bounds, columns=columns, rows=rows, source=str(a.precision), format=1)
    config_path = a.output / 'build-config.json'
    if config_path.exists() and json.loads(config_path.read_bytes()) != config: raise ValueError('Output belongs to a different source/grid')
    shared.write_json(config_path, config)
    print(f'Park source: {columns} × {rows} cells', flush=True)
    native, evidence, tiles = {}, [], set()
    ty0 = math.floor((1 - math.asinh(math.tan(math.radians(north))) / math.pi) / 2 * 1024)
    ty1 = math.floor((1 - math.asinh(math.tan(math.radians(bounds['minLatitude']))) / math.pi) / 2 * 1024)
    credit = None
    for ty in range(ty0, ty1 + 1):
        for tx in range(gx0 // 48, (gx0 + columns - 1) // 48 + 1):
            tiles.add((tx, ty)); folder = a.precision / f'tiles/10/{tx}/{ty}'
            if not (folder / 'manifest.json').exists():
                evidence.append(dict(path=str(folder / 'manifest.json'), available=False)); continue
            raw = (folder / 'manifest.json').read_bytes()
            completion = json.loads((folder / 'COMPLETE.json').read_bytes())
            if shared.digest(raw) != completion['manifestSHA256']: raise ValueError(f'Invalid source manifest: {folder}')
            m = json.loads(raw); credit = m['source']
            evidence.append(dict(path=str(folder / 'manifest.json'), sha256=shared.digest(raw)))
            for parent in m['parents']:
                for child in parent.get('precisionChildren', []):
                    level = next((l for l in child['lods'] if l['nominalSpacingMetres'] == 1), None)
                    if level is None: continue
                    t = level['terrain']
                    if (t['width'], t['height'], t['scaleMetres'], t['noDataValue']) != (513, 513, .1, shared.NO_DATA): raise ValueError('Unsupported source samples')
                    gx = tx * 48 + parent['parentX'] * 4 + child['subchunkX']
                    gy = ty * 48 + parent['parentY'] * 4 + child['subchunkY']
                    native[gx, gy] = (folder / 'parents' / parent['id'] / level['path'], level)
    STATE['native'] = native
    fingerprint = shared.digest(json.dumps(evidence, sort_keys=True, separators=(',', ':')).encode())
    fingerprint_path = a.output / 'terrain-inputs.json'
    if fingerprint_path.exists() and json.loads(fingerprint_path.read_bytes())['sha256'] != fingerprint:
        raise ValueError('Prepared source manifests changed. Use a fresh output folder rather than mixing revisions.')
    shared.write_json(fingerprint_path, dict(sha256=fingerprint))
    items = [(x, y) for y in range(rows) for x in range(columns)]
    ctx = multiprocessing.get_context('fork')
    records = []
    with ProcessPoolExecutor(a.workers, mp_context=ctx) as pool:
        for i, record in enumerate(pool.map(terrain_cell, items, chunksize=8)):
            records.append(record)
            if i % 200 == 0: print(f'Terrain {i + 1}/{len(items)}', flush=True)
    # A single small 8 m backing grid serves horizon crops and map contours.
    coarse = np.full((rows * 64 + 1, columns * 64 + 1), shared.NO_DATA, dtype='<i2')
    for record in records:
        level = next((l for l in record['levels'] if l['spacing'] == 4), None)
        if level is None: continue
        values = np.frombuffer(shared.checked_bytes(a.output / level['file'], level), dtype='<i2').reshape(129, 129)[::2, ::2]
        x, y = record['column'] * 64, record['row'] * 64
        window = coarse[y:y + 65, x:x + 65]; valid = values != shared.NO_DATA; window[valid] = values[valid]
    STATE['coarse'] = coarse
    horizon_levels = []
    for spacing in [8, 16, 32]:
        values = coarse[::spacing // 8, ::spacing // 8]; raw = values.astype('<i2').tobytes(); file = f'horizon-{spacing}m.bin'
        (a.output / file).write_bytes(raw)
        horizon_levels.append(dict(spacing=spacing, width=values.shape[1], height=values.shape[0], file=file, byteCount=len(raw), sha256=shared.digest(raw)))
    map_tiles = set()
    for tx, ty in tiles:
        descriptor = a.old / f'mapping/build/public/tiles/10/{tx}/{ty}/descriptor.json'
        if descriptor.exists(): map_tiles.add((tx, ty))
        elif any(gx // 48 == tx and gy // 48 == ty for gx, gy in native):
            raise ValueError(f'Prepared terrain has no matching OSM archive at {tx}/{ty}')
        else: print(f'No prepared land or map source at {tx}/{ty}; coverage remains unavailable.', flush=True)
    features, map_evidence = context.read_context_maps(a.old, map_tiles, bounds)
    indexed = [(f, context.map_feature_bounds(f)) for f in features]
    indexed = [(f, b) for f, b in indexed if b is not None]
    STATE['features'] = [f for f, b in indexed]
    STATE['tree'] = STRtree([box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude']) for f, b in indexed])
    maps = []
    with ProcessPoolExecutor(a.workers, mp_context=ctx) as pool:
        for i, record in enumerate(pool.map(map_cell, items, chunksize=4)):
            maps.append(record)
            if i % 200 == 0: print(f'Maps {i + 1}/{len(items)}', flush=True)
    # Graphs stay separate by source world tile. IDs are namespaced before
    # cropping; coincident original boundary nodes can be joined by coordinate.
    graphs, places = [], {}
    for tx, ty in sorted(map_tiles):
        b = shared.tile_bounds(tx, ty)
        if not context.intersect_bounds(b, bounds): continue
        clipped = {k: (max if k.startswith('min') else min)(b[k], bounds[k]) for k in bounds}
        _, graph, found, _ = shared.read_map(a.old, (tx, ty), clipped, context.resample_map_heights(coarse, bounds, clipped, 1025))
        offset = ((ty - ty0) * 4 + tx - gx0 // 48) * 1_000_000
        if len(graph['nodes']) >= 1_000_000: raise ValueError('Source graph exceeds its ID namespace')
        ids = {node['id']: offset + i for i, node in enumerate(graph['nodes'])}
        for n in graph['nodes']: n['id'] = ids[n['id']]
        for e in graph['edges']: e['from'] = ids[e['from']]; e['to'] = ids[e['to']]
        raw = (json.dumps(graph, separators=(',', ':')) + '\n').encode(); file = f'graph-{tx}-{ty}.json'
        (a.output / file).write_bytes(raw)
        graphs.append(dict(file=file, byteCount=len(raw), sha256=shared.digest(raw), bounds=clipped))
        for place in found: places[place['id']] = place
    # One small overview prevents decoding thousands of map previews on entry.
    overview = Image.new('RGB', (columns * 8, rows * 8), '#ede9d9')
    for i, record in enumerate(maps):
        with Image.open(a.output / record['preview']['file']) as im:
            overview.paste(im.crop((4, 4, 68, 68)).resize((8, 8), Image.Resampling.LANCZOS), (i % columns * 8, i // columns * 8))
    overview.save(a.output / 'overview.png'); overview.close()
    raw = (a.output / 'overview.png').read_bytes()
    overview_meta = dict(file='overview.png', width=columns * 8, height=rows * 8, bounds=bounds, byteCount=len(raw), sha256=shared.digest(raw))
    near = dict(bounds=bounds, levels=horizon_levels[:2], textures=[])
    far = dict(bounds=bounds, levels=[horizon_levels[2]], textures=[])
    levels = [dict(spacing=s, width=columns * 512 // s + 1, height=rows * 512 // s + 1, file=f'tiled-{s}m',
                   byteCount=(columns * 512 // s + 1) * (rows * 512 // s + 1) * 2, sha256='0' * 64) for s in [1, 2, 4, 8, 16, 32]]
    source = dict(schemaVersion=1, id=source_id, name='Eryri National Park', subtitle='Choose your area',
                  summary='Prepared terrain across Eryri. Select highlighted tiles to save a fixed area, then expand it from the 3D map.',
                  bounds=bounds, sourceResolution=1, heightScale=.1, noDataValue=shared.NO_DATA,
                  levels=levels, textures=[], places=list(places.values())[:5000], defaultSpacing=4, version='2026.09.14-park1',
                  sources=[dict(name=credit['name'], attribution=credit['attribution'], license=credit['license'], url=credit.get('sourcePage', credit.get('url', ''))),
                           dict(name='OpenStreetMap', attribution='© OpenStreetMap contributors', license='Open Database License 1.0', url='https://www.openstreetmap.org/copyright')],
                  grid=dict(gridID='ridge-eryri-uniform-v1', worldTileID=source_id + '-v1', originColumn=0, originRow=0, columns=columns, rows=rows),
                  tiledTerrain=dict(cells=records, graphs=graphs, overview=overview_meta), horizon=dict(near=near, far=far),
                  cartography=dict(sourceOnly=True, columns=columns, rows=rows, longitudeEdges=[bounds['minLongitude'] + x * dx for x in range(columns + 1)],
                                  latitudeEdges=[bounds['maxLatitude'] - y * dy for y in range(rows + 1)], tiles=maps),
                  verticalDatum='EGM96 / EPSG:5773 as recorded by prepared source; original LiDAR ODN / EPSG:5701')
    # Verify shared output edges independently before publication.
    complete = {(r['column'], r['row']): r for r in records if r['complete']}
    for (x, y), record in complete.items():
        level = record['levels'][1]; values = np.frombuffer(shared.checked_bytes(a.output / level['file'], level), dtype='<i2').reshape(129, 129)
        for key, edge, other in [((x - 1, y), values[:, 0], 'east'), ((x, y - 1), values[0, :], 'south')]:
            if key not in complete: continue
            l = complete[key]['levels'][1]; v = np.frombuffer(shared.checked_bytes(a.output / l['file'], l), dtype='<i2').reshape(129, 129)
            if not np.array_equal(edge, v[:, -1] if other == 'east' else v[-1, :]): raise ValueError(f'Output seam mismatch at {x},{y}')
    shared.write_json(a.output / 'source-evidence.json', dict(sources=evidence, maps=map_evidence, completeCells=len(complete), cells=len(records),
                      resampling='Linear latitude interpolation of existing 1m samples, quantised to source 0.1m units. Coarser anchors nested. No missing-height substitution.', seconds=time.monotonic() - started))
    (a.output / 'boundary.geojson').write_bytes(a.boundary.read_bytes())
    shared.write_json(a.output / '.pack-next.json', source)
    (a.output / '.pack-next.json').replace(a.output / 'pack.json')
    print(f'Published {len(complete)} complete selectable cells; {len(records) - len(complete)} unavailable cells. {time.monotonic() - started:.1f}s', flush=True)


if __name__ == '__main__': main()
