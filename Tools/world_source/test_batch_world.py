import json, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import batch_world as batch

class BatchTests(unittest.TestCase):
    def test_grid_partition_alignment(self):
        bounds=dict(minLongitude=-5,maxLongitude=-4,minLatitude=52,maxLatitude=53)
        for y in range(48):
            for x in range(48):
                c=dict(id=f'z10-x500-y333-c{x//4:02d}-{y//4:02d}-p{x%4:02d}-{y%4:02d}')
                self.assertEqual(batch.cell(c),(x,y))
                parent=batch.subbounds(bounds,x//16*16,y//16*16,16)
                child=batch.subbounds(bounds,x,y,1)
                self.assertTrue(batch.contains(parent,child['minLongitude'],child['maxLatitude']))
    def test_verified_read_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'asset';p.write_bytes(b'original')
            self.assertEqual(batch.read_verified(p,batch.sha(b'original'),8),b'original')
            p.write_bytes(b'changed')
            with self.assertRaises(ValueError):batch.read_verified(p,batch.sha(b'original'))
    def test_unavailable_file_never_opened(self):
        with patch.object(batch,'resident',return_value=False):
            with self.assertRaises(FileNotFoundError):batch.read_verified(Path('/not-downloaded'),'',0)
    def test_atomic_replacement_preserves_parseable_json(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'status.json'
            batch.atomic(p,batch.rawjson(dict(ready=0)))
            batch.atomic(p,batch.rawjson(dict(ready=1)))
            self.assertEqual(json.loads(p.read_bytes()),dict(ready=1))
            self.assertFalse(p.with_name('status.json.tmp').exists())

if __name__=='__main__':unittest.main()
