#!/usr/bin/env python3
"""Add retained OSM cartography to UK hillshade without decoding fine meshes.

Reads only checksum-verified staged archives. A section is rendered once at z12,
then its z11/z10 parents are reduced from it. The source vector features remain
unchanged; these JPEGs are an offline overview cache, not the close-up renderer.
"""
import argparse
import fcntl
import hashlib
import json
import math
import multiprocessing
import os
import shutil
import time
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from build import Builder, SEA, LAND, atomic_json, intersects, key, mercator, sha

SIDE = 1024
GUTTER = 4
AA = 2
FILLS = [('openLand', (227,227,206)), ('accessLand', (227,221,214)),
         ('wetland', (216,226,207)), ('woodland', (200,216,188)),
         ('water', SEA), ('building', (157,148,133))]
# Roads use the same ground widths and casing as WorldCartography. A minimum
# screen width would turn a 3 m road into a 20–40 m stripe in the atlas, then
# visibly shrink it at the handover to 3D.
LINES = [('water', (118,173,184), .95, .35),
         ('majorRoad', (216,169,121), 3.35, 0),
         ('minorRoad', (181,166,139), 2.4, 0),
         ('track', (155,141,112), 1.43, .3),
         ('footpath', (171,100,113), 1.43, .3),
         ('bridleway', (134,104,145), 1.43, .3),
         ('unknownPath', (164,155,149), 1.43, .3)]
ROAD_CASING_METRES = 1.43


def ground_stroke(image, points, ink, width_pixels):
    """Preserve fractional-pixel coverage instead of rounding thin roads up.

    Pillow requires integer stroke widths. Opacity supplies the remaining
    coverage, before the existing supersampled reduction filters the result.
    """
    width = max(1, math.ceil(width_pixels))
    opacity = max(0, min(255, round(255 * width_pixels / width)))
    if opacity:
        ImageDraw.Draw(image, 'RGBA').line(points, fill=(*ink, opacity), width=width, joint='curve')


def polygons(geometry):
    if geometry['type'] == 'Polygon': return [geometry['coordinates']]
    if geometry['type'] == 'MultiPolygon': return geometry['coordinates']
    return []


def lines(geometry):
    if geometry['type'] == 'LineString': return [geometry['coordinates']]
    if geometry['type'] == 'MultiLineString': return geometry['coordinates']
    return []


def polygon(image, rings, fill):
    """Holes reveal the existing layers, including islands inside water."""
    if not rings or len(rings[0]) < 3: return
    if len(rings) == 1:
        ImageDraw.Draw(image).polygon(rings[0], fill=fill)
        return
    a = np.asarray(rings[0])
    left, top = np.maximum(np.floor(a.min(axis=0)), 0).astype(int)
    right, bottom = np.minimum(np.ceil(a.max(axis=0))+1, image.size).astype(int)
    if right <= left or bottom <= top: return
    mask = Image.new('L', (right-left,bottom-top))
    draw = ImageDraw.Draw(mask)
    for i, ring in enumerate(rings):
        if len(ring) >= 3:
            draw.polygon([(px-left,py-top) for px,py in ring], fill=255 if i == 0 else 0)
    image.paste(fill, (left,top,right,bottom), mask)


def extrude_gutter(image, inset):
    """Do not filter the arbitrary clipping edge of a source section into it.

    Source features stop at each z10 boundary. Extend the last covered colour
    through the filter margin, as the device's vector texture pages do. Height
    derivatives still use actual neighbour samples, not this colour padding.
    """
    w,h=image.size
    image.paste(image.crop((inset,inset,inset+1,h-inset)).resize((inset,h-2*inset)),(0,inset))
    image.paste(image.crop((w-inset-1,inset,w-inset,h-inset)).resize((inset,h-2*inset)),(w-inset,inset))
    image.paste(image.crop((0,inset,w,inset+1)).resize((w,inset)),(0,0))
    image.paste(image.crop((0,h-inset-1,w,h-inset)).resize((w,inset)),(0,h-inset))


def read_map(root, descriptor_path):
    d = json.loads(descriptor_path.read_bytes())
    path = (root / d['archiveURL'].lstrip('/')).resolve()
    if not path.is_relative_to(root.resolve()): raise ValueError('Archive outside staged root')
    if path.stat().st_size != d['archiveSizeBytes']: raise ValueError('Archive size mismatch')
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        for k in ('tileID','tileVersion','bounds','datasetRevision'):
            if manifest[k] != d[k]: raise ValueError('Descriptor mismatch: '+k)
        member = next(f for f in manifest['files'] if f['path'] == 'map-data.ridgemap')
        raw = archive.read('map-data.ridgemap')
        if len(raw) != member['sizeBytes'] or sha(raw) != member['sha256']:
            raise ValueError('Semantic map checksum mismatch')
        data = json.loads(raw)
    if data['coordinateReferenceSystem'] != 'EPSG:4326' or data['bounds'] != d['bounds']:
        raise ValueError('Unsupported map coordinates or mismatched bounds')
    return d, data, member['sha256']


class Textures:
    def __init__(self, base, background, atlas, style, archives, output):
        self.base, self.archives, self.output = base, archives, output
        output.mkdir(parents=True,exist_ok=True)
        self.checkpoints = output/'sections'; self.checkpoints.mkdir(exist_ok=True)
        context = output/'context'; context.mkdir(exist_ok=True)
        self.context = Builder(background,atlas,style,context)
        self.base_index = json.loads((base/'index.json').read_bytes())
        self.identity = dict(renderer=sha(Path(__file__).read_bytes()), context=self.context.identity,
                             base=sha((base/'index.json').read_bytes()), side=SIDE, supersampling=AA)
        self.identity.update(getattr(self,'extra_identity',{}))
        prior = output/'inputs.json'
        if prior.exists() and json.loads(prior.read_bytes()) != self.identity:
            raise ValueError('Inputs changed; choose a new output revision')
        atomic_json(prior,self.identity)

    def render(self,x,y,data):
        heights,valid,lon,lat = self.context.sample(x,y,SIDE,GUTTER)
        side = heights.shape[0]
        def coords(ring, scale=AA):
            a=np.asarray(ring,dtype=float)
            if a.ndim != 2 or a.shape[1] != 2 or not np.isfinite(a).all():
                raise ValueError('Invalid map coordinates')
            px,py=mercator(a[:,0],a[:,1],10)
            return list(zip(((px-x)*SIDE+GUTTER)*scale, ((py-y)*SIDE+GUTTER)*scale))
        bounds=(lon.min(),lat.min(),lon.max(),lat.max())
        features=[f for f in self.context.features if intersects(f[2],bounds)]
        landmask=Image.new('L',(side,side)); draw=ImageDraw.Draw(landmask)
        for kind,rings,_ in features:
            if kind=='land': draw.polygon(coords(rings[0],1),fill=255)
        land=(np.asarray(landmask)>0) | (valid & (heights>0))
        rgb=np.empty((side,side,3),dtype=np.uint8);rgb[:]=SEA;rgb[land]=LAND
        image=Image.fromarray(rgb).resize((side*AA,side*AA),Image.Resampling.NEAREST)
        water=Image.new('L',image.size)
        for kind,rings,_ in features:
            if kind=='lake':
                projected=[coords(r) for r in rings]
                polygon(image,projected,SEA);polygon(water,projected,255)
        grouped={}
        for f in data['features']:
            kind=f['kind']
            # The retained vocabulary groups bogs and lakes under "water".
            # Use the original OSM tags so a wet hillside never becomes a lake.
            if kind=='water' and f.get('source',{}).get('tags',{}).get('natural')=='wetland':
                kind='wetland'
            grouped.setdefault(kind,[]).append(f['geometry'])
        for kind,fill in FILLS:
            for geometry in grouped.get(kind,[]):
                for rings in polygons(geometry):
                    projected=[coords(r) for r in rings]
                    polygon(image,projected,fill)
                    if kind=='water': polygon(water,projected,255)
        centre_lat=float(lat[side//2,side//2])
        metres=2*math.pi*6371008.8*math.cos(math.radians(centre_lat))/(1024*SIDE)
        draw=ImageDraw.Draw(image)
        for kind,ink,width,min_pixels in LINES:
            thickness=max(1,round(max(width/metres,min_pixels)*AA))
            for geometry in grouped.get(kind,[]):
                for ring in lines(geometry):
                    if len(ring)<2:continue
                    pts=coords(ring)
                    if kind.endswith('Road'):
                        ground_stroke(image,pts,(255,253,243),(width+ROAD_CASING_METRES)/metres*AA)
                        ground_stroke(image,pts,ink,width/metres*AA)
                    else:
                        draw.line(pts,fill=ink,width=thickness,joint='curve')
        extrude_gutter(image,GUTTER*AA)
        extrude_gutter(water,GUTTER*AA)
        image=image.resize((side,side),Image.Resampling.LANCZOS)
        water=np.asarray(water.resize((side,side),Image.Resampling.NEAREST))>0
        # Shared global samples and neighbour heights keep illumination continuous.
        metres=2*math.pi*6371008.8*np.cos(np.radians(lat))/(1024*SIDE)
        surface=np.where(land & valid,np.maximum(heights,0),0)
        dy,dx=np.gradient(surface);dx/=metres;dy/=metres
        light=np.array([-math.sin(.7)*math.cos(.8),math.sin(.8),math.cos(.7)*math.cos(.8)])
        intensity=np.clip((-dx*light[0]+light[1]-dy*light[2])/np.sqrt(1+dx*dx+dy*dy),0,1)
        shade=(.4+.6*intensity)**(1/2.2)
        shade[~land | water]=(.4+.6*light[1])**(1/2.2)
        rgb=np.clip(np.asarray(image)*shade[:,:,None],0,255).astype(np.uint8)
        return Image.fromarray(rgb[GUTTER:-GUTTER,GUTTER:-GUTTER])

    def section(self,path):
        d=json.loads(path.read_bytes());x,y=d['x'],d['y']
        if d['z']!=10: raise ValueError('Expected z10 source')
        checkpoint=self.checkpoints/(d['tileID']+'.json')
        descriptor_sha=sha(path.read_bytes())
        if checkpoint.exists():
            record=json.loads(checkpoint.read_bytes())
            if record['descriptorSHA256'] != descriptor_sha:raise ValueError('Source changed; choose a new output revision')
            if all((self.output/name).exists() and sha((self.output/name).read_bytes())==checksum
                   for name,checksum in record['pages'].items()):return record
        d,data,map_sha=read_map(self.archives,path)
        image=self.render(x,y,data)
        pages={}
        for z in range(getattr(self,'reference_zoom',12),9,-1):
            factor=2**(z-10)
            reduced=image.resize((256*factor,256*factor),Image.Resampling.LANCZOS)
            for dy in range(factor):
                for dx in range(factor):
                    name=key(z,x*factor+dx,y*factor+dy)
                    target=self.output/name;temporary=target.with_suffix('.tmp')
                    reduced.crop((dx*256,dy*256,(dx+1)*256,(dy+1)*256)).save(temporary,format='JPEG',quality=90,subsampling=0,optimize=True)
                    temporary.replace(target);pages[name]=sha(target.read_bytes())
        record=dict(id=d['tileID'],descriptorSHA256=descriptor_sha,mapSHA256=map_sha,
                    featureCount=len(data['features']),pages=pages)
        atomic_json(checkpoint,record)
        return record

    def publish(self,records):
        # Copy only absent base pages. Section leaves take precedence.
        for name in self.base_index['tiles']:
            target=self.output/name
            if not target.exists():
                temporary=target.with_suffix('.tmp');temporary.write_bytes((self.base/name).read_bytes());temporary.replace(target)
        leaves=[tuple(map(int,name[1:-4].replace('-x',',').replace('-y',',').split(',')))
                for name in self.base_index['tiles'] if name.startswith('z10-')]
        # Full base rectangle gives every parent all four children.
        self.context.output=self.output
        self.context.parents(leaves,self.base_index['minZoom'])
        inventory=set(self.base_index['tiles'])
        for r in records: inventory.update(r['pages'])
        index=dict(self.base_index)
        index.update(maxZoom=getattr(self,'reference_zoom',12),tiles=sorted(inventory),semanticSections=[r['id'] for r in records],
                     semanticSectionCount=len(records),textureInputs=self.identity,
                     quality='OSM cartography over coarse UK elevation; detailed LiDAR coverage is separate')
        index['sources']=list(index.get('sources',[]))+[dict(name='OpenStreetMap contributors',license='ODbL 1.0',url='https://www.openstreetmap.org/copyright')]
        atomic_json(self.output/'index.json',index)
        return dict(sections=len(records),pages=len(inventory),bytes=sum((self.output/n).stat().st_size for n in inventory))


WORKER = None

def render_section(path):
    return WORKER.section(path)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for flag in ('base','background','atlas','style','archives','output'):p.add_argument('--'+flag,type=Path,required=True)
    p.add_argument('--section',action='append',help='Optional source id(s), for a regional test')
    p.add_argument('--reserve-gib',type=float,default=35)
    p.add_argument('--workers',type=int,choices=(1,2),default=2)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    lock=(a.output/'.texture.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    t=Textures(a.base,a.background,a.atlas,a.style,a.archives,a.output)
    paths=sorted(a.archives.glob('tiles/10/*/*/descriptor.json'))
    if a.section:paths=[v for v in paths if f'z10-x{v.parent.parent.name}-y{v.parent.name}' in a.section]
    started=time.monotonic();records=[]
    global WORKER
    WORKER=t
    try:
        # No UI/threaded runtime is loaded here. Fork shares the read-only context;
        # recycling workers bounds memory retained after dense city source JSON.
        with multiprocessing.get_context('fork').Pool(a.workers,maxtasksperchild=8) as pool:
            for i,record in enumerate(pool.imap_unordered(render_section,paths)):
                if shutil.disk_usage(a.output).free<a.reserve_gib*1024**3:raise RuntimeError('Low disk: safely stopped; resume after freeing space')
                records.append(record)
                status=dict(state='rendering',completed=i+1,total=len(paths),section=record['id'],elapsedSeconds=round(time.monotonic()-started),pid=os.getpid())
                atomic_json(a.output/'status.json',status);print(json.dumps(status),flush=True)
        report=t.publish(sorted(records,key=lambda r:r['id']))
        atomic_json(a.output/'status.json',dict(state='complete',**report,elapsedSeconds=round(time.monotonic()-started)))
    except Exception as e:
        atomic_json(a.output/'status.json',dict(state='failed',error=str(e),completed=len(records),total=len(paths)));raise
    print(json.dumps(report),flush=True)

if __name__=='__main__':main()
