#!/usr/bin/env python3
"""Run after run_experiment.py. Compare 2 m error with larger cells/new pack layout.
Writes new reports/preview meshes only. The input pack is read-only.
"""
import argparse,hashlib,json,math,shutil,subprocess
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.tri as mtri
HERE=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=HERE.parent/'reports/crib-goch-adaptive');p.add_argument('--node',default=shutil.which('node'));a=p.parse_args();out=a.output
base=json.loads((out/'metrics.json').read_text());pack=Path(base['provenance']['sourcePack']);manifest=json.loads((pack/'pack.json').read_text())
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
assert sha(pack/'pack.json')==base['provenance']['manifestSHA256']
for item in base['provenance']['files']:assert sha(pack/item['file'])==item['sha256']
level=next(l for l in manifest['levels'] if l['spacing']==1)
source=np.memmap(pack/level['file'],dtype='<i2',mode='r',shape=(level['height'],level['width']))
h=np.array(source[9*512:11*512+1,6*512:7*512+1],dtype=float)*manifest['heightScale']
for i in [0,1]:
 old=np.fromfile(out/f'source-{i}.f32',dtype='<f4').reshape(513,513)
 assert np.array_equal(old,h[i*512:i*512+513].astype(np.float32))
subprocess.run([a.node,str(HERE/'build_layouts.mjs'),str(out)],check=True)
candidates=json.loads((out/'layout-candidates.json').read_text())['profiles']
sx,sy=base['provenance']['metresPerNativeStep'];gy,gx=np.gradient(h,sy,sx)
xx,yy=np.meshgrid(np.arange(513,dtype=float),np.arange(1025,dtype=float));cx,cy=np.meshgrid(np.arange(512,dtype=float)+.5,np.arange(1024,dtype=float)+.5)
refCentre=(h[:-1,1:]+h[1:,:-1])/2
bounds=base['provenance']['bounds'];peak=base['provenance']['peak']['coordinate']
px=(peak['longitude']-bounds['minLongitude'])/(bounds['maxLongitude']-bounds['minLongitude'])*512
py=(bounds['maxLatitude']-peak['latitude'])/(bounds['maxLatitude']-bounds['minLatitude'])*1024
mask=((xx-px)*sx)**2+((yy-py)*sy)**2<=100**2;cmask=((cx-px)*sx)**2+((cy-py)*sy)**2<=100**2

def stats(v):return dict(max=float(v.max()),rmse=float(np.sqrt(np.mean(v*v))),p95=float(np.quantile(v,.95)),p99=float(np.quantile(v,.99)))
def validate(xy,t,z):
 assert t.max()<len(xy) and np.unique(xy,axis=0).shape[0]==len(xy)
 q=xy[t].astype(np.int64);area=(q[:,1,0]-q[:,0,0])*(q[:,2,1]-q[:,0,1])-(q[:,1,1]-q[:,0,1])*(q[:,2,0]-q[:,0,0])
 assert np.all(area<0) or np.all(area>0)
 assert np.abs(area).sum()==512*1024*2
 assert xy.min()>=0 and xy[:,0].max()<=512 and xy[:,1].max()<=1024
 edges=np.sort(np.concatenate([t[:,[0,1]],t[:,[1,2]],t[:,[2,0]]]),axis=1)
 edges,n=np.unique(edges,axis=0,return_counts=True);assert np.isin(n,[1,2]).all()
 border=xy[edges[n==1]]
 assert len(border)==3072
 assert ((border[:,:,0]==0).all(axis=1)|(border[:,:,0]==512).all(axis=1)|(border[:,:,1]==0).all(axis=1)|(border[:,:,1]==1024).all(axis=1)).all()
 assert np.array_equal(z,h[xy[:,1],xy[:,0]])
 delta=q[:,[1,2,0]]-q;return float(np.sqrt(np.max(np.sum(delta*delta,axis=2))))

profiles=[];meshCache={};errorCache={}
for candidate in candidates:
 parts=[];offset=0;allxy=[];allt=[];viewerMeshes=[]
 for i,part in enumerate(candidate['parts']):
  xy=np.fromfile(out/part['xy'],dtype='<u2').reshape(-1,2).copy();xy[:,1]+=part['yOffset'];t=np.fromfile(out/part['tri'],dtype='<u4').reshape(-1,3)
  allxy.append(xy);allt.append(t+offset);offset+=len(xy);parts.append((xy,t,h[xy[:,1],xy[:,0]]))
 # Weld exact shared samples for surface validation, while counting the actual
 # per-part upload vertices in the renderer memory estimate.
 raw=np.vstack(allxy);xy,inv=np.unique(raw,axis=0,return_inverse=True);t=inv[np.vstack(allt)].astype(np.uint32);z=h[xy[:,1],xy[:,0]]
 maxEdge=validate(xy,t,z)
 if candidate['maxCellSteps'] is not None:assert maxEdge<=candidate['maxCellSteps']*math.sqrt(2)+1e-8
 f=mtri.LinearTriInterpolator(mtri.Triangulation(xy[:,0].astype(float),xy[:,1].astype(float),t),z)
 zz=f(xx,yy);zc=f(cx,cy);assert not np.ma.getmaskarray(zz).any() and not np.ma.getmaskarray(zc).any()
 e=np.abs(np.asarray(zz)-h);ec=np.abs(np.asarray(zc)-refCentre);error=stats(np.concatenate([e.ravel(),ec.ravel()]))
 assert error['max']<=2.0001,(candidate['id'],error)
 seamCount=int((xy[:,1]==512).sum());q=xy[t];crossCount=int(((q[:,:,1].min(axis=1)<512)&(q[:,:,1].max(axis=1)>512)).sum())
 if candidate['layout']=='joined':assert seamCount<513 and crossCount>0
 else:assert seamCount==513 and crossCount==0
 cap=candidate['maxCellSteps'];limit=f'{cap} m cell limit' if cap else 'no cell-size cap'
 region='original tiles' if candidate['layout']=='tiles' else 'joined area'
 result={**candidate,'label':f'2 m tolerance · {cap if cap else "uncapped"}{" m" if cap else ""} · {region}', 'note':f'{limit} · {region} · native outer boundary', 'triangles':len(t),'vertices':len(raw),'surfaceErrorMetres':error,'peak100mErrorMetres':stats(np.concatenate([e[mask],ec[cmask]])), 'estimatedCurrentMetalGeometryBytes':48*len(raw)+12*len(t),'maxActualEdgeNativeSteps':maxEdge,'verticesOnOldInternalBoundary':seamCount,'trianglesCrossingOldInternalBoundary':crossCount}
 for i,(v,tr,height) in enumerate(parts):
  x=v[:,0].astype(float);y=v[:,1].astype(float)
  pos=np.column_stack(((x-256)*sx,height-700,(y-512)*sy)).astype('<f4')
  face=np.cross(pos[tr[:,1]]-pos[tr[:,0]],pos[tr[:,2]]-pos[tr[:,0]])
  if np.mean(face[:,1])<0:tr=tr[:,[0,2,1]];face=-face
  normals=np.zeros_like(pos)
  for k in range(3):np.add.at(normals,tr[:,k],face)
  boundary=(v[:,0]==0)|(v[:,0]==512)|(v[:,1]==0)|(v[:,1]==1024)
  if candidate['layout']=='tiles':boundary|=(v[:,1]==512)
  normals[boundary]=np.column_stack((-gx[v[boundary,1],v[boundary,0]],np.ones(boundary.sum()),-gy[v[boundary,1],v[boundary,0]]))
  normals/=np.linalg.norm(normals,axis=1,keepdims=True)
  floats=np.column_stack((pos,normals,x/512,y/1024)).astype('<f4');stem=f'{candidate["id"]}-{i}'
  floats.tofile(out/f'{stem}.vertices');tr.astype('<u4').tofile(out/f'{stem}.indices')
  viewerMeshes.append(dict(vertices=f'{stem}.vertices',indices=f'{stem}.indices',count=int(tr.size)))
 result['meshes']=viewerMeshes;profiles.append(result);meshCache[result['id']]=(xy,t);errorCache[result['id']]=e
 print(result['id'],result['triangles'],round(result['estimatedCurrentMetalGeometryBytes']/1048576,3),'MiB',error['max'],'max error',seamCount,'seam vertices',flush=True)
original=next(p for p in profiles if p['id']=='layout-tiles-8');old=next(p for p in base['profiles'] if p['id']=='error-2')
assert original['vertices']==old['vertices'] and original['triangles']==old['triangles']
assert abs(original['surfaceErrorMetres']['max']-old['surfaceErrorMetres']['max'])<1e-8
for part in candidates[0]['parts']:
 i=part['yOffset']//512
 assert (out/part['xy']).read_bytes()==(out/f'error-2-{i}.xy').read_bytes()
 assert (out/part['tri']).read_bytes()==(out/f'error-2-{i}.tri').read_bytes()
checks=['All ten candidates <=2 m measured surface error (+0.0001 m numerical allowance)','1,050,113 unique native grid/cell-centre checks per candidate','No holes, overlaps by area/topology check, degenerate triangles, or unmatched internal edges','All visible vertices retain exact original heights','No padded vertices or triangles in the real-area output','Native outer boundary retained and consistent across candidates','Joined candidates contain triangles crossing the old internal tile boundary','Original 8 m candidate reproduces the previous 2 m geometry byte-for-byte','All source pack and texture hashes unchanged']
for item in base['provenance']['files']:assert sha(pack/item['file'])==item['sha256']
report={'profiles':profiles,'validation':checks,'provenance':base['provenance'],'sourceImageSHA256':sha(out/'map.png'),'toleranceMetres':2,'samplesPerProfile':h.size+refCentre.size,'method':'Fixed 2 m height tolerance. Vary maximum RTIN triangle size and whether the former internal tile boundary must retain all native vertices. Joined rectangular area uses square RTIN with a shifted origin and isolated boundary-height extrusion outside the real area; every padded triangle is excluded and validated.'}
(out/'layout-metrics.json').write_text(json.dumps(report,indent=2)+'\n')
viewer=json.loads((out/'viewer.json').read_text());viewer['profiles']=[p for p in viewer['profiles'] if not p['id'].startswith('layout-')]+profiles
viewer['defaultLeft']='layout-tiles-8';viewer['defaultRight']='layout-joined-uncapped';viewer['experiment']='pack-layout'
(out/'viewer.json').write_text(json.dumps(viewer,indent=2)+'\n')
plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False})
chosen=['layout-tiles-8','layout-tiles-32','layout-joined-32','layout-joined-uncapped']
fig,axs=plt.subplots(1,4,figsize=(15,7),layout='constrained')
for ax,id in zip(axs,chosen):
 xy,t=meshCache[id];ax.triplot(xy[:,0]*sx,xy[:,1]*sy,t,lw=.35,color='#285247')
 ax.axhline(512*sy,color='#cf683d',ls='--',lw=.7);ax.plot(px*sx,py*sy,'+',color='#bf4724',ms=9)
 ax.set_xlim(px*sx-110,px*sx+110);ax.set_ylim(py*sy+110,py*sy-110);ax.set_aspect('equal');ax.set_xlabel('East → metres');ax.set_ylabel('South → metres')
 r=next(p for p in profiles if p['id']==id);ax.set_title(r['label'].replace('2 m tolerance · ','').replace(' · ','\n')+f'\n{r["triangles"]:,} triangles')
fig.suptitle('Same 2 m height tolerance · change the pack constraints\nDashed line: old tile boundary; cross: named summit',fontsize=14)
fig.savefig(out/'layout-triangles.png',dpi=160);plt.close(fig)
fig,ax=plt.subplots(figsize=(10,5),layout='constrained')
for layout,label,color in [('tiles','Original tile boundaries','#5b7198'),('joined','Joined area','#29886f')]:
 data=[p for p in profiles if p['layout']==layout];ax.plot(range(5),[p['estimatedCurrentMetalGeometryBytes']/1048576 for p in data],'o-',label=label,color=color)
ax.set_xticks(range(5),['8 m','16 m','32 m','64 m','Uncapped']);ax.set(xlabel='Maximum equivalent cell size (native steps; spacing nominal)',ylabel='Estimated Metal geometry (MiB)',title='Crib Goch · fixed 2 m height tolerance');ax.legend();ax.grid(alpha=.15);fig.savefig(out/'layout-savings.png',dpi=160);plt.close(fig)
rows=[]
for r in profiles:
 rows.append(f'| {r["layout"]} | {r["maxCellSteps"] or "Uncapped"} | {r["triangles"]:,} | {r["estimatedCurrentMetalGeometryBytes"]/1048576:.3f} | {r["surfaceErrorMetres"]["max"]:.3f} | {100*(1-r["estimatedCurrentMetalGeometryBytes"]/original["estimatedCurrentMetalGeometryBytes"]):.1f}% |')
joined=profiles[-1]
text=f'''# Pack-layout tests at 2 m tolerance

The same approximately 490 × 981 m Crib Goch window, original height data, camera and map texture. No terrain smoothing, new survey processing, or iOS app changes. These are ten offline experiment candidates, not ten proposed shipping layers.

| Layout | Maximum cell size, nominal m | Triangles | Geometry MiB | Worst added error, m | Saving vs original |
|---|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

The original 8 m / separate-tiles candidate exactly reproduces the previous 2 m test. Larger cells isolate the effect of removing the old 8 m limit. Joining the area removes the mandatory dense internal boundary and shifts the RTIN origin by one native sample, so triangles can cross the old tile grid. This changes the triangulation alignment as well as the internal-edge policy. The external outline remains at native resolution in both layouts.

The joined uncapped candidate uses {joined['triangles']:,} triangles, {100*(1-joined['estimatedCurrentMetalGeometryBytes']/original['estimatedCurrentMetalGeometryBytes']):.1f}% less estimated geometry memory than the original. Its longest triangle edge is {joined['maxActualEdgeNativeSteps']:.1f} native grid steps. Uncapped means no extra triangle-size restriction; source resolution, the finite area, error tolerance and RTIN topology still constrain it. Larger allowed cells plateau here because the remaining terrain error/edge constraints force refinement, not because the file format requires 8 m cells.

## Compare visually

[Open the lab](index.html). It starts with original tiles / 8 m cell cap on the left and the joined uncapped area on the right. The top dropdowns include all ten variants. The pack-test buttons change only the right panel; the camera remains matched. All earlier 0.5/1/2/3 m tolerance comparisons remain available.

![Original and joined pack comparison](viewer-layout.png)

![Triangle arrangement across the old boundary](layout-triangles.png)

![Geometry memory by cell limit and layout](layout-savings.png)

## What is verified

{chr(10).join('- '+c for c in checks)}

The joined uncapped mesh has {joined['verticesOnOldInternalBoundary']} vertices on the former internal edge, compared with 513 distinct vertices before joining. It has {joined['trianglesCrossingOldInternalBoundary']} triangles crossing that line. It is a continuous mesh, not two separately simplified edges placed next to each other.

Heights are compared against the original native piecewise-planar surface at every grid vertex and cell centre. Error means added vertical deviation, not survey accuracy, slope accuracy, route safety, or guaranteed preservation of every visual feature. RMS and summit-region errors are in [layout-metrics.json](layout-metrics.json). Error sampling counts shared grid points once here, so RMS is not weighted identically to the earlier per-tile report.

Geometry estimates use the current Metal layout (48 bytes per vertex plus 32-bit indices). They exclude textures, CPU staging, routing lookup and app overhead; these are not M1 iPad performance measurements or compressed download sizes.

## Rebuilding packs

This test does not require the old internal tile boundary to survive. A future pack can be prepared as a larger continuous region and partitioned afterwards with coordinated boundary profiles. Adjacent independently prepared regions and mixed quality levels still need explicit matching edges; this experiment proves joining within this rectangle, not that entire production packaging/stitching problem.

The outer rim remains conservative and relatively costly in this small window. A larger region changes the ratio of edge to interior and includes different terrain, so do not extrapolate total Snowdon memory directly from this patch. We have not selected a final cell limit, tolerance, pack size or number of shipping levels.

Implementation note: upstream MARTINI accepts square grids. The rectangular joined input is embedded at a one-sample offset in a larger square, with nearest boundary heights extruded into unused padding. Locked real outer edges isolate it; any triangle crossing into padding is rejected, padding is removed, and the remaining area, topology, vertex provenance and error are verified independently. Padding is not displayed or counted in reported output geometry.

[Original tolerance results](REPORT.md) · [Reproduction instructions](../../adaptive_terrain/README.md)
'''
(out/'LAYOUT-REPORT.md').write_text(text)
shutil.copyfile(HERE/'viewer.html',out/'index.html')
print('LAYOUT TESTS COMPLETE',out,flush=True)
