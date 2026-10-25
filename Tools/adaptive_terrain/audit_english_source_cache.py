#!/usr/bin/env python3
"""Verify saved EA GeoTIFF blocks and compressed native arrays after recovery."""
import argparse,concurrent.futures,gzip,json,re,sys
from pathlib import Path
from pyproj import datadir,Transformer
from rasterio.io import MemoryFile
from prepare_english_border import fetch_parent,sha,raw,atomic,emit


def main():
    p=argparse.ArgumentParser()
    for name in ['cache','previous','mapping','grids']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();datadir.append_data_dir(str(a.grids));plan=json.loads((a.cache/'plan.json').read_bytes())
    if json.loads((a.cache/'preparation-status.json').read_bytes())['state']!='complete':raise ValueError('Complete native preparation before auditing all cached input')
    sys.path.insert(0,str(a.mapping));from scripts.build_snowdon_pyramid import source_samples
    rows={r['id']:r for r in plan['sections']};project=Transformer.from_crs(4326,27700,always_xy=True);vertical=Transformer.from_crs(7405,9707,always_xy=True)
    def native(file):
        record=json.loads(file.read_bytes());lod=record['lods'][0];path=Path(lod['compressedArchive']);data=gzip.decompress(path.read_bytes())
        if len(data)!=lod['byteCount'] or sha(data)!=lod['sha256']:raise ValueError('Native archive checksum: '+str(path))
        return len(data),path.stat().st_size
    receipts=sorted((a.cache/'native-archive').glob('*/*.bin.json'))
    with concurrent.futures.ThreadPoolExecutor(4) as pool:natives=list(pool.map(native,receipts))
    emit(event='native-cache-verified',files=len(natives))
    def response(file):
        ident=file.parent.name;row=rows.get(ident)
        if row is None:row=json.loads((a.previous/'selection'/(ident+'.json')).read_bytes())
        px,py=map(int,re.fullmatch(r'c(\d+)-(\d+)\.tif\.gz',file.name).groups())
        before=json.loads(file.with_suffix('.json').read_bytes())
        data,record=fetch_parent(a,plan['source'],row,px,py);reproduced=0
        x,y=re.fullmatch(r'z10-x(\d+)-y(\d+)',ident).groups();manifest=a.cache/f'native/tiles/10/{x}/{y}/manifest.json'
        if manifest.exists():
            parent=next(p for p in json.loads(manifest.read_bytes())['parents'] if p['id']==f'c{px:02d}-{py:02d}')
            children=[c for c in parent['precisionChildren'] if c['lods'] and c.get('sourceEvidence',{}).get('responseSHA256')!=record['sha256']]
            if children:
                with MemoryFile(data) as mem:
                    with mem.open() as ds:
                        for child in children:
                            sampled=source_samples(ds,child['bounds'],project,vertical,samples=513)
                            if sampled is None or sha(sampled.tobytes())!=child['lods'][0]['sha256']:raise ValueError('Replacing a truncated original changed native samples')
                            reproduced+=1
        return dict(path=str(file),byteCount=len(data),sha256=record['sha256'],replaced=before['sha256']!=record['sha256'],partialResponseSamplesReproduced=reproduced)
    files=sorted((a.cache/'wcs').glob('*/*.tif.gz'))
    with concurrent.futures.ThreadPoolExecutor(4) as pool:responses=list(pool.map(response,files))
    manifests={r['id']:sha((a.cache/f"native/tiles/10/{r['id'].split('-x')[1].split('-')[0]}/{r['id'].split('-y')[1]}/manifest.json").read_bytes()) for r in plan['sections']}
    report=dict(planSHA256=sha((a.cache/'plan.json').read_bytes()),nativeManifestSHA256=manifests,nativeArraysVerified=len(natives),nativeDecodedBytes=sum(x[0] for x in natives),nativeCompressedBytes=sum(x[1] for x in natives),rasterResponsesVerified=len(responses),rasterDecodedBytes=sum(x['byteCount'] for x in responses),truncatedResponsesReplaced=sum(x['replaced'] for x in responses),partialResponseSamplesReproduced=sum(x['partialResponseSamplesReproduced'] for x in responses),responses=responses)
    atomic(a.cache/'source-cache-audit.json',raw(report));emit(event='source-cache-audit-passed',**{k:v for k,v in report.items() if k!='responses'})


if __name__=='__main__':main()
