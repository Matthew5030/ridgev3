#!/usr/bin/env python3
"""Build a fixed offline cartographic atlas, independent of terrain mesh bands.

Reuses primary detail-map masters and saved 8 m context for the remaining map
masters. No terrain, overview, near/far map, graph, or source-drive file changes.
The runtime reads a bounded number of these PNG cells from local storage.
Requires NumPy and Pillow, as do the existing source preparation tools.
"""
from __future__ import annotations

import argparse
from collections import OrderedDict, Counter
import gc
import json
from pathlib import Path
import shutil
import time

import numpy as np
from PIL import Image

import prepare_packs as shared
import prepare_horizon as context

MASTER = 4096
CORE = 1024
PREVIEW_CORE = 64
GUTTER = 4
PREVIEW_SCALE = CORE // PREVIEW_CORE
# Lanczos needs neighbouring samples outside the retained preview gutters too.
FILTER_GUTTER = 4


def publish_json(path, document):
    temporary = path.with_name('.' + path.name + '-next')
    shared.write_json(temporary, document)
    temporary.replace(path)


def master_paths(target, manifest, stage, report):
    """Prepare at most one new master in memory at a time; retain them on disk."""
    horizon = manifest['horizon']['near']
    level = next(level for level in horizon['levels'] if level['spacing'] == 8)
    raw = shared.checked_bytes(target / level['file'], level)
    heights = np.frombuffer(raw, dtype='<i2').reshape(level['height'], level['width'])
    x0, y0 = report['parentOrigin']; columns, rows = report['parentShape']
    tiles = {(gx // 12, gy // 12) for gy in range(y0, y0 + rows) for gx in range(x0, x0 + columns)}
    features, map_evidence = context.read_context_maps(shared.OLD, tiles, horizon['bounds'])
    indexed = [(f, context.map_feature_bounds(f)) for f in features]
    paths, evidence = {}, []
    master_folder = stage / 'masters'; master_folder.mkdir(parents=True, exist_ok=True)
    for row in range(rows):
        for column in range(columns):
            gx, gy = x0 + column, y0 + row
            bounds = context.parent_bounds(gx, gy)
            existing = next((t for t in manifest.get('detailTextures', []) if context.same_bounds(t['bounds'], bounds)), None)
            if existing:
                path = target / existing['file']
                shared.checked_bytes(path, existing)
                with Image.open(path) as image:
                    if image.size != (MASTER, MASTER): raise ValueError('Primary master scale is not 4096 pixels per parent')
                record = dict(primaryFile=existing['file'], sha256=existing['sha256'], reused=True)
            else:
                path = master_folder / f'g{gx:04d}-{gy:04d}.png'
                selected = [f for f, fb in indexed if fb is not None and context.intersect_bounds(fb, bounds)]
                tile_heights = context.resample_map_heights(heights, horizon['bounds'], bounds)
                if not np.any(tile_heights != shared.NO_DATA): tile_heights = np.zeros_like(tile_heights)
                image = shared.render_texture(selected, tile_heights, bounds, MASTER)
                # These temporary masters are decoded again; PNG compression
                # changes storage only, never the pixels used by atlas cells.
                image.save(path, compress_level=6)
                image.close()
                record = dict(sha256=context.file_digest(path), reused=False, featureCount=len(selected))
            paths[column, row] = path
            evidence.append(dict(globalParent=[gx, gy], bounds=bounds, **record))
            print(f'Master {len(paths)}/{columns * rows}: g{gx:04d}-{gy:04d}' + (' (existing pixels)' if existing else ''), flush=True)
    feature_kinds = dict(Counter(f['kind'] for f in features))
    del indexed, features, heights, raw
    gc.collect()
    return paths, evidence, map_evidence, feature_kinds


class MasterWindow:
    """A bounded decoded-parent cache; no complete cartographic mosaic."""
    def __init__(self, paths, columns, rows):
        self.paths, self.columns, self.rows = paths, columns, rows
        self.images = OrderedDict()
        self.peak = 0

    def image(self, column, row):
        key = column, row
        if key not in self.images:
            # Evict before decoding so even the transient cache is bounded.
            while len(self.images) >= 9:
                _, removed = self.images.popitem(last=False); removed.close()
            source = Image.open(self.paths[key])
            try:
                source.load()
                if source.mode == 'RGB': self.images[key] = source
                else:
                    self.images[key] = source.convert('RGB')
                    source.close()
            except BaseException:
                source.close()
                raise
            self.peak = max(self.peak, len(self.images))
        self.images.move_to_end(key)
        return self.images[key]

    def extract(self, left, top, width, height):
        full_width, full_height = self.columns * MASTER, self.rows * MASTER
        x0, y0 = max(0, left), max(0, top)
        x1, y1 = min(full_width, left + width), min(full_height, top + height)
        if x1 <= x0 or y1 <= y0: raise ValueError('Atlas sample lies outside prepared coverage')
        result = Image.new('RGB', (x1 - x0, y1 - y0))
        for row in range(y0 // MASTER, (y1 - 1) // MASTER + 1):
            for column in range(x0 // MASTER, (x1 - 1) // MASTER + 1):
                a, b = max(x0, column * MASTER), max(y0, row * MASTER)
                c, d = min(x1, (column + 1) * MASTER), min(y1, (row + 1) * MASTER)
                fragment = self.image(column, row).crop((a - column * MASTER, b - row * MASTER, c - column * MASTER, d - row * MASTER))
                result.paste(fragment, (a - x0, b - y0)); fragment.close()
        # Clamping is restricted to the true outside edge of known coverage.
        padding = ((y0 - top, top + height - y1), (x0 - left, left + width - x1), (0, 0))
        if any(value for axis in padding for value in axis):
            values = np.pad(np.asarray(result), padding, mode='edge')
            result.close(); result = Image.fromarray(values)
        if result.size != (width, height): raise ValueError('Incorrect atlas extraction dimensions')
        return result

    def close(self):
        for image in self.images.values(): image.close()
        self.images.clear()


def write_image(stage, name, image, bounds):
    path = stage / 'assets' / name
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, compress_level=6)
    raw = path.read_bytes()
    maximum = 1_048_576 if image.width == PREVIEW_CORE + 2 * GUTTER else 16_777_216
    if not 0 < len(raw) <= maximum: raise ValueError('Atlas image exceeds the native encoded-file bound')
    return dict(file=name, width=image.width, height=image.height, byteCount=len(raw), sha256=shared.digest(raw), bounds=bounds)


def atlas_edges(x0, y0, columns, rows):
    longitude, latitude = [], []
    for column in range(columns):
        bounds = context.parent_bounds(x0 + column, y0)
        longitude.extend(bounds['minLongitude'] + (bounds['maxLongitude'] - bounds['minLongitude']) * step / 4 for step in range(4))
    longitude.append(context.parent_bounds(x0 + columns - 1, y0)['maxLongitude'])
    for row in range(rows):
        bounds = context.parent_bounds(x0, y0 + row)
        latitude.extend(bounds['maxLatitude'] - (bounds['maxLatitude'] - bounds['minLatitude']) * step / 4 for step in range(4))
    latitude.append(context.parent_bounds(x0, y0 + rows - 1)['minLatitude'])
    if not all(a < b for a, b in zip(longitude, longitude[1:])) or not all(a > b for a, b in zip(latitude, latitude[1:])):
        raise ValueError('Atlas edges are not strictly monotonic')
    return longitude, latitude


def make_atlas(stage, paths, report):
    parent_columns, parent_rows = report['parentShape']
    x0, y0 = report['parentOrigin']
    columns, rows = parent_columns * 4, parent_rows * 4
    longitude, latitude = atlas_edges(x0, y0, parent_columns, parent_rows)
    cache = MasterWindow(paths, parent_columns, parent_rows)
    records = []
    try:
        for row in range(rows):
            for column in range(columns):
                bounds = dict(minLongitude=longitude[column], maxLongitude=longitude[column + 1],
                              minLatitude=latitude[row + 1], maxLatitude=latitude[row])
                left, top = column * CORE, row * CORE
                image = cache.extract(left - GUTTER, top - GUTTER, CORE + 2 * GUTTER, CORE + 2 * GUTTER)
                full = write_image(stage, f'cartography-c{column:03d}-r{row:03d}.png', image, bounds)
                image.close()
                source_gutter = (GUTTER + FILTER_GUTTER) * PREVIEW_SCALE
                source = cache.extract(left - source_gutter, top - source_gutter, CORE + 2 * source_gutter, CORE + 2 * source_gutter)
                down = source.resize((PREVIEW_CORE + 2 * (GUTTER + FILTER_GUTTER),) * 2, Image.Resampling.LANCZOS)
                preview = down.crop((FILTER_GUTTER, FILTER_GUTTER, PREVIEW_CORE + 2 * GUTTER + FILTER_GUTTER, PREVIEW_CORE + 2 * GUTTER + FILTER_GUTTER))
                small = write_image(stage, f'cartography-c{column:03d}-r{row:03d}-preview.png', preview, bounds)
                source.close(); down.close(); preview.close()
                records.append(dict(image=full, preview=small))
            print(f'Atlas row {row + 1}/{rows}: {len(records)}/{columns * rows} cells', flush=True)
    finally: cache.close()
    return dict(columns=columns, rows=rows, longitudeEdges=longitude, latitudeEdges=latitude, tiles=records), cache.peak


def verify_atlas(stage, atlas, paths, report):
    """Read outputs independently: dimensions, checksums, shared gutters, previews."""
    columns, rows = atlas['columns'], atlas['rows']
    cache = MasterWindow(paths, *report['parentShape'])
    previous_images, previous_previews = {}, {}
    checks = Counter()
    try:
        for row in range(rows):
            row_images, row_previews = {}, {}
            for column in range(columns):
                tile = atlas['tiles'][row * columns + column]
                arrays = {}
                for kind, side in [('image', CORE + 2 * GUTTER), ('preview', PREVIEW_CORE + 2 * GUTTER)]:
                    metadata = tile[kind]
                    raw = shared.checked_bytes(stage / 'assets' / metadata['file'], metadata)
                    with Image.open(stage / 'assets' / metadata['file']) as image:
                        if image.size != (side, side): raise ValueError('Incorrect output image size')
                        arrays[kind] = np.asarray(image.convert('RGB'))
                    checks['verifiedFiles'] += 1
                full, preview = arrays['image'], arrays['preview']
                expected = cache.extract(column * CORE - GUTTER, row * CORE - GUTTER, CORE + 2 * GUTTER, CORE + 2 * GUTTER)
                if not np.array_equal(full, np.asarray(expected)): raise ValueError('Full cell changed canonical master pixels')
                expected.close(); checks['canonicalImageMatches'] += 1
                pad = (GUTTER + FILTER_GUTTER) * PREVIEW_SCALE
                source = cache.extract(column * CORE - pad, row * CORE - pad, CORE + 2 * pad, CORE + 2 * pad)
                down = source.resize((PREVIEW_CORE + 2 * (GUTTER + FILTER_GUTTER),) * 2, Image.Resampling.LANCZOS)
                expected = down.crop((FILTER_GUTTER, FILTER_GUTTER, PREVIEW_CORE + 2 * GUTTER + FILTER_GUTTER, PREVIEW_CORE + 2 * GUTTER + FILTER_GUTTER))
                if not np.array_equal(preview, np.asarray(expected)): raise ValueError('Preview does not match global source filtering')
                source.close(); down.close(); expected.close(); checks['previewMatches'] += 1
                if column:
                    for values, old in [(full, row_images[column - 1]), (preview, row_previews[column - 1])]:
                        if not np.array_equal(old['right'], values[:, :2 * GUTTER]): raise ValueError('Horizontal atlas gutter mismatch')
                        checks['matchingHorizontalSeams'] += 1
                if row:
                    for values, old in [(full, previous_images[column]), (preview, previous_previews[column])]:
                        if not np.array_equal(old['bottom'], values[:2 * GUTTER]): raise ValueError('Vertical atlas gutter mismatch')
                        checks['matchingVerticalSeams'] += 1
                # Retain only edge strips for the current/previous row, not all
                # full-resolution images from a row or a global mosaic.
                row_images[column] = dict(right=full[:, -2 * GUTTER:].copy(), bottom=full[-2 * GUTTER:].copy())
                row_previews[column] = dict(right=preview[:, -2 * GUTTER:].copy(), bottom=preview[-2 * GUTTER:].copy())
                bounds = tile['image']['bounds']
                if bounds != tile['preview']['bounds'] or bounds != dict(minLongitude=atlas['longitudeEdges'][column], maxLongitude=atlas['longitudeEdges'][column + 1], minLatitude=atlas['latitudeEdges'][row + 1], maxLatitude=atlas['latitudeEdges'][row]):
                    raise ValueError('Tile inner bounds differ from atlas edge coordinates')
            previous_images, previous_previews = row_images, row_previews
            print(f'Verified atlas row {row + 1}/{rows}', flush=True)
    finally: cache.close()
    return dict(checks)


def prepare(args):
    started = time.monotonic()
    target = shared.BUNDLE / 'regions' / args.id
    manifest = json.loads((target / 'pack.json').read_bytes())
    report = json.loads((shared.ROOT / 'Tools/reports' / f'{args.id}-horizon-source.json').read_bytes())
    if not manifest.get('horizon') or not manifest['horizon'].get('near'): raise ValueError('A saved context with 8 m samples is required')
    x0, y0 = report['parentOrigin']; columns, rows = report['parentShape']
    if columns < 1 or rows < 1 or columns * rows * 16 > 4096: raise ValueError('Atlas exceeds its bounded cell count')
    bounds = shared.union_bounds([context.parent_bounds(x0, y0), context.parent_bounds(x0 + columns - 1, y0 + rows - 1)])
    if not context.same_bounds(bounds, manifest['horizon']['near']['bounds']): raise ValueError('Source report and saved context coverage differ')
    preserved = {str(path.relative_to(target)): context.file_digest(path) for path in target.rglob('*') if path.is_file() and path.name != 'pack.json' and not path.name.startswith('cartography-')}
    stage = shared.ROOT / 'Tools/PreparedPacks' / f'.{args.id}-cartography-staging'
    if stage.exists(): shutil.rmtree(stage)
    stage.mkdir(parents=True)
    paths, masters, map_evidence, feature_kinds = master_paths(target, manifest, stage, report)
    atlas, maximum_cached_masters = make_atlas(stage, paths, report)
    checks = verify_atlas(stage, atlas, paths, report)
    for name, digest in preserved.items():
        if context.file_digest(target / name) != digest: raise ValueError(f'Existing asset changed: {name}')
    output_report = dict(region=args.id, cartography=atlas, masters=masters, maps=map_evidence, featureKinds=feature_kinds,
                         checks=checks, maximumCachedMasterImages=maximum_cached_masters, preservedAssets=preserved,
                         corePixels=CORE, previewCorePixels=PREVIEW_CORE, gutterPixels=GUTTER,
                         previewFilter='Global canonical pixels, Lanczos16:1; four additional output filter pixels discarded on each edge',
                         elapsedSeconds=round(time.monotonic() - started, 2))
    report_path = shared.ROOT / 'Tools/reports' / f'{args.id}-cartography-atlas.json'
    shared.write_json(report_path, output_report)
    shared.write_json(stage / 'cartography.json', atlas)
    if args.stage_only:
        print(json.dumps(dict(staged=str(stage), report=str(report_path), checks=checks)), flush=True); return
    previous_files = {tile[kind]['file'] for tile in (manifest.get('cartography') or {}).get('tiles', []) for kind in ['image', 'preview']}
    current_files = {tile[kind]['file'] for tile in atlas['tiles'] for kind in ['image', 'preview']}
    for name in current_files:
        (stage / 'assets' / name).replace(target / name)
    manifest['cartography'] = atlas
    publish_json(target / 'pack.json', manifest)
    catalog_path = shared.BUNDLE / 'catalog.json'
    catalog = json.loads(catalog_path.read_bytes())
    publish_json(catalog_path, [manifest if item['id'] == manifest['id'] else item for item in catalog])
    for name in previous_files - current_files:
        if Path(name).name == name and name.startswith('cartography-'): (target / name).unlink(missing_ok=True)
    shutil.rmtree(stage)
    full_bytes = sum(t['image']['byteCount'] for t in atlas['tiles'])
    preview_bytes = sum(t['preview']['byteCount'] for t in atlas['tiles'])
    print(json.dumps(dict(region=args.id, tiles=len(atlas['tiles']), fullBytes=full_bytes, previewBytes=preview_bytes,
                          atlasBytes=full_bytes + preview_bytes, sourcePackBytes=sum(p.stat().st_size for p in target.rglob('*') if p.is_file()),
                          bundleBytes=sum(p.stat().st_size for p in shared.BUNDLE.rglob('*') if p.is_file()),
                          preservedAssets=len(preserved), maximumCachedMasterImages=maximum_cached_masters,
                          checks=checks, elapsedSeconds=round(time.monotonic() - started, 2))), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--id', default='eryri-grid')
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    if not shared.re.fullmatch('[a-z0-9][a-z0-9-]{0,63}', args.id): parser.error('Invalid region ID')
    prepare(args)


if __name__ == '__main__': main()
