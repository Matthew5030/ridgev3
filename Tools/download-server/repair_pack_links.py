#!/usr/bin/env python3
"""Restore unavailable section packs from cached assets, preserving catalog hashes."""
import argparse, concurrent.futures, fcntl, hashlib, json, os, shutil, sys, tempfile, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'world_source'))
from pack_sections import assets, build
from audit_origin import region_source_ids


def available(path, asset):
    try:
        return path.is_file() and path.stat().st_size == asset['byteCount']
    except OSError:
        return False


def restore(world, region, storage):
    """Repackage checked source assets; install only the published exact hash."""
    folder = world / Path(region['path']).parent
    expected = region['pack']
    destination = folder / expected['file']
    if available(destination, expected):
        return dict(source=region['id'], state='available')
    storage.mkdir(parents=True, exist_ok=True)
    output = storage / region['id']
    actual = build(world, region, output_folder=output, expected_pack=expected)
    return dict(source=region['id'], state='restored', path=str((output / actual['file']).resolve(strict=True)), **actual)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--world', type=Path, required=True)
    p.add_argument('--storage', type=Path, action='append', required=True)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--zones', type=Path)
    p.add_argument('--priority', default='park-eryri')
    p.add_argument('--workers', type=int, default=4)
    a = p.parse_args()
    a.report.mkdir(parents=True, exist_ok=True)
    for path in a.storage:
        path.mkdir(parents=True, exist_ok=True)
    catalog_data = (a.world / 'catalog.json').read_bytes()
    catalog_sha = hashlib.sha256(catalog_data).hexdigest()
    catalog = json.loads(catalog_data)
    priority = set()
    if a.zones:
        zones = json.loads(a.zones.read_bytes())
        priority=region_source_ids(zones,a.priority)
    pending = [s for s in catalog['sources'] if not available(a.world / Path(s['path']).parent / s['pack']['file'], s['pack'])]
    pending.sort(key=lambda s: (s['id'] not in priority, s['id']))
    total = len(pending)
    print(json.dumps(dict(event='repair-start', packs=total, bytes=sum(s['pack']['byteCount'] for s in pending), priorityPacks=sum(s['id'] in priority for s in pending))), flush=True)
    reservation_lock = threading.Lock()
    reservations = {path: 0 for path in a.storage}
    reserve = 2 * 1024**3
    def run(region):
        need = region['pack']['byteCount'] * 3 + 32 * 1024**2
        with reservation_lock:
            storage = max(a.storage, key=lambda x: shutil.disk_usage(x).free - reservations[x])
            if shutil.disk_usage(storage).free - reservations[storage] < reserve + need:
                raise RuntimeError('Insufficient reserved space to repair ' + region['id'])
            reservations[storage] += need
        try:
            return restore(a.world, region, storage)
        finally:
            with reservation_lock:
                reservations[storage] -= need
    completed = 0
    failures = {}
    started = time.time()
    locks = []
    try:
        for name in ['.batch.lock', '.section-pack.lock']:
            lock = (a.world / name).open('a')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locks.append(lock)
        with (a.report / 'restored.jsonl').open('a') as journal, concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:
            jobs = {pool.submit(run, s): s for s in pending}
            for job in concurrent.futures.as_completed(jobs):
                region = jobs[job]
                try:
                    result = job.result()
                    journal.write(json.dumps(result) + '\n'); journal.flush()
                except Exception as error:
                    failures[region['id']] = str(error)
                completed += 1
                status = dict(completed=completed, total=total, failures=failures, seconds=round(time.time()-started), catalogSHA256=catalog_sha)
                temporary = a.report / 'status.tmp'
                temporary.write_text(json.dumps(status)); temporary.replace(a.report / 'status.json')
                if region['id'] in priority or completed % 25 == 0:
                    print(json.dumps(dict(source=region['id'], **status)), flush=True)
        if (a.world / 'catalog.json').read_bytes() != catalog_data:
            raise RuntimeError('Catalog changed during repair')
        if failures:
            raise RuntimeError('Some section repairs failed; inspect status.json')
        print('ALL MISSING SECTION PACKS RESTORED', completed, flush=True)
    finally:
        for lock in reversed(locks):
            lock.close()


if __name__ == '__main__':
    main()
