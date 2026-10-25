#!/usr/bin/env python3
"""Package existing, verified section assets without rebuilding terrain or maps."""
import argparse, concurrent.futures, fcntl, hashlib, json, os, struct, time, zlib
from pathlib import Path

MAGIC = b'RIDGEPK1'

def raw(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()

def atomic(path, data):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_bytes(data)
    temp.replace(path)

def assets(manifest, region):
    values = [manifest['overview'], region.get('routing') or manifest['graph']]
    for tile in manifest['tiles']:
        values += [tile[k] for k in ('background', 'map', 'mesh') if k in tile]
    seen = set()
    for value in values:
        if value['sha256'] not in seen:
            seen.add(value['sha256'])
            yield value

def build(root, region, *, output_folder=None, expected_pack=None):
    folder = root / Path(region['path']).parent
    write_folder = Path(output_folder) if output_folder is not None else folder
    write_folder.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((root / region['path']).read_bytes())
    items = list(assets(manifest, region))
    if not 1 <= len(items) <= 1024 or manifest['id'] != region['id']:
        raise ValueError('Invalid section identity or asset count')
    fingerprint = hashlib.sha256(raw([(x['sha256'], x['byteCount']) for x in items])).hexdigest()
    receipt = folder / 'section-pack-v1.json'
    if receipt.exists():
        previous = json.loads(receipt.read_bytes())
        file = folder / previous['pack']['file']
        if previous['fingerprint'] == fingerprint and file.exists() and file.stat().st_size == previous['pack']['byteCount']:
            with file.open('rb') as stream:
                digest = hashlib.sha256()
                while chunk := stream.read(1024*1024):
                    digest.update(chunk)
                if digest.hexdigest() == previous['pack']['sha256']:
                    return previous['pack']
    payload = write_folder / '.section-pack-payload.tmp'
    temporary = write_folder / '.section-pack.tmp'
    try:
        entries = []
        with payload.open('wb') as output:
            for asset in items:
                name = asset.get('file', asset.get('path'))
                if Path(name).name != name:
                    raise ValueError('Unsafe asset path')
                data = (folder / name).read_bytes()
                if not 1 <= len(data) <= 64_000_000 or len(data) != asset['byteCount'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
                    raise ValueError('Damaged source asset: ' + name)
                stored = zlib.compress(data, 6) if name.endswith('.json') else data
                compressed = len(stored) < len(data)
                if not compressed:
                    stored = data
                entries.append(dict(sha256=asset['sha256'], byteCount=len(data), offset=output.tell(),
                                    storedByteCount=len(stored), compressed=compressed))
                output.write(stored)
        index = raw(dict(schemaVersion=1, sourceID=manifest['id'], entries=entries))
        if len(index) > 2_000_000:
            raise ValueError('Oversized pack index')
        digest = hashlib.sha256()
        with temporary.open('wb') as output, payload.open('rb') as source:
            header = MAGIC + struct.pack('<I', len(index)) + index
            output.write(header); digest.update(header)
            while chunk := source.read(1024*1024):
                output.write(chunk); digest.update(chunk)
        pack = dict(file='section-' + digest.hexdigest() + '.ridgepack', byteCount=temporary.stat().st_size, sha256=digest.hexdigest())
        if expected_pack is not None and pack != expected_pack:
            raise ValueError('Reconstructed pack differs from catalog: ' + region['id'])
        if pack['byteCount'] > 256*1024*1024:
            raise ValueError('Oversized section pack')
        target = write_folder / pack['file']
        temporary.replace(target)
        if write_folder.resolve() != folder.resolve():
            link = folder / (pack['file'] + '.external-link')
            link.unlink(missing_ok=True)
            link.symlink_to(target.resolve())
            link.replace(folder / pack['file'])
        atomic(receipt, raw(dict(fingerprint=fingerprint, pack=pack)))
        return pack
    finally:
        payload.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--source')
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    root = args.root
    lock = (root / '.section-pack.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    catalog = json.loads((root / 'catalog.json').read_bytes())
    selected = [s for s in catalog['sources'] if args.source is None or s['id'] == args.source]
    if not selected:
        raise ValueError('No matching source')
    started = time.time(); completed = 0; byte_count = 0; results = {}
    originals = {source['id']: {k: v for k, v in source.items() if k != 'pack'} for source in selected}

    def publish():
        # Publish only verified immutable packs; preserve concurrent metadata updates
        # on other sources and reject changes to a source we just packaged.
        current = json.loads((root / 'catalog.json').read_bytes())
        for source in current['sources']:
            if source['id'] in results:
                if {k: v for k, v in source.items() if k != 'pack'} != originals[source['id']]:
                    raise ValueError('Catalogue changed during packaging; retry')
                source['pack'] = results[source['id']]
        current['packVersion'] = 1
        before = root / 'catalog.before-section-packs.json'
        if not before.exists():
            before.write_bytes((root / 'catalog.json').read_bytes())
        atomic(root / 'catalog.json', raw(current))

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(8, args.workers))) as pool:
        jobs = {pool.submit(build, root, source): source for source in selected}
        try:
            for job in concurrent.futures.as_completed(jobs):
                source = jobs[job]; pack = job.result(); results[source['id']] = pack
                completed += 1; byte_count += pack['byteCount']
                status = dict(state='building', completed=completed, total=len(selected), bytes=byte_count, seconds=round(time.time()-started))
                atomic(root / 'section-pack-status.json', raw(status))
                if completed % 25 == 0 or completed == len(selected):
                    if args.publish:
                        publish()
                    print(json.dumps(status), flush=True)
        except BaseException as error:
            pool.shutdown(wait=False, cancel_futures=True)
            atomic(root / 'section-pack-status.json', raw(dict(state='failed', completed=completed, total=len(selected), error=str(error))))
            raise
    status['state'] = 'complete'; status['published'] = args.publish
    atomic(root / 'section-pack-status.json', raw(status))
    print(json.dumps(results) if args.source else json.dumps(status), flush=True)

if __name__ == '__main__':
    main()
