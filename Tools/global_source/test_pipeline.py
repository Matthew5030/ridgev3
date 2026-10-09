"""Regression checks for elevation range, true routing topology and global grids."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import subprocess
from unittest.mock import patch
import numpy as np
from common import bounds,xy,digest,DiskReserveError,reserve
from terrain import quantize,tile_name,Surface
from build import routing,toolchain,CompactCodec,subbounds
from batch import cells

class FlatSurface:
    def sample(self,x,y):return np.zeros(np.broadcast_arrays(x,y)[0].shape)+4000


def feature(coords,ids):
    return dict(kind='footpath',properties=dict(access='public'),route=dict(coordinates=coords,nodes=ids,bidirectional=True,reverse=False))

class PipelineTests(unittest.TestCase):
    def test_altitude_offset(self):
        for heights in (np.array([[-430.01,12.27],[8900.01,8901.22]])[1:],np.array([[-440.03,-432.67]])):
            raw,offset=quantize(heights)
            self.assertLessEqual(np.abs(raw.astype(float)*.1+offset-heights).max(),.05001)
        with self.assertRaises(ValueError):quantize(np.array([0.,7000.]))
        with self.assertRaises(ValueError):quantize(np.array([np.nan]))

    def test_hemispheres_and_grid(self):
        self.assertIn('S46_00_W073',tile_name(-46,-73))
        for lon,lat in [(7.75,46.02),(172,-44),(-73,-46),(-115,52)]:
            x,y=xy(lon,lat);b=bounds(x,y)
            self.assertTrue(b['minLongitude']<=lon<=b['maxLongitude'])
            self.assertTrue(b['minLatitude']<=lat<=b['maxLatitude'])
            self.assertEqual(b['maxLongitude'],bounds(x+1,y)['minLongitude'])
            self.assertEqual(b['minLatitude'],bounds(x,y+1)['maxLatitude'])

    def test_true_junctions_and_crossings(self):
        b=dict(minLongitude=0,maxLongitude=2,minLatitude=0,maxLatitude=2)
        g=routing([feature([[0,1],[1,1],[2,1]],[10,11,12]),feature([[1,0],[1,1],[1,2]],[20,11,22])],b,FlatSurface())
        self.assertEqual(len(g['nodes']),5)
        separate=routing([feature([[0,1],[2,1]],[10,12]),feature([[1,0],[1,2]],[20,22])],b,FlatSurface())
        self.assertEqual(len(separate['nodes']),4)
        self.assertFalse(any(n['coordinate']==dict(longitude=1,latitude=1) for n in separate['nodes']))

    def test_boundary_connection_and_direction(self):
        a=dict(minLongitude=0,maxLongitude=1,minLatitude=0,maxLatitude=1)
        b=dict(a,minLongitude=1,maxLongitude=2)
        f=feature([[.5,.5],[1.5,.5]],[123,456])
        ga=routing([f],a,FlatSurface());gb=routing([f],b,FlatSurface())
        shared=set(n['id'] for n in ga['nodes']) & set(n['id'] for n in gb['nodes'])
        self.assertEqual(len(shared),1)
        f['route'].update(bidirectional=False,reverse=True)
        reverse=routing([f],a,FlatSurface())
        self.assertEqual(reverse['edges'][0]['from'],ga['edges'][0]['to'])
        self.assertFalse(reverse['edges'][0]['bidirectional'])

    def test_dateline_multipolygon_does_not_schedule_the_ocean(self):
        from shapely.geometry import box,MultiPolygon,mapping
        f=dict(properties=dict(id='test'),geometry=mapping(MultiPolygon([box(179.7,-44,179.99,-43.7),box(-179.99,-44,-179.7,-43.7)])))
        jobs,border=cells(f)
        self.assertGreater(len(jobs),0)
        self.assertTrue(all(x>4090 or x<5 for x,y,b in jobs))
        self.assertLess(len(jobs)+border,100)

    def test_land_mask_excludes_sea_and_defers_coastal_tiles(self):
        from shapely.geometry import box,mapping
        from land import Land
        f=dict(properties=dict(id='test'),geometry=mapping(box(6.9,45.9,7.5,46.5)))
        land=Land([box(7,46,7.4,46.4)])
        jobs,border=cells(f,land)
        self.assertGreater(len(jobs),0)
        self.assertGreater(border,0)
        for x,y,b in jobs:
            self.assertTrue(land.covers(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])))

    def test_disk_guard(self):
        with patch('common.shutil.disk_usage') as disk:
            disk.return_value.free=39*1024**3
            with self.assertRaises(DiskReserveError):reserve('.')

    def test_high_altitude_codec_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp);bins=toolchain(tmp/'bin')
            grid=np.full((513,513),8850.)+np.linspace(0,5,513)[None,:]
            raw,offset=quantize(grid);(tmp/'height').write_bytes(raw.tobytes())
            stats=json.loads(subprocess.check_output([str(bins/'park_mesh'),str(tmp/'height'),str(tmp/'mesh'),'.5']))
            decoded=bytearray((tmp/'mesh').read_bytes());struct.pack_into('<f',decoded,24,offset)
            codec=CompactCodec(bins/'libridge_compact_mesh.dylib');result=codec.decode(codec.encode(bytes(decoded)))
            self.assertEqual(bytes(decoded),result)
            count=struct.unpack_from('<I',result,4)[0]
            altitudes=[struct.unpack_from('<h',result,28+i*6+4)[0]*.1+struct.unpack_from('<f',result,24)[0] for i in range(count)]
            self.assertGreater(min(altitudes),8800)
            self.assertLessEqual(stats['maxErrorMetres'],.5)

    def test_osm_index_preserves_inner_rings_and_node_ids(self):
        from osm_index import make_index,query
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            positions=[(0,0),(2,0),(2,2),(0,2),(.5,.5),(1.5,.5),(1.5,1.5),(.5,1.5)]
            xml='<osm version="0.6">'+''.join(f'<node id="{i+1}" lon="{x}" lat="{y}"/>' for i,(x,y) in enumerate(positions))
            for ident,ids,tags in [(10,[1,2,3,4,1],''),(11,[5,6,7,8,5],''),(12,[1,5,7],'<tag k="highway" v="path"/><tag k="foot" v="private"/>')]:
                xml+=f'<way id="{ident}">'+''.join(f'<nd ref="{i}"/>' for i in ids)+tags+'</way>'
            xml+='<relation id="20"><member type="way" ref="10" role="outer"/><member type="way" ref="11" role="inner"/><tag k="type" v="multipolygon"/><tag k="landuse" v="forest"/></relation></osm>'
            (root/'map.osm').write_text(xml)
            make_index(root/'map.osm',root/'map.sqlite',reserve_gib=0)
            features=query(root/'map.sqlite',dict(minLongitude=0,maxLongitude=2,minLatitude=0,maxLatitude=2))
            forest=next(f for f in features if f['kind']=='woodland')
            self.assertEqual(len(forest['geometry']['coordinates']),2)
            route=next(f for f in features if 'route' in f)
            self.assertEqual(route['route']['nodes'],[1,5,7])
            self.assertEqual(route['properties']['access'],'private')

    def test_adjacent_surface_samples(self):
        # Small synthetic COGs verify alignment without network or external drive.
        import rasterio
        from rasterio.transform import from_origin
        step=1/3600
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'synthetic.tif'
            with rasterio.open(path,'w',driver='GTiff',height=400,width=800,count=1,dtype='float32',crs='EPSG:4326',transform=from_origin(7,46.1,step,step)) as ds:
                data=np.sin(np.arange(800)[None,:]/20)*20+np.arange(400)[:,None]+3000
                ds.write(data.astype('float32'),1)
            a=dict(minLongitude=7.01,maxLongitude=7.091234,minLatitude=46.02,maxLatitude=46.09)
            b=dict(a,minLongitude=a['maxLongitude'],maxLongitude=7.19)
            with patch('terrain.download',return_value=path):
                sa=Surface(a,tmp);sb=Surface(b,tmp)
            lat=np.linspace(46.02,46.09,50)
            np.testing.assert_allclose(sa.sample(a['maxLongitude'],lat),sb.sample(b['minLongitude'],lat),atol=.001)

if __name__=='__main__':unittest.main()
