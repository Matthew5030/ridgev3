#!/usr/bin/env python3
"""Export the reviewed blocks into the app resource, without repackaging terrain."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def main():
    raw=(ROOT/'Artifacts/larger-regions-preview/regions.json').read_bytes()
    draft=json.loads(raw)
    baseline=json.loads(Path(__file__).with_name('baseline-download-zones.json').read_text())
    parks={p['id']:p for p in baseline['parks']}
    areas=[]
    for area in draft['regions']:
        item={k:area[k] for k in ['id','name','mapLabel','cells','mapShapes','labelBounds']}
        item['subtitle']='Offline map'
        if area.get('downloadCells') is not None:item['downloadCells']=area['downloadCells']
        if area.get('parkIDs'):
            if len(area['parkIDs'])!=1:raise ValueError('Expected one named park per block')
            park=parks[area['parkIDs'][0]]
            item.update(parkID=park['id'],parkName=park['name'],artwork=park.get('artwork','countryside'),subtitle='Park and surrounding area')
        areas.append(item)
    out=dict(schemaVersion=3,revision='coastal-blocks-2026-10-18',
             description='Non-overlapping coastal map areas with complete park download memberships.',
             layoutSHA256=hashlib.sha256(raw).hexdigest(),boundarySources=draft['boundarySources'],regions=areas,parks=[])
    target=ROOT/'ridge v3/Resources/uk-download-zones.json'
    target.write_text(json.dumps(out,separators=(',',':'),ensure_ascii=False)+'\n')
    print('Installed',len(areas),'map areas in',target)

if __name__=='__main__':main()
