#!/usr/bin/env python3
"""Independent triangulation/error/topology checks on deterministic samples.
All chunks are fully checked by the compiler; this uses Matplotlib's independent
triangle locator, verifies decoded disk data and audits neighbouring source seams.
"""
import json,pathlib,struct,hashlib,sys
import numpy as np
import matplotlib.tri as tri
r=pathlib.Path(sys.argv[1]);m=json.loads((r/'manifest.json').read_text());chunks=m['chunks']
chosen=sorted(set(np.linspace(0,len(chunks)-1,24,dtype=int).tolist()+[int(np.argmax([c['triangles'] for c in chunks])),int(np.argmin([c['triangles'] for c in chunks]))]))
xx,yy=np.meshgrid(np.arange(513,dtype=float),np.arange(513,dtype=float));cx,cy=np.meshgrid(np.arange(512,dtype=float)+.5,np.arange(512,dtype=float)+.5)
results=[]
for k in chosen:
 c=chunks[k];b=(r/c['path']).read_bytes();magic,nv,nt,iw,grid,scale,offset=struct.unpack('<4s4I2f',b[:28]);assert magic==b'RME1' and grid==513
 assert hashlib.sha256(b).hexdigest()==c['sha256'];v=np.frombuffer(b,dtype=np.dtype([('x','<u2'),('y','<u2'),('h','<i2')]),offset=28,count=nv)
 t=np.frombuffer(b,dtype='<u2' if iw==2 else '<u4',offset=28+nv*6).astype(np.int64).reshape(-1,3);assert len(t)==nt and t.max()<nv
 xy=np.column_stack([v['x'],v['y']]).astype(np.int64);z=v['h'].astype(float)*.1
 source=np.fromfile(c['source'],dtype='<i2').reshape(513,513).astype(float)*.1;assert np.array_equal(z,source[xy[:,1],xy[:,0]])
 interp=tri.LinearTriInterpolator(tri.Triangulation(xy[:,0],xy[:,1],t),z)
 p=interp(xx,yy);q=interp(cx,cy);assert not np.ma.getmaskarray(p).any() and not np.ma.getmaskarray(q).any()
 e=max(float(np.max(np.abs(p-source))),float(np.max(np.abs(q-(source[:-1,1:]+source[1:,:-1])*.5))));assert e<=.500001
 edges,count=np.unique(np.sort(np.concatenate([t[:,[0,1]],t[:,[1,2]],t[:,[2,0]]]),axis=1),axis=0,return_counts=True);assert np.isin(count,[1,2]).all()
 border=xy[edges[count==1]];assert len(border)==2048
 assert ((border[:,:,0]==0).all(axis=1)|(border[:,:,0]==512).all(axis=1)|(border[:,:,1]==0).all(axis=1)|(border[:,:,1]==512).all(axis=1)).all()
 results.append({'id':c['id'],'triangles':nt,'maxErrorMetres':e});print(results[-1],flush=True)
# Audit actual mesh perimeter heights across every shared geographic edge.
edges={};seams=0;max_delta=0
for c in chunks:
 b=(r/c['path']).read_bytes();nv=c['vertices'];v=np.frombuffer(b,dtype=np.dtype([('x','<u2'),('y','<u2'),('h','<i2')]),offset=28,count=nv);bounds=c['bounds']
 for axis,side,coord in [('x',0,'minLongitude'),('x',512,'maxLongitude'),('y',0,'maxLatitude'),('y',512,'minLatitude')]:
  other='y' if axis=='x' else 'x';edge=v[v[axis]==side];edge=np.sort(edge,order=other);assert np.array_equal(edge[other],np.arange(513))
  key=(axis,round(bounds[coord],10),round(bounds['minLatitude' if axis=='x' else 'minLongitude'],10),round(bounds['maxLatitude' if axis=='x' else 'maxLongitude'],10))
  heights=edge['h'].astype(np.int32)
  if key in edges:seams+=1;max_delta=max(max_delta,int(np.max(np.abs(edges.pop(key)-heights))))
  else:edges[key]=heights
assert max_delta==0,f'Seam mismatch: {max_delta/10}m'
report={'independentSamples':results,'sharedEdgesChecked':seams,'maxSeamHeightDifferenceMetres':max_delta/10,'allChunkSurfaceValidation':'Compiler checked every emitted triangle against native vertices and cell centres; max in manifest.'}
(r/'validation.json').write_text(json.dumps(report,indent=2));print('Seams:',seams,'max difference:',max_delta/10,flush=True)
