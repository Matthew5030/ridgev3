import hashlib,json,tempfile,unittest,zlib
from pathlib import Path
import numpy as np
import rasterio
from rasterio.transform import from_origin
from standard_terrain import Boundaries,Surface,Compiler,build_compiler,key,bounds,plan

class StandardTests(unittest.TestCase):
    def test_transition_keeps_lidar_edge_and_shared_standard_edges(self):
        boundary=Boundaries.__new__(Boundaries);boundary.conflicts=set();boundary.edges={};boundary.corners={}
        x,y=np.meshgrid(np.arange(513),np.arange(513));base=100+y*.03+x*.04
        old=np.rint(base[:,0]*10).astype(np.int32)+100
        boundary.edges[key(9,20)]=np.array([old,old,old,old]);boundary.corners={key(10,20):int(old[0]),key(10,21):int(old[-1]),key(11,20):int(round(base[0,-1]*10))+30}
        a,correction=boundary.constrain(base,key(10,20));b,_=boundary.constrain(base+512*.04,key(11,20))
        np.testing.assert_array_equal(a[:,0],old);np.testing.assert_array_equal(a[:,-1],b[:,0]);self.assertGreater(correction,0)
        boundary.conflicts={key(10,20)}
        with self.assertRaisesRegex(ValueError,'corner heights conflict'):boundary.constrain(base,key(10,20))

    def test_canonical_surface_applies_geoid_difference_and_is_window_independent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'geoid-grids').mkdir();step=1/3600
            data=np.arange(1024,dtype='float32')[None,:]*.02+np.arange(1024,dtype='float32')[:,None]*.01+100
            with rasterio.open(root/'dem.vrt','w',driver='GTiff',width=1024,height=1024,count=1,dtype='float32',crs='EPSG:4326',transform=from_origin(-12,64,step,step)) as ds:ds.write(data,1)
            for name,height in [('us_nga_egm08_25.tif',45),('us_nga_egm96_15.tif',44)]:
                with rasterio.open(root/'geoid-grids'/name,'w',driver='GTiff',width=20,height=20,count=1,dtype='float32',crs='EPSG:4326',transform=from_origin(-13,65,1,1)) as ds:ds.write(np.full((20,20),height,dtype='float32'),1)
            a=Surface(root);b=Surface(root);lon=np.linspace(-11.99,-11.8,80);lat=np.full(80,63.9)
            expected=a.sample(lon,lat);b.sample(-11.95,63.95);np.testing.assert_array_equal(expected,b.sample(lon,lat))
            self.assertAlmostEqual(float(a.sample(-12+100.5*step,64-200.5*step)),float(data[200,100])+1,places=6)

    def test_planning_fills_land_gaps_and_does_not_relabel_existing_tiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);world=root/'live';world.mkdir();b=bounds(497,314,0,0,16);gap=bounds(497,314,0,0,1)
            ident='world-z10-x497-y314-c00-r00';entry=dict(id=ident,bounds=b,tileCount=255,missingTerrain=[gap]);(world/'catalog.json').write_text(json.dumps(dict(sources=[entry])))
            ring=[[gap['minLongitude'],gap['minLatitude']],[gap['maxLongitude'],gap['minLatitude']],[gap['maxLongitude'],gap['maxLatitude']],[gap['minLongitude'],gap['maxLatitude']],[gap['minLongitude'],gap['minLatitude']]]
            zones=root/'zones.json';zones.write_text(json.dumps(dict(regions=[dict(name='test',mapShapes=[dict(rings=[ring])],cells=[dict(id=ident,bounds=b)])])))
            result=plan(world,zones,root/'work');self.assertEqual(result['newNativeCells'],1);self.assertEqual(result['parents'][0]['sources'][0]['newCells'],[[0,0]])

    def test_shared_compiler_matches_frozen_pre_rollout_binary(self):
        # Hashes were measured from the previously published CLI compiler,
        # independently of the new process-local interface.
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);build_compiler(root);compiler=Compiler(root);x,y=np.meshgrid(np.arange(513),np.arange(513));grid=(4000+(x*x+y*y+x*y)//320).astype('<i2')
            for tolerance,native,expected in [(.5,True,'f90740ac2a3aef5544dd5e31cc07ad2863d4643c35d777aebfcff0480367384f'),(2,False,'eba7b3292498b41d90eeff09e424fbae939a2edea2ba7949a504320166d1c221')]:
                packed,_=compiler.compile(grid,tolerance,native);decoded=compiler.codec.decode(zlib.decompress(packed));self.assertEqual(hashlib.sha256(decoded).hexdigest(),expected)

if __name__=='__main__':unittest.main()
