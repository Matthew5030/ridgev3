#!/usr/bin/env python3
"""Check every published section and regional pack through the download origin."""
import argparse, concurrent.futures, hashlib, json, time, urllib.error, urllib.request
from pathlib import Path


def region_source_ids(zones, region_id):
    region = next(r for r in zones['regions'] + zones.get('parks', []) if r['id'] == region_id)
    cells = region.get('downloadCells')
    return {c['id'] for c in (region['cells'] if cells is None else cells)}


def audit(base, catalog_sha=None, source_ids=None, verify_content=False):
    base = base.rstrip('/') + '/'
    with urllib.request.urlopen(base + 'catalog.json', timeout=30) as response:
        data = response.read()
    actual_sha = hashlib.sha256(data).hexdigest()
    if catalog_sha is not None and actual_sha != catalog_sha:
        raise ValueError('Served catalog differs from publication')
    catalog = json.loads(data)
    sources = [s for s in catalog['sources'] if source_ids is None or s['id'] in source_ids]
    archives = [a for a in catalog.get('regionArchives', []) if source_ids is None or set(a['sourceIDs']) == {s['id'] for s in sources}]
    targets = [(str(Path(s['path']).parent / s['pack']['file']), s['pack']) for s in sources]
    targets += [('region-packs/' + a['asset']['file'], a['asset']) for a in archives]
    def check(target):
        path, asset = target
        for attempt in range(3):
            try:
                request = urllib.request.Request(base + path, method='GET' if verify_content else 'HEAD')
                with urllib.request.urlopen(request, timeout=30) as response:
                    if response.status != 200 or int(response.headers.get('Content-Length', -1)) != asset['byteCount']:
                        return dict(path=path, error='Pack response size differs from catalog')
                    if verify_content:
                        digest = hashlib.sha256(); count = 0
                        while chunk := response.read(1024 * 1024):
                            digest.update(chunk); count += len(chunk)
                        if count != asset['byteCount'] or digest.hexdigest() != asset['sha256']:
                            return dict(path=path, error='Downloaded pack checksum differs from catalog')
                return None
            except urllib.error.HTTPError as error:
                return dict(path=path, error='HTTP ' + str(error.code))
            except OSError as error:
                if attempt == 2:
                    return dict(path=path, error=str(error))
                time.sleep(.2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        errors = [error for error in pool.map(check, targets) if error]
    return dict(catalogSHA256=actual_sha, sections=len(sources), regionalPacks=len(archives), checked=len(targets), contentVerified=verify_content, errors=errors, passed=not errors, updated=time.time())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', default='http://127.0.0.1:8787/world/')
    p.add_argument('--catalog-sha')
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--region')
    p.add_argument('--zones', type=Path)
    p.add_argument('--verify-content', action='store_true')
    a = p.parse_args()
    if a.region and not a.zones:
        p.error('--region requires --zones')
    ids = region_source_ids(json.loads(a.zones.read_text()), a.region) if a.region else None
    result = audit(a.base, a.catalog_sha, ids, a.verify_content)
    a.report.write_text(json.dumps(result))
    print(json.dumps(result), flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__': main()
