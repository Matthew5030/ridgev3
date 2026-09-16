#!/usr/bin/env python3
"""One normal-app Eryri source across native partition boundaries.

Reuse the audited UK-v3 chunks, existing maps/path graphs, and 8/32 m context.
No fine terrain is recomputed or resampled. Publish the catalogue last.
"""
import argparse,copy,json,os
from pathlib import Path
from app_publication import read,write,linked,digest,contains,bounds_at,intersects

def publish(root,oldpath,activate=False):
 old=read(oldpath/'pack.json'); source=root/'uk-adaptive-0p5-v3';cat=read(source/'catalog.json')
 out=root/'ridge-adaptive-v2-eryri';out.mkdir(exist_ok=True)
 native=[];xs=set();ys=set();evidence=[]
 fields='id bounds path byteCount sha256 decodedByteCount decodedSHA256 vertices triangles indexWidth topologyByteCount topologySHA256 byteOffset maxErrorMetres'.split()
 for part in cat['partitions']:
  if not intersects(part['bounds'],old['bounds']):continue
  index=source/part['path'];g=read(index);b=g['bounds']
  columns=[x for x in range(48) if bounds_at(b,x,0)['minLongitude']>=old['bounds']['minLongitude']-1e-10 and bounds_at(b,x,0)['maxLongitude']<=old['bounds']['maxLongitude']+1e-10]
  rows=[y for y in range(48) if bounds_at(b,0,y)['minLatitude']>=old['bounds']['minLatitude']-1e-10 and bounds_at(b,0,y)['maxLatitude']<=old['bounds']['maxLatitude']+1e-10]
  if not columns or not rows:continue
  box=bounds_at(b,min(columns),min(rows),len(columns),len(rows))
  chunks=[{k:copy.deepcopy(c[k]) for k in fields} for c in g['chunks'] if contains(box,c['bounds'])]
  # Retain the native axis through missing coverage, too.
  for x in columns:
   cell=bounds_at(b,x,rows[0]);xs.update([round(cell['minLongitude'],12),round(cell['maxLongitude'],12)])
  for y in rows:
   cell=bounds_at(b,columns[0],y);ys.update([round(cell['minLatitude'],12),round(cell['maxLatitude'],12)])
  if not chunks:continue
  file='terrain-'+part['id']+'.ratpack';linked(index.parent/g['container']['path'],out/file,g['container'])
  for chunk in chunks:chunk['path']=file
  native+=chunks;evidence.append(dict(path=str(index),sha256=digest(index.read_bytes()),chunks=len(chunks)))
  print(f'Reused {part["id"]}: {len(chunks)} native chunks',flush=True)
 lon=sorted(xs);lat=sorted(ys,reverse=True);columns=len(lon)-1;rows=len(lat)-1
 assert columns<=256 and rows<=256
 mask=[False]*(columns*rows);xx={x:i for i,x in enumerate(lon)};yy={y:i for i,y in enumerate(lat)}
 for c in native:
  x=xx[round(c['bounds']['minLongitude'],12)];y=yy[round(c['bounds']['maxLatitude'],12)]
  assert not mask[y*columns+x];mask[y*columns+x]=True
 bounds=dict(minLongitude=lon[0],maxLongitude=lon[-1],minLatitude=lat[-1],maxLatitude=lat[0])
 maps=copy.deepcopy(old['cartography']);maps['sourceOnly']=True
 for i,tile in enumerate(maps['tiles']):
  for image in tile.values():linked(oldpath/image['file'],out/image['file'],image)
  if i%2000==0:print(f'Reused {i}/{len(maps["tiles"])} map cells',flush=True)
 graphs=old['tiledTerrain']['graphs']
 for graph in graphs:linked(oldpath/graph['file'],out/graph['file'],graph)
 context=copy.deepcopy(old['horizon']);blocks=[]
 for key,spacing in [('near',8),('far',32)]:
  layer=context[key];level=next(l for l in layer['levels'] if l['spacing']==spacing)
  file=f'context-source-{spacing}m.bin';linked(oldpath/level['file'],out/file,level)
  with (oldpath/level['file']).open('rb') as stream:
   offset=0;block=0
   while raw:=stream.read(level['width']*2*16):
    blocks.append(dict(file=f'context-{spacing}m-b{block:05d}.bin',remoteFile=file,byteOffset=offset,byteCount=len(raw),sha256=digest(raw)))
    offset+=len(raw);block+=1
  assert offset==level['byteCount']
  level['file']=file;layer['levels']=[level];layer['textures']=[]
 places=[p for p in old['places'] if bounds['minLatitude']<=p['coordinate']['latitude']<=bounds['maxLatitude'] and bounds['minLongitude']<=p['coordinate']['longitude']<=bounds['maxLongitude']]
 m=dict(schemaVersion=1,id=out.name,name='Eryri',subtitle='Adaptive terrain',bounds=bounds,sourceResolution=1,heightScale=.1,noDataValue=-32768,levels=[],textures=[],places=places,sources=old['sources'],defaultSpacing=0,version='adaptive-native-v2',summary='Native adaptive terrain, offline maps and paths.',verticalDatum=old['verticalDatum'],grid=dict(gridID='ridge-native-adaptive-v1',worldTileID='eryri-native-v2',originColumn=0,originRow=0,columns=columns,rows=rows,longitudeEdges=lon,latitudeEdges=lat),cartography=maps,adaptive=dict(toleranceMetres=.5,isSource=True,chunks=native,coverage=mask,graphs=graphs,context=context,contextBlocks=blocks,overview=old['tiledTerrain']['overview']))
 linked(oldpath/old['tiledTerrain']['overview']['file'],out/old['tiledTerrain']['overview']['file'],old['tiledTerrain']['overview'])
 raw=write(out/'index.json',m);assert len(raw)<32_000_000
 stub=copy.deepcopy(m);stub.pop('cartography');stub['adaptive'].update(chunks=[],graphs=[],index=dict(file='index.json',byteCount=len(raw),sha256=digest(raw)));stub['adaptive'].pop('context');stub['adaptive'].pop('contextBlocks')
 write(out/'pack.json',stub);write(root/'catalog-adaptive-next.json',dict(schemaVersion=2,sources=[stub]))
 write(root/'adaptive-app-publication.json',dict(appSource=out.name,chunks=len(native),sourceIndexBytes=len(raw),nativeAxes=[columns,rows],geometryEvidence=evidence,mapEvidence=dict(path=str(oldpath/'pack.json'),sha256=digest((oldpath/'pack.json').read_bytes())),notes='Geometry is unchanged; map and path files are hard-linked. Existing 8 m and 32 m context is cropped only after selection. Other UK adaptive geometry is preserved but needs map/path publication before being advertised.'))
 if activate:
  backup=root/'catalog-regular-rollback.json'
  if not backup.exists():backup.write_bytes((root/'catalog.json').read_bytes())
  (root/'catalog-adaptive-next.json').replace(root/'catalog.json')
 print(f'Prepared {len(native)} native chunks, {columns} × {rows} grid; index {len(raw)} bytes; activated={activate}',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--maps',type=Path,required=True);p.add_argument('--activate',action='store_true');a=p.parse_args();publish(a.root,a.maps,a.activate)
