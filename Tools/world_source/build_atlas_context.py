#!/usr/bin/env python3
"""Add public-domain Natural Earth physical context to the retained atlas.

Inputs are GeoJSON files from nvkelso/natural-earth-vector/geojson:
ne_10m_geography_regions_polys, ne_50m_lakes,
ne_50m_rivers_lake_centerlines, ne_10m_lakes,
ne_10m_rivers_lake_centerlines. Use --input for the cached directory.
These are geographic features, not an elevation model or hiking-scale map.
"""
import argparse, json, math
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--atlas',type=Path,required=True);a=p.parse_args()
def simplify(points, tolerance):
    if len(points)<3:return points
    x,y=points[0];dx=points[-1][0]-x;dy=points[-1][1]-y;length=dx*dx+dy*dy
    best,index=0,0
    for i,(px,py) in enumerate(points[1:-1],1):
        t=max(0,min(1,((px-x)*dx+(py-y)*dy)/length)) if length else 0
        d=(px-x-t*dx)**2+(py-y-t*dy)**2
        if d>best:best,index=d,i
    if best>tolerance*tolerance:return simplify(points[:index+1],tolerance)[:-1]+simplify(points[index:],tolerance)
    return [points[0],points[-1]]
def british(points):return any(-11<x<3 and 49<y<61 for x,y in points)
features=[];provenance=[]
for filename,kind,regional in [('regions.json','upland',False),('lakes.json','lake',False),('rivers.json','river',False),('lakes-10m.json','lake',True),('rivers-10m.json','river',True)]:
    raw=(a.input/filename).read_bytes()
    import hashlib
    provenance.append(dict(file=filename,sha256=hashlib.sha256(raw).hexdigest()))
    for feature in json.loads(raw)['features']:
        props=feature['properties'];g=feature['geometry']
        if kind=='upland' and props['FEATURECLA'] not in ['Range/mtn','Plateau','Foothills']:continue
        parts=g['coordinates'] if g['type'] in ['MultiPolygon','MultiLineString'] else [g['coordinates']]
        for part in parts:
            rings=part if g['type'] in ['Polygon','MultiPolygon'] else [part]
            points=[p[:2] for r in rings for p in r]
            if kind!='upland' and british(points)!=regional:continue
            tolerance=.001 if regional else .02
            reduced=[[[round(x,4),round(y,4)] for x,y in simplify([p[:2] for p in ring],tolerance)] for ring in rings]
            reduced=[r for r in reduced if len(r)>=(4 if kind!='river' else 2)]
            if not reduced:continue
            xs,ys=zip(*points)
            features.append(dict(kind=kind,name=props.get('NAME') or props.get('name') or '',rings=reduced,bounds=dict(minLatitude=max(-85,min(ys)),maxLatitude=min(85,max(ys)),minLongitude=min(xs),maxLongitude=max(xs))))
path=a.atlas;atlas=json.loads(path.read_bytes());atlas['physicalFeatures']=features
path.write_text(json.dumps(atlas,separators=(',',':'))+'\n')
(a.input/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
print(f'{len(features)} physical features; atlas {path.stat().st_size:,} bytes')
