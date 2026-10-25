"""Exercise atlas publication with no network, saved terrain or external drive."""
import json,tempfile,types,unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np
from PIL import Image,ImageDraw
import test_texture_overview as fixtures
from native_overview import NativeTextures
from install_native_bundle import install

class NativeAtlasTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.OverviewTests('test_polygon_hole_preserves_existing_pixels_and_mask');self.fixture.setUp()
        f=self.fixture;world=f.root/'world';world.mkdir();(world/'catalog.json').write_text(json.dumps(dict(revision='fixture',sources=[])))
        renderer=f.root/'capture';renderer.write_bytes(b'native renderer fixture')
        self.builder=NativeTextures(types.SimpleNamespace(base=f.base,background=f.background,atlas=f.atlas,style=f.style,archives=f.archives,output=f.root/'native',mosaics=[],renderer=renderer,world=world))
    def tearDown(self):self.fixture.temporary.cleanup()
    def capture(self,command,**kwargs):
        self.assertEqual(command[1],'--surface');folder=Path(command[2])
        metadata=json.loads((folder/'surface.json').read_bytes());self.assertEqual(metadata['side'],1025)
        self.assertEqual((folder/'heights.bin').stat().st_size,1025*1025*4)
        self.assertEqual((folder/'base.bin').stat().st_size,2056*2056*4)
        vector=json.loads((folder/'map.json').read_bytes())
        self.assertIn('woodland',{p['kind'] for p in vector['paths']})
        self.assertIn('water',{p['kind'] for p in vector['paths']})
        # Native cartography receives geometry, rather than the old atlas JPEG.
        self.assertTrue(all('rings' in p and 'closed' in p for p in vector['paths']))
        image=Image.new('RGB',(2048,2048),(180,25,20));image.paste((20,30,180),(0,1024,2048,2048));image.save(command[3])
        return types.SimpleNamespace(returncode=0,stderr='')
    def test_native_capture_preserves_north_and_real_semantics(self):
        with patch('native_overview.subprocess.run',self.capture):image=self.builder.render(500,333,self.fixture.data)
        self.assertEqual(image.size,(2048,2048));self.assertGreater(image.getpixel((100,100))[0],image.getpixel((100,100))[2])
        self.assertGreater(image.getpixel((100,1948))[2],image.getpixel((100,1948))[0])
    def test_reference_pages_publish_without_any_saved_map_or_server(self):
        with patch('native_overview.subprocess.run',self.capture):record=self.builder.section(self.fixture.descriptor)
        self.assertEqual(sum(p.startswith('z13-') for p in record['pages']),64)
        self.assertEqual(sum(p.startswith('z12-') for p in record['pages']),16)
        with patch('native_overview.subprocess.run',side_effect=AssertionError('Unchanged screenshot regenerated')):
            self.assertEqual(self.builder.section(self.fixture.descriptor),record)
        report=self.builder.publish([record]);index=json.loads((self.builder.output/'index.json').read_bytes())
        self.assertEqual(index['renderer'],'WorldPreview');self.assertEqual(index['semanticSectionCount'],1)
        self.assertEqual(index['maxZoom'],13)
        self.assertEqual(len(index['tiles']),report['pages'])
        for name in index['tiles']:
            with Image.open(self.builder.output/name) as image:self.assertEqual(image.size,(256,256))
    def test_fine_height_gaps_keep_background_instead_of_zero_cliffs(self):
        grid=self.builder.height_grid(500,333,self.fixture.data['bounds'])
        self.assertTrue(np.isfinite(grid).all());self.assertGreater(float(grid.min()),0)
    def test_partial_country_build_cannot_replace_the_installed_map(self):
        f=self.fixture;bundle=f.root/'installed';bundle.mkdir();(bundle/'existing-map').write_text('keep')
        output=f.root/'incomplete';output.mkdir()
        (output/'index.json').write_text(json.dumps(dict(renderer='WorldPreview',semanticSectionCount=1,maxZoom=13)))
        (output/'status.json').write_text(json.dumps(dict(state='sample-complete',sections=1)))
        with self.assertRaises(ValueError):install(output,bundle,f.root/'backup')
        self.assertEqual((bundle/'existing-map').read_text(),'keep')
        self.assertFalse((f.root/'backup').exists())
    def test_dense_city_passes_preserve_the_complete_capture(self):
        calls=[]
        def capture(command,**kwargs):
            folder=Path(command[2]);vector=json.loads((folder/'map.json').read_bytes());calls.append(len(vector['paths']))
            image=Image.new('RGB',(2048,2048),(235,232,215));paint=ImageDraw.Draw(image)
            for path in vector['paths']:
                ink={'woodland':(100,160,90),'water':(100,170,190),'building':(130,120,110)}[path['kind']]
                for ring in path['rings']:paint.polygon([(p[0]/vector['width']*2048,p[1]/vector['height']*2048) for p in ring],fill=ink)
            image.save(command[3]);return types.SimpleNamespace(returncode=0,stderr='')
        data=dict(self.fixture.data);data['features']=list(data['features'])
        # This real polygon crosses the image centre and must be retained in
        # every partial pass that could draw it, without resetting its position.
        data['features'].append(dict(kind='building',geometry=dict(type='Polygon',coordinates=[fixtures.rectangle(500.45,333.45,500.55,333.55)])))
        with patch('native_overview.subprocess.run',capture):whole=self.builder.render(500,333,data)
        self.assertEqual(calls,[3]);calls.clear();self.builder.maximum_capture_paths=2
        with patch('native_overview.subprocess.run',capture):parts=self.builder.render(500,333,data)
        self.assertGreater(len(calls),1);self.assertTrue(all(n<=2 for n in calls))
        np.testing.assert_array_equal(np.asarray(parts),np.asarray(whole))

if __name__=='__main__':unittest.main()
