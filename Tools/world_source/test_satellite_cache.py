import hashlib, io, json, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
from cache_satellite_scenes import fetch

class Response(io.BytesIO):
    def __init__(self,data,status=200,headers=None):
        super().__init__(data);self.status=status;self.headers=headers or {'ETag':'"stable"'}

class CacheTests(unittest.TestCase):
    def test_completed_cache_never_requests_network(self):
        with tempfile.TemporaryDirectory() as folder:
            cache=Path(folder);asset=dict(id='scene',kind='visual',url='https://example.test/image.tif',bytes=8)
            with patch('urllib.request.urlopen',return_value=Response(b'12345678')):record=fetch(asset,cache)
            with patch('urllib.request.urlopen',side_effect=AssertionError('redownload')):again=fetch(asset,cache)
            self.assertEqual(record,again);self.assertEqual(record['sha256'],hashlib.sha256(b'12345678').hexdigest())
    def test_partial_download_resumes_without_duplicate_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            cache=Path(folder);(cache/'assets').mkdir();(cache/'assets/scene-visual.part').write_bytes(b'1234')
            asset=dict(id='scene',kind='visual',url='https://example.test/image.tif',bytes=8)
            def read(request,**kwargs):
                self.assertEqual(request.headers['Range'],'bytes=4-')
                return Response(b'5678',206,{'Content-Range':'bytes 4-7/8','ETag':'"stable"'})
            with patch('urllib.request.urlopen',side_effect=read):fetch(asset,cache)
            self.assertEqual((cache/'assets/scene-visual.tif').read_bytes(),b'12345678')
    def test_completed_partial_is_recovered_without_network(self):
        with tempfile.TemporaryDirectory() as folder:
            cache=Path(folder);(cache/'assets').mkdir();(cache/'assets/scene-visual.part').write_bytes(b'12345678')
            asset=dict(id='scene',kind='visual',url='https://example.test/image.tif',bytes=8)
            with patch('urllib.request.urlopen',side_effect=AssertionError('redownload')):fetch(asset,cache)
            self.assertTrue((cache/'assets/scene-visual.tif').exists())
    def test_changed_server_object_replaces_partial_instead_of_appending(self):
        with tempfile.TemporaryDirectory() as folder:
            cache=Path(folder);(cache/'assets').mkdir();(cache/'assets/scene-visual.part').write_bytes(b'OLD!')
            asset=dict(id='scene',kind='visual',url='https://example.test/image.tif',bytes=8)
            with patch('urllib.request.urlopen',return_value=Response(b'12345678')):fetch(asset,cache)
            self.assertEqual((cache/'assets/scene-visual.tif').read_bytes(),b'12345678')
            self.assertEqual((cache/'assets/scene-visual.previous-part').read_bytes(),b'OLD!')

if __name__=='__main__':unittest.main()
