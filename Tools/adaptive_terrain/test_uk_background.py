import gzip,hashlib,tempfile,unittest
from pathlib import Path
import numpy as np
from build_uk_background import Sampler

class BackgroundTests(unittest.TestCase):
    def setUp(self):
        t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);self.root=Path(t.name);self.entries=[]
        for east in [0,1]:
            lon=east+np.arange(3)/2;lat=1-np.arange(3)/2;xx,yy=np.meshgrid(lon,lat);h=(100+10*xx+20*yy).astype('>i2')
            key=f'N00E{east:03d}';raw=gzip.compress(h.tobytes());(self.root/(key+'.hgt.gz')).write_bytes(raw)
            self.entries.append(dict(tile=key,path=key+'.hgt.gz',samplesPerSide=3,sizeBytes=len(raw),sha256=hashlib.sha256(raw).hexdigest()))
    def test_bilinear_plane_and_mask(self):
        s=Sampler(self.root,self.entries);x=np.array([.25,.75,1.25]);y=np.array([.25,.25,.25]);z=s.sample(x,y,np.array([True,False,True]))
        self.assertEqual(z[0],107.5);self.assertTrue(np.isnan(z[1]));self.assertEqual(z[2],117.5)
    def test_one_degree_seam_uses_same_source_from_either_window(self):
        s=Sampler(self.root,self.entries)
        a=s.sample(np.array([.7,1.0]),np.array([.25,.25]),np.array([True,True]))
        b=s.sample(np.array([1.0,1.3]),np.array([.25,.25]),np.array([True,True]))
        self.assertEqual(a[1],b[0]);self.assertEqual(a[1],115)
    def test_corrupt_source_is_refused(self):
        p=self.root/self.entries[0]['path'];raw=p.read_bytes();p.write_bytes(bytes([raw[0]^1])+raw[1:])
        with self.assertRaisesRegex(ValueError,'checksum'):Sampler(self.root,self.entries).tile(0,0)
    def test_nodata_is_not_filled(self):
        e=self.entries[0];p=self.root/e['path'];h=np.frombuffer(gzip.decompress(p.read_bytes()),dtype='>i2').copy();h[4]=-32768;raw=gzip.compress(h.tobytes());p.write_bytes(raw);e.update(sizeBytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        z=Sampler(self.root,self.entries).sample(np.array([.25]),np.array([.25]),np.array([True]));self.assertTrue(np.isnan(z[0]))

if __name__=='__main__':unittest.main()
