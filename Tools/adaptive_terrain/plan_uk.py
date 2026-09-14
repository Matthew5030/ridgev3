#!/usr/bin/env python3
"""Freeze a UK grid selection from existing verified native heightfields."""
from pathlib import Path
import json,hashlib,time,concurrent.futures,argparse
from shapely.geometry import shape,box,mapping
from shapely.ops import unary_union,transform
from pyproj import Transformer
from survey_coverage import SurveyCoverage,requires_ea_coverage
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',type=Path,required=True);p.add_argument('--source',type=Path,action='append',required=True)
p.add_argument('--boundary',type=Path,required=True);p.add_argument('--world-grid',type=Path,required=True);p.add_argument('--workers',type=int,default=3)
p.add_argument('--coordinate-grids',type=Path,required=True);p.add_argument('--source-policy',type=Path);p.add_argument('--ea-coverage',type=Path,required=True);p.add_argument('--id',default='uk-adaptive-0p5-v3')
a=p.parse_args()
if not 1<=a.workers<=8:p.error('Use 1–8 audit workers')
if any(not root.is_dir() for root in a.source):p.error('Every source root must exist')
ROOT=a.output;ROOT.mkdir(parents=True,exist_ok=True)
if (ROOT/'build-inputs.json').exists():raise ValueError('A build has frozen this plan; audit into a new directory')
roots=a.source;config=a.boundary;world_path=a.world_grid
feature=json.loads(config.read_text());uk=shape(feature['geometry']);world=json.loads(world_path.read_text())
(ROOT/'boundary.geojson').write_bytes(config.read_bytes());(ROOT/'world-grid.json').write_bytes(world_path.read_bytes())
project=Transformer.from_crs(4326,27700,always_xy=True).transform
bbox=lambda b:box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])
started=time.monotonic()
survey=SurveyCoverage(a.ea_coverage,a.coordinate_grids)
print('Verified official survey footprints:',survey.provenance['featureCount'],flush=True)
policy_raw=a.source_policy.read_bytes() if a.source_policy else b''
policy=json.loads(policy_raw) if policy_raw else dict(rules=[])
rules={}
for rule in policy['rules']:
 if rule['crs']!='EPSG:27700':raise ValueError('Source ownership must use British National Grid')
 rules[str(Path(rule['sourceRoot']).resolve())]=box(*rule['bounds'])
def scan(tile):
 b=tile['bounds'];area=uk.intersection(bbox(b));selected={};manifests=[];rejected=set();by_source={};ea_area=None;claimed=set();suppressed=set()
 for root in roots:
  path=root/f"tiles/10/{tile['x']}/{tile['y']}/manifest.json"
  if not path.exists():continue
  raw=path.read_bytes();m=json.loads(raw);sha=hashlib.sha256(raw).hexdigest();complete=path.with_name('COMPLETE.json')
  if complete.exists():assert json.loads(complete.read_text())['manifestSHA256']==sha
  manifests.append(dict(path=str(path),sha256=sha))
  check_ea=requires_ea_coverage(m)
  if check_ea and ea_area is None:ea_area=survey.for_bounds(b)
  ownership=rules.get(str(root.resolve()));claims=set()
  for parent in m['parents']:
   for child in parent.get('precisionChildren',[]):
    if not area.intersects(bbox(child['bounds'])):continue
    key=f"{m['tileID']}-{parent['id']}-{child['id']}"
    if ownership is not None and ownership.intersects(survey.envelope(child['bounds'])):claims.add(key)
    lod=next((l for l in child.get('lods',[]) if l['nominalSpacingMetres']==1),None)
    if not lod:continue
    if key in claimed:suppressed.add(key);continue
    t=lod['terrain']
    if (t['width'],t['height'],t['scaleMetres'],t['sampleFormat'],t['byteOrder'])!=(513,513,.1,'int16','little-endian'):raise ValueError('Unsupported native terrain format')
    if lod['byteCount']!=513*513*2:raise ValueError('Unexpected native heightfield length')
    key=f"{m['tileID']}-{parent['id']}-{child['id']}"
    if key in selected:continue
    if check_ea and not survey.accepts(ea_area,child['bounds']):rejected.add(key);continue
    selected[key]=dict(id=key,bounds=child['bounds'],source=str(path.parent/'parents'/parent['id']/lod['path']),sourceSHA256=lod['sha256'],sourceByteCount=lod['byteCount'])
    source_name=m['source']['name'];by_source[source_name]=by_source.get(source_name,0)+1
  claimed.update(claims)
 coverage=unary_union([bbox(c['bounds']) for c in selected.values()]);covered=area.intersection(coverage)
 d=dict(id=tile['tileID'],x=tile['x'],y=tile['y'],bounds=b,chunkCount=len(selected),sourceBytes=sum(c['sourceByteCount'] for c in selected.values()),coveredPolygonKm2=transform(project,covered).area/1e6,polygonKm2=transform(project,area).area/1e6,sourceManifests=manifests,rejectedEACandidates=len(rejected),rejectedWithoutFallback=len(rejected-set(selected)),suppressedFallbackCandidates=len(suppressed-set(selected)),selectedBySource=by_source,chunks=list(selected.values()))
 out=ROOT/'selection';out.mkdir(exist_ok=True);(out/(tile['tileID']+'.json')).write_text(json.dumps(d,separators=(',',':')))
 return {k:v for k,v in d.items() if k not in ['chunks']}
result=[]
with concurrent.futures.ThreadPoolExecutor(a.workers) as pool:
 for row in pool.map(scan,world['tiles']):
  result.append(row)
  if len(result)%25==0:print(len(result),'/',len(world['tiles']),'chunks',sum(r['chunkCount'] for r in result),'seconds',round(time.monotonic()-started),flush=True)
plan=dict(schemaVersion=1,id=a.id,sourceSelectionPolicy=dict(sha256=hashlib.sha256(policy_raw).hexdigest(),description=policy.get('description','No extra source ownership rules'),suppressedFallbackCandidates=sum(r['suppressedFallbackCandidates'] for r in result)),officialSurveyCoverage=survey.provenance,rejectedEACandidates=sum(r['rejectedEACandidates'] for r in result),rejectedWithoutFallback=sum(r['rejectedWithoutFallback'] for r in result),boundarySHA256=hashlib.sha256(config.read_bytes()).hexdigest(),worldGridSHA256=hashlib.sha256(world_path.read_bytes()).hexdigest(),sourceRoots=list(map(str,roots)),partitions=result,chunkCount=sum(r['chunkCount'] for r in result),sourceBytes=sum(r['sourceBytes'] for r in result),coveredPolygonKm2=sum(r['coveredPolygonKm2'] for r in result),polygonKm2=sum(r['polygonKm2'] for r in result))
(ROOT/'plan.json').write_text(json.dumps(plan,indent=2));print(json.dumps({k:v for k,v in plan.items() if k!='partitions'},indent=2),flush=True)
