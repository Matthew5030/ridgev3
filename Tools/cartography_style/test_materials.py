import unittest
import numpy as np
from materials import noise, render, soft_weight
from PIL import Image

class MaterialTests(unittest.TestCase):
    def test_world_noise_is_independent_of_tile_extent(self):
        x=np.linspace(-270000,-269900,33)[None,:]
        y=np.linspace(5900000,5900100,33)[:,None]
        whole=noise(x,y,14,23)
        np.testing.assert_array_equal(whole[:,16:],noise(x[:,16:],y,14,23))
        np.testing.assert_array_equal(whole[16:,:],noise(x,y[16:,:],14,23))
        self.assertTrue(np.all((whole>=0)&(whole<=1)))

    def test_transition_is_bounded_and_complementary(self):
        mask=np.zeros((81,81),dtype='uint8');mask[:,:40]=255
        a=soft_weight(Image.fromarray(mask),1,np.full(mask.shape,.5))
        b=soft_weight(Image.fromarray(255-mask),1,np.full(mask.shape,.5))
        np.testing.assert_allclose(a+b,1,atol=1e-6)
        self.assertTrue(np.all(a[:,:27]==1))
        self.assertTrue(np.all(a[:,52:]==0))
        self.assertGreater(a[40,39],a[40,40])
        np.testing.assert_array_equal(mask[:,:40],255)

    def test_material_pass_preserves_input_heights_and_repeats(self):
        b=dict(minLongitude=-4.01,maxLongitude=-4,minLatitude=53,maxLatitude=53.01)
        heights=np.arange(17*17,dtype=np.int16).reshape(17,17)+5000
        saved=heights.copy()
        one=render([],heights,b,side=64)
        two=render([],heights,b,side=64)
        self.assertEqual(one.tobytes(),two.tobytes())
        np.testing.assert_array_equal(saved,heights)

if __name__=='__main__':unittest.main()
