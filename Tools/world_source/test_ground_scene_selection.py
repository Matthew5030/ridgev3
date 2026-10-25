import unittest
from batch_ground_colour import choose_scenes

class SelectionTests(unittest.TestCase):
    def test_clear_slivers_do_not_displace_full_footprints(self):
        region=dict(bounds=dict(minLongitude=-3,minLatitude=55,maxLongitude=-2,maxLatitude=56))
        def item(name,date,nodata,cloud):
            return dict(id=name,bbox=[-3,55,-2,56],properties={'mgrs:utm_zone':30,'mgrs:latitude_band':'U','mgrs:grid_square':'WG','datetime':date+'T00:00:00Z','s2:nodata_pixel_percentage':nodata,'eo:cloud_cover':cloud})
        items=[item('sliver','2025-07-12',96,0),item('full-a','2025-08-13',0,6),item('full-b','2025-05-13',0,5),item('full-c','2025-07-07',0,12)]
        result=choose_scenes(items,[region])
        self.assertEqual({x['item']['id'] for x in result},{'full-a','full-b','full-c'})
    def test_acquisition_dates_are_distinct(self):
        region=dict(bounds=dict(minLongitude=-3,minLatitude=55,maxLongitude=-2,maxLatitude=56))
        items=[dict(id=str(i),bbox=[-3,55,-2,56],properties={'mgrs:utm_zone':30,'mgrs:latitude_band':'U','mgrs:grid_square':'WG','datetime':'2025-07-12T00:00:00Z','s2:nodata_pixel_percentage':0,'eo:cloud_cover':i}) for i in range(5)]
        self.assertEqual(len(choose_scenes(items,[region])),1)

if __name__=='__main__':unittest.main()
