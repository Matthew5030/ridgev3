#!/usr/bin/env python3
"""Verify shadow study invariants and produce matched remote-review screenshots."""
import argparse,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('study',type=Path);a=p.parse_args()
s=json.loads((a.source/'source.json').read_text());r=json.loads((a.study/'shadow-study.json').read_text())
assert s['verticesSHA256']==r['verticesSHA256'] and s['indicesSHA256']==r['indicesSHA256']
results={}
for view in ('close','wide'):
    baseline=np.asarray(Image.open(a.study/f'{view}-baseline.png').convert('RGB'))
    original=np.asarray(Image.open(a.source/f'{view}-astc.png').convert('RGB'))
    assert np.array_equal(baseline,original),'Baseline pixels changed'
    contrast=np.asarray(Image.open(a.study/f'{view}-contrast.png').convert('RGB'),dtype=np.int16)
    shadows=np.asarray(Image.open(a.study/f'{view}-shadows.png').convert('RGB'),dtype=np.int16)
    delta=contrast-shadows
    assert delta.min()>=0,'Shadow pass brightened a pixel'
    assert np.count_nonzero(delta)>0,'No shadow effect was rendered'
    results[view]=dict(baselineReproducedExactly=True,maxShadowDarkening=int(delta.max()),meanChannelDarkening=float(delta.mean()),pixelsDarkenedOver5=int(np.sum(delta.max(axis=2)>5)))
depth=np.fromfile(a.study/'shadow-depth.f32',dtype='<f4')
assert depth.size==r['shadowSize']**2 and np.isfinite(depth).all() and depth.min()>=0 and depth.max()<=1
assert 0<np.mean(depth<1)<1,'Shadow map missing terrain or background'
results['depthCoverageFraction']=float(np.mean(depth<1))
(a.study/'verification.json').write_text(json.dumps(results,indent=2)+'\n')
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',26)
comparison=Image.new('RGB',(1300,2145),'#f5f3ec');d=ImageDraw.Draw(comparison)
for i,(case,label) in enumerate([('baseline','1 · CURRENT LIGHTING'),('contrast','2 · STRONGER SUNLIGHT / CONTRAST'),('shadows','3 · STRONGER SUNLIGHT + SOFT CAST SHADOWS')]):
    y=i*715;d.text((22,y+14),label,font=font,fill='#254e40')
    comparison.paste(Image.open(a.study/f'close-{case}.png').convert('RGB').crop((80,285,1380,935)),(0,y+55))
comparison.save(a.study/'lighting-comparison.jpg',quality=95)
print(json.dumps(results,indent=2))
