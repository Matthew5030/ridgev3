#!/usr/bin/env python3
"""Publish verified adaptive terrain as independently downloadable zlib chunks.
The adaptive catalogue is separate from the normal app catalogue until the app
supports this codec. Existing published revisions are immutable.
"""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
from pathlib import Path
import re
import struct
import time
import zlib
from mesh_io import MeshReader
from compact_codec import CompactCodec


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic_json(path, value):
    temporary = path.with_suffix('.next.json')
    temporary.write_text(json.dumps(value, separators=(',', ':')) + '\n')
    temporary.replace(path)


def publish_catalog(directory):
    # Different parks can publish concurrently; serialize catalogue replacement.
    with (directory / '.adaptive-catalog.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # One catalogue choice per landscape. Older immutable URLs remain
        # valid after a smaller topology variant has been published.
        preferred={}
        publications=[]
        for path in sorted(directory.glob('*/adaptive.json')):
            raw=path.read_bytes();publications.append((raw,json.loads(raw)))
        superseded={old for _,m in publications for old in m.get('supersedes',[])}
        for raw,m in publications:
            if m['id'] in superseded:continue
            key=m.get('geometrySourceID',m['id'])
            if key not in preferred or m['requiredReader']=='rat1-zlib-v1':preferred[key]=(raw,m)
        entries=[]
        for raw,m in sorted(preferred.values(),key=lambda item:item[1]['name']):
            entries.append(dict(id=m['id'], name=m['name'], byteCount=len(raw),
                                sha256=digest(raw), meshBytes=m['byteCount'],
                                requiredReader=m['requiredReader'], bounds=m['bounds'],
                                chunks=len(m['chunks']), surfaceToleranceMetres=m['surfaceToleranceMetres'],
                                coveragePercent=max(0,100*(1-m['uncoveredParkAreaKm2']/m['parkAreaKm2']))))
        atomic_json(directory / 'adaptive-catalog.json', dict(schemaVersion=1, sources=entries))


def publish(root, directory, workers=4, mesh_package=None, codec="rme1", packed=False, update_catalog=True):
    if codec not in ("rme1","rat1"):raise ValueError("Unsupported codec")
    if packed and codec != "rat1":raise ValueError("Packed downloads require RAT1")
    raw_manifest = (root / 'manifest.json').read_bytes()
    manifest = json.loads(raw_manifest)
    validation = json.loads((root / 'validation.json').read_text())
    if validation.get('manifestSHA256') != digest(raw_manifest):
        raise ValueError('Validation does not match this manifest')
    if validation['maxSeamHeightDifferenceMetres'] != 0 or not validation['independentSamples']:
        raise ValueError('Independent validation must pass before publication')
    if manifest['maximumMeasuredErrorMetres'] > manifest['surfaceToleranceMetres'] + 1e-6:
        raise ValueError('Surface error exceeds declared tolerance')
    identifier = manifest['id']
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', identifier):
        raise ValueError('Unsafe source identifier')
    out = directory / identifier
    out.mkdir(parents=True, exist_ok=True)
    with (out / '.publish.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fingerprint = digest(raw_manifest)
        published = out / 'adaptive.json'
        if published.exists():
            if json.loads(published.read_text())['sourceManifestSHA256'] != fingerprint:
                raise ValueError('Published source is immutable: use a new source ID')
            print('Already published:', identifier, flush=True)
            if update_catalog:publish_catalog(directory)
            return
        reader=MeshReader(root,manifest['chunks'],mesh_package)
        compact_codec=CompactCodec() if codec=='rat1' else None
        started = time.monotonic()
        source_manifests = {}
        for chunk in manifest['chunks']:
            path = Path(chunk['source']).parents[4] / 'manifest.json'
            if path in source_manifests:
                continue
            raw = path.read_bytes()
            source = json.loads(raw)
            complete = path.with_name('COMPLETE.json')
            if complete.exists():
                expected = json.loads(complete.read_text()).get('manifestSHA256')
                if expected and expected != digest(raw):
                    raise ValueError(f'Source manifest checksum: {path}')
            source_manifests[path] = dict(tileID=source['tileID'],
                productID=source['productID'], productVersion=source['productVersion'],
                manifestSHA256=digest(raw), source=source['source'])

        def encode(chunk):
            chunk_id = chunk['id']
            if not re.fullmatch(r'[a-zA-Z0-9_-]+', chunk_id):
                raise ValueError('Unsafe chunk identifier')
            raw = reader.read(chunk)
            if len(raw) != chunk['compactBytes'] or digest(raw) != chunk['sha256']:
                raise ValueError(f'Mesh checksum: {chunk_id}')
            magic, vertices, triangles, index_width, grid, scale, offset = struct.unpack('<4s4I2f', raw[:28])
            if (magic, grid, vertices, triangles, index_width) != (
                    b'RME1', 513, chunk['vertices'], chunk['triangles'], chunk['indexWidth']):
                raise ValueError(f'Mesh header: {chunk_id}')
            if len(raw) != 28 + vertices * 6 + triangles * 3 * index_width:
                raise ValueError(f'Mesh layout: {chunk_id}')
            payload=compact_codec.encode(raw) if compact_codec else raw
            compressed = zlib.compress(payload, level=6)
            if zlib.decompress(compressed) != payload:
                raise ValueError('Compression round-trip failed')
            filename = f"mesh-{chunk_id}.{'rat' if compact_codec else 'rmesh'}.zlib"
            if packed:
                filename='terrain.ratpack'
            else:
                target = out / filename
                if not target.exists() or digest(target.read_bytes()) != digest(compressed):
                    temporary = target.with_suffix('.tmp')
                    temporary.write_bytes(compressed)
                    temporary.replace(target)
            # Measure an equally compressed original heightfield, not just an
            # uncompressed baseline. Do not publish duplicate source files.
            source_bytes = chunk['sourceByteCount']
            # New builds measure this while the SHA-verified input is already
            # in memory. Older builds need one source read for the comparison.
            if chunk.get('sourceZlibLevel') == 6 and isinstance(chunk.get('sourceZlibBytes'), int):
                source_zlib_bytes = chunk['sourceZlibBytes']
                if not 0 < source_zlib_bytes <= source_bytes * 2:
                    raise ValueError('Invalid recorded source compression size')
            else:
                source = Path(chunk['source']).read_bytes()
                if len(source) != source_bytes or digest(source) != chunk['sourceSHA256']:
                    raise ValueError(f'Source checksum: {chunk_id}')
                source_zlib_bytes = len(zlib.compress(source, level=6))
            entry=dict(id=chunk_id, bounds=chunk['bounds'], path=filename,
                        byteCount=len(compressed), sha256=digest(compressed),
                        decodedByteCount=len(raw), decodedSHA256=chunk['sha256'],
                        vertices=vertices, triangles=triangles, indexWidth=index_width,
                        packedGeometryBytes=vertices * 6 + triangles * 3 * index_width,
                        expandedGeometryBytes=chunk['metalGeometryBytes'],
                        maxErrorMetres=chunk['maxErrorMetres'],
                        sourceSHA256=chunk['sourceSHA256'],
                        sourceByteCount=source_bytes,
                        sourceZlibBytes=source_zlib_bytes)
            if compact_codec:entry.update(topologyByteCount=len(payload),topologySHA256=digest(payload))
            return (entry,compressed) if packed else entry

        chunks = []
        pack_path=out/'terrain.ratpack'
        pack_tmp=out/'terrain.ratpack.tmp'
        pack_hash=hashlib.sha256()
        pack_stream=pack_tmp.open('wb') if packed else None
        try:
            with concurrent.futures.ThreadPoolExecutor(workers) as pool:
                # Bounded batches prevent a slow disk from retaining an entire
                # partition's compressed output while later workers finish.
                for start in range(0,len(manifest['chunks']),64):
                    for item in pool.map(encode,manifest['chunks'][start:start+64]):
                        if packed:
                            c,data=item;c['byteOffset']=pack_stream.tell()
                            pack_stream.write(data);pack_hash.update(data)
                        else:c=item
                        chunks.append(c)
                        if len(chunks)%500==0:
                            print(f'{identifier}: compressed {len(chunks)}/{len(manifest["chunks"])}',flush=True)
        finally:
            if pack_stream:pack_stream.close()
        if packed:pack_tmp.replace(pack_path)
        assets = {}
        for name in ['boundary.geojson', 'coverage-gaps.geojson']:
            data = (root / name).read_bytes()
            (out / name).write_bytes(data)
            assets[name] = dict(byteCount=len(data), sha256=digest(data))
        park_name=manifest.get('parkName') or json.loads((root/'boundary.geojson').read_text()).get('properties',{}).get('displayName')
        display_name=f'{park_name} · adaptive 0.5 m' if park_name else manifest['name']
        result = dict(schemaVersion=1, id=identifier, name=display_name,
                      contentKind='adaptive-terrain', requiredReader=f'{codec}-zlib-range-v1' if packed else f'{codec}-zlib-v1',
                      storage=f'concatenated-zlib-{codec}' if packed else f'independent-zlib-{codec}', meshFormat='RME1',
                      geometrySourceID=manifest['id'],
                      payloadFormat='RAT1' if compact_codec else 'RME1',
                      surfaceToleranceMetres=manifest['surfaceToleranceMetres'],
                      sourceSpacingMetres=1, nativeGridSize=513,
                      sourceManifestSHA256=fingerprint,
                      compilerSHA256=manifest['compilerSHA256'],
                      bounds=manifest['bounds'], parkAreaKm2=manifest['parkAreaKm2'],
                      uncoveredParkAreaKm2=manifest['uncoveredParkAreaKm2'],
                      coveragePolicy=manifest['coveragePolicy'], assets=assets,
                      sourceManifests=list(source_manifests.values()),
                      validation=dict(sharedEdgesChecked=validation['sharedEdgesChecked'],
                                      maxSeamHeightDifferenceMetres=0,
                                      independentChunkCount=len(validation['independentSamples']),
                                      maximumMeasuredErrorMetres=manifest['maximumMeasuredErrorMetres']),
                      chunks=chunks)
        if manifest.get('supersedes'):
            if not all(isinstance(old,str) and old!=identifier for old in manifest['supersedes']):raise ValueError('Invalid superseded source ID')
            result['supersedes']=manifest['supersedes']
        for key in ['byteCount', 'decodedByteCount', 'packedGeometryBytes',
                    'expandedGeometryBytes', 'vertices', 'triangles', 'sourceByteCount', 'sourceZlibBytes']:
            result[key] = sum(c[key] for c in chunks)
        if compact_codec:
            result['topologyByteCount']=sum(c['topologyByteCount'] for c in chunks)
            result['encoderSourceSHA256']=digest(Path(__file__).with_name('compact_mesh.cpp').read_bytes())
        if packed:result['container']=dict(path='terrain.ratpack',byteCount=pack_path.stat().st_size,sha256=pack_hash.hexdigest())
        result['nativeGridTriangles'] = len(chunks) * 512 * 512 * 2
        result['publishSeconds'] = round(time.monotonic() - started, 3)
        atomic_json(published, result)
        print(json.dumps({k: v for k, v in result.items() if k not in ['chunks', 'assets', 'sourceManifests']}), flush=True)
    if update_catalog:publish_catalog(directory)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--workers', type=int, default=4)
    parser.add_argument('--mesh-package', type=Path)
    parser.add_argument('--codec',choices=['rme1','rat1'],default='rat1')
    parser.add_argument('--pack',action='store_true',help='One range-addressable RAT1 container per partition')
    parser.add_argument('--no-catalog',action='store_true',help='Let a collection runner publish its bounded catalogue')
    args = parser.parse_args()
    if not 1 <= args.workers <= 16:
        parser.error('--workers must be between 1 and 16')
    publish(args.source, args.directory, args.workers, args.mesh_package, args.codec,args.pack,not args.no_catalog)
