#!/usr/bin/env python3
"""Reproducible, read-only vector cartography experiment; not a shipping format.

Requires numpy, Pillow, shapely and contourpy. Uses retained semantic OSM data
and the exact mesh from the earlier texture study; never traces raster pixels.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import shutil

import contourpy
import numpy as np
from shapely.geometry import shape, box, LineString
from shapely.ops import transform

HERE = Path(__file__).resolve().parent
def sha(raw): return hashlib.sha256(raw).hexdigest()
def dump(path, value): path.write_text(json.dumps(value, indent=2) + '\n')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True)
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    if a.output.exists(): p.error('Use a fresh output directory')
    a.output.mkdir(parents=True)
    source_raw = a.source.read_bytes()
    source = json.loads(source_raw)
    prior = json.loads((a.reference/'results.json').read_text())
    catalog = json.loads((a.reference/'viewer.json').read_text())
    b = dict(prior['tiles'][0]['source']['bounds'])
    b['minLatitude'] = prior['tiles'][1]['source']['bounds']['minLatitude']
    width, height = catalog['tileWidthMetres'], catalog['tileHeightMetres']*2
    def project(x, y, z=None):
        return ((np.asarray(x)-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width,
                (b['maxLatitude']-np.asarray(y))/(b['maxLatitude']-b['minLatitude'])*height)
    # Clip with a real-world buffer so round strokes continue naturally at edges.
    clip = box(-8, -8, width+8, height+8)
    geographic_clip = box(b['minLongitude']-.0002, b['minLatitude']-.0002,
                          b['maxLongitude']+.0002, b['maxLatitude']+.0002)
    features, kinds, labels = [], Counter(), []
    for f in source['features']:
        geom = shape(f['geometry'])
        if not geom.intersects(geographic_clip): continue
        g = transform(project, geom).intersection(clip)
        if g.is_empty: continue
        if g.geom_type == 'Point':
            if f['properties'].get('name'):
                labels.append(dict(name=f['properties']['name'], kind=f['kind'], x=g.x, y=g.y))
            continue
        if not g.is_valid: g = g.buffer(0)
        features.append((f['kind'], g.simplify(.25, preserve_topology=True)))
        kinds[f['kind']] += 1
    vb = (a.reference/'terrain.vertices').read_bytes()
    assert sha(vb) == catalog['verticesSHA256']
    vertices = np.frombuffer(vb, dtype='<f4').reshape(257,129,8)
    heights = vertices[:,:,1].astype(float)+700
    cg = contourpy.contour_generator(x=np.linspace(0,width,129),
        y=np.linspace(0,height,257), z=heights, name='serial', line_type='Separate')
    contours, original_points, reduced_points, worst_error = [], 0, 0, 0
    for level in range(int(np.ceil(heights.min()/10))*10, int(heights.max())+1, 10):
        for coords in cg.lines(level):
            original = LineString(coords)
            simplified = original.simplify(.25, preserve_topology=True)
            original_points += len(coords); reduced_points += len(simplified.coords)
            worst_error = max(worst_error, original.hausdorff_distance(simplified))
            contours.append((level, simplified))
    def path(g):
        def ring(coords, closed=False):
            xy=list(coords)
            return 'M'+'L'.join(f'{x:.2f},{y:.2f}' for x,y in xy)+('Z' if closed else '')
        if g.geom_type=='Polygon':
            return ring(g.exterior.coords,True)+''.join(ring(r.coords,True) for r in g.interiors)
        if g.geom_type in ('LineString','LinearRing'): return ring(g.coords)
        if hasattr(g,'geoms'): return ''.join(path(c) for c in g.geoms)
        return ''
    # Style is deliberately simple and shared with the matched raster control.
    # Dynamic terrain lighting supplies relief equally on both sides.
    fills={'openLand':'#e3e3ce','accessLand':'#e3ddd6','woodland':'#c8d8bc','water':'#a8cbd1','building':'#9d9485'}
    lines={'water':('#76adb8',.95,''),'majorRoad':('#d8a979',3.35,''),
        'minorRoad':('#b5a68b',2.4,''),'track':('#9b8d70',1.43,'4.78 2.87'),
        'footpath':('#ab6471',1.43,'4.78 2.87'),'bridleway':('#866891',1.43,'4.78 2.87'),
        'unknownPath':('#a49b95',1.43,'4.78 2.87'),'boundary':('#ada79f',1.0,'4.78 2.87')}
    parts=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.6f} {height:.6f}">',
        '<metadata>© OpenStreetMap contributors, ODbL; Welsh Government terrain, OGL v3. Experimental rendering, not a navigation product.</metadata>',
        f'<path fill="#ede9d9" d="M0,0H{width}V{height}H0Z"/>',
        '<g fill-rule="evenodd" stroke-linejoin="round" stroke-linecap="round">']
    for kind, color in fills.items():
        for k,g in features:
            if k==kind and 'Polygon' in g.geom_type: parts.append(f'<path fill="{color}" d="{path(g)}"/>')
    for level,g in contours:
        colour,thickness=('#a79a80',.96) if level%50==0 else ('#c5b99f',.48)
        parts.append(f'<path fill="none" stroke="{colour}" stroke-width="{thickness}" d="{path(g)}"/>')
    for kind,(color,thickness,dash) in lines.items():
        for k,g in features:
            if k!=kind or 'Line' not in g.geom_type: continue
            if kind.endswith('Road'):
                parts.append(f'<path fill="none" stroke="#fffdf3" stroke-width="{thickness+1.43}" d="{path(g)}"/>')
            dash_attr=f' stroke-dasharray="{dash}"' if dash else ''
            parts.append(f'<path fill="none" stroke="{color}" stroke-width="{thickness}"{dash_attr} d="{path(g)}"/>')
    parts+=['</g></svg>']
    svg=''.join(parts).encode()
    compressed=gzip.compress(svg, compresslevel=9, mtime=0)
    assert gzip.decompress(compressed)==svg
    (a.output/'map.svg.gz').write_bytes(compressed)
    # Uncompressed SVG retained for inspection; the viewer downloads ONLY gzip.
    (a.output/'map.svg').write_bytes(svg)
    for filename in ['terrain.vertices','terrain.indices','view-webp-lossless.png']:
        shutil.copyfile(a.reference/filename,a.output/filename)
    assert sha((a.output/'terrain.indices').read_bytes())==catalog['indicesSHA256']
    report=dict(bounds=b, widthMetres=width, heightMetres=height,
        sourceSHA256=sha(source_raw),sourceRevision=source.get('sourceRevision'),
        vectorBytes=len(compressed), uncompressedVectorBytes=len(svg), vectorSHA256=sha(compressed),
        legacyPNGBytes=sum(t['source']['byteCount'] for t in prior['tiles'][:2]),
        legacyLosslessWebPBytes=sum(t['variants']['webp-lossless']['bytes'] for t in prior['tiles'][:2]),
        features=dict(kinds),labels=labels, contourCount=len(contours),
        contourPointsBefore=original_points,contourPointsAfter=reduced_points,
        contourSimplificationMetres=.25,contourMeasuredHausdorffMetres=worst_error,
        coordinateRoundingMetres=.01, geometrySpacingMetres=4,
        verticesSHA256=sha(vb), indicesSHA256=catalog['indicesSHA256'], peak=catalog['peak'],
        limits=['Two adjacent Crib Goch cells only; not representative of the UK.',
                'Legacy source/style; not the latest illustrated map style.',
                '10 m contours derived from retained 4 m terrain; no new 1 m processing.',
                'SVG is an experiment transport, not a proposed production format.',
                'Labels retained as metadata, not part of texture rendering.',
                'Matched control has identical features/style; legacy imagery also has baked relief.',
                'Runtime texture memory remains; this does not make a bigger texture free.'])
    dump(a.output/'report.json',report)
    shutil.copyfile(HERE/'viewer.html',a.output/'index.html')
    assert sha(a.source.read_bytes())==report['sourceSHA256']
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
