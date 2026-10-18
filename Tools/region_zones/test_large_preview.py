"""Geographic invariants for the saved draft; does not need the external drive."""
import json
import unittest
from pathlib import Path
from shapely.geometry import Polygon, Point, box
from shapely.ops import unary_union

ROOT=Path(__file__).resolve().parents[2]

class LargePreviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old=json.loads((ROOT/'ridge v3/Resources/uk-download-zones.json').read_text())
        cls.new=json.loads((ROOT/'Artifacts/larger-regions-preview/regions.json').read_text())

    def test_every_original_section_keeps_its_bounds_and_one_display_owner(self):
        old={c['id']:c for a in self.old['regions'] for c in a['cells']}
        new=[c for a in self.new['regions'] for c in a['cells']]
        self.assertEqual(len({c['id'] for c in new}),len(new))
        self.assertEqual(old,{c['id']:c for c in new})

    def test_whole_parks_and_displayed_blocks_are_downloadable(self):
        lookup={p:a for a in self.new['regions'] for p in a.get('parkIDs',[])}
        self.assertEqual(len(lookup),15)
        for park in self.old['parks']:
            group=lookup[park['id']]
            self.assertEqual(group['parkIDs'],[park['id']])
            downloads={c['id'] for c in group['downloadCells']}
            self.assertTrue({c['id'] for c in park['cells']}<=downloads)
            self.assertTrue({c['id'] for c in group['cells']}<=downloads)

    def test_mainland_blocks_have_no_inland_cutouts_or_interlocking_edges(self):
        cells={c['id']:c for a in self.old['regions'] for c in a['cells']}
        xs=sorted({c['bounds']['minLongitude'] for c in cells.values()})
        ys=sorted({c['bounds']['minLatitude'] for c in cells.values()})
        xi={v:i for i,v in enumerate(xs)};yi={v:i for i,v in enumerate(ys)}
        xy={i:(xi[c['bounds']['minLongitude']],yi[c['bounds']['minLatitude']]) for i,c in cells.items()}
        islands={c['id'] for a in self.new['regions'] if a['kind']=='island' for c in a['cells']}
        for a in self.new['regions']:
            if a['kind']=='island':continue
            if a['kind']=='surrounding':self.assertGreaterEqual(a['landAreaKm2'],200,a['name'])
            x0,y0,x1,y1=a['gridRectangle']
            expected={i for i,(x,y) in xy.items() if x0<=x<=x1 and y0<=y<=y1 and i not in islands}
            for t in self.new['coastalTransfers']:
                if t['source']==a['id']:expected.difference_update(t['cells'])
                if t['target']==a['id']:expected.update(t['cells'])
            self.assertEqual({c['id'] for c in a['cells']},expected,a['name'])
            self.assertGreaterEqual(min(x1-x0+1,y1-y0+1),3,a['name'])

    def test_land_is_preserved_without_visual_overlap_or_offshore_labels(self):
        def geom(area):return unary_union([Polygon(s['rings'][0],s['rings'][1:]) for s in area['mapShapes']])
        old=unary_union([geom(a) for a in self.old['regions']])
        shapes=[geom(a) for a in self.new['regions']]
        merged=unary_union(shapes)
        self.assertLess(old.symmetric_difference(merged).area,1e-9)
        self.assertAlmostEqual(sum(g.area for g in shapes),merged.area,places=9)
        for a,g in zip(self.new['regions'],shapes):
            if not g.is_empty:
                b=a['labelBounds'];self.assertTrue(g.covers(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])),a['name'])
                gaps=unary_union([Polygon(s['rings'][0],s['rings'][1:]) for s in a['missingShapes']])
                self.assertLess(gaps.difference(g).area,1e-9,a['name'])

    def test_sizes_and_coverage_are_not_fabricated_for_empty_areas(self):
        self.assertTrue(60<=self.new['summary']['areas']<=110)
        self.assertEqual(self.new['summary']['publishedSections'],2531)
        self.assertEqual(len({a['name'] for a in self.new['regions']}),len(self.new['regions']))
        for a in self.new['regions']:
            s=a['stats']
            self.assertEqual(s['oversize'],s['estimateBytes']>1_000_000_000 or s['sectionCount']>128,a['name'])
            if s['sectionCount']==0:
                self.assertEqual(s['availability'],'unavailable')
                self.assertEqual(s['estimateBytes'],0)
            elif s['archiveBytes'] is None:
                self.assertGreater(s['estimateBytes'],s['sectionBytes'])

    def test_key_mountain_groups_and_islands_remain_recognisable(self):
        def owner(lon,lat):
            return next(a['name'] for a in self.new['regions'] if any(Polygon(s['rings'][0],s['rings'][1:]).covers(Point(lon,lat)) for s in a['mapShapes']))
        for name,points in [('Eryri',[(-4.0763,53.0685),(-3.9966,53.1143)]),('Peak District',[(-1.873,53.384)]),('Lake District',[(-3.54,54.55)]),('Anglesey',[(-4.35,53.30)]),('Skye & Raasay',[(-6.2,57.25)])]:
            for p in points:self.assertEqual(owner(*p),name)

if __name__=='__main__':unittest.main()
