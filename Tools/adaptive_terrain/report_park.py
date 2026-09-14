#!/usr/bin/env python3
import json, pathlib, sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PatchCollection
from matplotlib.patches import Rectangle
from shapely.geometry import shape
r=pathlib.Path(sys.argv[1]);m=json.loads((r/'manifest.json').read_text());v=json.loads((r/'validation.json').read_text())
park=shape(json.loads((r/'boundary.geojson').read_text())['geometry']);gaps=shape(json.loads((r/'coverage-gaps.geojson').read_text())['geometry'])
fig,ax=plt.subplots(figsize=(9,10));fig.patch.set_facecolor('#f7f5ed');ax.set_facecolor('#e1eced')
patches=[];counts=[]
for c in m['chunks']:
 b=c['bounds'];patches.append(Rectangle((b['minLongitude'],b['minLatitude']),b['maxLongitude']-b['minLongitude'],b['maxLatitude']-b['minLatitude']));counts.append(c['triangles']/1000)
p=PatchCollection(patches,cmap='YlGn',linewidth=0);p.set_array(counts);ax.add_collection(p)
for polygon in park.geoms:ax.plot(*polygon.exterior.xy,color='#273f34',lw=.7)
for polygon in gaps.geoms:ax.fill(*polygon.exterior.xy,color='#d8644b')
ax.set_xlim(park.bounds[0]-.02,park.bounds[2]+.02);ax.set_ylim(park.bounds[1]-.015,park.bounds[3]+.015);ax.set_aspect(1.66)
ax.set_title('Eryri · adaptive 0.5 m experiment',loc='left',fontsize=19,pad=20)
ax.set_xlabel('Longitude');ax.set_ylabel('Latitude');fig.colorbar(p,ax=ax,shrink=.65,label='Thousands of triangles per native chunk')
fig.text(.12,.04,f"{len(m['chunks']):,} chunks · {m['triangles']/1e6:.1f} million triangles\nRed: {m['uncoveredParkAreaKm2']:.1f} km² without prepared 1 m coverage",fontsize=11)
fig.savefig(r/'coverage.png',dpi=160,bbox_inches='tight');plt.close(fig)
summary=f'''# Eryri adaptive 0.5 m — full park experiment

The existing prepared 1 m LiDAR supports **{100*(1-m['uncoveredParkAreaKm2']/m['parkAreaKm2']):.2f}% of the Eryri National Park boundary**. The remaining **{m['uncoveredParkAreaKm2']:.2f} km²** is recorded in `coverage-gaps.geojson` and stays empty in the native diagnostic. It has not been replaced with coarse terrain or counted as passing the 0.5 m test.

| Measurement | Result |
| --- | ---: |
| Park polygon area (British National Grid) | {m['parkAreaKm2']:,.2f} km² |
| Native chunks intersecting boundary | {len(m['chunks']):,} |
| Vertices, including shared perimeter duplicates | {m['vertices']:,} |
| Triangles | {m['triangles']:,} |
| Packed mesh bytes (uncompressed RME1) | {m['compactBytes']:,} ({m['compactBytes']/1e9:.2f} GB) |
| Current renderer: 48-byte vertices + 32-bit indices | {m['metalGeometryBytes']:,} ({m['metalGeometryBytes']/1e9:.2f} GB) |
| Maximum measured surface error | {m['maximumMeasuredErrorMetres']:.5f} m |
| Shared edges checked | {v['sharedEdgesChecked']:,} |
| Shared edge height disagreement | {v['maxSeamHeightDifferenceMetres']} m |

0.5 m means **additional vertical surface error against the prepared 1 m source**, not source survey accuracy or a 0.5 m sampling grid. Every output triangle was checked at the original source vertices and native NE–SW cell centres. The park compiler uses a 0.4999 m acceptance threshold. Final validation includes the restored native diagonals. An independent Matplotlib triangle locator checked {len(v['independentSamples'])} distributed/extreme chunks, full point/cell-centre coverage and topology. All adjacent chunk perimeter heights were compared from the written meshes. See `validation.json`.

Chunks retain every native perimeter sample for deterministic seams. Whole chunks touching the boundary are included; extra land just outside the polygon therefore contributes to the triangle count. There is no artificial maximum triangle span and no dynamic terrain streaming. This is not claimed to be the mathematically smallest triangulation.

## Native diagnostic

The iOS app has a separate **Eryri adaptive · full park stress test** at the bottom of Settings when `Documents/EryriAdaptiveTest/manifest.json` is installed and no normal terrain scene is open. It does not alter saved areas or routes.

The diagnostic reads packed 6-byte vertices and 16/32-bit indices directly into Metal buffers. It checks the entire scene against the current iOS memory allowance plus 512 MiB headroom and the recommended GPU working set. A refusal is recorded as **refused-before-allocation**, not reported as a successful load or crash. A successful test keeps all chunks resident, with offscreen draw culling only. Rendering uses simple terrain colour; it excludes map textures, routes and horizon meshes, so this is a lower-bound geometry experiment, not proof of complete app performance.

The app writes `Documents/EryriStressResult.json` with the device readings and result. The full-park camera button draws the same geometry; it does not reduce detail. Launch arguments `--eryri-stress-test --eryri-auto-test` open and run the diagnostic for development.

## Provenance and reproduction

Main source: England/Wales precision product `2026.09.02-1`. The earlier national-parks product `2026.09.01-1` was checked as a fallback but supplies no missing park chunks. Missing prepared parents report `noCompleteLidarCoverage`. Source manifests and child file SHA-256 values are verified. Output chunk hashes are stored in `manifest.json`.

Boundary: the existing project's OSM Eryri relation 287245, version 350, whose source references Natural Resources Wales. Reused to align with the existing generated map collection. LiDAR: Welsh Government 1 m DTM, source version 2024-10-11, as recorded by the prepared precision product. See the original product manifests for source evidence and licensing.

Compiler topology adapts MARTINI (Mapbox, ISC); see `Tools/adaptive_terrain/vendor/MARTINI-LICENSE`. `build_park.py` is resumable and bounds worker memory. `verify_park.py` independently audits the generated files. No existing source packs were modified.
'''
(r/'REPORT.md').write_text(summary)
print(summary[:1700])
