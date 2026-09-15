#!/usr/bin/env python3
"""Inventory retained semantic features and raw source tags without inference."""
import argparse,collections,hashlib,json,zipfile
from pathlib import Path
from preview import category

def main():
    p=argparse.ArgumentParser();p.add_argument('archive',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    raw=a.archive.read_bytes()
    with zipfile.ZipFile(a.archive) as z:data=json.loads(z.read('map-data.ridgemap'))
    fs=data['features'];keys=['natural','landuse','landcover','waterway','wetland','leaf_type','highway','surface','smoothness','tracktype','sac_scale','trail_visibility','access','foot','horse','bicycle','designation','access:conditional','foot:conditional','bridge','tunnel','ford','barrier','amenity','tourism','historic','railway','route','name:cy','name:en']
    counts={k:dict(collections.Counter(f.get('source',{}).get('tags',{}).get(k) for f in fs if k in f.get('source',{}).get('tags',{}))) for k in keys}
    report=dict(archive=str(a.archive),sha256=hashlib.sha256(raw).hexdigest(),featureCount=len(fs),featureKinds=dict(collections.Counter(f['kind'] for f in fs)),landcoverClasses=dict(collections.Counter(category(f) or 'not classified as land cover' for f in fs)),tags=counts,notes=['Counts are clipped feature pieces, not unique OSM objects or areas.','Only retained semantic features are counted. Features omitted by the original import cannot be recovered by changing the renderer.','Raw source.tags survive in these records; the current renderer mostly uses coarse kind and ignores them.','An absent tag is unknown, not evidence that a physical feature does not exist.'])
    a.output.write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
    print(json.dumps({k:report[k] for k in ['featureCount','featureKinds','landcoverClasses']},indent=2))
if __name__=='__main__':main()
