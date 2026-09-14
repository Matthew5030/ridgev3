#!/usr/bin/env python3
"""Snapshot all EA 2022 1 m DTM survey polygons with resumable, verified batches."""
from pathlib import Path
import urllib.request,urllib.parse,json,hashlib,concurrent.futures,time,argparse
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('output',type=Path);args=parser.parse_args()
root=args.output;root.mkdir(parents=True,exist_ok=True)
base='https://environment.data.gov.uk/KB6uNVj5ZcJr7jUP/ArcGIS/rest/services/LIDAR_Composite_Catalogues/FeatureServer/2'
def get(url):
 for attempt in range(4):
  try:
   request=urllib.request.Request(url.split('?')[0],data=url.split('?',1)[1].encode()) if '/query?' in url else url
   with urllib.request.urlopen(request,timeout=90) as r:return r.read()
  except Exception:
   if attempt==3:raise
   time.sleep(2*(attempt+1))
meta_raw=get(base+'?f=pjson');meta=json.loads(meta_raw)
if (root/'layer.json').exists() and json.loads((root/'layer.json').read_bytes())['editingInfo']!=meta['editingInfo']:raise ValueError('Changed official catalogue: use a new snapshot directory')
(root/'layer.json').write_bytes(meta_raw)
ids_raw=get(base+'/query?'+urllib.parse.urlencode(dict(where='1=1',returnIdsOnly='true',f='json')));ids=sorted(json.loads(ids_raw)['objectIds']);(root/'ids.json').write_bytes(ids_raw)
def batch(start):
 chosen=ids[start:start+250];path=root/f'features-{start:05d}.geojson'
 url=base+'/query?'+urllib.parse.urlencode(dict(objectIds=','.join(map(str,chosen)),outFields='objectid,FILENAME',returnGeometry='true',outSR=27700,f='geojson'))
 raw=path.read_bytes() if path.exists() else get(url);d=json.loads(raw)
 if d.get('error') or d.get('exceededTransferLimit') or sorted(f['id'] for f in d['features'])!=chosen:raise ValueError('Incomplete survey-footprint response')
 if d['crs']['properties']['name']!='EPSG:27700':raise ValueError('Footprint CRS')
 path.write_bytes(raw);return dict(path=path.name,sha256=hashlib.sha256(raw).hexdigest(),byteCount=len(raw),count=len(chosen),url=url)
parts=[]
with concurrent.futures.ThreadPoolExecutor(3) as pool:
 for item in pool.map(batch,range(0,len(ids),250)):
  parts.append(item);print('Footprints:',sum(p['count'] for p in parts),'/',len(ids),flush=True)
after=json.loads(get(base+'?f=pjson'))
if after['editingInfo']!=meta['editingInfo']:raise ValueError('Survey catalogue changed during acquisition')
index=dict(source=base,crs='EPSG:27700',editingInfo=meta['editingInfo'],featureCount=len(ids),parts=parts,license='Open Government Licence v3.0',attribution='Environment Agency LIDAR Composite DTM 1 m 2022 extents')
(root/'index.json').write_text(json.dumps(index,indent=2));print('Coverage footprint bytes:',sum(p['byteCount'] for p in parts),flush=True)
