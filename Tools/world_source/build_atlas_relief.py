#!/usr/bin/env python3
"""Prepare lightweight UK overview elevation bands as vectors, never live tiles.
Requires numpy, Pillow and contourpy. The app retains only derived vector rings.
Source: Mapzen Terrain Tiles via AWS Open Data; see atlas source credits.
"""
import argparse,concurrent.futures,hashlib,json,math,urllib.request
from pathlib import Path
import numpy as np
import contourpy
from PIL import Image
p=argparse.ArgumentParser();p.add_argument('--cache',type=Path,required=True);p.add_argument('--atlas',type=Path,required=True);a=p.parse_args();a.cache.mkdir(parents=True,exist_ok=True)
z=6;n=2**z
x0=math.floor((-12+180)/360*n);x1=math.floor((3+180)/360*n)
def tile_y(lat):return math.floor((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n)
y0=tile_y(61);y1=tile_y(49)
height=np.zeros(((y1-y0+1)*256,(x1-x0+1)*256))
provenance=[]
def fetch(xy):
 x,y=xy;path=a.cache/f'{z}-{x}-{y}.png';url=f'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png'
 if not path.exists():
  with urllib.request.urlopen(url,timeout=30) as response:path.write_bytes(response.read())
 rgb=np.asarray(Image.open(path).convert('RGB'),dtype=float)
 return x,y,rgb[:,:,0]*256+rgb[:,:,1]+rgb[:,:,2]/256-32768,dict(url=url,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
 for x,y,h,source in pool.map(fetch,[(x,y) for y in range(y0,y1+1) for x in range(x0,x1+1)]):
  height[(y-y0)*256:(y-y0+1)*256,(x-x0)*256:(x-x0+1)*256]=h;provenance.append(source)
lons=(np.arange(height.shape[1])+x0*256+.5)/(n*256)*360-180
lats=np.degrees(np.arctan(np.sinh(math.pi*(1-2*(np.arange(height.shape[0])+y0*256+.5)/(n*256)))))
# Smooth a single overview grid over two samples. This is cartographic context,
# not the fine elevation field used by 3D routing or terrain rendering.
for _ in range(2):
 padded=np.pad(height,1,mode='edge')
 height=(padded[1:-1,1:-1]*4+padded[:-2,1:-1]+padded[2:,1:-1]+padded[1:-1,:-2]+padded[1:-1,2:])/8
cg=contourpy.contour_generator(x=lons,y=lats,z=height,fill_type='OuterOffset')
features=[]
for level in [150,300,500,750,1000,1500,2500]:
 points,offsets=cg.filled(level,9000)
 for polygon,offset in zip(points,offsets):
  rings=[]
  for start,end in zip(offset,offset[1:]):
   ring=polygon[start:end]
   # Keep all contour intersections rounded to ~10 m; no invented geography.
   rings.append([[round(float(x),4),round(float(y),4)] for x,y in ring])
  if len(rings[0])<4:continue
  xs,ys=polygon[:,0],polygon[:,1]
  features.append(dict(kind=f'elevation{level}',name='',rings=rings,bounds=dict(minLatitude=float(ys.min()),maxLatitude=float(ys.max()),minLongitude=float(xs.min()),maxLongitude=float(xs.max()))))
atlas=json.loads(a.atlas.read_bytes());atlas['physicalFeatures']=[f for f in atlas.get('physicalFeatures',[]) if not f['kind'].startswith('elevation')]+features
atlas['physicalFeatures'].sort(key=lambda f:0 if f['kind'].startswith('elevation') else 1)
a.atlas.write_text(json.dumps(atlas,separators=(',',':'))+'\n')
(a.cache/'relief-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
print(f'{len(features)} elevation polygons; {len(provenance)} source tiles; atlas {a.atlas.stat().st_size:,} bytes')
