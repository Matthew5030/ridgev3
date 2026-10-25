#!/usr/bin/env python3
"""Offline texture codec study. Source packs are read-only; no app format changes."""
import argparse
import hashlib
import io
import json
import math
import platform
import random
import shutil
import statistics
import time
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, __version__ as pillow_version

HERE = Path(__file__).resolve().parent
VARIANTS = {
    'original': 'Original PNG', 'png9': 'Optimised PNG · lossless',
    'webp-lossless': 'WebP · lossless', 'palette256': 'PNG · 256 colours',
    'palette128': 'PNG · 128 colours', 'palette64': 'PNG · 64 colours',
    'webp90': 'WebP · quality 90', 'split': 'Small base + exact residual',
}

def sha(data): return hashlib.sha256(data).hexdigest()
def write(path, obj): path.write_text(json.dumps(obj, indent=2, allow_nan=False) + '\n')
def png(image, **kw):
    b = io.BytesIO(); image.save(b, format='PNG', **kw); return b.getvalue()
def image_bytes(raw):
    with Image.open(io.BytesIO(raw)) as im: return np.array(im.convert('RGB'))

def encode(name, image, original):
    if name == 'original': return {'image.png': original}
    if name == 'png9': return {'image.png': png(image, optimize=True)}
    if name.startswith('palette'):
        q = image.quantize(colors=int(name[7:]), method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        return {'image.png': png(q, optimize=True)}
    if name.startswith('webp'):
        b = io.BytesIO()
        image.save(b, format='WEBP', lossless=name.endswith('lossless'), quality=90, method=4)
        return {'image.webp': b.getvalue()}
    # An exact predictive transform, NOT source-derived land-cover/ink separation.
    # Keeping the residual tests whether a simple multiscale split is useful at all.
    base = image.resize(((image.width+3)//4, (image.height+3)//4), Image.Resampling.BOX)
    predictor = np.array(base.resize(image.size, Image.Resampling.BILINEAR))
    residual = (np.array(image).astype(np.int16)-predictor.astype(np.int16)).astype(np.uint8)
    spec = dict(width=image.width, height=image.height, filter='Pillow bilinear', residual='RGB modulo 256')
    return {'base.png': png(base, optimize=True), 'residual.zlib': zlib.compress(residual.tobytes(), 9),
            'format.json': json.dumps(spec, sort_keys=True).encode()}

def decode(files):
    if 'base.png' not in files: return image_bytes(next(iter(files.values())))
    spec = json.loads(files['format.json']); size = (spec['width'], spec['height'])
    base = Image.fromarray(image_bytes(files['base.png'])).resize(size, Image.Resampling.BILINEAR)
    residual = np.frombuffer(zlib.decompress(files['residual.zlib']), np.uint8).reshape(size[1], size[0], 3)
    return (np.array(base).astype(np.uint16)+residual.astype(np.uint16)).astype(np.uint8)

def edge_mask(a):
    a = a.astype(np.int16); g = np.zeros(a.shape[:2], np.uint8)
    g[:, 1:] |= (np.max(np.abs(a[:, 1:]-a[:, :-1]), axis=2) >= 20)
    g[1:] |= (np.max(np.abs(a[1:]-a[:-1]), axis=2) >= 20)
    return np.array(Image.fromarray(g*255).filter(ImageFilter.MaxFilter(3))) > 0

def errors(ref, candidate, edges):
    d = np.abs(ref.astype(np.int16)-candidate.astype(np.int16)); per_pixel = d.max(axis=2)
    return dict(exact=bool(np.array_equal(ref, candidate)), mae=float(d.mean()),
                maxChannel=int(d.max()), p99Pixel=float(np.quantile(per_pixel, .99)),
                edgeMAE=float(d[edges].mean()) if edges.any() else 0.,
                edgeP99=float(np.quantile(per_pixel[edges], .99)) if edges.any() else 0.,
                pixelsOver8Percent=float(np.mean(per_pixel > 8)*100))

def local(path): return path.is_file() and not (getattr(path.stat(), 'st_flags', 0) & 0x40000000)
def checked(path, record):
    raw = path.read_bytes()
    if len(raw) != record['byteCount'] or sha(raw) != record['sha256']:
        raise ValueError(f'Source checksum mismatch: {path}')
    return raw

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pack', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--samples', type=int, default=16); p.add_argument('--decode-repeats', type=int, default=9)
    a = p.parse_args()
    if a.samples < 4 or a.decode_repeats < 3: p.error('Use at least 4 samples and 3 decode repeats')
    if a.output.resolve() == a.pack.resolve() or a.pack.resolve() in a.output.resolve().parents:
        p.error('The study output must be outside the source pack')
    if a.output.exists(): p.error('Use a fresh output directory to keep runs immutable')
    a.output.mkdir(parents=True)
    manifest_raw = (a.pack/'pack.json').read_bytes(); m = json.loads(manifest_raw)
    available = sorted([t['image'] for t in m['cartography']['tiles'] if local(a.pack/t['image']['file'])], key=lambda t:(t['byteCount'],t['file']))
    peak = next(p for p in m['places'] if p['name'] == 'Crib Goch')['coordinate']
    crib = [t for t in available if abs(t['bounds']['minLongitude']-(-4.0576171875)) < 1e-8
            and any(abs(t['bounds']['maxLatitude']-y)<1e-8 for y in (53.08074842648101,53.07634210907817))]
    crib.sort(key=lambda t:-t['bounds']['maxLatitude'])
    if len(crib) != 2: raise ValueError('This matched Crib Goch run needs both original atlas cells')
    chosen = {t['file']:t for t in crib}
    for i in np.linspace(0,len(available)-1,a.samples-2).round().astype(int): chosen[available[i]['file']] = available[i]
    records = []; mosaics = {k:Image.new('RGB',(1024,2048)) for k in VARIANTS}; crop_images = {}
    for i, entry in enumerate(chosen.values()):
        raw = checked(a.pack/entry['file'],entry); ref = image_bytes(raw); edges = edge_mask(ref)
        image = Image.fromarray(ref); folder = a.output/Path(entry['file']).stem; folder.mkdir()
        record = dict(source=entry, edgePixels=int(edges.sum()), variants={}); encodings = {}; decoded = {}
        for key in VARIANTS:
            start=time.perf_counter(); files=encode(key,image,raw); encode_ms=(time.perf_counter()-start)*1000
            encodings[key] = files; candidate=decode(files); decoded[key]=candidate
            if key in ('original','png9','webp-lossless','split') and not np.array_equal(candidate,ref):
                raise AssertionError(f'{key} failed exact round trip')
            dest=folder/key; dest.mkdir()
            for name,data in files.items(): (dest/name).write_bytes(data)
            record['variants'][key] = dict(bytes=sum(map(len,files.values())), encodeMs=encode_ms,
                error=errors(ref,candidate,edges), files={name:dict(bytes=len(data),sha256=sha(data)) for name,data in files.items()})
        timings={k:[] for k in VARIANTS}; rng=random.Random(5030)
        for repeat in range(a.decode_repeats+1):
            order=list(VARIANTS);rng.shuffle(order)
            for key in order:
                start=time.perf_counter(); decode(encodings[key]); ms=(time.perf_counter()-start)*1000
                if repeat: timings[key].append(ms)
        for key in VARIANTS:
            record['variants'][key].update(decodeMedianMs=statistics.median(timings[key]),decodeP95Ms=float(np.quantile(timings[key],.95)))
        if entry in crib:
            row=crib.index(entry)
            for key in VARIANTS: mosaics[key].paste(Image.fromarray(decoded[key]).crop((4,4,1028,1028)),(0,row*1024))
            if row == 1:
                # Dense-edge crop is deterministic, chosen solely from the reference.
                scores=[(int(edges[y:y+192,x:x+192].sum()),x,y) for y in range(4,837,64) for x in range(4,837,64)]
                _,x,y=max(scores)
                for key in VARIANTS: crop_images[key]=Image.fromarray(decoded[key]).crop((x,y,x+192,y+192))
                record['inspectionCrop'] = [x,y,192,192]
        records.append(record); print(f'{i+1}/{len(chosen)} {entry["file"]}',flush=True)
    totals={}
    for key,label in VARIANTS.items():
        rs=[r['variants'][key] for r in records]
        totals[key]=dict(label=label,bytes=sum(r['bytes'] for r in rs),exact=all(r['error']['exact'] for r in rs),
            decodeMedianMs=statistics.median(r['decodeMedianMs'] for r in rs),
            worstEdgeP99=max(r['error']['edgeP99'] for r in rs),maxChannel=max(r['error']['maxChannel'] for r in rs),
            meanTileMAE=statistics.mean(r['error']['mae'] for r in rs))
    for t in totals.values():t['savingPercent']=100*(1-t['bytes']/totals['original']['bytes'])
    report=dict(sourcePack=str(a.pack),manifestSHA256=sha(manifest_raw),sourceName=m['name'],
        sourceKind='Locally retained legacy Eryri atlas, not the current illustrated experiment or full published park.',
        selection='Two Crib Goch cells plus deterministic file-size quantiles among locally available native tiles; not a UK-representative sample.',
        availableTiles=len(available),sampleCount=len(records),decodeRepeats=a.decode_repeats,
        environment=dict(platform=platform.platform(),machine=platform.machine(),python=platform.python_version(),pillow=pillow_version,numpy=np.__version__),
        scope='Encoded native images only; existing previews, network, disk I/O, mip generation, GPU upload and render timings excluded. Warm in-memory Pillow decode to RGB on Mac.',
        edgeMetric='3x3 dilation of reference adjacent RGB channel differences >=20; proxy for fine detail, not a semantic path/contour mask.',
        geometry='One fixed 4 m Crib Goch mesh reused by every profile. No terrain simplification or source changes.',
        totals=totals,tiles=records)
    write(a.output/'results.json',report)
    for key,im in mosaics.items():im.save(a.output/f'view-{key}.png')
    # Export exact source-derived error images, with a fixed gain for every profile.
    reference=np.array(mosaics['original']).astype(np.int16)
    for key,im in mosaics.items():
        delta=np.abs(np.array(im).astype(np.int16)-reference).max(axis=2)
        error=np.zeros((*delta.shape,3),np.uint8);error[:,:,0]=np.clip(delta*8,0,255)
        Image.fromarray(error).save(a.output/f'error-{key}.png')
    sheet=Image.new('RGB',(4*410,2*455),'#f5f4ef');d=ImageDraw.Draw(sheet)
    for i,(key,label) in enumerate(VARIANTS.items()):
        x=(i%4)*410;y=(i//4)*455;d.text((x+12,y+10),label,fill='#20352f')
        t=totals[key];d.text((x+12,y+29),f'{t["savingPercent"]:.1f}% saved / max error {t["maxChannel"]}/255',fill='#40534d')
        sheet.paste(crop_images[key].resize((384,384),Image.Resampling.NEAREST),(x+12,y+59))
    sheet.save(a.output/'comparison.png')
    build_viewer(a,m,crib,totals,peak)
    make_report(a.output,report)
    shutil.copyfile(HERE/'flat.html',a.output/'flat.html')
    # Final input verification catches accidental source changes during the run.
    for r in records: checked(a.pack/r['source']['file'],r['source'])
    assert (a.pack/'pack.json').read_bytes()==manifest_raw
    print(json.dumps(totals,indent=2),flush=True)

def build_viewer(a,m,crib,totals,peak):
    level=next(l for l in m['levels'] if l['spacing']==4)
    raw=checked(a.pack/level['file'],level);heights=np.frombuffer(raw,dtype='<i2').reshape(level['height'],level['width'])
    h=heights[9*128:11*128+1,6*128:7*128+1].astype(float)*m['heightScale']
    assert h.shape==(257,129) and np.all(h != m['noDataValue']*m['heightScale'])
    b=dict(minLongitude=crib[0]['bounds']['minLongitude'],maxLongitude=crib[0]['bounds']['maxLongitude'],
           minLatitude=crib[1]['bounds']['minLatitude'],maxLatitude=crib[0]['bounds']['maxLatitude'])
    width=math.radians(b['maxLongitude']-b['minLongitude'])*6371008.8*math.cos(math.radians((b['minLatitude']+b['maxLatitude'])/2))
    depth=math.radians(b['maxLatitude']-b['minLatitude'])*6371008.8
    x,z=np.meshgrid(np.linspace(-width/2,width/2,129),np.linspace(-depth/2,depth/2,257))
    gz,gx=np.gradient(h,depth/256,width/128);n=np.stack([-gx,np.ones_like(h),-gz],axis=-1);n/=np.linalg.norm(n,axis=-1,keepdims=True)
    u,v=np.meshgrid(np.linspace(0,1,129),np.linspace(0,1,257))
    vertices=np.dstack([x,h-700,z,n,u,v]).astype('<f4')
    q=(np.arange(256)[:,None]*129+np.arange(128)[None,:]).ravel()
    indices=np.stack([q,q+129,q+1,q+1,q+129,q+130],axis=1).astype('<u4')
    vertices.tofile(a.output/'terrain.vertices');indices.tofile(a.output/'terrain.indices')
    profiles=[]
    for key,t in totals.items():
        selected=sum(json.loads((a.output/'results.json').read_text())['tiles'][i]['variants'][key]['bytes'] for i in range(2))
        profiles.append(dict(id=key,label=t['label'],texture=f'view-{key}.png',bytes=selected,saving=t['savingPercent'],maxError=t['maxChannel'],
            note='Pixel-identical' if t['exact'] else 'Lossy: inspect fine lines and colour transitions',
            meshes=[dict(vertices='terrain.vertices',indices='terrain.indices',count=int(indices.size))]))
    px=(peak['longitude']-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width-width/2
    pz=(b['maxLatitude']-peak['latitude'])/(b['maxLatitude']-b['minLatitude'])*depth-depth/2
    write(a.output/'viewer.json',dict(profiles=profiles,defaultLeft='original',defaultRight='webp-lossless',
        peak=[px,float(h.max()-700),pz],tileWidthMetres=width,tileHeightMetres=depth/2,
        terrainSourceSHA256=sha(raw),verticesSHA256=sha(vertices.tobytes()),indicesSHA256=sha(indices.tobytes())))
    shutil.copyfile(HERE/'viewer.html',a.output/'index.html')

def make_report(out,r):
    lines=['# Texture compression study','',f'Measured {r["sampleCount"]} real tiles from {r["availableTiles"]} locally available native atlas images.',
        '',r['sourceKind'],r['selection'],'',r['scope'],'',
        '| Format | Sample MB | Saving | Exact pixels | Median decode / tile (ms) | Worst edge p99 /255 | Max error /255 |',
        '|---|---:|---:|---|---:|---:|---:|']
    for t in r['totals'].values():lines.append(f'| {t["label"]} | {t["bytes"]/1e6:.3f} | {t["savingPercent"]:.1f}% | {t["exact"]} | {t["decodeMedianMs"]:.2f} | {t["worstEdgeP99"]:.1f} | {t["maxChannel"]} |')
    lines+=['','## Interpretation and limits','',
        '- Palette tests preserve dimensions and positions but change colours, including anti-aliased line pixels. They are not lossless.',
        '- WebP requires verified iOS decoding and app loader integration before adoption; browser/Pillow support is not proof of app support.',
        '- Split is an exact low-resolution predictor plus RGB residual, not a semantic land-cover/ink implementation. Both files, reconstruction metadata and decode cost are counted.',
        '- All displayed images are reconstructed PNGs for controlled visual comparison. Their sizes are excluded; encoded candidate assets are measured instead.',
        '- Every browser profile uses the same measured heightfield, mesh, lighting, camera and resolution. Browser previews are not iPad GPU benchmarks.',
        '- 3D stats show two Crib Goch tile bytes; percentage saving is across the full sample. Error views show max channel difference ×8.',
        '- No geometry, texture resolution, map styles, source features, or production assets were changed.',
        '- Sample source hashes are checked before and after. Four lossless variants must round-trip exactly.',
        '- GPU memory is unchanged if candidates are expanded into the current RGBA atlas. Download compression is a separate metric.',
        '- Current illustrated sources and full park are unavailable on the disconnected external drive. True source-separated colour/ink, seam validation of such layers, and full-park size projection remain pending.',
        '',f'Environment: {json.dumps(r["environment"])}','',f'Edge metric: {r["edgeMetric"]}',
        '', 'Open index.html through a local HTTP server for matched 3D views, or flat.html for pixel inspection. Machine-readable evidence: results.json.']
    (out/'REPORT.md').write_text('\n'.join(lines)+'\n')

if __name__=='__main__': main()
