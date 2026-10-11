import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

import pack_sections as packs


class SectionPackTests(unittest.TestCase):
    def test_catalogue_publication_and_failure_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = []
            for number in range(26):
                source_id = f'test-{number}'
                folder = root / 'sources' / source_id
                folder.mkdir(parents=True)
                data = b'{"value":123}'
                (folder / 'data.json').write_bytes(data)
                asset = dict(file='data.json', byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
                manifest = dict(id=source_id, overview=asset, graph=asset, tiles=[])
                (folder / 'world.json').write_bytes(packs.raw(manifest))
                sources.append(dict(id=source_id, path=f'sources/{source_id}/world.json', preserved='coverage'))
            catalog = dict(schemaVersion=1, revision='fixture', sources=sources)
            (root / 'catalog.json').write_bytes(packs.raw(catalog))
            command = [sys.executable, packs.__file__, str(root), '--publish', '--workers', '2']
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            published = json.loads((root / 'catalog.json').read_bytes())
            self.assertEqual(published['packVersion'], 1)
            self.assertTrue(all(s['pack'] and s['preserved'] == 'coverage' for s in published['sources']))
            self.assertEqual(json.loads((root / 'catalog.before-section-packs.json').read_bytes()), catalog)
            self.assertEqual(json.loads((root / 'section-pack-status.json').read_bytes())['state'], 'complete')
            # Resume publication accepts its own added pack descriptors.
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            broken = root / 'sources/test-0'
            (broken / 'section-pack-v1.json').unlink()
            (broken / 'data.json').write_bytes(b'corrupt')
            result = subprocess.run(command + ['--source', 'test-0'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads((root / 'section-pack-status.json').read_bytes())['state'], 'failed')
            self.assertEqual(json.loads((root / 'catalog.json').read_bytes()), published)

    def test_round_trip_resume_corruption_and_changed_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / 'sources/test'
            folder.mkdir(parents=True)

            def asset(name, data):
                (folder / name).write_bytes(data)
                return dict(file=name, byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())

            overview = asset('overview.json', b'{"points":[' + b'[1,2,3],' * 100 + b'[]]}')
            graph = asset('graph.json', b'old graph')
            routing = asset('connected.json', b'connected graph' * 100)
            mesh = asset('mesh.rat.zlib', zlib.compress(b'original terrain' * 500))
            vector = asset('tile.map', zlib.compress(b'original cartography' * 500))
            manifest = dict(id='test', overview=overview, graph=graph,
                            tiles=[dict(mesh=dict(path=mesh['file'], byteCount=mesh['byteCount'], sha256=mesh['sha256']), map=vector)] * 2)
            (folder / 'world.json').write_bytes(packs.raw(manifest))
            region = dict(id='test', path='sources/test/world.json', routing=routing)
            pack = packs.build(root, region)
            data = (folder / pack['file']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), pack['sha256'])
            self.assertEqual(data[:8], packs.MAGIC)
            size = struct.unpack('<I', data[8:12])[0]
            index = json.loads(data[12:12+size])
            self.assertEqual(len(index['entries']), 4)  # Duplicate tile payloads removed.
            expected = {a['sha256']: (folder / a.get('file', a.get('path'))).read_bytes()
                        for a in packs.assets(manifest, region)}
            self.assertNotIn(graph['sha256'], expected)  # Connected graph override retained.
            for entry in index['entries']:
                start = 12 + size + entry['offset']
                stored = data[start:start + entry['storedByteCount']]
                decoded = zlib.decompress(stored) if entry['compressed'] else stored
                self.assertEqual(decoded, expected[entry['sha256']])
            self.assertEqual(packs.build(root, region), pack)
            damaged = bytearray(data)
            damaged[-1] ^= 1
            (folder / pack['file']).write_bytes(damaged)
            self.assertEqual(packs.build(root, region), pack)
            self.assertEqual((folder / pack['file']).read_bytes(), data)
            region['routing'] = asset('updated.json', b'new connected graph' * 100)
            self.assertNotEqual(packs.build(root, region)['sha256'], pack['sha256'])
            (folder / 'tile.map').write_bytes(b'damaged')
            (folder / 'section-pack-v1.json').unlink()
            with self.assertRaisesRegex(ValueError, 'Damaged source asset'):
                packs.build(root, region)
            self.assertFalse((folder / '.section-pack.tmp').exists())
            self.assertFalse((folder / '.section-pack-payload.tmp').exists())


if __name__ == '__main__':
    unittest.main()
