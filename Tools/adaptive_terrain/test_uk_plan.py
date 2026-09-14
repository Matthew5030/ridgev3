import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from shapely.geometry import box, mapping

HERE=Path(__file__).resolve().parent


class UKPlanTests(unittest.TestCase):
    def fixture(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);root=Path(temporary.name)
        bounds=dict(minLongitude=-1.51,maxLongitude=-1.509,minLatitude=53,maxLatitude=53.001)
        (root/'boundary.json').write_text(json.dumps(dict(type='Feature',properties={},geometry=mapping(box(-1.51,53,-1.509,53.001)))))
        (root/'world.json').write_text(json.dumps(dict(tiles=[dict(tileID='z10-x1-y1',x=1,y=1,bounds=bounds)])))
        coverage=root/'coverage';coverage.mkdir()
        raw=json.dumps(dict(type='FeatureCollection',crs={'properties':{'name':'EPSG:27700'}},features=[dict(id=1,geometry=mapping(box(0,0,10,10)))])).encode()
        (coverage/'part.json').write_bytes(raw)
        (coverage/'index.json').write_text(json.dumps(dict(crs='EPSG:27700',parts=[dict(path='part.json',byteCount=len(raw),sha256=hashlib.sha256(raw).hexdigest(),count=1)],featureCount=1,source='https://example.test/survey',editingInfo={},license='OGL',attribution='Test')))
        for source in ['england','wales']:
            path=root/source/'tiles/10/1/1/manifest.json';path.parent.mkdir(parents=True)
            manifest=dict(tileID='z10-x1-y1',sourceKey=source,source={'name':source},parents=[dict(id='c00-00',precisionChildren=[dict(id='p00-00',bounds=bounds,lods=[dict(nominalSpacingMetres=1,byteCount=513*513*2,path='terrain.bin',sha256=hashlib.sha256(source.encode()).hexdigest(),terrain=dict(width=513,height=513,scaleMetres=.1,sampleFormat='int16',byteOrder='little-endian'))])])])
            raw=json.dumps(manifest).encode();path.write_bytes(raw);path.with_name('COMPLETE.json').write_text(json.dumps(dict(manifestSHA256=hashlib.sha256(raw).hexdigest())))
        return root

    def run_plan(self,root):
        return subprocess.run([sys.executable,str(HERE/'plan_uk.py'),'--output',str(root/'out'),'--source',str(root/'england'),'--source',str(root/'wales'),'--boundary',str(root/'boundary.json'),'--world-grid',str(root/'world.json'),'--ea-coverage',str(root/'coverage'),'--workers','1'],capture_output=True,text=True)

    def test_unsupported_primary_uses_valid_fallback(self):
        root=self.fixture();result=self.run_plan(root);self.assertEqual(result.returncode,0,result.stderr)
        selection=json.loads((root/'out/selection/z10-x1-y1.json').read_bytes())
        self.assertEqual(selection['chunkCount'],1);self.assertEqual(selection['rejectedEACandidates'],1);self.assertEqual(selection['rejectedWithoutFallback'],0)
        self.assertIn('/wales/',selection['chunks'][0]['source'])
        self.assertEqual(selection['selectedBySource'],{'wales':1})

    def test_changed_prepared_manifest_is_refused(self):
        root=self.fixture();path=root/'wales/tiles/10/1/1/manifest.json';path.write_bytes(path.read_bytes()+b' ')
        result=self.run_plan(root);self.assertNotEqual(result.returncode,0);self.assertIn('AssertionError',result.stderr)

    def test_no_source_means_explicit_gap(self):
        root=self.fixture();path=root/'wales/tiles/10/1/1/manifest.json';d=json.loads(path.read_bytes());d['parents']=[];raw=json.dumps(d).encode();path.write_bytes(raw);path.with_name('COMPLETE.json').write_text(json.dumps(dict(manifestSHA256=hashlib.sha256(raw).hexdigest())))
        result=self.run_plan(root);self.assertEqual(result.returncode,0,result.stderr)
        plan=json.loads((root/'out/plan.json').read_bytes());self.assertEqual(plan['chunkCount'],0);self.assertEqual(plan['rejectedWithoutFallback'],1)


if __name__=='__main__':unittest.main()
