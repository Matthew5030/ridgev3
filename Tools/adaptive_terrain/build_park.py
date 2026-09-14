#!/usr/bin/env python3
"""Compile a resumable fixed-scene Eryri stress pack from existing 1 m sources.
No terrain resampling, streaming or tolerance downgrades. Run in the experiment
venv with numpy, shapely and pyproj. All generated data belongs in Tools/reports.
"""
import argparse, concurrent.futures, hashlib, json, pathlib, subprocess, time, math, fcntl
from shapely.geometry import shape, box, mapping
from shapely.ops import unary_union, transform
from pyproj import Transformer
P=argparse.ArgumentParser();P.add_argument('--source',type=pathlib.Path,required=True);P.add_argument('--fallback',type=pathlib.Path);P.add_argument('--boundary',type=pathlib.Path,required=True);P.add_argument('--output',type=pathlib.Path,required=True);P.add_argument('--compiler',type=pathlib.Path,required=True);P.add_argument('--workers',type=int,default=6);a=P.parse_args()
a.output.mkdir(parents=True,exist_ok=True)
lock=(a.output/'.build.lock').open('w')
fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
(a.output/'meshes').mkdir(exist_ok=True)
feature=json.loads(a.boundary.read_text());park=shape(feature['geometry']);project=Transformer.from_crs(4326,27700,always_xy=True).transform
bbox=lambda b:box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])
selected={}; unavailable=[]
west,south,east,north=park.bounds
xs=range(math.floor((west+180)/360*1024),math.floor((east+180)/360*1024)+1)
def tile_y(lat):return math.floor((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*1024)
ys=range(tile_y(north),tile_y(south)+1)
for root in filter(None,[a.source,a.fallback]):
 for path in [root/f'tiles/10/{x}/{y}/manifest.json' for x in xs for y in ys]:
  if not path.exists():continue
  m=json.loads(path.read_text())
  if not park.intersects(bbox(m['bounds'])):continue
  complete=path.with_name('COMPLETE.json')
  if complete.exists():
   expected=json.loads(complete.read_text()).get('manifestSHA256')
   if expected and hashlib.sha256(path.read_bytes()).hexdigest()!=expected:raise ValueError(f'Manifest checksum: {path}')
  for parent in m['parents']:
   if not park.intersects(bbox(parent['bounds'])):continue
   if parent['status']!='available': unavailable.append({'tile':m['tileID'],'parent':parent['id'],'reason':parent.get('reasonCode'),'bounds':parent['bounds']})
   for child in parent.get('precisionChildren',[]):
    if not park.intersects(bbox(child['bounds'])):continue
    levels=[l for l in child.get('lods',[]) if l['nominalSpacingMetres']==1]
    if not levels:continue
    level=levels[0];key=f"{m['tileID']}-{parent['id']}-{child['id']}"
    if key in selected:continue
    t=level['terrain']
    if (t['width'],t['height'],t['scaleMetres'],t['sampleFormat'],t['byteOrder'])!=(513,513,.1,'int16','little-endian'):raise ValueError('Unsupported source format')
    selected[key]={'id':key,'bounds':child['bounds'],'source':str(path.parent/'parents'/parent['id']/level['path']),'sourceSHA256':level['sha256'],'sourceByteCount':level['byteCount']}
coverage=unary_union([bbox(c['bounds']) for c in selected.values()]);gap=park.difference(coverage)
(a.output/'coverage-gaps.geojson').write_text(json.dumps({'type':'Feature','properties':{'description':'No prepared 1 m source; not covered by the adaptive error guarantee'},'geometry':mapping(gap)}))
(a.output/'boundary.geojson').write_text(json.dumps(feature))
compiler_hash=hashlib.sha256(a.compiler.read_bytes()).hexdigest();started=time.time()
manifest={'schemaVersion':1,'id':'eryri-park-adaptive-0p5','name':'Eryri National Park · 0.5 m experiment','surfaceToleranceMetres':.5,'sourceSpacingMetres':1,'nativeGridSize':513,'meshFormat':'RME1','compilerSHA256':compiler_hash,'parkAreaKm2':transform(project,park).area/1e6,'uncoveredParkAreaKm2':transform(project,gap).area/1e6,'bounds':dict(zip(['minLongitude','minLatitude','maxLongitude','maxLatitude'],park.bounds)),'coveragePolicy':'Whole native chunks intersecting park. Missing prepared 1 m coverage is explicitly excluded. No coarse substitution.','chunks':[]}
print(json.dumps({k:v for k,v in manifest.items() if k!='chunks'}),flush=True)
print(f'Compiling {len(selected)} chunks',flush=True)
def build(c):
 out=a.output/'meshes'/f"{c['id']}.rmesh";record=out.with_suffix('.json')
 if record.exists() and out.exists():
  old=json.loads(record.read_text())
  if old.get('compilerSHA256')==compiler_hash and old['sourceSHA256']==c['sourceSHA256'] and hashlib.sha256(out.read_bytes()).hexdigest()==old['sha256']:return old
 data=pathlib.Path(c['source']).read_bytes()
 if len(data)!=c['sourceByteCount'] or hashlib.sha256(data).hexdigest()!=c['sourceSHA256']:raise ValueError(f"Source checksum {c['id']}")
 tmp=out.with_suffix('.tmp');result=subprocess.run([str(a.compiler),c['source'],str(tmp)],capture_output=True,text=True,check=True)
 stats=json.loads(result.stdout);tmp.replace(out)
 result={**c,**stats,'compilerSHA256':compiler_hash,'path':str(out.relative_to(a.output)),'sha256':hashlib.sha256(out.read_bytes()).hexdigest()}
 record.write_text(json.dumps(result));return result
with concurrent.futures.ThreadPoolExecutor(a.workers) as executor:
 futures={executor.submit(build,c):c for c in selected.values()}
 for i,f in enumerate(concurrent.futures.as_completed(futures),1):
  try: manifest['chunks'].append(f.result())
  except BaseException:
   for pending in futures: pending.cancel()
   raise
  if i%250==0:print(json.dumps({'done':i,'total':len(selected),'seconds':round(time.time()-started,1),'triangles':sum(c['triangles'] for c in manifest['chunks'])}),flush=True)
manifest['chunks'].sort(key=lambda c:c['id'])
for key in ['vertices','triangles','metalGeometryBytes','compactBytes']:manifest[key]=sum(c[key] for c in manifest['chunks'])
manifest['maximumMeasuredErrorMetres']=max(c['maxErrorMetres'] for c in manifest['chunks']);manifest['buildSeconds']=time.time()-started
(a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps({k:v for k,v in manifest.items() if k!='chunks'},indent=2),flush=True)
