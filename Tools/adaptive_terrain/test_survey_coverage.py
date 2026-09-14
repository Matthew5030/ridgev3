import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from shapely.geometry import box, mapping, MultiPolygon
from survey_coverage import SurveyCoverage, requires_ea_coverage


class SurveyTests(unittest.TestCase):
    bounds=dict(minLongitude=-1.51,maxLongitude=-1.509,minLatitude=53,maxLatitude=53.001)

    def fixture(self,geometries):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);root=Path(temporary.name)
        raw=json.dumps(dict(type='FeatureCollection',crs={'properties':{'name':'EPSG:27700'}},features=[dict(id=i,geometry=mapping(g)) for i,g in enumerate(geometries)])).encode()
        (root/'part.json').write_bytes(raw)
        index=dict(crs='EPSG:27700',parts=[dict(path='part.json',byteCount=len(raw),sha256=hashlib.sha256(raw).hexdigest(),count=len(geometries))],featureCount=len(geometries),source='https://example.test/official',editingInfo={},license='OGL',attribution='Test')
        (root/'index.json').write_text(json.dumps(index));return root

    def test_adjacent_footprints_cover_a_chunk_together(self):
        from pyproj import Transformer
        x,y=Transformer.from_crs(4326,27700,always_xy=True).transform(-1.5095,53.0005)
        survey=SurveyCoverage(self.fixture([box(x-200,y-200,x,y+200),box(x,y-200,x+200,y+200)]))
        self.assertTrue(survey.accepts(survey.for_bounds(self.bounds),self.bounds))

    def test_hole_and_interpolation_margin_are_excluded(self):
        survey=SurveyCoverage(self.fixture([box(0,0,700000,1300000)]));envelope=survey.envelope(self.bounds)
        x,y=envelope.centroid.coords[0]
        with_hole=envelope.difference(box(x-1,y-1,x+1,y+1))
        self.assertFalse(survey.accepts(with_hole,self.bounds))
        self.assertFalse(survey.accepts(envelope.buffer(-1),self.bounds))
        self.assertTrue(survey.accepts(envelope,self.bounds))

    def test_nested_arcgis_shells_retain_holes(self):
        root=self.fixture([MultiPolygon([box(0,0,100,100),box(25,25,75,75)])]);survey=SurveyCoverage(root)
        self.assertEqual(survey.provenance['repairedGeometries'],1)
        self.assertFalse(survey.polygons[0].covers(box(49,49,51,51)))

    def test_corrupt_snapshot_is_refused(self):
        root=self.fixture([box(0,0,100,100)]);(root/'part.json').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'checksum'):SurveyCoverage(root)

    def test_incomplete_snapshot_is_refused(self):
        root=self.fixture([box(0,0,100,100)]);p=root/'index.json';d=json.loads(p.read_text());d['featureCount']=2;p.write_text(json.dumps(d))
        with self.assertRaisesRegex(ValueError,'Incomplete'):SurveyCoverage(root)

    def test_ea_filter_is_not_applied_to_welsh_or_scottish_sources(self):
        self.assertTrue(requires_ea_coverage({'sourceKey':'england'}))
        self.assertFalse(requires_ea_coverage({'sourceKey':'wales','source':{'adapter':'cog'}}))
        self.assertFalse(requires_ea_coverage({'source':{'name':'Scottish public sector LiDAR DTM'}}))


if __name__=='__main__':unittest.main()
