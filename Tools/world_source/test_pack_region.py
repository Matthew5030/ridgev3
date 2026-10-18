import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path

import pack_region
import pack_sections


class RegionPackTests(unittest.TestCase):
    def test_nested_sections_are_unchanged_and_publication_is_additive(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = []
            for i in range(2):
                source_id = f'world-test-{i}'
                folder = root / 'sources' / source_id
                folder.mkdir(parents=True)
                data = ('{"height":%d}' % i).encode()
                asset = dict(file='overview.json', byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
                (folder / asset['file']).write_bytes(data)
                (folder / 'world.json').write_bytes(pack_sections.raw(dict(id=source_id, overview=asset, graph=asset, tiles=[])))
                source = dict(id=source_id, path=f'sources/{source_id}/world.json')
                source['pack'] = pack_sections.build(root, source)
                sources.append(source)
            catalog = dict(schemaVersion=1, revision='fixture', sources=sources)
            (root / 'catalog.json').write_bytes(pack_sections.raw(catalog))
            zones = root / 'zones.json'
            zones.write_bytes(pack_sections.raw(dict(regions=[dict(id='pilot', cells=[dict(id=s['id']) for s in sources])])))
            result = pack_region.build(root, zones, 'pilot', publish=True)
            data = (root / 'region-packs' / result['asset']['file']).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), result['asset']['sha256'])
            self.assertEqual(data[:8], b'RIDGERG1')
            size = struct.unpack('<I', data[8:12])[0]
            header = json.loads(data[12:12+size])
            for source, member in zip(sources, header['members']):
                original = (root / Path(source['path']).parent / source['pack']['file']).read_bytes()
                start = 12 + size + member['offset']
                self.assertEqual(data[start:start+len(original)], original)
            published = json.loads((root / 'catalog.json').read_bytes())
            self.assertEqual(published['sources'], sources)
            self.assertEqual(published['regionArchives'], [result])
            self.assertEqual(pack_region.build(root, zones, 'pilot', publish=True), result)
            broken = root / Path(sources[0]['path']).parent / sources[0]['pack']['file']
            broken.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'Damaged section pack'):
                pack_region.build(root, zones, 'pilot', publish=True)
            self.assertEqual(json.loads((root / 'catalog.json').read_bytes()), published)
            self.assertFalse((root / 'region-packs/pilot.tmp').exists())


if __name__ == '__main__':
    unittest.main()
