#!/usr/bin/env python3
"""Prepare individual coastal chunks from the same immutable Welsh 1 m COG.
Unlike the older parent builder, one incomplete child does not discard its
otherwise valid siblings. Original sampling is reproduced against a reference.
"""
import argparse,fcntl,hashlib,json,os,sys,time,urllib.request
from pathlib import Path
os.environ['PROJ_NETWORK']='ON'
import numpy as np
import rasterio
from pyproj import Transformer
from publish_adaptive import atomic_json


def sha(raw):return hashlib.sha256(raw).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--mapping-root',type=Path,required=True);p.add_argument('--source-manifest',type=Path,required=True)
    p.add_argument('--reference-selection',type=Path,required=True);p.add_argument('--reference-id',required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--tile',default='10/502/341');a=p.parse_args()
    sys.path.insert(0,str(a.mapping_root));from scripts import precision_tile_builder as native
    from scripts.build_snowdon_pyramid import source_samples
    z,x,y=map(int,a.tile.split('/'))
    if z!=10:p.error('Only the established z10 grid is supported')
    source_manifest_raw=a.source_manifest.read_bytes();source=json.loads(source_manifest_raw)['source']
    if source['adapter']!='cog' or source['horizontalCRS']!='EPSG:27700':raise ValueError('Expected Welsh COG source')
    def source_identity():
        with urllib.request.urlopen(urllib.request.Request(source['dataURL'],method='HEAD'),timeout=60) as r:
            if r.headers['ETag'].strip('"')!=source['etag'].strip('"'):raise ValueError('Welsh COG version changed')
            return dict(etag=r.headers['ETag'],byteCount=int(r.headers['Content-Length']),lastModified=r.headers['Last-Modified'])
    identity=dict(remote=source_identity(),sourceManifestSHA256=sha(source_manifest_raw),builderSHA256=sha(Path(__file__).read_bytes()),samplerSHA256=sha((a.mapping_root/'scripts/build_snowdon_pyramid.py').read_bytes()))
    a.output.mkdir(parents=True,exist_ok=True);lock=(a.output/'.build.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    frozen=a.output/'inputs.json'
    if frozen.exists() and json.loads(frozen.read_bytes())!=identity:raise ValueError('Changed preparation inputs')
    atomic_json(frozen,identity)
    project=Transformer.from_crs(4326,27700,always_xy=True);vertical=Transformer.from_crs(7405,9707,always_xy=True)
    reference=next(c for c in json.loads(a.reference_selection.read_bytes())['chunks'] if c['id']==a.reference_id)
    old=Path(reference['source']).read_bytes()
    if sha(old)!=reference['sourceSHA256']:raise ValueError('Reference source checksum')
    tile_root=a.output/f'tiles/{z}/{x}/{y}';tile_root.mkdir(parents=True,exist_ok=True);parents=[];count=0;checked=0;started=time.monotonic()
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN='EMPTY_DIR',GDAL_HTTP_MULTIRANGE='YES',GDAL_CACHEMAX=128,PROJ_NETWORK='ON'):
        with rasterio.open(source['dataURL']) as dataset:
            if dataset.crs.to_epsg()!=27700:raise ValueError('Source CRS')
            sampled=source_samples(dataset,reference['bounds'],project,vertical,samples=513)
            if sampled is None or sampled.tobytes()!=old:raise ValueError('Sampling does not reproduce the retained Welsh reference exactly')
            print('Existing Welsh reference reproduced byte-for-byte.',flush=True)
            extent=list(dataset.bounds)
            for py in range(12):
                for px in range(12):
                    parent=dict(id=f'c{px:02d}-{py:02d}',parentX=px,parentY=py,precisionChildren=[])
                    for cy in range(4):
                        for cx in range(4):
                            b=native.child_bounds(z,x,y,px,py,cx,cy);key=f'p{cx:02d}-{cy:02d}';record=tile_root/'parents'/parent['id']/'precision'/key/'chunk.json'
                            if record.exists():
                                child=json.loads(record.read_bytes())
                                if child.get('lods'):
                                    level=child['lods'][0];raw=(tile_root/'parents'/parent['id']/level['path']).read_bytes()
                                    if sha(raw)!=level['sha256'] or len(raw)!=level['byteCount']:raise ValueError('Cached native chunk checksum')
                            else:
                                west,south,east,north=project.transform_bounds(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'],densify_pts=21)
                                values=None
                                if west>=extent[0] and south>=extent[1] and east<=extent[2] and north<=extent[3]:values=source_samples(dataset,b,project,vertical,samples=513)
                                child=dict(id=key,bounds=b,status='unavailable',reasonCode='noCompleteWelshLidarCoverage',lods=[])
                                if values is not None:
                                    raw=values.tobytes();path=f'precision/{key}/lod-1m.bin';destination=tile_root/'parents'/parent['id']/path;destination.parent.mkdir(parents=True,exist_ok=True);temporary=destination.with_suffix('.tmp');temporary.write_bytes(raw);temporary.replace(destination)
                                    child=dict(id=key,bounds=b,status='available',lods=[dict(nominalSpacingMetres=1,byteCount=len(raw),sha256=sha(raw),path=path,terrain=native.terrain_metadata(b,513))])
                                record.parent.mkdir(parents=True,exist_ok=True);atomic_json(record,child)
                            parent['precisionChildren'].append(child);count+=bool(child['lods']);checked+=1
                    parents.append(parent)
                print('Checked',checked,'native chunks; complete Welsh chunks:',count,'seconds',round(time.monotonic()-started),flush=True)
    if source_identity()!=identity['remote']:raise ValueError('Welsh COG changed during preparation')
    source.update(preparation='Individual 513 × 513 native chunks; original bilinear ODN-to-EGM96 sampling, exact reference reproduction, no NoData filling.',preparationInputFingerprints=identity)
    manifest=dict(schemaVersion=1,productID='welsh-coast-precision',productVersion='2026.09.14-1',tileID=f'z10-x{x}-y{y}',z=z,x=x,y=y,sourceKey='wales',source=source,sourceEnvelopeBNG=extent,availablePrecisionChunkCount=count,parents=parents)
    atomic_json(tile_root/'manifest.json',manifest);atomic_json(tile_root/'COMPLETE.json',dict(manifestSHA256=sha((tile_root/'manifest.json').read_bytes())))
    print('Welsh coastal source complete:',count,flush=True)


if __name__=='__main__':main()
