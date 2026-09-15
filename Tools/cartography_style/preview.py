#!/usr/bin/env python3
"""Deterministic Crib Goch land-cover preview. Reuses the texture lab geometry."""
import argparse, collections, hashlib, json, math, shutil, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageColor, ImageDraw
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import prepare_packs as shared
import prepare_horizon as context
STYLE=json.loads(Path(__file__).with_name('style.json').read_text())
def rgb(s): return np.array(ImageColor.getrgb(s),dtype='float32')
def category(f):
    t=f.get('source',{}).get('tags',{}); n=t.get('natural'); l=t.get('landuse'); c=t.get('landcover')
    if n in ('bare_rock','scree','heath','scrub','sand','shingle','wetland'):return n
    if n=='grassland' or l in ('grass','meadow','village_green') or c=='grass':return 'grassland'
    if c in ('scrub','bare_rock'):return c
    if f['kind'] in ('woodland','building'):return f['kind']
    if n=='water' or (f['kind']=='water' and n!='wetland'):return 'water'
    return None

def mask_geometry(mask,g,bounds,side):
    d=ImageDraw.Draw(mask);typ=g['type'];coords=g['coordinates']
    if typ=='Polygon':
        d.polygon([shared.pixels(bounds,p,side) for p in coords[0]],fill=255)
        for hole in coords[1:]:d.polygon([shared.pixels(bounds,p,side) for p in hole],fill=0)
    elif typ=='MultiPolygon':
        for part in coords:mask_geometry(mask,dict(type='Polygon',coordinates=part),bounds,side)

def pattern(side,b,kind,ink):
    # A fixed world-Mercator lattice. Stable across tiles and reruns, without
    # per-tile normalization or seeded runtime randomness. Symbolic only.
    image=Image.new('RGB',(side,side));mask=Image.new('L',(side,side));d=ImageDraw.Draw(image);a=ImageDraw.Draw(mask)
    R=6378137
    X=lambda lon:R*math.radians(lon)
    Y=lambda lat:R*math.log(math.tan(math.pi/4+math.radians(lat)/2))
    x0,x1=X(b['minLongitude']),X(b['maxLongitude']);y0,y1=Y(b['minLatitude']),Y(b['maxLatitude'])
    step=30.;unit=side/(x1-x0);width=max(1,round(unit*.55))
    for row in range(math.floor(y0/step)-1,math.ceil(y1/step)+1):
        for col in range(math.floor(x0/step)-1,math.ceil(x1/step)+1):
            h=((col*73856093)^(row*19349663))&0xffffffff
            px=(col*step+(h%17-8)*.7-x0)*unit;py=(y1-row*step-((h>>8)%17-8)*.7)*side/(y1-y0)
            r=unit*(1.0 if kind in ('scree','dots') else 2.0)
            for draw,color in [(d,ink),(a,255)]:
                if kind=='rock':draw.line([(px-r,py+r),(px,py-r),(px+r*1.8,py-r*.6)],fill=color,width=width)
                elif kind=='woodland':draw.ellipse((px-r,py-r,px+r,py+r),outline=color,width=width)
                elif kind=='wetland':draw.line([(px-r*2,py),(px+r*2,py)],fill=color,width=width)
                elif kind=='heath':draw.line([(px-r,py),(px,py+r),(px+r,py)],fill=color,width=width)
                else:draw.ellipse((px-r,py-r,px+r,py+r),fill=color)
    return image,mask

def render(features,heights,b,side=2368):
    h=heights.astype('float32')*.1;valid=heights!=shared.NO_DATA
    # Unknown elevations remain neutral; they do not generate slopes or habitat.
    elevation=np.asarray(Image.fromarray(np.where(valid,h,350)).resize((side,side),Image.Resampling.BILINEAR))
    stops=STYLE['elevationRamp'];colors=np.array([rgb(x[1]) for x in stops]);z=[x[0] for x in stops]
    base=np.stack([np.interp(elevation,z,colors[:,i]) for i in range(3)],axis=-1).astype('float32')
    image=Image.fromarray(base.astype('uint8'))
    for kind,paint in STYLE['landcover'].items():
        mask=Image.new('L',(side,side))
        for f in features:
            if category(f)!=kind:continue
            # Per-feature mask ensures a hole exposes lower layers rather than
            # erasing an overlapping polygon already in this class.
            fm=Image.new('L',(side,side));mask_geometry(fm,f['geometry'],b,side)
            mask=Image.fromarray(np.maximum(np.asarray(mask),np.asarray(fm)))
        if not mask.getbbox():continue
        image.paste(paint['color'],(0,0,side,side),mask)
        if paint.get('pattern'):
            tile,marks=pattern(side,b,paint['pattern'],paint['ink'])
            clipped=Image.fromarray(np.minimum(np.asarray(mask),np.asarray(marks)))
            image.paste(tile,(0,0),clipped)
    space=shared.spacing_meters(b,heights.shape[1],heights.shape[0]);gy,gx=np.gradient(np.where(valid,h,350),space['northSouth'],space['eastWest'])
    light=np.clip((-gx+gy)/np.sqrt(1+gx*gx+gy*gy),-.8,.8)
    light[~valid]=0
    shade=np.asarray(Image.fromarray(light).resize((side,side),Image.Resampling.BILINEAR))
    image=Image.fromarray(np.clip(np.asarray(image).astype('float32')*(1+shade[...,None]*.07),0,255).astype('uint8'));d=ImageDraw.Draw(image)
    for level,segments in shared.contour_segments(heights):
        color=STYLE['linework']['indexContour' if level%50==0 else 'contour']['color']
        for points in segments:d.line([(x*(side-1)/(heights.shape[1]-1),y*(side-1)/(heights.shape[0]-1)) for x,y in points],fill=color,width=4 if level%50==0 else 2)
    def line(g,kind):
        if g['type']=='MultiLineString':
            for p in g['coordinates']:line(dict(type='LineString',coordinates=p),kind)
        elif g['type']=='LineString':
            points=[shared.pixels(b,p,side) for p in g['coordinates']];color=STYLE['linework'][kind]['color'];width={'majorRoad':14,'minorRoad':10,'water':4,'track':6}.get(kind,6)
            if kind in ('footpath','bridleway','track','unknownPath','boundary'):shared.dashed(d,points,color,width,dash=20,gap=12)
            else:
                if kind.endswith('Road'):d.line(points,fill='#fffdf3',width=width+6,joint='curve')
                d.line(points,fill=color,width=width,joint='curve')
    for kind in STYLE['linework']:
        for f in features:
            if f['kind']==kind:line(f['geometry'],kind)
    return image

def main():
    p=argparse.ArgumentParser();p.add_argument('--source',type=Path,required=True);p.add_argument('--baseline',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--encoder',type=Path,required=True);appearance=p.add_mutually_exclusive_group();appearance.add_argument('--materials',action='store_true');appearance.add_argument('--illustrated',action='store_true');p.add_argument('--contours',action='store_true');a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    renderer=render;style_document=STYLE
    if a.materials:
        import materials
        renderer=lambda fs,h,b: materials.render(fs,h,b,contours=a.contours)
        style_document=materials.CONFIG
    if a.illustrated:
        import illustrated
        renderer=lambda fs,h,b: illustrated.render(fs,h,b,contours=a.contours)
        style_document=illustrated.CONFIG
    report=json.loads((a.baseline/'source.json').read_text());m=json.loads((a.source/'pack.json').read_text())
    level=next(x for x in m['horizon']['near']['levels'] if x['spacing']==8)
    coarse=np.frombuffer(shared.checked_bytes(a.source/level['file'],level),dtype='<i2').reshape(level['height'],level['width'])
    bounds=report['bounds'];dx=bounds['maxLongitude']-bounds['minLongitude'];dy=bounds['maxLatitude']-bounds['minLatitude'];wide={k:v+(-1 if k.startswith('min') else 1)*(.1*dx if k.endswith('Longitude') else .1*dy) for k,v in bounds.items()}
    features,evidence=context.read_context_maps(shared.OLD,{(500,333)},wide)
    hd=Image.new('RGB',(4096,4096))
    for row in (48,49):
        for col in (30,31):
            b=m['cartography']['tiles'][row*m['cartography']['columns']+col]['image']['bounds'];dx=b['maxLongitude']-b['minLongitude'];dy=b['maxLatitude']-b['minLatitude'];expanded={k:v+(-1 if k.startswith('min') else 1)*(dx if k.endswith('Longitude') else dy)*80/1024 for k,v in b.items()}
            fs=[f for f in features if shared.intersects_geometry(expanded,f['geometry'])];heights=context.resample_map_heights(coarse,m['bounds'],expanded,149)
            im=renderer(fs,heights,expanded);hd.paste(im.crop((160,160,2208,2208)),((col-30)*2048,(row-48)*2048));print('Styled cell',col,row,flush=True)
    # Baseline in this study is the old style at the SAME 2x resolution.
    report['variants']['current']=[]
    for i,entry in enumerate(report['variants']['hd']):
        file=f'current-{i}.png';shutil.copyfile(a.baseline/entry['file'],a.output/file);report['variants']['current'].append(dict(entry,file=file))
    for file in ('vertices.bin','indices.bin'):shutil.copyfile(a.baseline/file,a.output/file)
    entries=[];image=hd;i=0
    while True:
        file=f'hd-{i}.png';image.save(a.output/file);raw=(a.output/file).read_bytes();entries.append(dict(file=file,width=image.width,height=image.height,sha256=shared.digest(raw),byteCount=len(raw)))
        if image.width==1:break
        pixels=np.asarray(image)/255;linear=np.where(pixels<=.04045,pixels/12.92,((pixels+.055)/1.055)**2.4).astype('float32');reduced=(linear[::2,::2]+linear[1::2,::2]+linear[::2,1::2]+linear[1::2,1::2])*.25;srgb=np.where(reduced<=.0031308,reduced*12.92,1.055*reduced**(1/2.4)-.055);image=Image.fromarray(np.rint(np.clip(srgb,0,1)*255).astype('uint8'));i+=1
    report['variants']['hd']=entries;astc=[]
    for i,entry in enumerate(entries):
        file=f'astc-{i}.astc';subprocess.run([str(a.encoder),'-cs',str(a.output/entry['file']),str(a.output/file),'4x4','-thorough','-j','6','-silent'],check=True);raw=(a.output/file).read_bytes();astc.append(dict(entry,file=file,sha256=shared.digest(raw),byteCount=len(raw)));print('Encoded style mip',i,flush=True)
    report['variants']['astc']=astc
    subprocess.run([str(a.encoder),'-ds',str(a.output/'astc-0.astc'),str(a.output/'astc-reference.png'),'-silent'],check=True)
    delta=np.abs(np.asarray(hd,dtype='float32')-np.asarray(Image.open(a.output/'astc-reference.png').convert('RGB'),dtype='float32'))
    report['compression']=dict(profile='ASTC sRGB 4x4 thorough',meanAbsoluteChannelError=float(delta.mean()),maxChannelError=float(delta.max()))
    report['styleStudy']=dict(version=style_document['version'],baseline='Previous style at 2x resolution',styleSHA256=shared.digest(json.dumps(style_document,sort_keys=True).encode()),rendererSHA256=shared.digest(Path(__file__).with_name('illustrated.py' if a.illustrated else ('materials.py' if a.materials else 'preview.py')).read_bytes()),contours=a.contours if (a.materials or a.illustrated) else True,landcoverFeatureCounts=dict(collections.Counter(category(f) or 'unclassified' for f in features)),mapSources=evidence,notes=style_document.get('notes','No habitat inferred from altitude or slope. Decorative symbols occur only inside mapped land-cover polygons.')+' No app integration. Geometry unchanged.')
    for k in ('baselinePixelsReproduced','encoderSHA256'):report.pop(k,None)
    report['encoderSHA256']=shared.digest(a.encoder.read_bytes())
    (a.output/'style.json').write_text(json.dumps(style_document,indent=2)+'\n')
    (a.output/'source.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['styleStudy'],indent=2),flush=True)
if __name__=='__main__':main()
