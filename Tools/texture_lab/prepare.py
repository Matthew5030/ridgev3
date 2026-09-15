#!/usr/bin/env python3
"""Build a fixed Crib Goch texture comparison from the normal app's sources."""
import argparse, hashlib, json, math, subprocess, sys, zlib
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_packs as shared
import prepare_horizon as context

def write(path, value): path.write_text(json.dumps(value, indent=2)+'\n')
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--encoder', type=Path, required=True)
    a=p.parse_args(); a.output.mkdir(parents=True, exist_ok=True)
    source_raw=(a.source/'pack.json').read_bytes(); m=json.loads(source_raw)
    atlas=m['cartography']; columns=atlas['columns']; selected=[]
    for row in [48,49]:
        for col in [30,31]: selected.append((col,row,atlas['tiles'][row*columns+col]))
    bounds=shared.union_bounds([t['image']['bounds'] for _,_,t in selected])
    grid=np.empty((257,257),dtype='<i2'); receipts=[]
    for col,row,t in selected:
        c=m['tiledTerrain']['cells'][row*m['grid']['columns']+col]
        level=next(x for x in c['levels'] if x['spacing']==4)
        raw=shared.checked_bytes(a.source/level['file'],level)
        heights=np.frombuffer(raw,dtype='<i2').reshape(129,129)
        assert np.all(heights != shared.NO_DATA)
        x,y=(col-30)*128,(row-48)*128
        if x: assert np.array_equal(grid[y:y+129,x],heights[:,0])
        if y: assert np.array_equal(grid[y,x:x+129],heights[0,:])
        grid[y:y+129,x:x+129]=heights
        receipts.append(dict(column=col,row=row,terrainSHA256=sha(raw),mapSHA256=t['image']['sha256']))
    near=m['horizon']['near']; level=next(x for x in near['levels'] if x['spacing']==8)
    coarse_raw=shared.checked_bytes(a.source/level['file'],level)
    coarse=np.frombuffer(coarse_raw,dtype='<i2').reshape(level['height'],level['width'])
    dx=bounds['maxLongitude']-bounds['minLongitude']; dy=bounds['maxLatitude']-bounds['minLatitude']
    wide={k:v+(-1 if k.startswith('min') else 1)*(.1*dx if k.endswith('Longitude') else .1*dy) for k,v in bounds.items()}
    features,evidence=context.read_context_maps(shared.OLD,{(500,333)},wide)
    native=Image.new('RGB',(2048,2048)); hd=Image.new('RGB',(4096,4096))
    for col,row,t in selected:
        b=t['image']['bounds']; cell_dx=b['maxLongitude']-b['minLongitude']; cell_dy=b['maxLatitude']-b['minLatitude']
        expanded={k:v+(-1 if k.startswith('min') else 1)*(cell_dx if k.endswith('Longitude') else cell_dy)*80/1024 for k,v in b.items()}
        selected_features=[f for f in features if shared.intersects_geometry(expanded,f['geometry'])]
        heights=context.resample_map_heights(coarse,m['bounds'],expanded,149)
        reference=Image.open(a.source/t['image']['file']).convert('RGB')
        shared.checked_bytes(a.source/t['image']['file'],t['image'])
        rendered=shared.render_texture(selected_features,heights,expanded,1184)
        crop=rendered.crop((76,76,1108,1108))
        assert np.array_equal(np.asarray(crop),np.asarray(reference)), f'Baseline reproduction failed at {col},{row}'
        native.paste(reference.crop((4,4,1028,1028)),((col-30)*1024,(row-48)*1024))
        doubled=shared.render_texture(selected_features,heights,expanded,2368,style_scale=2)
        hd.paste(doubled.crop((160,160,2208,2208)),((col-30)*2048,(row-48)*2048))
        print(f'Reproduced original pixels and rendered 2x cell {col},{row}',flush=True)
    variants={}
    # Identical linear-light box mip filter for both resolutions, prepared once.
    for name,image in [('current',native),('hd',hd)]:
        entries=[]; index=0
        while True:
            file=f'{name}-{index}.png'; image.save(a.output/file)
            raw=(a.output/file).read_bytes(); entries.append(dict(file=file,width=image.width,height=image.height,sha256=sha(raw),byteCount=len(raw)))
            if image.width==1: break
            pixels=np.asarray(image); linear=np.where(pixels/255<=.04045,pixels/255/12.92,((pixels/255+.055)/1.055)**2.4).astype('float32')
            reduced=(linear[::2,::2]+linear[1::2,::2]+linear[::2,1::2]+linear[1::2,1::2])*.25
            srgb=np.where(reduced<=.0031308,reduced*12.92,1.055*reduced**(1/2.4)-.055)
            image=Image.fromarray(np.rint(np.clip(srgb,0,1)*255).astype('uint8'));index+=1
        variants[name]=entries
    astc=[]
    for i,entry in enumerate(variants['hd']):
        file=f'astc-{i}.astc'
        subprocess.run([str(a.encoder),'-cs',str(a.output/entry['file']),str(a.output/file),'4x4','-thorough','-j','6','-silent'],check=True)
        raw=(a.output/file).read_bytes()
        assert raw[:4]==bytes.fromhex('13aba15c') and raw[4:7]==bytes([4,4,1])
        astc.append(dict(file=file,width=entry['width'],height=entry['height'],sha256=sha(raw),byteCount=len(raw)))
        print('Encoded ASTC mip',i,flush=True)
    variants['astc']=astc
    subprocess.run([str(a.encoder),'-ds',str(a.output/astc[0]['file']),str(a.output/'astc-reference.png'),'-silent'],check=True)
    reference=np.asarray(hd).astype('float32'); decoded=np.asarray(Image.open(a.output/'astc-reference.png').convert('RGB')).astype('float32')
    delta=np.abs(reference-decoded); mse=float(np.mean(delta**2))
    edges=np.zeros(reference.shape[:2],dtype=bool)
    edges[:,1:] |= np.max(np.abs(np.diff(reference,axis=1)),axis=2)>12
    edges[1:,:] |= np.max(np.abs(np.diff(reference,axis=0)),axis=2)>12
    w=dx*111320*math.cos(math.radians((bounds['minLatitude']+bounds['maxLatitude'])/2)); depth=dy*111320
    h=grid.astype('float32')*.1; minimum=float(h.min()); h-=minimum
    gz,gx=np.gradient(h,depth/256,w/256)
    normals=np.stack([-gx,np.ones_like(h),-gz],axis=-1);normals/=np.linalg.norm(normals,axis=-1)[...,None]
    u,v=np.meshgrid(np.linspace(0,1,257),np.linspace(0,1,257))
    vertices=np.zeros((257,257,12),dtype='<f4');vertices[:,:,0]=(u-.5)*w;vertices[:,:,1]=h;vertices[:,:,2]=(v-.5)*depth
    vertices[:,:,4:7]=normals;vertices[:,:,8]=u;vertices[:,:,9]=v
    indices=[]
    for y in range(256):
        for x in range(256):
            q=y*257+x;indices.extend([q,q+257,q+1,q+1,q+257,q+258])
    raw=vertices.tobytes();(a.output/'vertices.bin').write_bytes(raw)
    indexraw=np.asarray(indices,dtype='<u4').tobytes();(a.output/'indices.bin').write_bytes(indexraw)
    joined=b''.join((a.output/x['file']).read_bytes() for x in astc)
    (a.output/'astc-mips.zlib').write_bytes(zlib.compress(joined,6))
    report=dict(bounds=bounds,widthMetres=w,depthMetres=depth,minHeight=minimum,maxHeight=float(h.max()),
        variants=variants,vertexCount=257*257,indexCount=len(indices),verticesSHA256=sha(raw),indicesSHA256=sha(indexraw),
        sourceManifestSHA256=sha(source_raw),cells=receipts,mapSources=evidence,geometrySpacing=4,
        geometryNote='Same prepared normal-app 4 m samples, mesh and camera in every variant; no new LiDAR processing.',
        baselinePixelsReproduced=True,encoderSHA256=sha(a.encoder.read_bytes()),
        compression=dict(profile='ASTC sRGB 4x4 thorough',meanAbsoluteChannelError=float(delta.mean()),
            psnrDB=10*math.log10(255**2/mse),edgeMeanAbsoluteChannelError=float(delta[edges].mean()),
            pixelsWithChannelErrorOver16Percent=float(np.mean(delta.max(axis=2)>16)*100),
            astcMipBytes=len(joined),zlibMipBytes=(a.output/'astc-mips.zlib').stat().st_size))
    write(a.output/'source.json',report)
    print(json.dumps(report['compression'],indent=2))

if __name__=='__main__': main()
