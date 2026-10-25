#!/usr/bin/env python3
"""Build an offline UK overview from verified elevation and retained geography.

The overview uses WorldCartography's palette and the terrain renderer's light.
It is geographic context, not a claim of detailed LiDAR coverage. Immutable
inputs, per-page checkpoints and atomic publication make interrupted runs safe.
"""
import argparse, collections, hashlib, json, math, os, re, shutil, time, zlib
from functools import lru_cache
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

SIZE=256
GUTTER=4
SEA=(168,203,209)
LAND=(237,233,217)

def sha(raw): return hashlib.sha256(raw).hexdigest()
def atomic_json(path, data):
    temporary=path.with_suffix(path.suffix+'.tmp')
    temporary.write_text(json.dumps(data,separators=(',',':'))+'\n');temporary.replace(path)
def key(z,x,y): return f'z{z}-x{x}-y{y}.jpg'
def mercator(lon,lat,z):
    return ((np.asarray(lon)+180)/360*2**z, (1-np.arcsinh(np.tan(np.radians(np.clip(lat,-85,85))))/math.pi)/2*2**z)
def intersects(a,b):
    return a[0]<=b[2] and b[0]<=a[2] and a[1]<=b[3] and b[1]<=a[3]

class Builder:
    def __init__(self,background,atlas,style,output):
        self.root=background.parent;self.output=output
        self.background=json.loads(background.read_bytes());self.atlas=json.loads(atlas.read_bytes())
        self.entries={p['id']:p for p in self.background['partitions']}
        self.features=[]
        # Retain real coastlines, lakes and rivers. No elevation-band polygons or
        # invented landcover. Fine vector map pages replace this regional context.
        for ring in self.atlas['land']:
            a=np.asarray(ring);self.features.append(('land',[ring],(a[:,0].min(),a[:,1].min(),a[:,0].max(),a[:,1].max())))
        for f in self.atlas.get('physicalFeatures',[]):
            if f['kind'] in ('lake','river'):
                b=f['bounds'];self.features.append((f['kind'],f['rings'],(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])))
        text=style.read_text()
        assert '0xede9d9' in text and '0xa8cbd1' in text, 'Palette changed: update generator explicitly'
        self.checkpoints=output/'checkpoints';self.checkpoints.mkdir(exist_ok=True)
        self.identity=dict(schemaVersion=1,builder=sha(Path(__file__).read_bytes()),background=sha(background.read_bytes()),atlas=sha(atlas.read_bytes()),style=sha(style.read_bytes()))
        old=output/'inputs.json'
        if old.exists() and json.loads(old.read_bytes())!=self.identity:raise ValueError('Input changed; choose a new output revision')
        atomic_json(old,self.identity)
    @lru_cache(maxsize=16)
    def height(self,x,y):
        e=self.entries.get(f'z10-x{x}-y{y}')
        if not e:return None
        raw=(self.root/e['path']).read_bytes()
        if len(raw)!=e['byteCount'] or sha(raw)!=e['sha256']:raise ValueError('Height checksum: '+e['id'])
        decoded=zlib.decompress(raw)
        if sha(decoded)!=e['decodedSHA256']:raise ValueError('Decoded height checksum: '+e['id'])
        return np.frombuffer(decoded,dtype='<i2').reshape(513,513)
    def sample(self,x,y,size=SIZE,gutter=GUTTER):
        # Global pixel centres and real neighbour samples avoid a hillshade seam
        # at every JPEG edge. Latitude interpolation follows the stored grid.
        p=(np.arange(size+gutter*2)-gutter+.5)/size
        gx,gy=np.meshgrid(x+p,y+p)
        lon=gx/1024*360-180;lat=np.degrees(np.arctan(np.sinh(math.pi*(1-2*gy/1024))))
        result=np.zeros(gx.shape);valid=np.zeros(gx.shape,dtype=bool)
        for sy in range(y-1,y+2):
            for sx in range(x-1,x+2):
                select=(np.floor(gx)==sx)&(np.floor(gy)==sy)
                if not select.any():continue
                h=self.height(sx,sy)
                if h is None:continue
                b=self.entries[f'z10-x{sx}-y{sy}']['bounds']
                xx=np.clip((gx[select]-sx)*512,0,512)
                yy=np.clip((b['maxLatitude']-lat[select])/(b['maxLatitude']-b['minLatitude'])*512,0,512)
                ix=xx.astype(int);iy=yy.astype(int);jx=np.minimum(ix+1,512);jy=np.minimum(iy+1,512)
                a=h[iy,ix].astype(float);b0=h[iy,jx].astype(float);c=h[jy,ix].astype(float);d=h[jy,jx].astype(float)
                ok=(a!=-32768)&(b0!=-32768)&(c!=-32768)&(d!=-32768)
                tx=xx-ix;ty=yy-iy
                values=(a*(1-tx)*(1-ty)+b0*tx*(1-ty)+c*(1-tx)*ty+d*tx*ty)*.1
                result[select]=np.where(ok,values,0);valid[select]=ok
        return result,valid,lon,lat
    def leaf(self,x,y):
        name=key(10,x,y);path=self.output/name;checkpoint=self.checkpoints/(name+'.json')
        if path.exists() and checkpoint.exists():
            facts=json.loads(checkpoint.read_bytes())
            if sha(path.read_bytes())==facts['sha256']:return
        heights,valid,lon,lat=self.sample(x,y);side=heights.shape[0]
        mask=Image.new('L',(side,side),0);paint=ImageDraw.Draw(mask)
        bounds=(lon.min(),lat.min(),lon.max(),lat.max())
        features=[f for f in self.features if intersects(f[2],bounds)]
        def coordinates(ring):
            a=np.asarray(ring);px,py=mercator(a[:,0],a[:,1],10)
            return list(zip((px-x)*SIZE+GUTTER,(py-y)*SIZE+GUTTER))
        for kind,rings,_ in features:
            if kind=='land':paint.polygon(coordinates(rings[0]),fill=255)
        land=np.asarray(mask)>0
        # Coarse geographic coastlines are refined by the existing elevation
        # surface; below-sea-level inland land remains land through the mask.
        land |= valid & (heights>0)
        rgb=np.empty((side,side,3),dtype=np.uint8);rgb[:]=SEA;rgb[land]=LAND
        image=Image.fromarray(rgb);draw=ImageDraw.Draw(image)
        water=Image.new('L',(side,side),0);waterdraw=ImageDraw.Draw(water)
        for kind,rings,_ in features:
            if kind=='lake':
                for i,ring in enumerate(rings):
                    draw.polygon(coordinates(ring),fill=SEA if i==0 else LAND)
                    waterdraw.polygon(coordinates(ring),fill=255 if i==0 else 0)
            elif kind=='river':
                for ring in rings:draw.line(coordinates(ring),fill=(118,173,184),width=1)
        # Same directional-light orientation as WorldScene / WorldPreview.
        metres=2*math.pi*6371008.8*np.cos(np.radians(lat))/(1024*SIZE)
        surface=np.where(land & valid,np.maximum(heights,0),0)
        dy,dx=np.gradient(surface)
        dx/=metres;dy/=metres
        light=np.array([-math.sin(.7)*math.cos(.8), math.sin(.8), math.cos(.7)*math.cos(.8)])
        intensity=np.clip((-dx*light[0]+light[1]-dy*light[2])/np.sqrt(1+dx*dx+dy*dy),0,1)
        shade=(.4+.6*intensity)**(1/2.2)
        shade[~land | (np.asarray(water)>0)]=(.4+.6*light[1])**(1/2.2)
        rgb=np.clip(np.asarray(image)*shade[:,:,None],0,255).astype(np.uint8)
        page=Image.fromarray(rgb[GUTTER:-GUTTER,GUTTER:-GUTTER])
        temporary=path.with_suffix('.tmp');page.save(temporary,format='JPEG',quality=90,subsampling=0);temporary.replace(path)
        atomic_json(checkpoint,dict(sha256=sha(path.read_bytes()),byteCount=path.stat().st_size))
    def parents(self,leafkeys,minzoom):
        current=set(leafkeys);allkeys=set(current)
        for z in range(9,minzoom-1,-1):
            parents={(z,x//2,y//2) for _,x,y in current}
            for _,x,y in sorted(parents):
                # Full leaf rectangle is aligned at minZoom, so every child is
                # present and parent resampling never introduces empty quadrants.
                page=Image.new('RGB',(SIZE*2,SIZE*2),tuple(int(c*((.4+.6*math.sin(.8))**(1/2.2))) for c in SEA))
                for dy in range(2):
                    for dx in range(2):
                        child=self.output/key(z+1,x*2+dx,y*2+dy)
                        if child.exists():
                            with Image.open(child) as image:page.paste(image,(dx*SIZE,dy*SIZE))
                temporary=self.output/(key(z,x,y)+'.tmp')
                page.resize((SIZE,SIZE),Image.Resampling.LANCZOS).save(temporary,format='JPEG',quality=90,subsampling=0)
                temporary.replace(self.output/key(z,x,y))
            allkeys|=parents;current=parents
        return allkeys

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--background',type=Path,required=True);p.add_argument('--atlas',type=Path,required=True)
    p.add_argument('--style',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--min-zoom',type=int,default=5);p.add_argument('--sample',action='store_true')
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    import fcntl
    lock=(a.output/'.build.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    builder=Builder(a.background,a.atlas,a.style,a.output)
    if a.sample:
        builder.leaf(500,333);return
    # Whole UK including Shetland and Northern Ireland, plus context at edges.
    # Clip at z5 page boundaries. Parent tiles at those boundaries are complete.
    xa,ya=mercator(-9,61.1,10);xb,yb=mercator(2.2,49.5,10)
    stride=2**(10-a.min_zoom)
    x0=math.floor(xa/stride)*stride;x1=math.ceil(xb/stride)*stride
    y0=math.floor(ya/stride)*stride;y1=math.ceil(yb/stride)*stride
    leaves=[(10,x,y) for y in range(y0,y1) for x in range(x0,x1)]
    started=time.monotonic()
    for i,(_,x,y) in enumerate(leaves):
        if shutil.disk_usage(a.output).free<2*1024**3:raise RuntimeError('Less than 2 GiB free; safely stopped')
        builder.leaf(x,y)
        if i%25==0 or i==len(leaves)-1:
            status=dict(stage='overview',completed=i+1,total=len(leaves),elapsedSeconds=round(time.monotonic()-started),updated=time.time())
            atomic_json(a.output/'status.json',status);print(json.dumps(status),flush=True)
    tiles=builder.parents(leaves,a.min_zoom)
    # Index appears only once all pages are present and parents are complete.
    index=dict(schemaVersion=1,tileSize=SIZE,minZoom=a.min_zoom,maxZoom=10,tiles=[key(*t) for t in sorted(tiles)],
               quality='Coarse UK geographic context, not detailed LiDAR coverage',inputs=builder.identity,
               sources=[builder.background['source'],dict(name='Natural Earth',license='Public domain',description='Retained atlas coastlines, lakes and rivers')])
    atomic_json(a.output/'index.json',index)
    atomic_json(a.output/'status.json',dict(stage='complete',completed=len(leaves),total=len(leaves),pages=len(tiles),bytes=sum((a.output/f).stat().st_size for f in index['tiles']),elapsedSeconds=round(time.monotonic()-started)))
    print((a.output/'status.json').read_text(),flush=True)
if __name__=='__main__':main()
