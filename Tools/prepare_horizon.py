#!/usr/bin/env python3
"""Add finite surrounding terrain to an existing fixed-grid source pack.

Reads only already processed precision 8m products and prepared OSM archives.
Default Eryri context extends five original parents (~9.8km) on every side.
No raw LiDAR, satellite images, routing generation, network or source writes.
Requires NumPy and Pillow, as does prepare_packs.py.
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
import time
import zipfile

import numpy as np
from PIL import Image

import prepare_packs as shared


def file_digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''): hasher.update(block)
    return hasher.hexdigest()


def parent_bounds(gx, gy):
    world = shared.tile_bounds(gx // 12, gy // 12)
    dx = (world['maxLongitude'] - world['minLongitude']) / 12
    dy = (world['maxLatitude'] - world['minLatitude']) / 12
    return dict(minLongitude=world['minLongitude'] + (gx % 12) * dx,
                maxLongitude=world['minLongitude'] + (gx % 12 + 1) * dx,
                maxLatitude=world['maxLatitude'] - (gy % 12) * dy,
                minLatitude=world['maxLatitude'] - (gy % 12 + 1) * dy)


def gather_sources(precision, x0, y0, columns, rows):
    selected, manifests = {}, []
    for ty in range(y0 // 12, (y0 + rows - 1) // 12 + 1):
        for tx in range(x0 // 12, (x0 + columns - 1) // 12 + 1):
            folder = precision / f'tiles/10/{tx}/{ty}'
            if not (folder / 'manifest.json').exists():
                manifests.append(dict(tile=f'z10-x{tx}-y{ty}', available=False)); continue
            raw = (folder / 'manifest.json').read_bytes()
            complete = json.loads((folder / 'COMPLETE.json').read_bytes())
            if shared.digest(raw) != complete['manifestSHA256']: raise ValueError(f'Manifest hash mismatch: {folder}')
            document = json.loads(raw)
            if document['chunksPerTileAxis'] != 12: raise ValueError('Unsupported parent grid')
            manifests.append(dict(path=str(folder / 'manifest.json'), sha256=shared.digest(raw), byteCount=len(raw), source=document['source']))
            for parent in document['parents']:
                gx, gy = tx * 12 + parent['parentX'], ty * 12 + parent['parentY']
                if not (x0 <= gx < x0 + columns and y0 <= gy < y0 + rows): continue
                if parent['status'] != 'available': continue
                level = next((l for l in parent['baseLODs'] if l['nominalSpacingMetres'] == 8), None)
                if level is None: continue
                terrain = level['terrain']
                if (terrain['width'], terrain['height'], terrain['scaleMetres'], terrain['noDataValue'], terrain['verticalCRS']) != (257, 257, .1, shared.NO_DATA, 'EPSG:5773'):
                    raise ValueError(f'Incompatible prepared terrain in {folder}/{parent["id"]}')
                expected = parent_bounds(gx, gy)
                if any(abs(expected[k] - terrain['bounds'][k]) > 1e-10 for k in expected): raise ValueError('Source grid bounds mismatch')
                selected[gx, gy] = (folder / 'parents' / parent['id'] / level['path'], level)
    return selected, manifests


def assemble_context(selected, x0, y0, columns, rows):
    """Stitch original prepared samples, then correct the cross-world-tile latitude axis.

    Each original z10 tile has linearly spaced latitude samples internally, but
    its latitude step differs from its north/south neighbour. Context is a single
    uniformly spaced WGS84 grid, so only rows need linear resampling. Never use
    an unknown sample to interpolate or substitute zero for an unknown height.
    """
    joined = np.full((rows * 256 + 1, columns * 256 + 1), shared.NO_DATA, dtype='<i2')
    latitude = np.empty(rows * 256 + 1, dtype=np.float64)
    sources, missing, seams, disagreements = [], [], 0, []
    for row in range(rows):
        pb = parent_bounds(x0, y0 + row)
        latitude[row * 256:row * 256 + 257] = np.linspace(pb['maxLatitude'], pb['minLatitude'], 257)
        for column in range(columns):
            key = (x0 + column, y0 + row)
            if key not in selected:
                missing.append(dict(globalParent=list(key), bounds=parent_bounds(*key))); continue
            path, level = selected[key]
            raw = shared.checked_bytes(path, level)
            samples = np.frombuffer(raw, dtype='<i2').reshape(257, 257)
            y, x = row * 256, column * 256
            # Check both valid sides of each source edge before joining. Unknown
            # edge values may be supplied by their known adjacent source sample.
            for axis, old, new, neighbour in [
                ('west', joined[y:y + 257, x], samples[:, 0], (key[0] - 1, key[1])),
                ('north', joined[y, x:x + 257], samples[0], (key[0], key[1] - 1))]:
                if neighbour not in selected or (axis == 'west' and not column) or (axis == 'north' and not row): continue
                both = (old != shared.NO_DATA) & (new != shared.NO_DATA)
                if np.any(old[both] != new[both]):
                    disagreements.append(dict(path=str(path), edge=axis, count=int(np.sum(old[both] != new[both])),
                                              maximumDifferenceDecimetres=int(np.max(np.abs(old[both].astype(int) - new[both].astype(int))))))
                seams += 1
            window = joined[y:y + 257, x:x + 257]
            valid = samples != shared.NO_DATA
            window[valid] = samples[valid]
            sources.append(dict(path=str(path), sha256=shared.digest(raw), byteCount=len(raw), bounds=level['terrain']['bounds'],
                                noDataSamples=int(np.sum(~valid)), nominalSpacing=8))
    # A height discontinuity is evidence to inspect, not silently smooth away.
    if disagreements: raise ValueError(f'Prepared source edges disagree: {disagreements[:4]}')
    bounds = shared.union_bounds([parent_bounds(x0, y0), parent_bounds(x0 + columns - 1, y0 + rows - 1)])
    target_lat = np.linspace(bounds['maxLatitude'], bounds['minLatitude'], joined.shape[0])
    source_rows = np.interp(-target_lat, -latitude, np.arange(joined.shape[0]))
    output = np.full_like(joined, shared.NO_DATA)
    for index, position in enumerate(source_rows):
        nearest = round(float(position))
        if abs(position - nearest) < 1e-7:
            output[index] = joined[nearest]; continue
        top = int(math.floor(position)); alpha = float(position - top)
        upper, lower = joined[top], joined[min(top + 1, joined.shape[0] - 1)]
        valid = (upper != shared.NO_DATA) & (lower != shared.NO_DATA)
        output[index, valid] = np.rint(upper[valid].astype(np.float64) * (1 - alpha) + lower[valid].astype(np.float64) * alpha).astype('<i2')
    report = dict(parents=sources, missingParents=missing, verifiedSeams=seams, sourceNoDataSamples=int(np.sum(joined == shared.NO_DATA)),
                  uniformGridNoDataSamples=int(np.sum(output == shared.NO_DATA)), uniformGridSamples=int(output.size),
                  maximumRowDisplacementFromNaiveStitch=float(np.max(np.abs(source_rows - np.arange(joined.shape[0])))),
                  resampling='Linear interpolation of prepared 8m north/south sample rows onto uniform WGS84 bounds; all contributing samples must be known. 16m/32m are exact nested decimations.')
    return output, bounds, report


def read_context_maps(old, tiles, bounds):
    features, evidence, seen = [], [], set()
    for x, y in sorted(tiles):
        folder = old / f'mapping/build/public/tiles/10/{x}/{y}'
        descriptor = json.loads((folder / 'descriptor.json').read_bytes())
        archive = folder / Path(descriptor['archiveURL']).name
        if archive.stat().st_size != descriptor['archiveSizeBytes'] or file_digest(archive) != descriptor['archiveSHA256']:
            raise ValueError(f'OSM archive checksum mismatch: {archive}')
        with zipfile.ZipFile(archive) as source:
            semantic = json.loads(source.read('map-data.ridgemap'))
        count = 0
        for feature in semantic['features']:
            if not shared.intersects_geometry(bounds, feature['geometry']): continue
            # Deduplicate only identical geometry. Tile-clipped pieces of the
            # same OSM element must remain, or a world-tile seam can lose roads.
            key = (feature['kind'], json.dumps(feature['geometry'], separators=(',', ':')))
            if key in seen: continue
            seen.add(key); features.append(feature); count += 1
        evidence.append(dict(path=str(archive), sha256=descriptor['archiveSHA256'], byteCount=descriptor['archiveSizeBytes'], selectedFeatures=count))
        print(f'OSM context {x}/{y}: {count:,} cartographic features', flush=True)
    return features, evidence


def resample_map_heights(heights, source_bounds, target_bounds, side=257):
    """Sample the saved 8 m context for cartographic contours, never alter it.

    Parent map tiles follow original world-tile latitude boundaries while the
    saved context heightfield has a uniform latitude grid. Geographic sampling
    keeps the map in the same place across that change in grid coordinates.
    """
    xs = np.linspace((target_bounds['minLongitude'] - source_bounds['minLongitude']) /
                     (source_bounds['maxLongitude'] - source_bounds['minLongitude']) * (heights.shape[1] - 1),
                     (target_bounds['maxLongitude'] - source_bounds['minLongitude']) /
                     (source_bounds['maxLongitude'] - source_bounds['minLongitude']) * (heights.shape[1] - 1), side)
    ys = np.linspace((source_bounds['maxLatitude'] - target_bounds['maxLatitude']) /
                     (source_bounds['maxLatitude'] - source_bounds['minLatitude']) * (heights.shape[0] - 1),
                     (source_bounds['maxLatitude'] - target_bounds['minLatitude']) /
                     (source_bounds['maxLatitude'] - source_bounds['minLatitude']) * (heights.shape[0] - 1), side)
    xs, ys = np.clip(xs, 0, heights.shape[1] - 1), np.clip(ys, 0, heights.shape[0] - 1)
    x0, y0 = np.floor(xs).astype(int), np.floor(ys).astype(int)
    x1, y1 = np.minimum(x0 + 1, heights.shape[1] - 1), np.minimum(y0 + 1, heights.shape[0] - 1)
    a, b = heights[y0[:, None], x0[None, :]], heights[y0[:, None], x1[None, :]]
    c, d = heights[y1[:, None], x0[None, :]], heights[y1[:, None], x1[None, :]]
    fx, fy = (xs - x0)[None, :], (ys - y0)[:, None]
    wa, wb, wc, wd = (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy
    valid = (((a != shared.NO_DATA) | (wa < 1e-9)) & ((b != shared.NO_DATA) | (wb < 1e-9)) &
             ((c != shared.NO_DATA) | (wc < 1e-9)) & ((d != shared.NO_DATA) | (wd < 1e-9)))
    result = np.full((side, side), shared.NO_DATA, dtype='<i2')
    interpolated = a * wa + b * wb + c * wc + d * wd
    result[valid] = np.rint(interpolated[valid]).astype('<i2')
    return result


def map_feature_bounds(feature):
    coordinates = list(shared.geom_coords(feature['geometry']['coordinates']))
    if not coordinates: return None
    return dict(minLongitude=min(c[0] for c in coordinates), maxLongitude=max(c[0] for c in coordinates),
                minLatitude=min(c[1] for c in coordinates), maxLatitude=max(c[1] for c in coordinates))


def intersect_bounds(a, b):
    return not (a['maxLongitude'] < b['minLongitude'] or a['minLongitude'] > b['maxLongitude'] or
                a['maxLatitude'] < b['minLatitude'] or a['minLatitude'] > b['maxLatitude'])


def same_bounds(a, b):
    return all(abs(a[k] - b[k]) < 1e-10 for k in a)


def render_context_tiles(stage, target, manifest, features, heights, bounds, x0, y0, columns, rows):
    """A single cartographic style at every distance, independent of mesh spacing.

    Render at the primary detail-map scale (4096 pixels per original parent),
    then derive near/far maps from the same master. Primary parents reuse their
    existing detail pixels exactly; elsewhere the shared renderer supplies the
    same palette, contours, paths, tracks, roads, water, buildings and boundaries.
    Texture tiles retain their geographic bounds through all image resolutions.
    """
    indexed = [(f, map_feature_bounds(f)) for f in features]
    near, far, evidence = [], [], []
    preview = Image.new('RGB', (columns * 128, rows * 128))
    for row in range(rows):
        for column in range(columns):
            gx, gy = x0 + column, y0 + row
            tile_bounds = parent_bounds(gx, gy)
            existing = next((t for t in manifest.get('detailTextures', []) if same_bounds(t['bounds'], tile_bounds)), None)
            selected_features = [f for f, fb in indexed if fb is not None and intersect_bounds(fb, tile_bounds)]
            if existing:
                shared.checked_bytes(target / existing['file'], existing)
                with Image.open(target / existing['file']) as source:
                    if source.size != (4096, 4096): raise ValueError('Primary detail-map scale changed')
                    master = source.convert('RGB')
                source_evidence = dict(file=existing['file'], sha256=existing['sha256'], reuse='Exact primary detail-map master')
            else:
                tile_heights = resample_map_heights(heights, bounds, tile_bounds)
                if np.any(tile_heights != shared.NO_DATA):
                    master = shared.render_texture(selected_features, tile_heights, tile_bounds, 4096)
                else:
                    # The shared renderer requires at least one known height for
                    # contours. Zero here is only the no-relief map background;
                    # all terrain files retain NoData and remain non-pickable.
                    master = shared.render_texture(selected_features, np.zeros_like(tile_heights), tile_bounds, 4096)
                source_evidence = dict(renderer='prepare_packs.render_texture', heightSource='Saved horizon-near-8m.bin, geographic resampling for map contours only')
            near_image = master.resize((1024, 1024), Image.Resampling.LANCZOS)
            # Both mip densities come from this same map. No separate far style.
            far_image = near_image.resize((512, 512), Image.Resampling.LANCZOS)
            name = f'g{gx:04d}-{gy:04d}'
            near.append(write_map(stage, near_image, tile_bounds, f'near-{name}'))
            far.append(write_map(stage, far_image, tile_bounds, f'far-{name}'))
            preview.paste(near_image.resize((128, 128), Image.Resampling.LANCZOS), (column * 128, row * 128))
            evidence.append(dict(globalParent=[gx, gy], bounds=tile_bounds, featureCount=len(selected_features), **source_evidence))
            master.close(); near_image.close(); far_image.close()
            print(f'Cartography {len(near)}/{columns * rows}: {name}, {len(selected_features):,} features' + (' (primary pixels reused)' if existing else ''), flush=True)
    # Prove exact complete tiling in original parent coordinates, including the
    # nonuniform latitude step across z10 world tiles. Far bounds are identical.
    for index, texture in enumerate(near):
        row, column = divmod(index, columns)
        if texture['bounds'] != parent_bounds(x0 + column, y0 + row) or texture['bounds'] != far[index]['bounds']:
            raise ValueError('Cartographic tile bounds changed')
        if column and abs(near[index - 1]['bounds']['maxLongitude'] - texture['bounds']['minLongitude']) > 1e-10:
            raise ValueError('Cartographic longitude gap')
        if row and abs(near[index - columns]['bounds']['minLatitude'] - texture['bounds']['maxLatitude']) > 1e-10:
            raise ValueError('Cartographic latitude gap')
    if not same_bounds(shared.union_bounds([t['bounds'] for t in near]), bounds): raise ValueError('Cartographic coverage differs from terrain')
    return near, far, preview, evidence


def write_level(stage, heights, spacing, layer):
    raw = heights.astype('<i2').tobytes()
    name = f'horizon-{layer}-{spacing}m.bin'
    (stage / name).write_bytes(raw)
    return dict(spacing=spacing, width=heights.shape[1], height=heights.shape[0], file=name, byteCount=len(raw), sha256=shared.digest(raw))


def write_map(stage, image, bounds, layer):
    name = f'horizon-{layer}-map.png'; image.save(stage / name, optimize=True)
    raw = (stage / name).read_bytes()
    return dict(file=name, width=image.width, height=image.height, byteCount=len(raw), sha256=shared.digest(raw), bounds=bounds)


def prepare(args):
    started = time.monotonic()
    target = shared.BUNDLE / 'regions' / args.id
    manifest = json.loads((target / 'pack.json').read_bytes())
    grid = manifest['grid']
    match = re.fullmatch(r'z10-x(\d+)-y(\d+)', grid['worldTileID'])
    if not match: raise ValueError('Unsupported grid identity')
    tx, ty = map(int, match.groups())
    if any(grid[k] % 4 for k in ['originColumn', 'originRow', 'columns', 'rows']): raise ValueError('Source must align to complete original parents')
    if manifest['heightScale'] != .1 or manifest['noDataValue'] != shared.NO_DATA: raise ValueError('Incompatible inherited height encoding')
    x0, y0 = tx * 12 + grid['originColumn'] // 4 - args.margin, ty * 12 + grid['originRow'] // 4 - args.margin
    columns, rows = grid['columns'] // 4 + 2 * args.margin, grid['rows'] // 4 + 2 * args.margin
    if max(columns, rows) > 18: raise ValueError('Context limited to 18 original parents per axis')
    prior_report_path = shared.ROOT / 'Tools/reports' / f'{args.id}-horizon-source.json'
    if args.maps_only:
        if not manifest.get('horizon') or not prior_report_path.exists(): raise ValueError('--maps-only requires an existing horizon and source report')
        prior = json.loads(prior_report_path.read_bytes())
        existing = manifest['horizon']
        bounds = existing['near']['bounds']
        if not same_bounds(bounds, shared.union_bounds([parent_bounds(x0, y0), parent_bounds(x0 + columns - 1, y0 + rows - 1)])):
            raise ValueError('Existing horizon coverage differs from requested parent margin')
        level8 = next(l for l in existing['near']['levels'] if l['spacing'] == 8)
        raw = shared.checked_bytes(target / level8['file'], level8)
        heights = np.frombuffer(raw, dtype='<i2').reshape(level8['height'], level8['width'])
        manifests, terrain_evidence = prior['sourceManifests'], prior['terrain']
        print(f'Reusing saved context {heights.shape}; terrain files will not be rewritten', flush=True)
    else:
        selected, manifests = gather_sources(args.precision, x0, y0, columns, rows)
        print(f'Found {len(selected)}/{columns * rows} prepared 8m parents', flush=True)
        heights, bounds, terrain_evidence = assemble_context(selected, x0, y0, columns, rows)
    if not np.any(heights != shared.NO_DATA): raise ValueError('Context contains no known terrain')
    print(f'Joined context {heights.shape}, missing {terrain_evidence["uniformGridNoDataSamples"]:,}, verified {terrain_evidence["verifiedSeams"]} seams', flush=True)
    stage = shared.ROOT / 'Tools/PreparedPacks' / f'.{args.id}-horizon-staging'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    # Capture primary files before generating: additions may never rewrite the
    # selected grid, cartography, graph or existing optional high-detail maps.
    primary_hashes = {p.name: file_digest(p) for p in target.iterdir() if p.is_file() and p.name != 'pack.json' and not p.name.startswith('horizon-')}
    if args.maps_only:
        near_levels, far_levels = existing['near']['levels'], existing['far']['levels']
    else:
        near_levels = [write_level(stage, heights, 8, 'near'), write_level(stage, heights[::2, ::2], 16, 'near')]
        far_levels = [write_level(stage, heights[::4, ::4], 32, 'far')]
    tiles = {(gx // 12, gy // 12) for gy in range(y0, y0 + rows) for gx in range(x0, x0 + columns)}
    features, map_evidence = read_context_maps(args.old, tiles, bounds)
    near_maps, far_maps, preview_image, texture_evidence = render_context_tiles(stage, target, manifest, features, heights, bounds, x0, y0, columns, rows)
    horizon = dict(near=dict(bounds=bounds, levels=near_levels, textures=near_maps), far=dict(bounds=bounds, levels=far_levels, textures=far_maps))
    known = heights[heights != shared.NO_DATA]
    report = dict(region=args.id, bounds=bounds, parentOrigin=[x0, y0], parentShape=[columns, rows], sourceManifests=manifests,
                  terrain=terrain_evidence, maps=map_evidence, featureCount=len(features), featureKinds=dict(Counter(f['kind'] for f in features)),
                  textureTiles=texture_evidence, textureStyle='Shared primary detail cartography; 4096 px parent master, 1024 px near and 512 px far nested downsampling', horizon=horizon,
                  heightMinimumMeters=float(known.min()) * .1, heightMaximumMeters=float(known.max()) * .1,
                  validPercent=float(known.size / heights.size * 100), mainFilesPreservedSHA256=primary_hashes,
                  actualSpacing={str(l['spacing']):shared.spacing_meters(bounds, l['width'], l['height']) for l in near_levels + far_levels})
    for layer in horizon.values():
        for item in layer['levels'] + layer['textures']:
            asset = target / item['file'] if args.maps_only and item in layer['levels'] else stage / item['file']
            raw = shared.checked_bytes(asset, item)
            if item in layer['levels'] and len(raw) != item['width'] * item['height'] * 2: raise ValueError('Invalid output height dimensions')
            if item in layer['textures']:
                with Image.open(stage / item['file']) as check:
                    if check.size != (item['width'], item['height']): raise ValueError('Invalid output map dimensions')
    for name, expected in primary_hashes.items():
        if file_digest(target / name) != expected: raise ValueError(f'Primary source changed during build: {name}')
    report_path = shared.ROOT / 'Tools/reports' / f'{args.id}-horizon-source.json'
    shared.write_json(report_path, report)
    preview_image.save(shared.ROOT / 'Tools/reports' / f'{args.id}-horizon-preview.png')
    shared.write_json(stage / 'horizon.json', horizon)
    if args.stage_only:
        print(json.dumps(dict(staged=str(stage), report=str(report_path), validPercent=report['validPercent'])), flush=True); return
    previous_context_files = {item['file'] for layer in manifest.get('horizon', {}).values() if layer for item in layer['levels'] + layer['textures']}
    for layer in horizon.values():
        for item in layer['levels'] + layer['textures']:
            if args.maps_only and item in layer['levels']: continue
            (stage / item['file']).replace(target / item['file'])
    manifest['horizon'] = horizon
    shared.write_json(target / '.pack-next.json', manifest); (target / '.pack-next.json').replace(target / 'pack.json')
    catalog_path = shared.BUNDLE / 'catalog.json'
    catalog = json.loads(catalog_path.read_bytes())
    catalog = [manifest if item['id'] == manifest['id'] else item for item in catalog]
    shared.write_json(shared.BUNDLE / '.catalog-next.json', catalog); (shared.BUNDLE / '.catalog-next.json').replace(catalog_path)
    current_context_files = {item['file'] for layer in horizon.values() for item in layer['levels'] + layer['textures']}
    for name in previous_context_files - current_context_files:
        # Delete only obsolete files recorded by the prior generated horizon.
        if Path(name).name == name and name.startswith('horizon-'): (target / name).unlink(missing_ok=True)
    shutil.rmtree(stage)
    total_bytes = sum(p.stat().st_size for p in target.iterdir() if p.is_file())
    bundle_bytes = sum(p.stat().st_size for p in shared.BUNDLE.rglob('*') if p.is_file())
    print(json.dumps(dict(region=args.id, horizonBytes=sum(i['byteCount'] for l in horizon.values() for i in l['levels'] + l['textures']),
                          sourcePackBytes=total_bytes, bundleBytes=bundle_bytes, validPercent=report['validPercent'],
                          primaryFilesPreserved=len(primary_hashes), elapsedSeconds=round(time.monotonic() - started, 2))), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--precision', type=Path, default=shared.PRECISION)
    parser.add_argument('--old', type=Path, default=shared.OLD)
    parser.add_argument('--id', default='eryri-grid')
    parser.add_argument('--margin', type=int, default=5, help='Original parent cells added to each side, default five (~9.8km)')
    parser.add_argument('--stage-only', action='store_true', help='Prepare and verify files without updating bundled manifests')
    parser.add_argument('--maps-only', action='store_true', help='Reuse saved horizon heights and coverage; update cartography only')
    args = parser.parse_args()
    if not re.fullmatch('[a-z0-9][a-z0-9-]{0,63}', args.id): parser.error('Invalid region ID')
    if not 1 <= args.margin <= 7: parser.error('--margin must be 1..7 parents')
    prepare(args)


if __name__ == '__main__': main()
