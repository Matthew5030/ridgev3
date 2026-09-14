#!/usr/bin/env python3
import hashlib
import io
import json
from unittest.mock import patch
from pathlib import Path
import tempfile
import unittest
import numpy as np
import rasterio
from rasterio.transform import from_origin
from prepare_scottish_sources import inspect_sources,make_mosaic,sample_projected
from scottish_dtm import footprint, download_file


class ScottishInputTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='ridge-scottish-test-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)

    def raster(self,name,left,top,width,height,res=1,extra=0,hole=None):
        x=left+(np.arange(width)+.5)*res;y=top-(np.arange(height)+.5)*res
        xx,yy=np.meshgrid(x,y);data=(2*xx+3*yy+extra).astype('float32')
        if hole:data[hole]=-9999
        path=self.root/name
        with rasterio.open(path,'w',driver='GTiff',width=width,height=height,count=1,dtype='float32',
                crs='EPSG:27700',transform=from_origin(left,top,res,res),nodata=-9999) as ds:ds.write(data,1)
        return dict(path=str(path),key='lidar/phase-1/dtm/'+name,byteCount=path.stat().st_size,
                    sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    def test_adjacent_rasters_interpolate_without_a_false_seam(self):
        records=inspect_sources([self.raster('left.tif',0,16,16,16),self.raster('right.tif',16,16,16,16)])
        vrt=self.root/'joined.vrt';make_mosaic(records,vrt)
        x=np.array([15.75,16,16.25]);y=np.array([8.25,8.25,8.25])
        with rasterio.open(vrt) as ds:z,valid=sample_projected(ds,x,y)
        self.assertTrue(valid.all());np.testing.assert_allclose(z,2*x+3*y,atol=1e-5)

    def test_missing_samples_stay_missing(self):
        record=self.raster('hole.tif',0,16,16,16,hole=(8,8))
        vrt=self.root/'hole.vrt';make_mosaic(inspect_sources([record]),vrt)
        with rasterio.open(vrt) as ds:z,valid=sample_projected(ds,np.array([8.75]),np.array([7.75]))
        self.assertFalse(valid.all())

    def test_nominal_one_metre_georeferencing_roundoff(self):
        records=inspect_sources([self.raster('rounded.tif',0,16,16,16,res=1.0000036)])
        self.assertEqual(len(records),1)
        with self.assertRaisesRegex(ValueError,'coarser'):
            inspect_sources([self.raster('not-one-metre.tif',0,16,16,16,res=1.001)])

    def test_finer_source_wins_and_coarse_inputs_are_refused(self):
        records=inspect_sources([self.raster('base.tif',0,16,16,16),self.raster('fine.tif',8,12,8,8,res=.5,extra=10)])
        vrt=self.root/'mixed.vrt';make_mosaic(records,vrt)
        x=np.array([4.5,9.5]);y=np.array([4.5,10.5])
        with rasterio.open(vrt) as ds:z,valid=sample_projected(ds,x,y)
        self.assertTrue(valid.all());np.testing.assert_allclose(z,2*x+3*y+np.array([0,10]),atol=1e-5)
        with self.assertRaisesRegex(ValueError,'coarser'):
            inspect_sources([self.raster('coarse.tif',0,16,8,8,res=2)])

    def test_same_coordinate_is_identical_in_different_chunk_windows(self):
        # Historic raster spacing makes GDAL's bilinear VRT result sensitive
        # to the requested window. Shared samples must remain bit-identical.
        record=self.raster('rounded-large.tif',0,1024,1024,1024,res=1.0000036)
        vrt=self.root/'rounded-large.vrt';make_mosaic(inspect_sources([record]),vrt)
        with rasterio.open(vrt) as ds:
            a,valid_a=sample_projected(ds,np.array([111.123,512.345]),np.array([713.234,511.234]))
            b,valid_b=sample_projected(ds,np.array([512.345,901.456]),np.array([511.234,201.234]))
        self.assertTrue(valid_a.all() and valid_b.all())
        self.assertEqual(a[1],b[0])

    def test_grid_footprints_and_quadrants(self):
        self.assertEqual(footprint('NN00_1M_DTM.tif').bounds,(200000,700000,210000,710000))
        self.assertEqual(footprint('NN00NE_1M_DTM.tif').bounds,(205000,705000,210000,710000))
        self.assertEqual(footprint('NN1234_50CM_DTM.tif').bounds,(212000,734000,213000,735000))
        self.assertIsNone(footprint('not-a-grid.tif'))

    def test_download_resume_rechecks_bytes_and_changed_objects_are_refused(self):
        entry=dict(key='lidar/phase-1/dtm/NN00_1M_DTM.tif',byteCount=4,etag='"known"')
        def response(data=b'data',etag='"known"'):
            stream=io.BytesIO(data);stream.headers={'ETag':etag};return stream
        with patch('scottish_dtm.urllib.request.urlopen',return_value=response()) as request:
            first=download_file(entry,self.root)
            self.assertEqual(request.call_args.args[0].get_header('If-match'),'"known"')
        with patch('scottish_dtm.urllib.request.urlopen',side_effect=AssertionError('Unexpected network')):
            self.assertEqual(download_file(entry,self.root)['sha256'],first['sha256'])
        Path(first['path']).write_bytes(b'FAIL')
        with patch('scottish_dtm.urllib.request.urlopen',return_value=response()):
            second=download_file(entry,self.root)
        self.assertEqual(Path(second['path']).read_bytes(),b'data')
        Path(second['path']).write_bytes(b'FAIL')
        with patch('scottish_dtm.urllib.request.urlopen',return_value=response(etag='"changed"')):
            with self.assertRaisesRegex(ValueError,'Source object changed'):
                download_file(entry,self.root)


if __name__=='__main__':unittest.main()
