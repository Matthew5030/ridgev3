import unittest
import numpy as np
from illustrated import render

class IllustratedTests(unittest.TestCase):
    def test_uniform_matte_has_no_noise_and_preserves_elevation(self):
        h=np.full((17,17),5000,dtype=np.int16);before=h.copy()
        bounds=dict(minLongitude=-4.01,maxLongitude=-4,minLatitude=53,maxLatitude=53.01)
        image=render([],h,bounds,side=64)
        self.assertEqual(np.unique(np.asarray(image).reshape(-1,3),axis=0).shape[0],1)
        self.assertEqual(image.tobytes(),render([],h,bounds,side=64).tobytes())
        np.testing.assert_array_equal(before,h)

if __name__=='__main__':unittest.main()
