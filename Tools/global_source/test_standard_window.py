"""Interrupted receipt writes reuse completed satellite windows."""
import hashlib,json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'world_source'))
import batch_ground_colour as colour

class WindowRecoveryTests(unittest.TestCase):
    def test_completed_window_reuses_data_and_rebuilds_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);parent='world-test';bounds=[-1,50,0,51];width,height=2,3
            item=dict(id='scene',assets=dict(visual=dict(href='https://example.invalid/rgb.tif'),scl=dict(href='https://example.invalid/scl.tif')))
            identity=hashlib.sha256(colour.raw([item['id'],item['assets']['visual']['href'],item['assets']['scl']['href'],bounds,width,height,'full-UK-VRT-exact-v1'])).hexdigest()
            file=root/'windows'/parent/('scene-'+identity[:12]+'.npz');file.parent.mkdir(parents=True)
            rgb=np.ones((height,width,3),np.uint8)*80;scl=np.ones((height,width),np.uint8)*4;valid=np.ones((height,width),bool)
            np.savez_compressed(file,rgb=rgb,scl=scl,valid=valid)
            with patch.object(colour.rasterio,'open',side_effect=AssertionError('Cached data must avoid network reads')):
                values=colour.window(root,parent,item,bounds,width,height,None,full_uk=True)
                np.testing.assert_array_equal(values[0],rgb)
                receipt=json.loads(file.with_suffix('.json').read_bytes());self.assertTrue(receipt['receiptRecovered'])
                self.assertEqual(receipt['sha256'],hashlib.sha256(file.read_bytes()).hexdigest())
                colour.window(root,parent,item,bounds,width,height,None,full_uk=True)
                receipt['sha256']='0'*64;file.with_suffix('.json').write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError,'checksum mismatch'):colour.window(root,parent,item,bounds,width,height,None,full_uk=True)

if __name__=='__main__':unittest.main()
