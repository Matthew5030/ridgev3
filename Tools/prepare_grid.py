#!/usr/bin/env python3
"""Package an original precision-cell grid from existing processed LiDAR.

Default: original z10-x500-y333, parents c04..07 / rows00..03,
giving sixteen by sixteen ~490m cells, each with genuine 513² 1m samples.
No raw LiDAR processing, network access or writes to either source project.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import time

import numpy as np

import prepare_packs as shared


def detail_maps(directory, manifest, heights4, features):
    """One high-detail cartographic image per original precision parent.

    Four children per axis gives 1024 cartographic pixels per ~490m cell.
    This is optional source imagery: installation selects only one map set.
    """
    grid = manifest['grid']
    if grid['columns'] % 4 or grid['rows'] % 4 or grid['originColumn'] % 4 or grid['originRow'] % 4:
        raise ValueError('Detail-map source must align to original parent boundaries')
    columns, rows = grid['columns'] // 4, grid['rows'] // 4
    if heights4.shape != (rows * 512 + 1, columns * 512 + 1):
        raise ValueError('The 4m source does not align with original precision parents')
    bounds = manifest['bounds']
    lat_step = (bounds['maxLatitude'] - bounds['minLatitude']) / rows
    lon_step = (bounds['maxLongitude'] - bounds['minLongitude']) / columns
    result = []
    for y in range(rows):
        for x in range(columns):
            parent_x, parent_y = grid['originColumn'] // 4 + x, grid['originRow'] // 4 + y
            child_bounds = dict(minLatitude=bounds['maxLatitude'] - (y + 1) * lat_step, maxLatitude=bounds['maxLatitude'] - y * lat_step,
                                minLongitude=bounds['minLongitude'] + x * lon_step, maxLongitude=bounds['minLongitude'] + (x + 1) * lon_step)
            selected_features = [f for f in features if shared.intersects_geometry(child_bounds, f['geometry'])]
            image = shared.render_texture(selected_features, heights4[y * 512:y * 512 + 513, x * 512:x * 512 + 513], child_bounds, 4096)
            file = f'detail-map-c{parent_x:02d}-{parent_y:02d}.png'
            image.save(directory / file, optimize=True)
            image.close()
            raw = (directory / file).read_bytes()
            with shared.Image.open(directory / file) as check:
                if check.size != (4096, 4096): raise ValueError('Incorrect high-detail map dimensions')
            result.append(dict(file=file, width=4096, height=4096, bounds=child_bounds, byteCount=len(raw), sha256=shared.digest(raw)))
            print(f'Detail map {len(result)}/{columns * rows}: original parent c{parent_x:02d}-{parent_y:02d}, {len(raw):,} bytes', flush=True)
    area = lambda b: (b['maxLatitude'] - b['minLatitude']) * (b['maxLongitude'] - b['minLongitude'])
    if abs(sum(area(t['bounds']) for t in result) - area(bounds)) > area(bounds) * 1e-9:
        raise ValueError('High-detail maps do not cover the complete source')
    manifest['detailTextures'] = result
    return result


def publish_catalog(manifest):
    catalog_path = shared.BUNDLE / 'catalog.json'
    catalog = json.loads(catalog_path.read_bytes()) if catalog_path.exists() else []
    catalog = [manifest] + [m for m in catalog if m['id'] != manifest['id']]
    next_catalog = shared.BUNDLE / '.catalog-next.json'
    shared.write_json(next_catalog, catalog)
    next_catalog.replace(catalog_path)


def prepare_detail_only(args):
    target = shared.BUNDLE / 'regions' / args.id
    manifest = json.loads((target / 'pack.json').read_bytes())
    level = next(l for l in manifest['levels'] if l['spacing'] == 4)
    raw = shared.checked_bytes(target / level['file'], level)
    heights4 = np.frombuffer(raw, dtype='<i2').reshape(level['height'], level['width'])
    world = shared.re.fullmatch(r'z10-x(\d+)-y(\d+)', manifest['grid']['worldTileID'])
    if not world: raise ValueError('Unsupported world tile identity')
    tile = list(map(int, world.groups()))
    features, _, _, map_evidence = shared.read_map(args.old, tile, manifest['bounds'], heights4)
    stage = shared.ROOT / 'Tools/PreparedPacks' / f'.{args.id}-detail-staging'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    try:
        textures = detail_maps(stage, manifest, heights4, features)
        # Preserve every existing heightfield and overview image byte-for-byte.
        # Readers see new optional metadata only after all named images exist.
        for texture in textures: (stage / texture['file']).replace(target / texture['file'])
        next_manifest = target / '.pack-next.json'
        shared.write_json(next_manifest, manifest); next_manifest.replace(target / 'pack.json')
        publish_catalog(manifest)
        shared.write_json(shared.ROOT / 'Tools/reports' / f'{args.id}-detail-source.json',
                          dict(sourceTerrain=level, sourceMap=map_evidence, detailTextures=textures,
                               pixelsPerPrecisionCell=1024, terrainProcessing='Exact prepared 4m anchors; no raw LiDAR processing'))
        print(json.dumps(dict(id=args.id, detailTextureCount=len(textures), detailTextureBytes=sum(t['byteCount'] for t in textures),
                              sourcePackBytes=sum(f.stat().st_size for f in target.iterdir()), pixelsPerPrecisionCell=1024)), flush=True)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def prepare(args):
    start = time.monotonic()
    tile_dir = args.precision / f'tiles/10/{args.tile[0]}/{args.tile[1]}'
    raw_manifest = (tile_dir / 'manifest.json').read_bytes()
    completion = json.loads((tile_dir / 'COMPLETE.json').read_bytes())
    if shared.digest(raw_manifest) != completion['manifestSHA256']:
        raise ValueError('Source precision manifest checksum mismatch')
    source = json.loads(raw_manifest)
    if source['chunksPerTileAxis'] != 12 or source['subchunksPerChunkAxis'] != 4:
        raise ValueError('Unsupported original precision grid')
    parents = {(p['parentX'], p['parentY']): p for p in source['parents']}
    columns, rows = args.shape[0] * 4, args.shape[1] * 4
    # First prove all selected cells exist; do not emit a partial source area.
    records = []
    for parent_y in range(args.parent[1], args.parent[1] + args.shape[1]):
        for parent_x in range(args.parent[0], args.parent[0] + args.shape[0]):
            parent = parents.get((parent_x, parent_y))
            if not parent or parent['status'] != 'available':
                raise ValueError(f'Missing complete source at parent c{parent_x:02d}-{parent_y:02d}')
            children = {(c['subchunkX'], c['subchunkY']): c for c in parent['precisionChildren']}
            if len(children) != 16:
                raise ValueError(f'Incomplete child grid in {parent["id"]}')
            for child_y in range(4):
                for child_x in range(4):
                    child = children[(child_x, child_y)]
                    level = next(l for l in child['lods'] if l['nominalSpacingMetres'] == 1)
                    if level['terrain']['width'] != 513 or level['terrain']['height'] != 513:
                        raise ValueError('A precision cell does not contain a genuine 513-square source')
                    column = (parent_x - args.parent[0]) * 4 + child_x
                    row = (parent_y - args.parent[1]) * 4 + child_y
                    path = tile_dir / f'parents/c{parent_x:02d}-{parent_y:02d}' / level['path']
                    records.append((row, column, parent_x, parent_y, child_x, child_y, child, level, path))
    records.sort(key=lambda item: item[:2])
    print(f'Confirmed {len(records)} original precision cells, all with genuine 1m source.', flush=True)
    heights = np.full((rows * 512 + 1, columns * 512 + 1), shared.NO_DATA, dtype='<i2')
    provenance = []
    seams = 0
    for row, column, parent_x, parent_y, child_x, child_y, child, level, path in records:
        raw = shared.checked_bytes(path, level)
        array = np.frombuffer(raw, dtype='<i2').reshape(513, 513)
        if (array == shared.NO_DATA).any():
            raise ValueError(f'Missing terrain samples in {path}')
        x, y = column * 512, row * 512
        if column:
            if not np.array_equal(heights[y:y + 513, x], array[:, 0]): raise ValueError(f'East/west seam mismatch at cell {column},{row}')
            seams += 1
        if row:
            if not np.array_equal(heights[y, x:x + 513], array[0, :]): raise ValueError(f'North/south seam mismatch at cell {column},{row}')
            seams += 1
        heights[y:y + 513, x:x + 513] = array
        provenance.append(dict(id=f'{source["tileID"]}-c{parent_x:02d}-{parent_y:02d}-p{child_x:02d}-{child_y:02d}',
                               column=args.parent[0] * 4 + column, row=args.parent[1] * 4 + row,
                               bounds=child['bounds'], path=str(path), byteCount=len(raw), sha256=shared.digest(raw)))
    bounds = shared.union_bounds([r[6]['bounds'] for r in records])
    if (heights == shared.NO_DATA).any(): raise ValueError('The joined grid contains missing cells')
    print(f'Joined {heights.shape[1]} × {heights.shape[0]} samples; {seams} complete source seams verified.', flush=True)
    stage = shared.ROOT / 'Tools/PreparedPacks' / f'.{args.id}-grid-staging'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    levels = []
    for spacing in [1, 2, 4, 8, 16, 32]:
        grid = heights[::spacing, ::spacing]
        raw = grid.astype('<i2').tobytes()
        file = f'terrain-{spacing}m.bin'
        (stage / file).write_bytes(raw)
        levels.append(dict(spacing=spacing, width=grid.shape[1], height=grid.shape[0], file=file,
                           byteCount=len(raw), sha256=shared.digest(raw)))
    features, graph, places, map_evidence = shared.read_map(args.old, args.tile, bounds, heights)
    graph_raw = (json.dumps(graph, separators=(',', ':')) + '\n').encode()
    (stage / 'graph.json').write_bytes(graph_raw)
    print(f'Reused OSM cartography: {len(features)} features; {len(graph["nodes"])} graph nodes; {len(graph["edges"])} graph edges.', flush=True)
    # Terrain cartography does not require expanding an 8193² float field.
    # Use the exact 4m anchors for hillshade/contours; routes retain 1m heights.
    image = shared.render_texture(features, heights[::4, ::4], bounds, 4096)
    textures = []
    for y in range(2):
        for x in range(2):
            file = f'map-{x}-{y}.png'
            image.crop((x * 2048, y * 2048, (x + 1) * 2048, (y + 1) * 2048)).save(stage / file, optimize=True)
            raw = (stage / file).read_bytes()
            lat_step = (bounds['maxLatitude'] - bounds['minLatitude']) / 2
            lon_step = (bounds['maxLongitude'] - bounds['minLongitude']) / 2
            tb = dict(minLatitude=bounds['maxLatitude'] - (y + 1) * lat_step, maxLatitude=bounds['maxLatitude'] - y * lat_step,
                      minLongitude=bounds['minLongitude'] + x * lon_step, maxLongitude=bounds['minLongitude'] + (x + 1) * lon_step)
            textures.append(dict(file=file, width=2048, height=2048, bounds=tb, byteCount=len(raw), sha256=shared.digest(raw)))
    terrain_source = source['source']
    manifest = dict(schemaVersion=1, id=args.id, name=args.name, subtitle='Original precision tiles',
                    summary=f'{columns} × {rows} original precision cells from the prepared Eryri data. Each cell is approximately 490 m across and includes genuine 1 m LiDAR. Select fixed tiles and choose the terrain spacing that fits your device.',
                    version=shared.VERSION, bounds=bounds, sourceResolution=1, heightScale=.1, noDataValue=shared.NO_DATA,
                    levels=levels, textures=textures, graphFile='graph.json', graphSHA256=shared.digest(graph_raw), graphByteCount=len(graph_raw),
                    places=places, sources=[dict(name=terrain_source['name'], attribution=terrain_source['attribution'], license=terrain_source['license'],
                                               url=terrain_source.get('sourcePage', terrain_source.get('url', ''))),
                                           dict(name='OpenStreetMap', attribution='© OpenStreetMap contributors', license='Open Database License 1.0',
                                                url='https://www.openstreetmap.org/copyright')], defaultSpacing=8,
                    verticalDatum='EGM96 / EPSG:5773, as recorded by the prepared source; original LiDAR ODN / EPSG:5701',
                    grid=dict(gridID='ridge-web-mercator-z10-v1', worldTileID=source['tileID'], originColumn=args.parent[0] * 4,
                              originRow=args.parent[1] * 4, columns=columns, rows=rows))
    detail_maps(stage, manifest, heights[::4, ::4], features)
    shared.write_json(stage / 'pack.json', manifest)
    shared.validate_pack(stage)
    report = dict(sourceManifest=str(tile_dir / 'manifest.json'), sourceManifestSHA256=shared.digest(raw_manifest), sourceCells=provenance,
                  originalGrid=manifest['grid'], bounds=bounds, cells=len(records), verifiedSeams=seams,
                  graphNodes=len(graph['nodes']), graphEdges=len(graph['edges']), mapSource=map_evidence,
                  noDataSamples=0, levels=levels, detailTextures=manifest['detailTextures'], heightMinimumMeters=float(heights.min()) * .1, heightMaximumMeters=float(heights.max()) * .1,
                  actualSpacing={str(l['spacing']):shared.spacing_meters(bounds, l['width'], l['height']) for l in levels})
    shared.write_json(shared.ROOT / 'Tools/reports' / f'{args.id}-source.json', report)
    shared.write_json(shared.ROOT / 'Tools/reports' / f'{args.id}-detail-source.json',
                      dict(sourceTerrain=next(l for l in levels if l['spacing'] == 4), sourceMap=map_evidence,
                           detailTextures=manifest['detailTextures'], pixelsPerPrecisionCell=1024,
                           terrainProcessing='Exact prepared 4m anchors; no raw LiDAR processing'))
    preview = image.copy(); preview.thumbnail((1024, 1024)); preview.save(shared.ROOT / 'Tools/reports' / f'{args.id}-preview.jpg', quality=92)
    target = shared.BUNDLE / 'regions' / args.id
    if target.exists(): shutil.rmtree(target)
    stage.rename(target)
    publish_catalog(manifest)
    total = sum(f.stat().st_size for f in target.iterdir())
    print(json.dumps(dict(id=args.id, bytes=total, terrainBytes=sum(l['byteCount'] for l in levels), textureBytes=sum(t['byteCount'] for t in textures),
                          detailTextureBytes=sum(t['byteCount'] for t in manifest['detailTextures']), graphBytes=len(graph_raw),
                          cells=len(records), seams=seams, elapsedSeconds=round(time.monotonic() - start, 2))), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--precision', type=Path, default=shared.PRECISION)
    parser.add_argument('--old', type=Path, default=shared.OLD)
    parser.add_argument('--tile', nargs=2, type=int, default=[500, 333])
    parser.add_argument('--parent', nargs=2, type=int, default=[4, 0])
    parser.add_argument('--shape', nargs=2, type=int, default=[4, 4])
    parser.add_argument('--id', default='eryri-grid'); parser.add_argument('--name', default='Eryri')
    parser.add_argument('--detail-only', action='store_true', help='Add or refresh optional high-detail maps without changing existing terrain or overview maps')
    args = parser.parse_args()
    if min(args.shape) < 1 or max(args.shape) > 4: parser.error('--shape must be 1..4 parents per axis')
    if not shared.re.fullmatch('[a-z0-9][a-z0-9-]{0,63}', args.id): parser.error('Invalid pack identifier')
    if args.detail_only: prepare_detail_only(args)
    else: prepare(args)


if __name__ == '__main__': main()
