import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path

import pack_region
import pack_sections


class RegionPackTests(unittest.TestCase):
    def test_source_rollout_drops_only_groups_with_removed_archives(self):
        catalog = dict(regionArchives=[dict(id='kept')], regionArchiveGroups=[
            dict(id='valid', archiveIDs=['kept']), dict(id='stale', archiveIDs=['kept', 'removed'])])
        pack_region.retain_archive_groups(catalog)
        self.assertEqual(catalog['regionArchiveGroups'], [dict(id='valid', archiveIDs=['kept'])])

    def test_chunk_group_keeps_download_membership_and_publishes_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = []
            for i in range(3):
                sid = f'world-chunk-{i}'
                folder = root / 'sources' / sid
                folder.mkdir(parents=True)
                data = bytes([i+1]) * 1000
                asset = dict(file='overview.json', byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
                (folder / asset['file']).write_bytes(data)
                (folder / 'world.json').write_bytes(pack_sections.raw(dict(id=sid, overview=asset, graph=asset, tiles=[])))
                source = dict(id=sid, path=f'sources/{sid}/world.json')
                source['pack'] = pack_sections.build(root, source)
                sources.append(source)
            (root / 'catalog.json').write_bytes(pack_sections.raw(dict(schemaVersion=1, revision='fixture', sources=sources)))
            zones = root / 'zones.json'
            zones.write_bytes(pack_sections.raw(dict(regions=[dict(id='pilot', cells=[dict(id=sources[0]['id'])],
                downloadCells=[dict(id=s['id']) for s in sources])])))
            result = pack_region.build_group(root, zones, 'pilot', publish=True, target_bytes=sources[0]['pack']['byteCount'])
            self.assertEqual(len(result['archives']), 3)
            self.assertEqual([s for a in result['archives'] for s in a['sourceIDs']], [s['id'] for s in sources])
            published = json.loads((root / 'catalog.json').read_bytes())
            self.assertEqual(published['regionArchiveGroups'], [result['group']])
            self.assertTrue(all(a['asset']['byteCount'] <= 1024**3 for a in published['regionArchives']))
            for descriptor in result['archives']:
                data = (root / 'region-packs' / descriptor['asset']['file']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), descriptor['asset']['sha256'])
                count = struct.unpack('<I', data[8:12])[0]
                header = json.loads(data[12:12+count])
                member = header['members'][0]
                original = next(s for s in sources if s['id'] == member['sourceID'])
                self.assertEqual(data[12+count:], (root / Path(original['path']).parent / original['pack']['file']).read_bytes())
            self.assertEqual(pack_region.build_group(root, zones, 'pilot', publish=True, target_bytes=sources[0]['pack']['byteCount']), result)
            self.assertEqual(json.loads((root / 'catalog.json').read_bytes()), published)
            broken = root / Path(sources[-1]['path']).parent / sources[-1]['pack']['file']
            broken.write_bytes(b'broken')
            with self.assertRaisesRegex(ValueError, 'Damaged section pack'):
                pack_region.build_group(root, zones, 'pilot', publish=True, target_bytes=sources[0]['pack']['byteCount'])
            self.assertEqual(json.loads((root / 'catalog.json').read_bytes()), published)

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
            park_zone = dict(id='park-pilot', cells=[dict(id=s['id']) for s in sources])
            zones.write_bytes(pack_sections.raw(dict(regions=[], parks=[park_zone])))
            park = pack_region.build(root, zones, 'park-pilot', publish=True)
            published = json.loads((root / 'catalog.json').read_bytes())
            self.assertEqual(published['regionArchives'], [result, park])
            self.assertEqual(park['sourceIDs'], result['sourceIDs'])
            zones.write_bytes(pack_sections.raw(dict(regions=[dict(id='pilot', cells=[dict(id=s['id']) for s in sources])])))
            broken = root / Path(sources[0]['path']).parent / sources[0]['pack']['file']
            broken.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'Damaged section pack'):
                pack_region.build(root, zones, 'pilot', publish=True)
            self.assertEqual(json.loads((root / 'catalog.json').read_bytes()), published)
            self.assertFalse((root / 'region-packs/pilot.tmp').exists())


if __name__ == '__main__':
    unittest.main()
