#!/usr/bin/env python3
"""Audit/download official Scottish DTM inputs for the two Scottish parks.

The audit uses filename grid squares only to shortlist files. It is NOT a
valid-data coverage claim; prepare_scottish_sources.py checks actual rasters.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

from pyproj import Transformer
from shapely.geometry import shape, box
from shapely.ops import transform, unary_union

BUCKET = 'https://srsp-open-data.s3.eu-west-2.amazonaws.com'
SOURCE = 'https://registry.opendata.aws/scottish-lidar/'
PREFIXES = [f'lidar/phase-{i}/dtm/' for i in range(1, 7)] + ['lidar/national-lidar-programme/dtm/']
PARKS = ['cairngorms', 'loch-lomond-and-the-trossachs']
NS = {'s': 'http://s3.amazonaws.com/doc/2006-03-01/'}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4*1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.next.json')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def footprint(name):
    match = re.match(r'([A-HJ-Z]{2})(\d{2}|\d{4})(NE|NW|SE|SW)?_', name)
    if not match:
        return None
    letters, digits, quadrant = match.groups()
    n = [ord(c)-65-(c > 'I') for c in letters]
    e = ((n[0]-2) % 5)*5+n[1] % 5
    north = 19-(n[0]//5)*5-n[1]//5
    half = len(digits)//2
    size = 10**(5-half)
    x = e*100000+int(digits[:half])*size
    y = north*100000+int(digits[half:])*size
    if quadrant:
        size /= 2
        if 'E' in quadrant:
            x += size
        if 'N' in quadrant:
            y += size
    return box(x, y, x+size, y+size)


def scan(prefix, parks):
    result = []
    token = None
    while True:
        query = {'list-type': '2', 'prefix': prefix, 'max-keys': '1000'}
        if token:
            query['continuation-token'] = token
        with urllib.request.urlopen(BUCKET+'/?'+urllib.parse.urlencode(query), timeout=60) as response:
            tree = ET.fromstring(response.read())
        for item in tree.findall('s:Contents', NS):
            key = item.find('s:Key', NS).text
            name = key.rsplit('/', 1)[-1]
            area = footprint(name)
            if area is None or not name.lower().endswith('.tif'):
                continue
            hits = [key for key, park in parks.items() if park.intersects(area)]
            if hits:
                spacing = .5 if re.search(r'_50cm_', name, re.I) else 1 if re.search(r'_1m_', name, re.I) else None
                result.append(dict(key=key, byteCount=int(item.find('s:Size', NS).text),
                    etag=item.find('s:ETag', NS).text, gridBounds=list(area.bounds),
                    parks=hits, nominalSpacingMetres=spacing))
        continuation = tree.find('s:NextContinuationToken', NS)
        if continuation is None:
            return result
        token = continuation.text


def audit(boundaries, output, workers):
    project = Transformer.from_crs(4326, 27700, always_xy=True).transform
    parks = {key: transform(project, shape(json.loads((boundaries/f'{key}.geojson').read_text())['geometry'])) for key in PARKS}
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        records = sum(pool.map(lambda prefix: scan(prefix, parks), PREFIXES), [])
    summary = {}
    for key, park in parks.items():
        selected = [r for r in records if key in r['parks'] and r['nominalSpacingMetres'] is not None]
        covered = unary_union([box(*r['gridBounds']) for r in selected]).intersection(park)
        summary[key] = dict(files=len(selected), downloadBytes=sum(r['byteCount'] for r in selected),
            gridFootprintUpperBoundPercent=100*covered.area/park.area)
    atomic_json(output, dict(source=SOURCE, prefixes=PREFIXES,
        note='Filename grid-footprint upper bound, NOT valid LiDAR coverage. Actual TIFF bounds and NoData may reduce coverage.',
        summary=summary, files=records))
    print(json.dumps(summary, indent=2), flush=True)


def download_file(entry, out):
    name = hashlib.sha256(entry['key'].encode()).hexdigest()[:12]+'-'+entry['key'].rsplit('/', 1)[-1]
    path = out/name
    receipt = path.with_suffix('.json')
    if path.exists() and receipt.exists():
        old = json.loads(receipt.read_text())
        if (path.stat().st_size == entry['byteCount'] and old['etag'] == entry['etag']
                and old['key'] == entry['key'] and digest(path) == old['sha256']):
            return dict(old, path=str(path.resolve()))
    url = BUCKET+'/'+urllib.parse.quote(entry['key'], safe='/')
    request = urllib.request.Request(url, headers={'If-Match': entry['etag'], 'User-Agent': 'Ridge-offline-park-builder/1.0'})
    temporary = path.with_suffix('.download')
    sha = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as stream:
        if response.headers.get('ETag') != entry['etag']:
            raise ValueError('Source object changed; audit again into a new source version')
        for block in iter(lambda: response.read(4*1024*1024), b''):
            stream.write(block)
            sha.update(block)
            size += len(block)
    if size != entry['byteCount']:
        raise ValueError('Incomplete source file')
    temporary.replace(path)
    result = dict(entry, path=str(path.resolve()), url=url, sha256=sha.hexdigest())
    atomic_json(receipt, result)
    return result


def download(audit_path, output, workers):
    source = json.loads(audit_path.read_text())
    output.mkdir(parents=True, exist_ok=True)
    entries = [e for e in source['files'] if e['nominalSpacingMetres'] in (.5, 1)]
    results = []
    with concurrent.futures.ThreadPoolExecutor(workers) as pool:
        for entry in pool.map(lambda e: download_file(e, output), entries):
            results.append(entry)
            print(f"Downloaded {len(results)}/{len(entries)} · {sum(r['byteCount'] for r in results)/1e9:.2f} GB", flush=True)
    atomic_json(output/'sources.json', dict(source=source['source'], license='Open Government Licence v3.0', files=results))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    a = sub.add_parser('audit')
    a.add_argument('--boundaries', type=Path, required=True)
    a.add_argument('--output', type=Path, required=True)
    a.add_argument('--workers', type=int, default=4)
    d = sub.add_parser('download')
    d.add_argument('--audit', type=Path, required=True)
    d.add_argument('--output', type=Path, required=True)
    d.add_argument('--workers', type=int, default=3)
    args = p.parse_args()
    if not 1 <= args.workers <= 4:
        p.error('Use 1–4 workers')
    if args.command == 'audit':
        audit(args.boundaries, args.output, args.workers)
    else:
        download(args.audit, args.output, args.workers)


if __name__ == '__main__':
    main()
