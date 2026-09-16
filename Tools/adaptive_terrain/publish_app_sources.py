#!/usr/bin/env python3
"""Publish RAT1 sources for the normal app, reusing verified map/path assets.

Geometry is never recomputed. Only coarse context windows are cropped/resampled.
The catalogue is staged separately until --activate is explicitly supplied.
Original LiDAR, adaptive archives, map masters and route graphs are retained.
"""
import argparse, copy, hashlib, json, math, os
from pathlib import Path
import numpy as np
from PIL import Image

def digest(raw): return hashlib.sha256(raw).hexdigest()
def read(p): return json.loads(p.read_bytes())
def write(p,d):
 raw=(json.dumps(d,separators=(',',':'))+'\n').encode(); tmp=p.with_name('.'+p.name+'.tmp');tmp.write_bytes(raw);tmp.replace(p);return raw
def intersects(a,b): return a['minLongitude']<b['maxLongitude'] and a['maxLongitude']>b['minLongitude'] and a['minLatitude']<b['maxLatitude'] and a['maxLatitude']>b['minLatitude']
def contains(a,b): return a['minLongitude']<=b['minLongitude']+1e-10 and a['maxLongitude']>=b['maxLongitude']-1e-10 and a['minLatitude']<=b['minLatitude']+1e-10 and a['maxLatitude']>=b['maxLatitude']-1e-10
def bounds_at(b,x,y,w=1,h=1):
 dx=(b['maxLongitude']-b['minLongitude'])/48;dy=(b['maxLatitude']-b['minLatitude'])/48
 return dict(minLongitude=b['minLongitude']+x*dx,maxLongitude=b['minLongitude']+(x+w)*dx,maxLatitude=b['maxLatitude']-y*dy,minLatitude=b['maxLatitude']-(y+h)*dy)
def linked(src,dst,meta):
 if dst.exists():
  if dst.stat().st_size != meta['byteCount']:raise ValueError(f'Existing asset size mismatch: {dst}')
  return
 if src.stat().st_size!=meta['byteCount'] or digest(src.read_bytes())!=meta['sha256']:raise ValueError(f'Bad source asset: {src}')
 os.link(src,dst)
def publish(root,oldpath,activate):
 old=read(oldpath/'pack.json'); atlas=old['cartography']; mb=old['bounds']
 geomroot=root/'uk-adaptive-0p5-v3'; cat=read(geomroot/'catalog.json')
 far=old['horizon']['far']; level=far['levels'][0]; raw=(oldpath/level['file']).read_bytes()
 assert digest(raw)==level['sha256'];heights=np.frombuffer(raw,dtype='<i2').reshape(level['height'],level['width'])
 stubs=[];report=[]
 for part in cat['partitions']:
  if not intersects(part['bounds'],mb):continue
  src=geomroot/part['path']; g=read(src); b=g['bounds']
  # Keep native cells; never reinterpret the old uniformly resampled tile grid.
  columns=[x for x in range(48) if contains(mb,bounds_at(b,x,24)) or (bounds_at(b,x,24)['minLongitude']>=mb['minLongitude']-1e-10 and bounds_at(b,x,24)['maxLongitude']<=mb['maxLongitude']+1e-10)]
  rows=[y for y in range(48) if bounds_at(b,24,y)['minLatitude']>=mb['minLatitude']-1e-10 and bounds_at(b,24,y)['maxLatitude']<=mb['maxLatitude']+1e-10]
  if not columns or not rows:continue
  x0,x1=min(columns),max(columns)+1;y0,y1=min(rows),max(rows)+1
  primary=bounds_at(b,x0,y0,x1-x0,y1-y0)
  chunks=[copy.deepcopy(c) for c in g['chunks'] if contains(primary,c['bounds'])]
  if not chunks:continue
  id='ridge-adaptive-v1-'+part['id']; out=root/id;out.mkdir(exist_ok=True)
  container=g['container'];linked(src.parent/container['path'],out/'terrain.ratpack',container)
  # Map context is a bounded 60-cell window (~30 km), independent of detail.
  lon=atlas['longitudeEdges'];lat=atlas['latitudeEdges'];cx=(primary['minLongitude']+primary['maxLongitude'])/2;cy=(primary['minLatitude']+primary['maxLatitude'])/2
  mx=min(range(atlas['columns']),key=lambda x:abs((lon[x]+lon[x+1])/2-cx));my=min(range(atlas['rows']),key=lambda y:abs((lat[y]+lat[y+1])/2-cy))
  left=max(0,min(atlas['columns']-60,mx-30));top=max(0,min(atlas['rows']-60,my-30));right=min(atlas['columns'],left+60);bottom=min(atlas['rows'],top+60)
  surround=dict(minLongitude=lon[left],maxLongitude=lon[right],maxLatitude=lat[top],minLatitude=lat[bottom])
  assert contains(surround,primary),(id,primary,surround)
  tiles=[atlas['tiles'][y*atlas['columns']+x] for y in range(top,bottom) for x in range(left,right)]
  maps=dict(columns=right-left,rows=bottom-top,longitudeEdges=lon[left:right+1],latitudeEdges=lat[top:bottom+1],tiles=tiles,sourceOnly=True)
  for tile in tiles:
   for im in tile.values(): linked(oldpath/im['file'],out/im['file'],im)
  # Resample only the already-coarse context; the primary mesh is unchanged.
  xs=(np.linspace(surround['minLongitude'],surround['maxLongitude'],513)-mb['minLongitude'])/(mb['maxLongitude']-mb['minLongitude'])*(level['width']-1)
  ys=(mb['maxLatitude']-np.linspace(surround['maxLatitude'],surround['minLatitude'],513))/(mb['maxLatitude']-mb['minLatitude'])*(level['height']-1)
  xx=np.rint(xs).astype(int);yy=np.rint(ys).astype(int);values=heights[yy[:,None],xx[None,:]];raw=values.astype('<i2').tobytes();(out/'surroundings.bin').write_bytes(raw)
  horizon=dict(far=dict(bounds=surround,levels=[dict(spacing=64,width=513,height=513,file='surroundings.bin',byteCount=len(raw),sha256=digest(raw))],textures=[]))
  graphs=[x for x in old['tiledTerrain']['graphs'] if intersects(x['bounds'],primary)]
  for graph in graphs:linked(oldpath/graph['file'],out/graph['file'],graph)
  mask=[False]*((x1-x0)*(y1-y0))
  for chunk in chunks:
   bb=chunk['bounds'];x=round((bb['minLongitude']-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*48);y=round((b['maxLatitude']-bb['maxLatitude'])/(b['maxLatitude']-b['minLatitude'])*48)
   assert not mask[(y-y0)*(x1-x0)+x-x0];mask[(y-y0)*(x1-x0)+x-x0]=True
  places=[p for p in old['places'] if contains(primary,dict(minLongitude=p['coordinate']['longitude'],maxLongitude=p['coordinate']['longitude'],minLatitude=p['coordinate']['latitude'],maxLatitude=p['coordinate']['latitude']))]
  name='Eryri · '+(min(places,key=lambda p:abs(p['coordinate']['latitude']-cy)+abs(p['coordinate']['longitude']-cx))['name'] if places else part['id'])
  m=dict(schemaVersion=1,id=id,name=name,subtitle='Adaptive terrain',bounds=primary,sourceResolution=1,heightScale=.1,noDataValue=-32768,levels=[],textures=[],places=places,sources=old['sources'],defaultSpacing=0,version='adaptive-v1',summary='Prepared adaptive terrain and offline maps.',verticalDatum=old.get('verticalDatum'),grid=dict(gridID='ridge-native-adaptive-v1',worldTileID=part['id'],originColumn=x0,originRow=y0,columns=x1-x0,rows=y1-y0),horizon=horizon,cartography=maps,adaptive=dict(toleranceMetres=.5,isSource=True,chunks=chunks,coverage=mask,graphs=graphs))
  raw=write(out/'index.json',m)
  stub=copy.deepcopy(m);stub.pop('horizon');stub.pop('cartography');stub['adaptive'].update(chunks=[],graphs=[],index=dict(file='index.json',byteCount=len(raw),sha256=digest(raw)))
  write(out/'pack.json',stub);stubs.append(stub)
  report.append(dict(id=id,chunks=len(chunks),mapImages=len(tiles),sourceGeometry=str(src),sourceMap=str(oldpath)))
  print(f'{id}: {len(chunks)} adaptive chunks, {len(tiles)} existing map cells',flush=True)
 staged=root/'catalog-adaptive-next.json';write(staged,dict(schemaVersion=2,sources=stubs));write(root/'adaptive-app-publication.json',dict(sources=report,notes='Only regions with existing complete cartography/path assets are advertised. Whole-UK geometry remains preserved.'))
 if activate:
  oldcatalog=root/'catalog.json';backup=root/'catalog-regular-rollback.json'
  if oldcatalog.exists() and not backup.exists():backup.write_bytes(oldcatalog.read_bytes())
  staged.replace(oldcatalog)
 print(f'Prepared {len(stubs)} app sources; activated={activate}',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--maps',type=Path,required=True);p.add_argument('--activate',action='store_true');a=p.parse_args();publish(a.root,a.maps,a.activate)
