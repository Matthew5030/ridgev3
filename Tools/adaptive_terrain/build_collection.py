#!/usr/bin/env python3
"""Plan or build all parks in an existing boundary collection, with bounded jobs."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--boundaries', type=Path, required=True)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--fallback', type=Path)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--downloads', type=Path, required=True)
p.add_argument('--compiler', type=Path, required=True)
p.add_argument('--jobs', type=int, default=2)
p.add_argument('--workers', type=int, default=3)
p.add_argument('--plan-only', action='store_true')
p.add_argument('--work-directory', type=Path, help='Optional local scratch; verified compressed files remain on the download drive')
p.add_argument('--exclude', nargs='*', default=[])
a = p.parse_args()
if not 1 <= a.jobs <= 4 or not 1 <= a.workers <= 8:
    p.error('Use 1–4 park jobs and 1–8 workers per park')
a.output.mkdir(parents=True, exist_ok=True)
HERE = Path(__file__).resolve().parent
features = json.loads(a.boundaries.read_text())['features']
status_path = a.output / ('collection-plan.json' if a.plan_only else 'collection-status.json')
results = {}
started = time.time()


def save():
    temporary = status_path.with_suffix('.next.json')
    temporary.write_text(json.dumps(dict(boundaryCollectionSHA256=hashlib.sha256(a.boundaries.read_bytes()).hexdigest(),
        elapsedSeconds=round(time.time()-started, 1), parks=results), indent=2))
    temporary.replace(status_path)


def command(script, arguments, log):
    with log.open('w') as stream:
        subprocess.run([sys.executable, str(HERE / script), *map(str, arguments)],
                       stdout=stream, stderr=subprocess.STDOUT, check=True)


def build(feature):
    key = feature['properties']['collectionID'].removeprefix('national-park-')
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', key):
        raise ValueError('Unsafe park identifier')
    archive = a.output / f'{key}-adaptive-0p5'
    archive.mkdir(exist_ok=True)
    out = (a.work_directory / f'{key}-adaptive-0p5') if a.work_directory and not a.plan_only and key not in a.exclude else archive
    out.mkdir(parents=True,exist_ok=True)
    boundary = out / 'input-boundary.geojson'
    boundary.write_text(json.dumps(feature))
    args = ['--source', a.source, '--boundary', boundary, '--output', out,
            '--compiler', a.compiler, '--workers', a.workers]
    if a.fallback:
        args += ['--fallback', a.fallback]
    command('build_park.py', [*args, '--plan-only'], out / 'plan.log')
    plan = json.loads((out / 'plan.json').read_text())
    result = dict(name=feature['properties']['displayName'], chunks=plan['chunkCount'],
                  coveragePercent=100*(1-plan['uncoveredParkAreaKm2']/plan['parkAreaKm2']),
                  missingKm2=plan['uncoveredParkAreaKm2'], parkAreaKm2=plan['parkAreaKm2'])
    if not plan['chunkCount']:
        return key, dict(**result, status='unavailable', reason='No prepared 1 m source chunks')
    if a.plan_only:
        return key, dict(**result, status='ready-to-build')
    if key in a.exclude:
        return key, dict(**result, status='building-in-existing-job')
    manifest_path = out / 'manifest.json'
    if manifest_path.exists():
        old = json.loads(manifest_path.read_text())
        old_selection=old.get('sourceSelectionSHA256') or hashlib.sha256(json.dumps([{k:c[k] for k in ['id','bounds','sourceSHA256']} for c in sorted(old['chunks'],key=lambda c:c['id'])],sort_keys=True).encode()).hexdigest()
        if old['boundarySHA256'] != plan['boundarySHA256'] or old['compilerSHA256'] != plan['compilerSHA256'] or old_selection != plan['sourceSelectionSHA256']:
            raise ValueError(f'Changed inputs for existing build {key}; use a new output directory')
    else:
        command('build_park.py', args, out / 'build.log')
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    validation_path = out / 'validation.json'
    if not validation_path.exists() or json.loads(validation_path.read_text()).get('manifestSHA256') != manifest_hash:
        command('verify_park.py', [out], out / 'verify.log')
    command('publish_adaptive.py', [out, a.downloads, '--workers', a.workers], out / 'publish.log')
    published = a.downloads / plan['id']
    command('report_park.py', [out, '--published', published], out / 'report.log')
    index = json.loads((published / 'adaptive.json').read_text())
    if out != archive:
        for filename in ['manifest.json','validation.json','REPORT.md','coverage.png',
                         'boundary.geojson','coverage-gaps.geojson','plan.json',
                         'input-boundary.geojson','build.log','verify.log','publish.log','report.log']:
            path=out/filename
            if path.exists():shutil.copyfile(path,archive/filename)
        # The verified compressed chunks are the durable geometry. Remove only
        # this run's scratch cache after its index and audit records are saved.
        if hashlib.sha256((archive/'manifest.json').read_bytes()).hexdigest()!=index['sourceManifestSHA256']:
            raise ValueError('Archived manifest does not match published source')
        shutil.rmtree(out/'meshes',ignore_errors=True)
    return key, dict(**result, status='published', downloadBytes=index['byteCount'],
                     triangles=index['triangles'], sourceBytes=index['sourceByteCount'],
                     sourceZlibBytes=index['sourceZlibBytes'],
                     triangleReductionPercent=100*(1-index['triangles']/index['nativeGridTriangles']))


with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
    pending = {pool.submit(build, feature): feature for feature in features}
    for future in concurrent.futures.as_completed(pending):
        feature = pending[future]
        key = feature['properties']['collectionID'].removeprefix('national-park-')
        try:
            key, result = future.result()
        except Exception as error:
            result = dict(name=feature['properties']['displayName'], status='failed', error=str(error))
        results[key] = result
        save()
        print(json.dumps(dict(park=key, **result)), flush=True)
if any(r['status'] == 'failed' for r in results.values()):
    raise SystemExit(1)
