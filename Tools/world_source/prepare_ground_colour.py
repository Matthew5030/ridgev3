#!/usr/bin/env python3
"""Add satellite-guided illustrative colour to a new copy of a world source.

Requires numpy, Pillow and rasterio. --item is a local Sentinel-2 L2A STAC item.
Reads remote COG windows only. Never modifies the input or publishes a catalogue.
"""
import argparse
import base64
import hashlib
import json
import math
import shutil
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_bounds
from rasterio.vrt import WarpedVRT

REFERENCE_LUMINANCE = 0.0758987459699433  # approved Crib Goch comparison; fixed across sources


def raw(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()


def palette(rgb):
    # Low-frequency chromaticity guides illustrative tones, not land classification.
    samples = np.asarray(Image.fromarray(rgb).filter(ImageFilter.GaussianBlur(.65))) / 255.0
    linear = np.where(samples <= .04045, samples / 12.92, ((samples + .055) / 1.055) ** 2.4)
    luminance = linear @ np.array([.2126, .7152, .0722])
    ratios = linear / np.maximum(luminance[..., None], .005)
    green = np.clip((ratios[..., 1] - ratios[..., 0] + .025) * 4, 0, 1)
    brown = np.clip((ratios[..., 0] - ratios[..., 2] - .12) * 1.8, 0, 1) * (1 - green)
    neutral = np.array([.61, .59, .51])
    colour = neutral * (1 - green - brown)[..., None] + np.array([.45, .55, .31]) * green[..., None] + np.array([.61, .48, .32]) * brown[..., None]
    confidence = np.clip((luminance - .004) / .025, 0, 1)
    colour = neutral + (colour - neutral) * confidence[..., None]
    colour *= np.clip(np.exp(.12 * np.log(np.maximum(luminance, .005) / REFERENCE_LUMINANCE)), .92, 1.08)[..., None]
    encoded = np.where(colour <= .0031308, colour * 12.92, 1.055 * np.maximum(colour, 0) ** (1 / 2.4) - .055)
    return np.uint8(np.clip(encoded, 0, 1) * 255 + .5)


def prepare(source, output, item_path, cache):
    if output.exists():
        raise ValueError('Output must be a new directory; published sources are immutable')
    manifest = json.loads((source / 'world.json').read_bytes())
    item = json.loads(item_path.read_bytes())
    if item.get('collection') != 'sentinel-2-l2a':
        raise ValueError('A Sentinel-2 L2A item with visual and SCL assets is required')
    bounds = manifest['bounds']
    west, south, east, north = [bounds[k] for k in ('minLongitude', 'minLatitude', 'maxLongitude', 'maxLatitude')]
    columns, rows = manifest['columns'], manifest['rows']
    core_w = max(1, round((east - west) * 111320 * math.cos(math.radians((south + north) / 2)) / columns / 10))
    core_h = max(1, round((north - south) * 111320 / rows / 10))
    border = math.ceil(max(core_w, core_h) / 8) + 1
    if border > 32 or max(core_w, core_h) + 2 * border > 256:
        raise ValueError('Source cells exceed the colour sample budget')
    width, height = core_w * columns, core_h * rows
    dx, dy = (east - west) / width, (north - south) / height
    transform = from_bounds(west - border * dx, south - border * dy, east + border * dx, north + border * dy, width + 2 * border, height + 2 * border)
    # Cache is content-addressed by scene, asset URLs, bounds and grid.
    key = hashlib.sha256(raw([item['id'], item['assets']['visual']['href'], item['assets']['scl']['href'], bounds, width, height, border])).hexdigest()
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / (key + '.npz')
    if cached.exists():
        with np.load(cached) as saved:
            rgb, scl, valid = saved['rgb'], saved['scl'], saved['valid']
    else:
        options = dict(crs='EPSG:4326', transform=transform, width=width + 2 * border, height=height + 2 * border)
        with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN='EMPTY_DIR', CPL_VSIL_CURL_ALLOWED_EXTENSIONS='.tif', GDAL_HTTP_TIMEOUT='60'):
            with rasterio.open(item['assets']['visual']['href']) as dataset:
                with WarpedVRT(dataset, **options, resampling=Resampling.bilinear) as vrt:
                    rgb = vrt.read([1, 2, 3]).transpose(1, 2, 0)
                    valid = vrt.dataset_mask() > 0
            with rasterio.open(item['assets']['scl']['href']) as dataset:
                with WarpedVRT(dataset, **options, resampling=Resampling.nearest) as vrt:
                    scl = vrt.read(1)
        np.savez_compressed(cached, rgb=rgb, scl=scl, valid=valid)
    # Conservative mask: vegetation, bare land and water only. Expand excluded
    # samples by 30 m so the palette blur cannot bleed clouds into valid colours.
    usable = valid & np.isin(scl, [4, 5, 6])
    excluded = Image.fromarray(np.uint8(~usable) * 255).filter(ImageFilter.MaxFilter(7))
    alpha = 255 - np.asarray(excluded)
    colours = np.dstack([palette(rgb), alpha])
    if not np.any(alpha):
        raise ValueError('No usable imagery in this source')
    output.mkdir(parents=True)
    # Copy source assets (never mutate shared hard links). Keep only referenced files.
    assets = [manifest['overview'], manifest['graph']]
    for tile in manifest['tiles']:
        assets += [tile[k] for k in ('map', 'mesh', 'background') if k in tile]
    for asset in assets:
        name = asset.get('file', asset.get('path'))
        if Path(name).name != name:
            raise ValueError('Unsafe asset path')
        data = (source / name).read_bytes()
        if len(data) != asset['byteCount'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
            raise ValueError('Damaged input: ' + name)
        if not name.endswith('.map'):
            shutil.copyfile(source / name, output / name)
    added = 0
    for tile in manifest['tiles']:
        asset = tile['map']
        original = zlib.decompress((source / asset['file']).read_bytes())
        if len(original) != asset['decodedByteCount']:
            raise ValueError('Incorrect decoded map length')
        data = json.loads(original)
        x, y = tile['column'] * core_w, tile['row'] * core_h
        patch = colours[y:y + core_h + 2 * border, x:x + core_w + 2 * border]
        data.pop('groundColour', None)
        if np.any(patch[..., 3]):
            data['groundColour'] = dict(version=1, width=patch.shape[1], height=patch.shape[0], border=border, rgba=base64.b64encode(patch.tobytes()).decode())
        decoded = raw(data)
        if len(decoded) > 8_000_000:
            raise ValueError('Map exceeds decoded size budget')
        compressed = zlib.compress(decoded, 9)
        digest = hashlib.sha256(compressed).hexdigest()
        # Immutable names also allow old downloads to finish after publication.
        name = tile['id'] + '-ground-' + digest[:16] + '.map'
        (output / name).write_bytes(compressed)
        added += len(compressed) - asset['byteCount']
        tile['map'] = dict(file=name, byteCount=len(compressed), sha256=digest, decodedByteCount=len(decoded))
    year = item['properties']['datetime'][:4]
    credit = dict(name='Copernicus Sentinel-2', attribution=f'Contains modified Copernicus Sentinel data {year}. Satellite-guided illustrative ground colours.', license='Copernicus Sentinel data terms', url='https://dataspace.copernicus.eu/explore-data/data-collections/sentinel-data/sentinel-2')
    manifest['sources'] = [s for s in manifest['sources'] if s['name'] != credit['name']] + [credit]
    manifest['revision'] += '-ground-v1-' + item['id']
    (output / 'world.json').write_bytes(raw(manifest))
    report = dict(sceneID=item['id'], datetime=item['properties']['datetime'], strength=.66, bounds=bounds, usablePercent=float((alpha[border:-border, border:-border] > 0).mean() * 100), addedMapBytes=added, samplePixelsPerTile=[core_w, core_h], border=border, referenceLuminance=REFERENCE_LUMINANCE, attribution=credit['attribution'], inputManifestSHA256=hashlib.sha256((source / 'world.json').read_bytes()).hexdigest(), cachedWindowSHA256=hashlib.sha256(cached.read_bytes()).hexdigest(), limitations=['Approximately 10 m observed colour variation, not recovered fine texture or land-cover classification.', 'SCL masking is conservative but is not a guarantee of cloud-free imagery.'])
    (output / 'ground-colour-provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    (output / 'ground-colour-scene.json').write_bytes(raw(item))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--item', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.output, args.item, args.cache), indent=2), flush=True)
