#!/usr/bin/env python3
"""Reproducible offline Crib Goch test. Never writes to the input pack or app.
Requires numpy, matplotlib, Pillow and Node.js. See README.md.
"""
import argparse, hashlib, json, math, os, shutil, struct, subprocess, time, zlib
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.tri as mtri
from PIL import Image

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
ap=argparse.ArgumentParser()
ap.add_argument('--pack',type=Path,default=PROJECT/'ridge v3/Resources/RidgeData.bundle/regions/eryri-grid')
ap.add_argument('--output',type=Path,default=PROJECT/'Tools/reports/crib-goch-adaptive')
ap.add_argument('--node',default=shutil.which('node'))
args=ap.parse_args(); pack=args.pack; out=args.output; out.mkdir(parents=True,exist_ok=True)
m=json.loads((pack/'pack.json').read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
 return h.hexdigest()
provenance={'sourcePack':str(pack),'manifestSHA256':sha(pack/'pack.json'),'sources':m['sources'], 'files':[]}
levels={}
for spacing in [1,2,4,8]:
 level=next(l for l in m['levels'] if l['spacing']==spacing)
 p=pack/level['file']; digest=sha(p); assert digest==level['sha256']
 provenance['files'].append({'file':level['file'],'sha256':digest})
 raster=np.memmap(p,dtype='<i2',mode='r',shape=(level['height'],level['width']))
 n=512//spacing
 levels[spacing]=[np.array(raster[row*n:(row+1)*n+1,6*n:7*n+1]) for row in [9,10]]
 assert all(np.all(h!=m['noDataValue']) for h in levels[spacing])
source=[h.astype(float)*m['heightScale'] for h in levels[1]]
for i,h in enumerate(source): h.astype('<f4').tofile(out/f'source-{i}.f32')
assert np.array_equal(source[0][-1],source[1][0])
for spacing in [2,4,8]:
 for i in [0,1]: assert np.array_equal(levels[spacing][i],levels[1][i][::spacing,::spacing])
provenance['coarseLevelsAreExactNativeSubsamples']=True
# Follow the app's geographic grid and the atlas's own boundaries.
b=m['bounds']; lon0=b['minLongitude']+(b['maxLongitude']-b['minLongitude'])*6/16
lon1=b['minLongitude']+(b['maxLongitude']-b['minLongitude'])*7/16
lat0=b['maxLatitude']-(b['maxLatitude']-b['minLatitude'])*9/16
lat1=b['maxLatitude']-(b['maxLatitude']-b['minLatitude'])*11/16
latmid=(lat0+lat1)/2
sx=(lon1-lon0)*111320*math.cos(math.radians(latmid))/512
sy=(lat0-lat1)*111320/1024
textures=[]
for row in [9,10]:
 north=b['maxLatitude']-(b['maxLatitude']-b['minLatitude'])*row/16
 entry=next(t['image'] for t in m['cartography']['tiles'] if abs(t['image']['bounds']['minLongitude']-lon0)<1e-9 and abs(t['image']['bounds']['maxLatitude']-north)<1e-9)
 p=pack/entry['file']; digest=sha(p); assert digest==entry['sha256']
 provenance['files'].append({'file':entry['file'],'sha256':digest})
 image=Image.open(p).convert('RGB'); assert image.size==(1032,1032)
 textures.append(image.crop((4,4,1028,1028)))
texture=Image.new('RGB',(1024,2048)); texture.paste(textures[0],(0,0));texture.paste(textures[1],(0,1024));texture.save(out/'map.png')
peak=next(p for p in m['places'] if p['name']=='Crib Goch')
px=(peak['coordinate']['longitude']-lon0)/(lon1-lon0)*512
py=(lat0-peak['coordinate']['latitude'])/(lat0-lat1)*1024
provenance.update(bounds={'minLongitude':lon0,'maxLongitude':lon1,'maxLatitude':lat0,'minLatitude':lat1},localTiles=[{'column':6,'row':9},{'column':6,'row':10}],metresPerNativeStep=[sx,sy],peak=peak)
print('Source ready',flush=True)
subprocess.run([args.node,str(HERE/'build_meshes.mjs'),str(out)],check=True,stdout=subprocess.DEVNULL)
candidates=json.loads((out/'mesh-candidates.json').read_text())

def uniform(spacing,i):
 h=levels[spacing][i]*m['heightScale']; n=h.shape[0]
 xx,yy=np.meshgrid(np.arange(n)*spacing,np.arange(n)*spacing)
 xy=np.column_stack((xx.ravel(),yy.ravel())).astype(np.uint16)
 a=(np.arange(n-1)[:,None]*n+np.arange(n-1)[None,:]).ravel()
 tri=np.stack((np.column_stack((a,a+n,a+1)),np.column_stack((a+1,a+n,a+n+1))),axis=1).reshape(-1,3).astype(np.uint32)
 return xy,tri,h.ravel()

def adaptive(p,i):
 xy=np.fromfile(out/f'{p["id"]}-{i}.xy',dtype='<u2').reshape(-1,2)
 tri=np.fromfile(out/f'{p["id"]}-{i}.tri',dtype='<u4').reshape(-1,3)
 return xy,tri,source[i][xy[:,1],xy[:,0]]

def interpolator(mesh):
 xy,tri,z=mesh
 return mtri.LinearTriInterpolator(mtri.Triangulation(xy[:,0].astype(float),xy[:,1].astype(float),tri),z)

xx,yy=np.meshgrid(np.arange(513,dtype=float),np.arange(513,dtype=float))
cx,cy=np.meshgrid(np.arange(512,dtype=float)+.5,np.arange(512,dtype=float)+.5)

def stats(a):
 a=np.asarray(a); return {'max':float(a.max()),'rmse':float(np.sqrt(np.mean(a*a))),'p95':float(np.quantile(a,.95)),'p99':float(np.quantile(a,.99))}

def measure(meshes):
 errs=[]; peaks=[]; maps=[]
 for i,mesh in enumerate(meshes):
  f=interpolator(mesh)
  e=np.abs(np.asarray(f(xx,yy))-source[i])
  ref=(source[i][:-1,1:]+source[i][1:,:-1])/2
  ec=np.abs(np.asarray(f(cx,cy))-ref)
  assert np.isfinite(e).all() and np.isfinite(ec).all()
  errs.extend([e.ravel(),ec.ravel()]); maps.append(e)
  mask=((xx-px)*sx)**2+((yy+512*i-py)*sy)**2<=100**2
  cmask=((cx-px)*sx)**2+((cy+512*i-py)*sy)**2<=100**2
  peaks.extend([e[mask],ec[cmask]])
 return {'surfaceErrorMetres':stats(np.concatenate(errs)),'peak100mErrorMetres':stats(np.concatenate(peaks))},maps

results={}; meshes_by_id={}; maps_by_id={}
for spacing in [1,2,4,8]:
 id=f'grid-{spacing}'; meshes=[uniform(spacing,i) for i in [0,1]]
 result,maps=measure(meshes)
 result.update(id=id,label=f'Uniform {spacing} m',triangles=sum(len(t) for _,t,_ in meshes),vertices=sum(len(x) for x,_,_ in meshes),heightFileBytes=sum(h.nbytes for h in levels[spacing]))
 results[id]=result;meshes_by_id[id]=meshes;maps_by_id[id]=maps
 print(id,result,flush=True)
for p in candidates:
 meshes=[adaptive(p,i) for i in [0,1]]; result,maps=measure(meshes)
 result.update(id=p['id'],label='Adaptive · 4 m budget' if p['id']=='matched' else f'Adaptive criterion {p["threshold"]:g} m',criterionMetres=p['threshold'],triangles=sum(len(t) for _,t,_ in meshes),vertices=sum(len(x) for x,_,_ in meshes),offlineExtractionMs=p['extractionMs'],offlineErrorPreparationMs=p['errorPreparationMs'])
 results[p['id']]=result;meshes_by_id[p['id']]=meshes;maps_by_id[p['id']]=maps
 print(p['id'],result,flush=True)
# Select the cheapest tested candidate whose independent error is <= 0.5 m.
qualified=[r for id,r in results.items() if id.startswith('error-') and r['surfaceErrorMetres']['max']<=.50001]
quality=min(qualified,key=lambda r:r['triangles']) if qualified else None
if quality is None: raise RuntimeError('Need finer candidate: no tested adaptive profile meets 0.5 m measured error.')
quality['label']='Adaptive · 0.5 m tolerance'
for tolerance in [1,2,3]:
 profile=results[f'error-{tolerance}']
 assert profile['surfaceErrorMetres']['max'] <= tolerance + 0.0001, profile
 profile['label']=f'Adaptive · {tolerance} m tolerance'
selected=['grid-1','grid-4','matched',quality['id'],'error-1','error-2','error-3']

checks=[]
for id in [id for id in selected if not id.startswith('grid-')]:
 edges_for_seam=[]
 for i,(xy,tri,z) in enumerate(meshes_by_id[id]):
  assert tri.max()<len(xy)
  q=xy[tri].astype(np.int64)
  area2=(q[:,1,0]-q[:,0,0])*(q[:,2,1]-q[:,0,1])-(q[:,1,1]-q[:,0,1])*(q[:,2,0]-q[:,0,0])
  assert np.all(area2>0) or np.all(area2<0)
  assert np.abs(area2).sum()==512*512*2
  delta=q[:,[1,2,0]]-q
  assert np.max(np.sum(delta*delta,axis=2))<=128
  edges=np.sort(np.concatenate([tri[:,[0,1]],tri[:,[1,2]],tri[:,[2,0]]]),axis=1)
  edges,count=np.unique(edges,axis=0,return_counts=True)
  assert np.isin(count,[1,2]).all()
  border=xy[edges[count==1]]
  assert len(border)==2048
  assert ((border[:,:,0]==0).all(axis=1)|(border[:,:,0]==512).all(axis=1)|(border[:,:,1]==0).all(axis=1)|(border[:,:,1]==512).all(axis=1)).all()
  assert np.array_equal(z,source[i][xy[:,1],xy[:,0]])
  seam=np.where(xy[:,1]==(512 if i==0 else 0))[0]; seam=seam[np.argsort(xy[seam,0])]
  assert np.array_equal(xy[seam,0],np.arange(513))
  edges_for_seam.append(z[seam]);checks.append(f'{id} tile {i}: manifold, full area, 2,048 native boundary edges, exact source vertex heights')
 assert np.array_equal(*edges_for_seam); checks.append(f'{id}: shared edge positions and heights identical')

# Compact prototype payload: lossless native x/y and source decimetres, plus indices.
# This is an experimental local format, not a production/iOS format migration.
for id in selected:
 total=compressed=0
 for i,(xy,tri,z) in enumerate(meshes_by_id[id]):
  index_bytes=2 if len(xy)<=65536 else 4
  vertices=np.empty(len(xy),dtype=[('x','<u2'),('y','<u2'),('z','<i2')]);vertices['x']=xy[:,0];vertices['y']=xy[:,1];vertices['z']=np.rint(z/m['heightScale']).astype(np.int16)
  payload=struct.pack('<4sIIIIff',b'RME1',len(xy),len(tri),index_bytes,513,m['heightScale'],0)+vertices.tobytes()+tri.astype('<u2' if index_bytes==2 else '<u4').tobytes()
  (out/f'{id}-{i}.rmesh').write_bytes(payload); comp=zlib.compress(payload,9);(out/f'{id}-{i}.rmesh.zlib').write_bytes(comp)
  total+=len(payload);compressed+=len(comp)
  # Validate round trip independent of buffers used to construct it.
  decoded=zlib.decompress(comp);magic,nv,nt,ib,gs,hs,_=struct.unpack('<4sIIIIff',decoded[:28]);assert magic==b'RME1' and gs==513
  vv=np.frombuffer(decoded,dtype=vertices.dtype,count=nv,offset=28)
  tt=np.frombuffer(decoded,dtype='<u2' if ib==2 else '<u4',count=nt*3,offset=28+nv*6).reshape(-1,3)
  assert np.array_equal(tt,tri) and np.array_equal(vv['x'],xy[:,0]) and np.array_equal(vv['y'],xy[:,1]) and np.allclose(vv['z']*hs,z,atol=.0001)
 results[id]['prototypeMeshBytes']=total;results[id]['prototypeMeshZlibBytes']=compressed
for r in results.values(): r['estimatedCurrentMetalGeometryBytes']=r['vertices']*48+r['triangles']*12
for file in provenance['files']: assert sha(pack/file['file'])==file['sha256']
assert sha(pack/'pack.json')==provenance['manifestSHA256']
checks+=['Prepared 2/4/8 m heights exactly equal corresponding 1 m source samples', 'All adaptive triangle edges within 8√2 native steps', 'All source hashes unchanged after build','Compact binary mesh round trips verified for all displayed profiles']
report={'selected':selected,'fineProfileID':quality['id'],'comparisonTolerancesMetres':[0.5,1,2,3],'profiles':list(results.values()),'validation':checks,'provenance':provenance,'samplesPerProfile':2*(513**2+512**2),'method':'MARTINI RTIN topology with custom full-surface error fields and native diagonal preservation; 1 m boundary lock; maximum leaf equivalent to 8 m; error checked independently at every source grid vertex and every 1 m cell centre. Errors are relative to the existing 1 m triangulated pack, not surveyed truth.','sourceScaleMetres':m['heightScale'],'algorithm':json.loads((HERE/'vendor/provenance.json').read_text())}
(out/'metrics.json').write_text(json.dumps(report,indent=2)+'\n')

# Export float buffers for a dependency-free offline WebGL viewer.
viewer={'profiles':[],'defaultLeft':quality['id'],'defaultRight':'error-1', 'peak':[float((px-256)*sx),float(peak['elevation']-700),float((py-512)*sy)],'bounds':provenance['bounds'],'tileWidthMetres':512*sx,'tileHeightMetres':512*sy}
combined=np.vstack([source[0][:-1],source[1]])
gy,gx=np.gradient(combined,sy,sx)
for id in selected:
 meshlist=[]
 for i,(xy,tri,z) in enumerate(meshes_by_id[id]):
  x=xy[:,0].astype(float);y=xy[:,1].astype(float)+512*i
  # Area-weighted face normals show actual simplification rather than hiding it
  # under high-resolution normals. Shared native border normals prevent lighting seams.
  pos=np.column_stack(((x-256)*sx,z-700,(y-512)*sy)).astype('<f4')
  face=np.cross(pos[tri[:,1]]-pos[tri[:,0]],pos[tri[:,2]]-pos[tri[:,0]])
  if np.mean(face[:,1])<0: tri=tri[:,[0,2,1]];face=-face
  normals=np.zeros_like(pos)
  for k in range(3): np.add.at(normals,tri[:,k],face)
  boundary=(xy[:,0]==0)|(xy[:,0]==512)|(xy[:,1]==0)|(xy[:,1]==512)
  normals[boundary]=np.column_stack((-gx[y[boundary].astype(int),x[boundary].astype(int)],np.ones(boundary.sum()),-gy[y[boundary].astype(int),x[boundary].astype(int)]))
  normals/=np.linalg.norm(normals,axis=1,keepdims=True)
  v=np.column_stack((pos,normals,x/512,y/1024)).astype('<f4')
  v.tofile(out/f'{id}-{i}.vertices');tri.astype('<u4').tofile(out/f'{id}-{i}.indices')
  meshlist.append({'vertices':f'{id}-{i}.vertices','indices':f'{id}-{i}.indices','count':int(tri.size)})
 viewer['profiles'].append({**results[id],'meshes':meshlist})
(out/'viewer.json').write_text(json.dumps(viewer,indent=2)+'\n')

plt.rcParams.update({'font.family':'sans-serif','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
compare=['grid-4','matched',quality['id']]
fig,axs=plt.subplots(1,3,figsize=(12,8),layout='constrained')
for ax,id in zip(axs,compare):
 e=np.vstack([maps_by_id[id][0][:-1],maps_by_id[id][1]])
 im=ax.imshow(e,extent=[0,512*sx,1024*sy,0],cmap='magma',vmin=0,vmax=2)
 ax.axhline(512*sy,color='cyan',lw=.6,alpha=.7);ax.plot(px*sx,py*sy,'+',color='lime',ms=9)
 ax.set_title(results[id]['label']+'\n'+f'{results[id]["triangles"]:,} triangles');ax.set_xlabel('East → metres');ax.set_ylabel('South → metres')
fig.colorbar(im,ax=axs,label='Added height error at source samples (m; colour capped at 2 m)',shrink=.75)
fig.suptitle('Crib Goch · same two tiles, independent error measurement\nGreen cross: named summit; cyan: shared tile boundary',fontsize=14)
fig.savefig(out/'error-comparison.png',dpi=160);plt.close(fig)
fig,axs=plt.subplots(1,3,figsize=(13,7),layout='constrained')
for ax,id in zip(axs,compare):
 for i,(xy,tri,z) in enumerate(meshes_by_id[id]):
  ax.triplot(xy[:,0]*sx,(xy[:,1].astype(float)+512*i)*sy,tri,lw=.3,color='#284e49')
 ax.set_xlim(px*sx-90,px*sx+90);ax.set_ylim(py*sy+90,py*sy-90);ax.set_aspect('equal');ax.plot(px*sx,py*sy,'+',color='#bf4724',ms=9)
 ax.set_title(results[id]['label']);ax.set_xlabel('East → metres');ax.set_ylabel('South → metres')
fig.suptitle('Triangles around the summit · 180 × 180 metres\nThe native shared boundary is retained in both adaptive meshes',fontsize=14)
fig.savefig(out/'triangle-comparison.png',dpi=160);plt.close(fig)
fig,ax=plt.subplots(figsize=(12,5),layout='constrained')
ys=np.linspace(py-100/sy,py+100/sy,1201)
for id,color in zip(['grid-1','grid-4','matched',quality['id']],['#202d35','#dd6b34','#5c77c4','#20a58a']):
 zs=np.empty(len(ys))
 for i in [0,1]:
  mask=(ys<=512) if i==0 else (ys>512)
  zs[mask]=np.asarray(interpolator(meshes_by_id[id][i])(np.full(mask.sum(),px),ys[mask]-512*i))
 ax.plot((ys-py)*sy,zs,label=results[id]['label'],color=color,lw=2 if id=='grid-1' else 1.2,alpha=.9)
ax.set(xlabel='Distance south of named summit (m)',ylabel='Elevation in pack datum (m)',title='North–south section through Crib Goch · no vertical exaggeration in 3D viewer')
ax.legend();ax.grid(alpha=.15);fig.savefig(out/'ridge-section.png',dpi=180);plt.close(fig)
fig,axs=plt.subplots(1,4,figsize=(14,8),layout='constrained')
for ax,id in zip(axs,[quality['id'],'error-1','error-2','error-3']):
 e=np.vstack([maps_by_id[id][0][:-1],maps_by_id[id][1]])
 im=ax.imshow(e,extent=[0,512*sx,1024*sy,0],cmap='magma',vmin=0,vmax=3)
 ax.axhline(512*sy,color='cyan',lw=.6,alpha=.7);ax.plot(px*sx,py*sy,'+',color='lime',ms=8)
 ax.set_title(results[id]['label'].replace('Adaptive · ','')+'\n'+f'{results[id]["triangles"]:,} triangles')
 ax.set_xlabel('East → metres');ax.set_ylabel('South → metres')
fig.colorbar(im,ax=axs,label='Added height error at source samples (m)',shrink=.75)
fig.suptitle('Crib Goch · compare four tolerances before choosing\nSame source, maximum triangle size, boundary rules and colour scale',fontsize=14)
fig.savefig(out/'tolerance-comparison.png',dpi=160);plt.close(fig)
shutil.copyfile(HERE/'viewer.html',out/'index.html')
subprocess.run([os.sys.executable,str(HERE/'write_report.py'),str(out)],check=True)
print('DONE',quality['id'],out,flush=True)
