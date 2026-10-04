#!/usr/bin/env python3
"""Real page/edge/resume checks with an independent analytic height fixture."""
import json,tempfile,zlib
from pathlib import Path
import numpy as np
from PIL import Image
from build import Builder,sha

def main():
    with tempfile.TemporaryDirectory() as temporary:
        root=Path(temporary);parts=[]
        for x in (500,501):
            # Matching shared edges, sloping smoothly east with no tile reset.
            h=np.tile(np.arange(513)+(x-500)*512+1000,(513,1)).astype('<i2')
            raw=h.tobytes();compressed=zlib.compress(raw);name=f'z10-x{x}-y333.height.zlib';(root/name).write_bytes(compressed)
            def latitude(y):return float(np.degrees(np.arctan(np.sinh(np.pi*(1-2*y/1024)))))
            parts.append(dict(id=f'z10-x{x}-y333',path=name,byteCount=len(compressed),sha256=sha(compressed),decodedSHA256=sha(raw),bounds=dict(minLongitude=x/1024*360-180,maxLongitude=(x+1)/1024*360-180,maxLatitude=latitude(333),minLatitude=latitude(334))))
        background=root/'background.json';background.write_text(json.dumps(dict(partitions=parts)))
        atlas=root/'atlas.json';atlas.write_text(json.dumps(dict(land=[[[-10,49],[2,49],[2,61],[-10,61],[-10,49]]])))
        style=root/'style.swift';style.write_text('0xede9d9 0xa8cbd1')
        output=root/'out';output.mkdir();builder=Builder(background,atlas,style,output)
        left=builder.sample(500,333)[0];right=builder.sample(501,333)[0]
        assert np.allclose(left[:,256:],right[:,:8],atol=1e-10), 'Neighbour sample gutters differ'
        builder.leaf(500,333);page=output/'z10-x500-y333.jpg';original=page.read_bytes()
        with Image.open(page) as im: assert im.size==(256,256) and im.mode=='RGB'
        builder.leaf(500,333);assert page.read_bytes()==original, 'Resume changed a completed page'
        page.write_bytes(b'corrupt');builder.leaf(500,333);assert page.read_bytes()==original,'Corruption was not repaired'
        (root/parts[1]['path']).write_bytes(b'bad height');builder.height.cache_clear()
        try:builder.sample(501,333)
        except ValueError:pass
        else:raise AssertionError('Damaged source was accepted')
        print('PASS: shared global samples, image format, unchanged resume, repaired checkpoint, rejected corrupt source')
if __name__=='__main__':main()
