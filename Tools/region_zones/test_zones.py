import json
import unittest
import re
from pathlib import Path
from shapely.geometry import box, Polygon
from shapely.ops import unary_union


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

    def test_display_footprints_exclude_sea_and_keep_labels_on_land(self):
        atlas = json.loads((ROOT/'ridge v3/Resources/RidgeData.bundle/atlas.json').read_text())
        land = unary_union([Polygon(r).buffer(0) for r in atlas['land']])
        for zone in self.index['regions']:
            polygons = [Polygon(s['rings'][0], s['rings'][1:]) for s in zone['mapShapes']]
            footprint = unary_union(polygons)
            self.assertLess(footprint.difference(land).area, 1e-10, zone['id'])
            cells = [box(c['bounds']['minLongitude'], c['bounds']['minLatitude'], c['bounds']['maxLongitude'], c['bounds']['maxLatitude']) for c in zone['cells']]
            self.assertLess(footprint.difference(unary_union(cells)).area, 1e-10, zone['id'])
            if footprint.is_empty:
                self.assertIsNone(zone['labelBounds'])
            else:
                b = zone['labelBounds']
                label = box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude'])
                self.assertTrue(footprint.covers(label), zone['id'])

    def test_simple_areas_and_independent_park_downloads(self):
        self.assertEqual(len(self.index['boundarySources']), 15)
        self.assertEqual(len(self.index['parks']), 15)
        for source in self.index['boundarySources']:
            self.assertEqual(source['source'], 'OpenStreetMap')
            self.assertEqual(len(source['sha256']), 64)
        areas = self.index['regions']
        self.assertEqual(len({z['name'] for z in areas}),len(areas))
        for zone in areas:
            self.assertLessEqual(len(zone['mapLabel'].split('\n')),2)
            b = unary_union([box(c['bounds']['minLongitude'], c['bounds']['minLatitude'], c['bounds']['maxLongitude'], c['bounds']['maxLatitude']) for c in zone['cells']])
            # Full inland blocks remain rectangular. Coastal remnants may join
            # an adjacent block, but are never cut into park-shaped leftovers.
            bins=set()
            for c in zone['cells']:
                x,y,col,row=map(int,re.search(r'x(\d+)-y(\d+)-c(\d+)-r(\d+)',c['id']).groups())
                bins.add(((x*3+col//16)//5,(y*3+row//16)//5))
            if len(zone['cells'])==25 and len(bins)==1:
                self.assertAlmostEqual(b.area,b.envelope.area,places=10)
        ids = {c['id'] for z in areas for c in z['cells']}
        for park in self.index['parks']:
            self.assertEqual(park['id'],park['parkID'])
            self.assertTrue(set(c['id'] for c in park['cells']).issubset(ids))
            self.assertEqual(len(park['cells']),len({c['id'] for c in park['cells']}))


if __name__ == '__main__':
    unittest.main()
