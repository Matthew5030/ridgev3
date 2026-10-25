#!/usr/bin/env python3
"""Encode the browser-rendered control, then summarize any completed benchmark."""
import argparse
import json
from pathlib import Path
import statistics
from PIL import Image, ImageDraw

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('output',type=Path)
a=p.parse_args(); out=a.output
r=json.loads((out/'report.json').read_text())
im=Image.open(out/'matched.png').convert('RGB')
im.save(out/'matched.webp',lossless=True,method=6)
assert Image.open(out/'matched.webp').convert('RGB').tobytes()==im.tobytes()
r.update(matchedPNGBytes=(out/'matched.png').stat().st_size,
         matchedWebPBytes=(out/'matched.webp').stat().st_size,matchedWidth=im.width,matchedHeight=im.height)
(out/'report.json').write_text(json.dumps(r,indent=2)+'\n')
lines=['# Crib Goch vector map experiment','',
       'One compressed vector source is rasterized locally at the requested resolution, then draped over the existing terrain. No app or source packs were modified.','',
       '| Source for the same area | Bytes |','|---|---:|',
       f'| SVG + gzip, including shared style | {r["vectorBytes"]:,} |',
       f'| Matched-style lossless WebP, {im.width} × {im.height} | {r["matchedWebPBytes"]:,} |',
       f'| Matched-style PNG | {r["matchedPNGBytes"]:,} |','',
       f'Vectors save **{100*(1-r["vectorBytes"]/r["matchedWebPBytes"]):.1f}%** against the matched WebP in this sample. They are not pixel-lossless against the older production map. At equal output size the matched WebP and vector draw are verified pixel-identical.','',
       f'The earlier legacy WebP pair was {r["legacyLosslessWebPBytes"]:,} bytes, but it includes baked relief and differently generated contours. Comparing against that figure would mix a format change with a content/style change.','',
       f'{r["contourCount"]} contour lines: {r["contourPointsBefore"]:,} → {r["contourPointsAfter"]:,} points. Measured planar simplification error before coordinate rounding: {r["contourMeasuredHausdorffMetres"]:.4f} m. Coordinates rounded to 0.01 m. This is contour geometry simplification, not a terrain elevation accuracy claim.','']
if (out/'browser-benchmark.json').exists():
    bench=json.loads((out/'browser-benchmark.json').read_text())
    lines+=['## Browser measurements','',bench['scope'], '', 'Renderer: '+bench.get('renderer','not recorded'), '',
            '| Texture width | Draw submission median | Draw + readback median | Upload + mips + GPU finish median | RGBA + mip estimate |',
            '|---|---:|---:|---:|---:|']
    for row in bench['rows']:
        w=row['width']; h=round(w*r['heightMetres']/r['widthMetres'])
        lines.append(f'| {w} px | {statistics.median(row["drawSubmissionMs"]):.2f} ms | {statistics.median(row["drawWithReadbackMs"]):.2f} ms | {statistics.median(row["uploadMipsAndFinishMs"]):.2f} ms | {w*h*4*4/3/1048576:.1f} MiB |')
    lines+=['','Seven warm samples after one discarded run per size. Tiny sample on this Mac, not an iPad performance guarantee. A blocking GPU finish is used only by the benchmark. The interactive viewer does not wait for GPU completion.','',
            'Memory estimates describe one resident RGBA texture and its mipmaps, not total app memory. Canvas, decoding, meshes, comparison textures and temporary old/new textures during replacement add more. This prototype redraws on the main thread after zoom settles; it does not prove background rendering or smooth streaming.','']
lines+=['## Limits and next decision','']+['- '+s for s in r['limits']]+[
    '- This is one combined study extent, not a proof of seamless independently clipped vector tiles. Dash phase, polygon edges, contour continuity, labels and seams need separate multi-tile validation.',
    '- Point labels are retained in report metadata but deliberately absent from BOTH matched textures. A production screen-space label renderer and its costs remain to be tested.',
    '- The source buffer is 8 m. Simplification and clipping are offline. Routing graphs are separate and unchanged.',
    '- The automatic detail policy is a small camera-distance experiment capped at 2048 px wide, not a production screen-space-error scheduler.',
    '- No device disk cache, network stress test, sustained memory measurement, wider-UK extrapolation or latest illustrated material test was performed.',
    '- Next: test native background rasterization on M1 iPad and larger mixed rural/urban/water areas; reuse the same vector source while keeping GPU texture pages bounded.','',
    'Attribution: © OpenStreetMap contributors (ODbL); Welsh Government terrain (OGL v3).']
(out/'REPORT.md').write_text('\n'.join(lines)+'\n')
if (out/'vector-fine.png').exists():
    fine=Image.open(out/'vector-fine.png').convert('RGB')
    # A fixed crop around the Crib Goch peak and adjoining paths; no edge cherry-picking.
    label=next(x for x in r['labels'] if x['name']=='Crib Goch')
    x=label['x']/r['widthMetres']*im.width;y=label['y']/r['heightMetres']*im.height
    crop=(round(x)-96,round(y)-96,round(x)+96,round(y)+96)
    sheet=Image.new('RGB',(1040,595),'#f5f4ef');d=ImageDraw.Draw(sheet)
    d.text((20,15),'Same map features; fixed pixels vs redrawn vector detail',fill='#20352f')
    for i,(image,title) in enumerate([(im,'Lossless image / 1024 px wide'),(fine,'Same vector source / 2048 px wide')]):
        scale=image.width/im.width;rect=tuple(round(v*scale) for v in crop)
        sheet.paste(image.crop(rect).resize((496,496),Image.Resampling.BILINEAR),(16+i*520,65))
        d.text((16+i*520,42),title,fill='#20352f')
    d.text((16,575),'Crib Goch path/contour detail. Illustrative crop; no terrain changes.',fill='#40534d')
    sheet.save(out/'detail-comparison.png')
print((out/'REPORT.md').read_text())
