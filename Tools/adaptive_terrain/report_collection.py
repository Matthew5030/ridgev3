#!/usr/bin/env python3
"""Summarize verified park publications without calling missing coverage complete."""
import argparse
import hashlib
import json
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument('builds', type=Path)
p.add_argument('downloads', type=Path)
a = p.parse_args()
plan = json.loads((a.builds/'collection-plan.json').read_text())
indices = [json.loads(path.read_text()) for path in sorted(a.downloads.glob('*/adaptive.json'))]
parks=[]
for key, item in sorted(plan['parks'].items(),key=lambda kv:kv[1]['name']):
    matches=[m for m in indices if m['id'].startswith(key+'-adaptive-') or m['id'].startswith(key+'-park-adaptive-')]
    m=sorted(matches,key=lambda m:m['requiredReader']=='rat1-zlib-v1',reverse=True)[0] if matches else None
    row=dict(key=key,name=item['name'],coveragePercent=item['coveragePercent'],missingKm2=item['missingKm2'])
    if m:
        row.update(coveragePercent=100*(1-m['uncoveredParkAreaKm2']/m['parkAreaKm2']),missingKm2=m['uncoveredParkAreaKm2'],status='published',codec=m['requiredReader'],id=m['id'],chunks=len(m['chunks']),downloadBytes=m['byteCount'],
                   rawSourceBytes=m['sourceByteCount'],compressedSourceBytes=m['sourceZlibBytes'],
                   rawMeshBytes=m['decodedByteCount'],triangles=m['triangles'],
                   nativeTriangles=m['nativeGridTriangles'],
                   triangleReductionPercent=100*(1-m['triangles']/m['nativeGridTriangles']),
                   sharedEdgesChecked=m['validation']['sharedEdgesChecked'],
                   maxSeamDifferenceMetres=m['validation']['maxSeamHeightDifferenceMetres'],
                   measuredMaxErrorMetres=m['validation']['maximumMeasuredErrorMetres'])
    else:
        row.update(status='awaiting-source' if not item['chunks'] else 'not-yet-published',chunks=item['chunks'])
    parks.append(row)
published=[p for p in parks if p['status']=='published']
totals={k:sum(p[k] for p in published) for k in ['downloadBytes','rawSourceBytes','compressedSourceBytes',
    'rawMeshBytes','triangles','nativeTriangles','sharedEdgesChecked']}
result=dict(parkCount=len(parks),publishedParkCount=len(published),parks=parks,totals=totals,
            scope='Terrain-only adaptive 0.5 m assets; normal-app reader integration remains separate')
(a.builds/'NATIONAL-PARKS.json').write_text(json.dumps(result,indent=2))
rows=[]
for item in parks:
    coverage=f"{item['coveragePercent']:.2f}%"
    if item['status']=='published':
        values=[item['name'],coverage,f"{item['downloadBytes']/1e6:,.1f} MB",f"{item['rawSourceBytes']/1e9:.3f} GB",f"{item['triangleReductionPercent']:.2f}%"]
    else:
        values=[item['name'],coverage,'Awaiting 1 m source' if item['status']=='awaiting-source' else 'Not yet published','—','—']
    rows.append('| '+' | '.join(values)+' |')
text=f'''# UK national parks — adaptive terrain batch

**{len(published)} of {len(parks)} parks have published adaptive assets.** Coverage below is the fraction of the park polygon supported by complete prepared 1 m chunks. A published park with gaps is not a complete-coverage claim.

| Park | Prepared coverage | Adaptive download | Original heightfields | Triangle reduction vs 1 m grid |
| --- | ---: | ---: | ---: | ---: |
'''+ '\n'.join(rows)+f'''

Published terrain totals: **{totals['downloadBytes']/1e9:.3f} GB** compressed adaptive geometry, compared with **{totals['rawSourceBytes']/1e9:.3f} GB** of raw heightfields and **{totals['compressedSourceBytes']/1e9:.3f} GB** of heightfields compressed with the same zlib level. The mesh contains **{totals['triangles']:,} triangles**, compared with **{totals['nativeTriangles']:,}** native-grid triangles. Detailed per-park reports show both packed and expanded geometry memory; compressed download size is not a RAM estimate.

Each chunk retains native seam vertices and is checked against a 0.5 m additional vertical surface-error limit relative to its prepared 1 m source. Every shared edge is audited; the published set has **{totals['sharedEdgesChecked']:,} shared-edge comparisons**. Independent interpolation/topology checks cover distributed and extreme chunks in every park, and every compressed file is verified by lossless round-trip before publication.

## Files and use

The external drive's `Ridge Sources/<park>-adaptive-0p5` folders contain individually downloadable compact RAT1 topology chunks (or an older explicit RME1 encoding) and `adaptive.json`. The static Docker server exposes them through `/adaptive-catalog.json`. Geographic bounds, compressed/decoded lengths and checksums, triangle counts and geometry-memory estimates let a future reader choose a bounded area before allocating a scene. Private provenance manifests, reports and coverage images are retained under `Ridge Experiments`.

These are **terrain-only assets**. They exclude map textures, walking graphs and horizon meshes. The normal app's regular-grid reader does not consume the adaptive codecs yet. The adaptive catalogue remains separate from its normal catalogue, and no removed experiment screen is restored. Nothing here proves that an entire national park fits in one iPad scene.

The existing boundary collection contains the 15 listed parks. The supplied precision products contain no Scottish inputs; the Scottish parks use separately acquired official DTMs at 1 m or finer, reprojected and sampled onto the native chunk grid. Their remaining source gaps are explicitly excluded. Coverage is reported against each full park polygon, not just dry land or a survey footprint. Missing chunks in any park stay unavailable; coarser data is not relabelled as 1 m LiDAR. Original source licensing and attribution are retained with every publication.

## Rechecking durable compressed files

The collection runner may use local temporary mesh files to avoid repeated small-file I/O on the external drive. It removes that scratch cache only after publishing checked compressed chunks and copying private audit records. Recheck a published park directly, without restoring the raw mesh cache:

```sh
python Tools/adaptive_terrain/verify_park.py /path/to/private/park-build \\
  --published /path/to/Ridge-Sources/park-adaptive-0p5
```

This checks compressed and decoded hashes, independent interpolation against the retained original prepared source, topology and all shared edges.
'''
(a.builds/'NATIONAL-PARKS.md').write_text(text)
print(json.dumps(dict(published=len(published),parks=len(parks),**totals),indent=2))
