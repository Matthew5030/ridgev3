#!/usr/bin/env python3
"""Stage checksum-verified retained world archives without hanging on cloud files.

Reads original products only. A descriptor is published in the cache only after
its archive has been copied and verified. macOS may hydrate iCloud placeholders
when read; child-process deadlines bound those reads. No cloud files are evicted.
"""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

DATALESS = 0x40000000
GIB = 1024 ** 3


class SpaceReserveError(OSError):
    pass


def file_sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def copy_checked(source, destination, expected_size, expected_sha):
    """Runs in a killable child, including the potentially blocking open()."""
    source, destination = Path(source), Path(destination)
    digest = hashlib.sha256()
    size = 0
    with source.open('rb') as incoming, destination.open('wb') as outgoing:
        while True:
            block = incoming.read(1024 * 1024)
            if not block:
                break
            size += len(block)
            if size > expected_size:
                raise ValueError('Source exceeds declared byte count')
            digest.update(block)
            outgoing.write(block)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    if expected_sha != '-' and (size != expected_size or digest.hexdigest() != expected_sha):
        raise ValueError('Source checksum or byte count mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='Original mapping/build/public')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fallback', type=Path, action='append', default=[], help='Only exact descriptor hash matches are admitted')
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--descriptor-timeout', type=int, default=45)
    parser.add_argument('--archive-timeout', type=int, default=900)
    parser.add_argument('--minimum-local-free-gib', type=float, default=8)
    parser.add_argument('--minimum-output-free-gib', type=float, default=30)
    parser.add_argument('--resident-only', action='store_true')
    parser.add_argument('--tile', action='append', default=[], help='x/y, repeatable')
    parser.add_argument('--limit', type=int)
    args = parser.parse_args()
    if not 1 <= args.workers <= 4:
        parser.error('Use one to four workers')
    args.source = args.source.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    args.output = args.output.resolve()
    if args.source == args.output:
        parser.error('Output must differ from source')
    lock = (args.output / '.stage.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    identity = {'source': str(args.source), 'schemaVersion': 1}
    identity_file = args.output / 'inputs.json'
    if identity_file.exists() and json.loads(identity_file.read_text()) != identity:
        raise ValueError('Changed source root: use a new output')
    atomic_json(identity_file, identity)
    descriptors = list((args.source / 'tiles/10').glob('*/*/descriptor.json'))
    if args.tile:
        wanted = set(args.tile)
        descriptors = [p for p in descriptors if f'{p.parent.parent.name}/{p.parent.name}' in wanted]
    # Do useful, already-resident work first; no source bytes are read here.
    def priority(path):
        archives = list(path.parent.glob('*.ridgetile'))
        resident = any(not p.stat().st_flags & DATALESS for p in archives)
        return (not resident, bool(path.stat().st_flags & DATALESS), str(path))
    descriptors.sort(key=priority)
    if args.limit:
        descriptors = descriptors[:args.limit]
    state_path = args.output / 'status.json'
    previous = json.loads(state_path.read_text()).get('tiles', {}) if state_path.exists() else {}
    state = {'schemaVersion': 1, 'source': str(args.source), 'pid': os.getpid(),
             'running': True, 'requested': len(descriptors), 'tiles': previous}
    mutex = threading.Lock()
    space_blocked = threading.Event()

    def save():
        state['updatedAt'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        state['ready'] = sum(x['status'] == 'ready' for x in state['tiles'].values())
        atomic_json(state_path, state)

    def copy(source, destination, size, digest, timeout):
        try:
            subprocess.run([sys.executable, __file__, '--copy-one', str(source),
                            str(destination), str(size), digest], timeout=timeout,
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except subprocess.TimeoutExpired as error:
            destination.unlink(missing_ok=True)
            raise TimeoutError(f'Cloud/file read exceeded {timeout}s: {source}') from error
        except BaseException:
            destination.unlink(missing_ok=True)
            raise

    def stage(descriptor):
        ident = f'z10-x{descriptor.parent.parent.name}-y{descriptor.parent.name}'
        target = args.output / descriptor.relative_to(args.source)
        target.parent.mkdir(parents=True, exist_ok=True)
        metadata_temp = target.with_suffix('.incoming')
        started = time.monotonic()
        try:
            old = previous.get(ident, {})
            if old.get('status') == 'ready' and target.exists():
                saved = json.loads(target.read_text())
                archive = args.output / saved['archiveURL'].lstrip('/')
                if (archive.exists() and archive.stat().st_size == saved['archiveSizeBytes']
                        and file_sha(archive) == saved['archiveSHA256']):
                    return ident, old
            if space_blocked.is_set():
                return ident, {'status': 'blocked', 'reason': 'Free-space reserve reached earlier in this run'}
            if args.resident_only and descriptor.stat().st_flags & DATALESS:
                return ident, {'status': 'deferred', 'reason': 'Descriptor is an iCloud placeholder'}
            if shutil.disk_usage(args.source).free < args.minimum_local_free_gib * GIB:
                raise SpaceReserveError('Local free-space reserve reached; retained cloud sources were not evicted')
            copy(descriptor, metadata_temp, 1024 * 1024, '-', args.descriptor_timeout)
            data = json.loads(metadata_temp.read_text())
            relative = Path(data['archiveURL'].lstrip('/'))
            if relative.is_absolute() or '..' in relative.parts or relative.suffix != '.ridgetile':
                raise ValueError('Unsafe archive path')
            if data['tileID'] != ident:
                raise ValueError('Descriptor grid identity mismatch')
            size = int(data['archiveSizeBytes'])
            destination = args.output / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if shutil.disk_usage(args.output).free < args.minimum_output_free_gib * GIB + size * args.workers:
                raise SpaceReserveError('Output free-space reserve reached')
            candidates = [root / relative for root in args.fallback]
            candidates = [p for p in candidates if p.exists() and not p.stat().st_flags & DATALESS]
            primary = args.source / relative
            if (primary.stat().st_flags & DATALESS and not args.resident_only
                    and shutil.disk_usage(args.source).free < args.minimum_local_free_gib * GIB + size * args.workers):
                raise SpaceReserveError('Local free-space reserve cannot admit another cloud archive')
            if not args.resident_only or not primary.stat().st_flags & DATALESS:
                candidates.append(primary)
            if not candidates:
                return ident, {'status': 'deferred', 'reason': 'Archive is an iCloud placeholder'}
            temporary = destination.with_suffix('.incoming')
            last_error = None
            for candidate in candidates:
                try:
                    copy(candidate, temporary, size, data['archiveSHA256'], args.archive_timeout)
                    temporary.replace(destination)
                    metadata_temp.replace(target)
                    return ident, {'status': 'ready', 'archiveBytes': size,
                                   'archiveSHA256': data['archiveSHA256'], 'input': str(candidate),
                                   'seconds': round(time.monotonic() - started, 2)}
                except Exception as error:
                    last_error = error
            raise last_error
        except SpaceReserveError as error:
            space_blocked.set()
            return ident, {'status': 'blocked', 'reason': str(error)}
        except Exception as error:
            return ident, {'status': 'failed', 'reason': str(error),
                           'seconds': round(time.monotonic() - started, 2)}
        finally:
            metadata_temp.unlink(missing_ok=True)

    save()
    try:
        with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
            futures = [pool.submit(stage, descriptor) for descriptor in descriptors]
            for future in concurrent.futures.as_completed(futures):
                ident, result = future.result()
                with mutex:
                    state['tiles'][ident] = result
                    save()
                print(ident, result['status'], result.get('reason', ''), flush=True)
    finally:
        state['running'] = False
        state['complete'] = all(state['tiles'].get(f'z10-x{p.parent.parent.name}-y{p.parent.name}', {}).get('status') == 'ready' for p in descriptors)
        save()
    print(json.dumps({k: v for k, v in state.items() if k != 'tiles'}), flush=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--copy-one':
        copy_checked(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5])
    else:
        main()
