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
        parks=[a for a in self.index['regions'] if a.get('parkID')==a['id']]
        self.assertEqual(len(parks),15)
        self.assertEqual(self.index['parks'],[])
        for source in self.index['boundarySources']:
            self.assertEqual(source['source'], 'OpenStreetMap')
            self.assertEqual(len(source['sha256']), 64)
        areas = self.index['regions']
        self.assertEqual(len(areas),84)
        self.assertEqual(len({z['name'] for z in areas}),len(areas))
        self.assertEqual(len({z['mapLabel'] for z in areas}),len(areas))
        for zone in areas:
            self.assertLessEqual(len(zone['mapLabel'].split('\n')),2)
            self.assertTrue(zone['id'].startswith(('area-','park-')))
        ids = {c['id'] for z in areas for c in z['cells']}
        for park in parks:
            self.assertEqual(park['id'],park['parkID'])
            self.assertTrue(set(c['id'] for c in park['downloadCells']).issubset(ids))
            self.assertTrue(set(c['id'] for c in park['cells']).issubset(c['id'] for c in park['downloadCells']))
            self.assertEqual(len(park['cells']),len({c['id'] for c in park['cells']}))

    def test_app_ships_the_reviewed_layout_without_frozen_coverage_flags(self):
        import hashlib
        raw=(ROOT/'Artifacts/larger-regions-preview/regions.json').read_bytes()
        preview=json.loads(raw)
        self.assertEqual(self.index['layoutSHA256'],hashlib.sha256(raw).hexdigest())
        self.assertNotIn('draft',self.index)
        for app,proposed in zip(self.index['regions'],preview['regions']):
            for key in ['id','cells','mapShapes','mapLabel','labelBounds','downloadCells']:
                self.assertEqual(app.get(key),proposed.get(key),app['name'])
            self.assertNotIn('stats',app)
            self.assertNotIn('missingShapes',app)
            self.assertNotIn('Draft',app['subtitle'])

    def test_recognisable_walking_areas_keep_key_mountains_together(self):
        from shapely.geometry import Point
        def area_at(lon,lat):
            for z in self.index['regions']:
                if any(Polygon(s['rings'][0],s['rings'][1:]).covers(Point(lon,lat)) for s in z['mapShapes']):
                    return z
        snowdon=area_at(-4.0763,53.0685)
        self.assertEqual(snowdon['id'],area_at(-3.9966,53.1143)['id']) # Tryfan
        self.assertEqual('Eryri',snowdon['name'])
        self.assertEqual('Peak District',area_at(-1.873,53.384)['name']) # Kinder Scout
        self.assertNotEqual(area_at(-4.35,53.30)['id'],snowdon['id']) # Anglesey


if __name__ == '__main__':
    unittest.main()
