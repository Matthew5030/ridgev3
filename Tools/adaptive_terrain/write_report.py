#!/usr/bin/env python3
"""Generate a human-readable report directly from verified experiment metrics."""
import json,sys
from pathlib import Path
out=Path(sys.argv[1]);m=json.loads((out/'metrics.json').read_text());r={p['id']:p for p in m['profiles']};q=r[m['fineProfileID']];matched=r['matched'];native=r['grid-1'];grid=r['grid-4']
rows=[]
for id in m['selected']:
 p=r[id];rows.append(f"| {p['label']} | {p['triangles']:,} | {p['surfaceErrorMetres']['max']:.3f} m | {p['surfaceErrorMetres']['rmse']:.3f} m | {p['estimatedCurrentMetalGeometryBytes']/1048576:.2f} MiB |")
storage=[]
for id in m['selected']:
 p=r[id];storage.append(f"| {p['label']} | {p['prototypeMeshBytes']:,} | {p['prototypeMeshZlibBytes']:,} |")
s=f'''# Crib Goch adaptive terrain experiment

Two original neighbouring precision tiles around the named Crib Goch summit: Eryri local column 6, rows 9 and 10. Approximately 490 × 981 metres in total. Built from the existing pack; the source pack and iOS app were not changed.

## Result

The adaptive mesh at the 4 m triangle budget reduces maximum measured added error from **{grid['surfaceErrorMetres']['max']:.2f} m to {matched['surfaceErrorMetres']['max']:.2f} m**, with **{matched['triangles']:,} versus {grid['triangles']:,} triangles**. Its estimated geometry memory is {100*(matched['estimatedCurrentMetalGeometryBytes']/grid['estimatedCurrentMetalGeometryBytes']-1):.1f}% higher because it needs slightly more vertices despite fewer triangles.

The finer mesh stays within **{q['surfaceErrorMetres']['max']:.3f} m** of the original surface, using **{100*(1-q['triangles']/native['triangles']):.1f}% fewer triangles** and **{100*(1-q['estimatedCurrentMetalGeometryBytes']/native['estimatedCurrentMetalGeometryBytes']):.1f}% less estimated geometry memory** than the full 1 m grid. It still costs {q['triangles']/grid['triangles']:.2f}× as many triangles as uniform 4 m. This is a useful quality/memory tradeoff, not free 1 m detail everywhere.

| Surface | Triangles | Maximum added error | RMS added error | Estimated Metal geometry |
|---|---:|---:|---:|---:|
{chr(10).join(rows)}

Errors are relative to the existing 1 m triangulated pack, **not absolute LiDAR accuracy or field survey truth**. The geometry estimate uses the current renderer's 48-byte vertex and 32-bit indices. It excludes textures, CPU staging, elevation lookup, route data, horizon geometry, and app overhead. It is not an observed M1 iPad memory or frame-time measurement.

Within 100 m of the named summit, maximum error falls from {grid['peak100mErrorMetres']['max']:.2f} m at 4 m to {matched['peak100mErrorMetres']['max']:.2f} m at the matched budget, or {q['peak100mErrorMetres']['max']:.3f} m in the fine version. Worst errors are local; the table also includes RMS so isolated extremes are not mistaken for the whole terrain.

## Inspect it

Open [the interactive comparison](index.html) through a local static file server. Drag to orbit, shift-drag to pan, and scroll to zoom. Both panels share the camera. Switch either panel between native 1 m, current 4 m, adaptive at the 4 m triangle budget, and 0.5/1/2/3 m adaptive tolerances. The initial view compares 0.5 m on the left against 1 m on the right. Quick buttons change only the right-hand tolerance and preserve the camera. The map and triangle overlays toggle independently.

![0.5 m and 1 m adaptive terrain](viewer-ridge.png)

- [Four-tolerance error heat maps](tolerance-comparison.png)
- [Original baseline error heat maps](error-comparison.png)
- [Triangle placement near the summit](triangle-comparison.png)
- [North–south crest cross-section](ridge-section.png)
- [All metrics, checks, source hashes and provenance](metrics.json)

## How it works

A preprocessing tool uses [MARTINI's RTIN topology](https://github.com/mapbox/martini), with a custom error field evaluated against the original surface. It places small triangles where larger ones fail the error test, including ridges, gullies and rough flanks. All vertices remain on the original 1 m sample grid; the largest triangle is equivalent to an 8 m cell. Named sample spacing is nominal: these source cells have ground steps approximately {m['provenance']['metresPerNativeStep'][0]:.3f} × {m['provenance']['metresPerNativeStep'][1]:.3f} m.

The generic algorithm's midpoint criterion alone was insufficient. It also sometimes chose the opposite diagonal between four native samples, creating a different surface at cell centres. This experiment measures each candidate triangle against native vertices and cell centres, propagates shared-edge constraints, and preserves the app's native diagonal where necessary. The independent evaluator then verifies the finished mesh. A criterion is never reported as a measured result.

The two tiles keep every native perimeter sample. Their shared edge matches exactly in position, height and tessellation. This conservative seam policy costs geometry: 2,048 boundary vertices per tile, all included in the counts. The summit lies almost on that edge, so some local ridge detail benefits from forced boundary refinement. Results should be repeated on a crest away from an edge before treating them as representative of the UK.

The viewer reuses the original two 1,024-pixel map cores, cropped from their existing gutters, in one 1,024 × 2,048 texture. Every profile uses identical UV coordinates, map pixels, mipmaps and anisotropic filtering. Geometry normals are calculated from each mesh, with common source normals only at native boundaries to avoid lighting seams. No high-resolution normal map disguises simplification.

The viewer loads precomputed local meshes. It does not fetch or refine terrain while the camera moves. The local static server only serves files for browser viewing; it is not a live terrain service.

## Validation

Every profile was independently sampled at **{m['samplesPerProfile']:,} positions**: every native grid vertex and every native cell centre across both tiles. Shared seam samples are counted once per tile. Centre checks catch diagonal changes that vertex-only validation misses. The reference uses the same NE–SW cell diagonal as the current renderer. Prepared 2/4/8 m values are verified to be exact subsamples of the existing 1 m grid.

{chr(10).join('- '+c for c in m['validation'])}

## Disk cost and format

The test writes a small, documented `.rmesh` binary for each tile, with integer sample coordinates, lossless source height units and 16- or 32-bit triangle indices. It also writes zlib-compressed copies and separate WebGL preview buffers. These are experimental artifacts, not a new production pack schema.

| Surface | Mesh bytes, both tiles | zlib bytes, both tiles |
|---|---:|---:|
{chr(10).join(storage)}

For comparison, the existing raw height arrays are {native['heightFileBytes']:,} bytes at 1 m and {grid['heightFileBytes']:,} bytes at 4 m. An explicit triangle mesh can be **larger on disk than a regular height grid** despite using much less rendering memory. This prototype proves geometry savings; it does not prove download savings. Map files are unchanged, and normals or an elevation lookup structure would add to a production payload.

## Decision still open

No quality setting or number of shipping layers has been selected. The four tolerances are comparison candidates. First inspect the crest, flanks and silhouette at the same camera position, with the map both on and off. Then compare acceptable candidates over a larger chosen Snowdon area; these two tiles cannot establish the total cost or immersion of that scene.

All candidates currently retain the original conservative 8 m maximum cell size and full native boundaries. Consequently, the 2/3 m tests may reach a geometry floor even where their height tolerance would permit larger triangles. These numbers describe this experiment, not the minimum achievable memory for those tolerances. Keep this constant for a fair visual comparison before varying a second parameter.

Before integration, benchmark prebuilt mesh decoding, first frame, peak resident memory, orbiting and route picking on the actual M1 iPad Pro. Repeat on tiles where the crest lies away from a boundary.

The next implementation step would add a versioned mesh reader, precomputed normals, bounded scene loading and a spatial lookup for route placement, while keeping the current grid pack as a fallback. No iOS integration or device speedup is claimed by this experiment.

Source attribution: contains Welsh Government information licensed under the Open Government Licence v3.0; © OpenStreetMap contributors, ODbL. Upstream MARTINI is vendored unchanged under its ISC licence with a pinned commit and hashes.
'''
(out/'REPORT.md').write_text(s)
