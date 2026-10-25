#!/usr/bin/env python3
"""Prepare a small, immutable streaming source from retained original 1 m data."""
import argparse,json,gzip,zlib,hashlib,subprocess,struct,tempfile,concurrent.futures,math,shutil,sys
from pathlib import Path
import numpy as np
import contourpy
from shapely.geometry import shape,box,LineString
from shapely.ops import transform
p=argparse.ArgumentParser();p.add_argument('--pack',type=Path,required=True);p.add_argument('--map',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
if a.output.exists() and any(a.output.iterdir()):
 p.error('--output must be a new or empty directory; published sources are immutable')
a.output.mkdir(parents=True,exist_ok=True)
sha=lambda b:hashlib.sha256(b).hexdigest()
def rawjson(x):return json.dumps(x,separators=(',',':'),allow_nan=False).encode()
def asset(name,raw):
 (a.output/name).write_bytes(raw);return dict(file=name,byteCount=len(raw),sha256=sha(raw))
m=json.loads((a.pack/'pack.json').read_bytes());lod=next(l for l in m['levels'] if l['spacing']==1)
raw=(a.pack/lod['file']).read_bytes();assert sha(raw)==lod['sha256'];h=np.frombuffer(raw,dtype='<i2').reshape(lod['height'],lod['width'])
b=m['bounds'];width=math.radians(b['maxLongitude']-b['minLongitude'])*6371008.8*math.cos(math.radians((b['minLatitude']+b['maxLatitude'])/2));depth=math.radians(b['maxLatitude']-b['minLatitude'])*6371008.8
cols=(h.shape[1]-1)//512;rows=(h.shape[0]-1)//512
coarse=h[::8,::8].astype(float)*m['heightScale'];coarse=np.where(h[::8,::8]==m['noDataValue'],0,coarse)
coarse=np.round(coarse,1)
coarseAsset=asset('overview-8m.json',rawjson(dict(width=coarse.shape[1],height=coarse.shape[0],heights=coarse.ravel().tolist())))
graph=(a.pack/m['graphFile']).read_bytes();assert sha(graph)==m['graphSHA256'];graphAsset=asset('paths.json',graph)
features=[]
def project(x,y,z=None):return ((np.asarray(x)-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width,(b['maxLatitude']-np.asarray(y))/(b['maxLatitude']-b['minLatitude'])*depth)
for f in json.loads(a.map.read_bytes())['features']:
 g=shape(f['geometry'])
 if not g.intersects(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])) or g.geom_type=='Point':continue
 if not g.is_valid:g=g.buffer(0)
 features.append((f['kind'],transform(project,g)))
# Contours are joined and simplified once across the source, then clipped into
# tiles with a gutter. Dashed path phase currently restarts at a clipped edge;
# preserving source-distance phase is a follow-up for national publication.
cg=contourpy.contour_generator(x=np.linspace(0,width,h[::4,::4].shape[1]),y=np.linspace(0,depth,h[::4,::4].shape[0]),z=h[::4,::4].astype(float)*.1)
for level in range(10,math.ceil(h.max()*.1/10)*10,10):
 for points in cg.lines(level):features.append(('contourIndex' if level%50==0 else 'contour',LineString(points).simplify(.25)))
root=Path(__file__).resolve().parents[1]/'adaptive_terrain'
tmp=Path(tempfile.mkdtemp(prefix='ridge-world-'))
for name in ['park_mesh','compact_mesh']:subprocess.run(['clang++','-O3','-std=c++17',str(root/(name+'.cpp')),'-o',str(tmp/name)],check=True)
def tile(c,r):
 ident=f'c{c:02d}-r{r:02d}';grid=h[r*512:r*512+513,c*512:c*512+513]
 if np.any(grid==-32768):return None
 x0=c*width/cols;y0=r*depth/rows;w=width/cols;d=depth/rows;clip=box(x0-4,y0-4,x0+w+4,y0+d+4)
 def coords(cs):return [[round(x-x0,2),round(y-y0,2)] for x,y in cs]
 paths=[]
 def append(kind,g):
  if g.is_empty:return
  if g.geom_type=='Polygon':paths.append(dict(kind=kind,closed=True,rings=[coords(g.exterior.coords)]+[coords(q.coords) for q in g.interiors]))
  elif g.geom_type in ['LineString','LinearRing']:paths.append(dict(kind=kind,closed=False,rings=[coords(g.coords)]))
  elif hasattr(g,'geoms'):
   for part in g.geoms:append(kind,part)
 for kind,g in features:
  if g.intersects(clip):append(kind,g.intersection(clip))
 vector=rawjson(dict(width=w,height=d,paths=paths));vasset=asset(ident+'.map',zlib.compress(vector,9));vasset['decodedByteCount']=len(vector)
 src=tmp/(ident+'.bin');src.write_bytes(grid.tobytes());mesh=tmp/(ident+'.rmesh');topology=tmp/(ident+'.rat')
 facts=json.loads(subprocess.check_output([str(tmp/'park_mesh'),str(src),str(mesh)]));subprocess.run([str(tmp/'compact_mesh'),'encode',str(mesh),str(topology)],stdout=subprocess.DEVNULL,check=True)
 decoded=mesh.read_bytes();top=topology.read_bytes();compressed=zlib.compress(top,9);asset(ident+'.rat.zlib',compressed)
 bounds=dict(minLongitude=b['minLongitude']+(b['maxLongitude']-b['minLongitude'])*c/cols,maxLongitude=b['minLongitude']+(b['maxLongitude']-b['minLongitude'])*(c+1)/cols,maxLatitude=b['maxLatitude']-(b['maxLatitude']-b['minLatitude'])*r/rows,minLatitude=b['maxLatitude']-(b['maxLatitude']-b['minLatitude'])*(r+1)/rows)
 chunk=dict(id=ident,path=ident+'.rat.zlib',bounds=bounds,byteCount=len(compressed),sha256=sha(compressed),decodedByteCount=len(decoded),decodedSHA256=sha(decoded),vertices=facts['vertices'],triangles=facts['triangles'],indexWidth=facts['indexWidth'],topologyByteCount=len(top),topologySHA256=sha(top),maxErrorMetres=facts['maxErrorMetres'])
 print(ident,flush=True);return dict(id=ident,column=c,row=r,mesh=chunk,map=vasset)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:tiles=list(pool.map(lambda cr:tile(*cr),[(c,r) for r in range(rows) for c in range(cols)]))
manifest=dict(schemaVersion=1,id='world-snowdon',name='Snowdon & the Glyderau',revision='2026-10-04-v3',bounds=b,columns=cols,rows=rows,overview=coarseAsset,graph=graphAsset,tiles=[t for t in tiles if t],places=m['places'],sources=m['sources'],sourceTerrainSHA256=sha(raw))
asset('world.json',rawjson(manifest))
with tempfile.TemporaryDirectory(prefix='ridge-background-publish-') as background:
 subprocess.run([sys.executable,str(Path(__file__).with_name('build_background.py')),'--pack',str(a.pack),'--world',str(a.output),'--output',background,'--tolerance','2'],check=True)
 background=Path(background);report=json.loads((background/'background-index.json').read_bytes());chunks={x['chunk']['id']:x['chunk'] for x in report['tiles']}
 for tile in manifest['tiles']:
  tile['background']=chunks[tile['id']];shutil.copy2(background/tile['background']['path'],a.output/tile['background']['path'])
 manifest['backgroundToleranceMetres']=2;asset('world.json',rawjson(manifest))
print(json.dumps(dict(tiles=len(manifest['tiles']),bytes=sum(p.stat().st_size for p in a.output.iterdir()))))
