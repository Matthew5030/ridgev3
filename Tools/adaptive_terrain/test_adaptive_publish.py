#!/usr/bin/env python3
"""Exercise the real compiler, independent verifier and compressed publisher."""
import contextlib
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from compact_codec import CompactCodec
from repack_adaptive import repack

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('publisher', HERE / 'publish_adaptive.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class AdaptivePublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='ridge-adaptive-test-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / 'build'
        self.root.mkdir()
        self.out = self.directory / 'downloads'
        source_y = math.floor((1-math.asinh(math.tan(math.radians(53.001)))/math.pi)/2*1024)
        source_dir = self.directory / f'source/tiles/10/506/{source_y}'
        self.source = source_dir / 'parents/c00-00/precision/p00-00/lod-1m.bin'
        self.source.parent.mkdir(parents=True)
        # A sloped plane has exact source heights but should simplify heavily.
        raw = b''.join(struct.pack('<h', 100 + x + y) for y in range(513) for x in range(513))
        self.source.write_bytes(raw)
        (source_dir / 'manifest.json').write_text(json.dumps(dict(
            tileID='synthetic-tile', productID='synthetic', productVersion='1',
            source=dict(name='Synthetic plane, not survey data', license='Test fixture'))))
        mesh = self.root / 'fixture.rmesh'
        self.compiler = os.environ.get('RIDGE_PARK_COMPILER', '/tmp/ridge-park-mesh')
        stats = json.loads(subprocess.check_output([self.compiler, str(self.source), str(mesh)]))
        bounds = dict(minLongitude=-2, maxLongitude=-1.999, minLatitude=53, maxLatitude=53.001)
        chunk = dict(id='fixture', bounds=bounds, path=mesh.name, source=str(self.source),
                     sourceByteCount=len(raw), sourceSHA256=publisher.digest(raw),
                     sha256=publisher.digest(mesh.read_bytes()), **stats)
        self.manifest = dict(schemaVersion=1, id='test-park-adaptive-0p5', name='Synthetic test park',
            surfaceToleranceMetres=.5, maximumMeasuredErrorMetres=stats['maxErrorMetres'],
            compilerSHA256=publisher.digest(Path(self.compiler).read_bytes()),
            parkAreaKm2=.01, uncoveredParkAreaKm2=0, coveragePolicy='Synthetic fixture',
            bounds=bounds, chunks=[chunk])
        self.write_manifest()
        polygon = {'type':'Feature', 'properties':{}, 'geometry':{'type':'Polygon',
            'coordinates':[[[-2,53],[-1.999,53],[-1.999,53.001],[-2,53.001],[-2,53]]]}}
        (self.root / 'boundary.geojson').write_text(json.dumps(polygon))
        (self.root / 'coverage-gaps.geojson').write_text(json.dumps(
            {'type':'Feature','properties':{},'geometry':{'type':'MultiPolygon','coordinates':[]}}))
        subprocess.run([sys.executable, str(HERE / 'verify_park.py'), str(self.root)],
                       check=True, stdout=subprocess.DEVNULL)

    def write_manifest(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def publish(self, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            publisher.publish(self.root, self.out, 1, **kwargs)
        return self.out / self.manifest['id']

    def test_real_compiler_roundtrip_and_catalogue(self):
        out = self.publish()
        m = json.loads((out / 'adaptive.json').read_text())
        c = m['chunks'][0]
        compressed = (out / c['path']).read_bytes()
        decoded = zlib.decompress(compressed)
        self.assertEqual(decoded, (self.root / 'fixture.rmesh').read_bytes())
        self.assertEqual(publisher.digest(compressed), c['sha256'])
        self.assertEqual(len(decoded), c['decodedByteCount'])
        self.assertLess(m['triangles'], m['nativeGridTriangles'] / 20)
        self.assertEqual(m['validation']['maximumMeasuredErrorMetres'], 0)
        self.assertEqual(m['sourceManifests'][0]['source']['license'], 'Test fixture')
        self.assertNotIn(str(self.directory), (out / 'adaptive.json').read_text())
        catalog = json.loads((self.out / 'adaptive-catalog.json').read_text())
        self.assertEqual(catalog['sources'][0]['sha256'], publisher.digest((out / 'adaptive.json').read_bytes()))
        self.assertFalse((self.out / 'catalog.json').exists())
        (self.root/'fixture.rmesh').unlink()
        subprocess.run([sys.executable,str(HERE/'verify_park.py'),str(self.root),
                        '--published',str(out)],check=True,stdout=subprocess.DEVNULL)

    def test_repeat_publish_recovers_missing_catalogue(self):
        out = self.publish()
        before = (out / 'adaptive.json').read_bytes()
        (self.out / 'adaptive-catalog.json').unlink()
        self.publish()
        self.assertEqual((out / 'adaptive.json').read_bytes(), before)
        self.assertTrue((self.out / 'adaptive-catalog.json').exists())

    def test_corrupt_mesh_is_not_published(self):
        (self.root / 'fixture.rmesh').write_bytes(b'damaged')
        with self.assertRaisesRegex(ValueError, 'Mesh checksum'):
            self.publish()
        self.assertFalse((self.out / self.manifest['id'] / 'adaptive.json').exists())

    def test_corrupt_source_is_not_published(self):
        self.source.write_bytes(b'damaged')
        with self.assertRaisesRegex(ValueError, 'Source checksum'):
            self.publish()
        self.assertFalse((self.out / self.manifest['id'] / 'adaptive.json').exists())

    def test_validation_must_match_manifest(self):
        self.manifest['name'] = 'Changed manifest'
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'Validation does not match'):
            self.publish()

    def test_published_revision_is_immutable(self):
        self.publish()
        self.manifest['name'] = 'Changed source'
        self.write_manifest()
        validation = json.loads((self.root / 'validation.json').read_text())
        validation['manifestSHA256'] = publisher.digest((self.root / 'manifest.json').read_bytes())
        (self.root / 'validation.json').write_text(json.dumps(validation))
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.publish()

    def test_existing_mesh_package_is_reused(self):
        package=self.directory/'existing-package';package.mkdir()
        raw=(self.root/'fixture.rmesh').read_bytes()
        c=dict(self.manifest['chunks'][0],path='terrain.rmeshpack',byteOffset=16)
        (package/'terrain.rmeshpack').write_bytes(b'padding-for-test'+raw)
        (package/'manifest.json').write_text(json.dumps(dict(storage='concatenated-rme1',chunks=[c])))
        (self.root/'fixture.rmesh').unlink()
        subprocess.run([sys.executable,str(HERE/'verify_park.py'),str(self.root),
                        '--mesh-package',str(package)],check=True,stdout=subprocess.DEVNULL)
        out=self.publish(mesh_package=package)
        index=json.loads((out/'adaptive.json').read_text())
        self.assertEqual(zlib.decompress((out/index['chunks'][0]['path']).read_bytes()),raw)

    def test_compact_topology_publication(self):
        raw=(self.root/'fixture.rmesh').read_bytes()
        out=self.publish(codec='rat1')
        m=json.loads((out/'adaptive.json').read_text());c=m['chunks'][0]
        payload=zlib.decompress((out/c['path']).read_bytes())
        self.assertEqual(m['requiredReader'],'rat1-zlib-v1')
        self.assertEqual(payload[:4],b'RAT1')
        self.assertEqual(len(payload),c['topologyByteCount'])
        self.assertEqual(CompactCodec().decode(payload),raw)
        (self.root/'fixture.rmesh').unlink()
        subprocess.run([sys.executable,str(HERE/'verify_park.py'),str(self.root),
                        '--published',str(out)],check=True,stdout=subprocess.DEVNULL)

    def test_compact_codec_full_native_mesh(self):
        raw=b''.join(struct.pack('<h',100+10*((x+y)%2)) for y in range(513) for x in range(513))
        self.source.write_bytes(raw)
        target=self.root/'dense.rmesh'
        subprocess.run([self.compiler,str(self.source),str(target)],check=True,stdout=subprocess.DEVNULL)
        original=target.read_bytes();codec=CompactCodec()
        self.assertEqual(struct.unpack_from('<I',original,12)[0],4)
        payload=codec.encode(original)
        self.assertEqual(codec.decode(payload),original)
        self.assertLess(len(payload),len(original)/5)

    def test_compact_codec_rejects_invalid_input(self):
        codec=CompactCodec();raw=(self.root/'fixture.rmesh').read_bytes()
        payload=codec.encode(raw)
        with self.assertRaises(ValueError):codec.decode(payload[:-1])
        damaged=bytearray(payload);struct.pack_into('<I',damaged,4,0xffffffff)
        with self.assertRaises(ValueError):codec.decode(bytes(damaged))
        with self.assertRaises(ValueError):codec.encode(b'invalid')

    def test_compact_codec_refuses_noncanonical_triangle_order(self):
        raw=bytearray((self.root/'fixture.rmesh').read_bytes())
        nv=struct.unpack_from('<I',raw,4)[0];width=struct.unpack_from('<I',raw,12)[0]
        start=28+nv*6;size=width*3
        first=bytes(raw[start:start+size]);second=bytes(raw[start+size:start+size*2])
        raw[start:start+size]=second;raw[start+size:start+size*2]=first
        with self.assertRaisesRegex(ValueError,'canonical'):CompactCodec().encode(bytes(raw))

    def test_repack_keeps_old_source_and_one_catalogue_choice(self):
        old=self.publish();before=(old/'adaptive.json').read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):new=repack(old,self.out,1)
        self.assertEqual((old/'adaptive.json').read_bytes(),before)
        catalog=json.loads((self.out/'adaptive-catalog.json').read_text())
        self.assertEqual(len(catalog['sources']),1)
        self.assertEqual(catalog['sources'][0]['id'],new.name)
        self.assertEqual(catalog['sources'][0]['requiredReader'],'rat1-zlib-v1')
        m=json.loads((new/'adaptive.json').read_text());c=m['chunks'][0]
        self.assertEqual(CompactCodec().decode(zlib.decompress((new/c['path']).read_bytes())),
                         (self.root/'fixture.rmesh').read_bytes())

    def test_generic_builder_recovers_interrupted_cache(self):
        c = self.manifest['chunks'][0]
        source_manifest = self.source.parents[4] / 'manifest.json'
        m = json.loads(source_manifest.read_text())
        level = dict(nominalSpacingMetres=1, path='precision/p00-00/lod-1m.bin',
            sha256=c['sourceSHA256'], byteCount=c['sourceByteCount'],
            terrain=dict(width=513,height=513,scaleMetres=.1,sampleFormat='int16',byteOrder='little-endian'))
        m.update(bounds=c['bounds'], parents=[dict(id='c00-00',status='available',bounds=c['bounds'],
            precisionChildren=[dict(id='p00-00',bounds=c['bounds'],lods=[level])])])
        source_manifest.write_text(json.dumps(m))
        compiled = self.directory / 'compiled'
        args = [sys.executable,str(HERE/'build_park.py'),'--source',str(self.directory/'source'),
            '--boundary',str(self.root/'boundary.geojson'),'--output',str(compiled),
            '--compiler',self.compiler,'--workers','1','--id','fixture','--name','Fixture park']
        subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
        result = json.loads((compiled/'manifest.json').read_text())
        chunk = result['chunks'][0]
        self.assertEqual(chunk['sourceZlibBytes'],len(zlib.compress(self.source.read_bytes(),6)))
        self.assertEqual(result['id'],'fixture-adaptive-0p5')
        record = (compiled/chunk['path']).with_suffix('.json')
        record.write_text('{interrupted')
        subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
        restored = json.loads(record.read_text())
        self.assertEqual(restored['sha256'],chunk['sha256'])

    def test_empty_source_plan_records_full_gap(self):
        out = self.directory/'empty-plan'
        args = [sys.executable,str(HERE/'build_park.py'),'--source',str(self.directory/'missing-source'),
            '--boundary',str(self.root/'boundary.geojson'),'--output',str(out),
            '--compiler',self.compiler,'--id','missing','--name','Missing park','--plan-only']
        subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
        plan = json.loads((out/'plan.json').read_text())
        self.assertEqual(plan['chunkCount'],0)
        self.assertAlmostEqual(plan['parkAreaKm2'],plan['uncoveredParkAreaKm2'])
        self.assertFalse((out/'manifest.json').exists())

    def test_nodata_is_refused_by_compiler(self):
        raw = bytearray(self.source.read_bytes())
        raw[0:2] = struct.pack('<h', -32768)
        self.source.write_bytes(raw)
        result = subprocess.run([self.compiler, str(self.source), str(self.root / 'bad.rmesh')], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'NoData', result.stderr)
        self.assertFalse((self.root / 'bad.rmesh').exists())


if __name__ == '__main__':
    unittest.main()
