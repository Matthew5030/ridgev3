import json
import unittest
from pathlib import Path
from shapely.geometry import box
from build_zones import split

ROOT = Path(__file__).resolve().parents[2]


class DownloadZonesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.index = json.loads((ROOT/'ridge v3/Resources/uk-download-zones.json').read_text())
        cls.original = json.loads((ROOT/'ridge v3/Resources/uk-pack-regions.json').read_text())

    def test_partition_preserves_every_parent_without_overlap(self):
        children = {}
        for zone in self.index['regions']:
            self.assertTrue(zone['cells'])
            for cell in zone['cells']:
                self.assertNotIn(cell['id'], children)
                children[cell['id']] = cell
        for region in self.original['regions']:
            for parent in region['cells']:
                b = parent['bounds']
                rectangle = box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude'])
                parts = []
                for row in (0, 16, 32):
                    for col in (0, 16, 32):
                        b = children[f"world-{parent['id']}-c{col:02d}-r{row:02d}"]['bounds']
                        parts.append(box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude']))
                from shapely.ops import unary_union
                self.assertLess(rectangle.symmetric_difference(unary_union(parts)).area, 1e-12)
                self.assertAlmostEqual(sum(p.area for p in parts), rectangle.area, places=10)

    def test_park_boundaries_auditable_and_compass_names_match(self):
        self.assertEqual(len(self.index['boundarySources']), 15)
        for source in self.index['boundarySources']:
            self.assertEqual(source['source'], 'OpenStreetMap')
            self.assertEqual(len(source['sha256']), 64)
        parks = {}
        for zone in self.index['regions']:
            if zone.get('parkID'):
                parks.setdefault(zone['parkID'], []).append(zone)
        for ident, zones in parks.items():
            if len(zones) == 1:
                self.assertLessEqual(len(zones[0]['cells']), 24)
                continue
            members = [c for z in zones for c in z['cells']]
            quadrants = split(members)
            for z in zones:
                suffix = z['id'].removeprefix(ident+'-')
                self.assertEqual({c['id'] for c in z['cells']}, {c['id'] for c in quadrants[suffix]})


if __name__ == '__main__':
    unittest.main()
