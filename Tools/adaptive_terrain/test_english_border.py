import unittest
from shapely.geometry import box
from prepare_english_border import missing_candidates,validate_response
import numpy as np
from rasterio.io import MemoryFile
from rasterio.transform import from_origin
from rasterio.errors import RasterioIOError


class Footprints:
    def __init__(self,geometry,margin=0):self.geometry=geometry;self.margin=margin
    def for_bounds(self,bounds):return self.geometry
    def envelope(self,b):return box(b['minLongitude']-self.margin,b['minLatitude']-self.margin,b['maxLongitude']+self.margin,b['maxLatitude']+self.margin)


class BorderSelectionTests(unittest.TestCase):
    row=dict(id='z10-x504-y336',bounds=dict(minLongitude=0,maxLongitude=48,minLatitude=0,maxLatitude=48))

    def test_missing_welsh_input_can_use_verified_english_footprint(self):
        # An overlapping country-selection rectangle must not hide the English
        # survey: acceptance depends on the actual native-child footprint.
        found=missing_candidates(self.row,set(),Footprints(box(24,24,26,26)),box(0,0,48,48),[])
        self.assertEqual({(c['parentX']*4+c['childX'],c['parentY']*4+c['childY']) for c in found},{(24,22),(25,22),(24,23),(25,23)})

    def test_existing_terrain_and_explicit_owner_are_preserved(self):
        selected={'z10-x504-y336-c06-05-p00-02'}
        found=missing_candidates(self.row,selected,Footprints(box(24,24,26,26)),box(0,0,48,48),[box(25.1,24.1,25.9,24.9)])
        self.assertEqual(len(found),2)
        self.assertNotIn(next(iter(selected)),{c['id'] for c in found})

    def test_intersection_without_full_interpolation_support_is_rejected(self):
        found=missing_candidates(self.row,set(),Footprints(box(24,24,26,26),margin=.01),box(0,0,48,48),[])
        self.assertEqual(found,[])

    def test_complete_header_does_not_admit_a_truncated_raster(self):
        with MemoryFile() as mem:
            with mem.open(driver='GTiff',width=64,height=64,count=1,dtype='float32',crs='EPSG:27700',transform=from_origin(300000,300000,1,1),tiled=True,blockxsize=16,blockysize=16) as ds:
                ds.write(np.arange(4096,dtype=np.float32).reshape(64,64),1)
            data=mem.read()
        validate_response(data)
        with self.assertRaises(RasterioIOError):validate_response(data[:len(data)//2])


if __name__=='__main__':unittest.main()
