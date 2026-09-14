#!/usr/bin/env python3
"""Prepare a separate coarse UK background from checksum-locked Skadi inputs.
This is not 1 m LiDAR and carries no 0.5 m survey-accuracy claim.
"""
import argparse,gzip,hashlib,json,math,re,time
from collections import OrderedDict
from pathlib import Path
import numpy as np
from shapely.geometry import shape,box
from shapely import intersects_xy,prepare
from publish_adaptive import atomic_json


def sha(data):return hashlib.sha256(data).hexdigest()


class Sampler:
    def __init__(self,root,entries):
        self.root=root;self.entries={e['tile']:e for e in entries};self.cache=OrderedDict();self.used={}
    def tile(self,lat,lon):
        key=f"{'N' if lat>=0 else 'S'}{abs(lat):02d}{'E' if lon>=0 else 'W'}{abs(lon):03d}"
        if key not in self.cache:
            e=self.entries[key];path=self.root/e['path'];raw=path.read_bytes()
            if len(raw)!=e['sizeBytes'] or sha(raw)!=e['sha256']:raise ValueError(f'Skadi source checksum: {key}')
            data=gzip.decompress(raw);side=e['samplesPerSide']
            if len(data)!=side*side*2:raise ValueError('HGT dimensions')
            self.cache[key]=np.frombuffer(data,dtype='>i2').reshape(side,side).astype(np.int16)
            self.used[key]={k:v for k,v in e.items() if k not in ('path',)}
            if len(self.cache)>8:self.cache.popitem(last=False)
        self.cache.move_to_end(key);return self.cache[key]
    def sample(self,lon,lat,inside):
        result=np.full(lon.shape,np.nan,dtype=np.float64)
        tile_lon=np.floor(lon).astype(int);tile_lat=np.floor(lat).astype(int)
        for n,e in sorted(set(zip(tile_lat[inside].tolist(),tile_lon[inside].tolist()))):
            choose=inside&(tile_lon==e)&(tile_lat==n);h=self.tile(n,e);size=h.shape[0]-1
            x=(lon[choose]-e)*size;y=(n+1-lat[choose])*size
            x0=np.clip(np.floor(x).astype(int),0,size);y0=np.clip(np.floor(y).astype(int),0,size);x1=np.minimum(x0+1,size);y1=np.minimum(y0+1,size)
            fx=x-x0;fy=y-y0;a=h[y0,x0].astype(float);b=h[y0,x1].astype(float);c=h[y1,x0].astype(float);d=h[y1,x1].astype(float)
            valid=(a!=-32768)&(b!=-32768)&(c!=-32768)&(d!=-32768)
            values=a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy;values[~valid]=np.nan;result[choose]=values
        return result


def main():
    import fcntl,zlib
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,required=True);p.add_argument('--source-lock',type=Path,required=True);p.add_argument('--source-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);lock=(a.output/'.build.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    raw_lock=a.source_lock.read_bytes();source=json.loads(raw_lock);world_raw=(a.build/'world-grid.json').read_bytes();world=json.loads(world_raw);boundary_raw=(a.build/'boundary.geojson').read_bytes();uk=shape(json.loads(boundary_raw)['geometry'])
    identity=dict(sourceLockSHA256=sha(raw_lock),worldGridSHA256=sha(world_raw),boundarySHA256=sha(boundary_raw),builderSHA256=sha(Path(__file__).read_bytes()))
    identity_path=a.output/'inputs.json'
    if identity_path.exists() and json.loads(identity_path.read_text())!=identity:raise ValueError('Changed background inputs: use a new revision')
    atomic_json(identity_path,identity)
    prepare(uk)
    sampler=Sampler(a.source_root,source['elevation']['tiles']);entries=[];edges={};seams=0;started=time.monotonic();total_valid=0
    for tile in world['tiles']:
        b=tile['bounds'];lon=np.round(np.linspace(b['minLongitude'],b['maxLongitude'],513),12);lat=np.round(np.linspace(b['maxLatitude'],b['minLatitude'],513),12);xx,yy=np.meshgrid(lon,lat)
        # Use the shared UK mask, not a separately clipped tile polygon: tiny
        # coordinate rounding at a tile edge must not flip its NoData mask.
        inside=intersects_xy(uk,xx,yy)
        values=sampler.sample(xx,yy,inside);valid=np.isfinite(values);h=np.full(values.shape,-32768,dtype='<i2');quantized=np.rint(values[valid]*10)
        if len(quantized) and (quantized.min()<=-32768 or quantized.max()>32767):raise ValueError('Background elevation exceeds declared height format')
        h[valid]=quantized.astype('<i2');total_valid+=int(valid.sum())
        for axis,coord,lo,hi,line in [('x',b['minLongitude'],b['minLatitude'],b['maxLatitude'],h[:,0]),('x',b['maxLongitude'],b['minLatitude'],b['maxLatitude'],h[:,-1]),('y',b['maxLatitude'],b['minLongitude'],b['maxLongitude'],h[0,:]),('y',b['minLatitude'],b['minLongitude'],b['maxLongitude'],h[-1,:])]:
            key=(axis,round(coord,10),round(lo,10),round(hi,10));raw=line.tobytes()
            if key in edges:
                if edges.pop(key)!=raw:raise ValueError(f'Coarse shared-edge mismatch at {tile["tileID"]}')
                seams+=1
            else:edges[key]=raw
        raw=h.tobytes();compressed=zlib.compress(raw,6)
        if zlib.decompress(compressed)!=raw:raise ValueError('Background round-trip')
        filename=tile['tileID']+'.height.zlib';temporary=a.output/(filename+'.tmp');temporary.write_bytes(compressed);temporary.replace(a.output/filename)
        entries.append(dict(id=tile['tileID'],bounds=b,path=filename,byteCount=len(compressed),sha256=sha(compressed),decodedByteCount=len(raw),decodedSHA256=sha(raw),validSampleCount=int(valid.sum())))
        if len(entries)%25==0:print('Coarse sections:',len(entries),'seconds:',round(time.monotonic()-started),flush=True)
    provenance={k:v for k,v in source['elevation'].items() if k!='tiles'};provenance['tiles']=list(sampler.used.values())
    catalog=dict(schemaVersion=1,id='uk-coarse-background',name='United Kingdom coarse background',contentKind='coarse-background-heightfields',requiredReader='int16-heightfield-zlib-v1',quality='Coarse global elevation; not detailed LiDAR. Grid spacing is not survey accuracy.',width=513,height=513,scaleMetres=.1,noDataValue=-32768,sampleFormat='int16',byteOrder='little-endian',horizontalCRS='EPSG:4326',verticalCRS='EPSG:5773',source=provenance,inputFingerprints=identity,partitions=entries,byteCount=sum(e['byteCount'] for e in entries),validSampleCount=total_valid,sharedEdgesChecked=seams,maxSharedEdgeDifferenceMetres=0)
    atomic_json(a.output/'background.json',catalog);print(json.dumps({k:v for k,v in catalog.items() if k not in ['partitions','source','inputFingerprints']}),flush=True)


if __name__=='__main__':main()
