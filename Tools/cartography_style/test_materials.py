import unittest
import numpy as np
from materials import noise, render

class MaterialTests(unittest.TestCase):
    def test_world_noise_is_independent_of_tile_extent(self):
        x=np.linspace(-270000,-269900,33)[None,:]
        y=np.linspace(5900000,5900100,33)[:,None]
        whole=noise(x,y,14,23)
        np.testing.assert_array_equal(whole[:,16:],noise(x[:,16:],y,14,23))
        np.testing.assert_array_equal(whole[16:,:],noise(x,y[16:,:],14,23))
        self.assertTrue(np.all((whole>=0)&(whole<=1)))

    def test_material_pass_preserves_input_heights_and_repeats(self):
        b=dict(minLongitude=-4.01,maxLongitude=-4,minLatitude=53,maxLatitude=53.01)
        heights=np.arange(17*17,dtype=np.int16).reshape(17,17)+5000
        saved=heights.copy()
        one=render([],heights,b,side=64)
        two=render([],heights,b,side=64)
        self.assertEqual(one.tobytes(),two.tobytes())
        np.testing.assert_array_equal(saved,heights)

if __name__=='__main__':unittest.main()
