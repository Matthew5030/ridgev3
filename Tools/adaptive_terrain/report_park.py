#!/usr/bin/env python3
"""Create a measured park report; optionally include published download sizes."""
import argparse
import json
import math
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PatchCollection
from matplotlib.patches import Rectangle
from shapely.geometry import shape

p = argparse.ArgumentParser()
p.add_argument('source', type=Path)
p.add_argument('--published', type=Path)
a = p.parse_args()
r = a.source
m = json.loads((r / 'manifest.json').read_text())
v = json.loads((r / 'validation.json').read_text())
feature = json.loads((r / 'boundary.geojson').read_text())
park = shape(feature['geometry'])
gaps = shape(json.loads((r / 'coverage-gaps.geojson').read_text())['geometry'])
name = m.get('parkName', feature.get('properties', {}).get('displayName', m['name']))
coverage = 100 * (1 - m['uncoveredParkAreaKm2'] / m['parkAreaKm2'])
fig, ax = plt.subplots(figsize=(9, 10))
fig.patch.set_facecolor('#f7f5ed')
ax.set_facecolor('#e1eced')
patches, counts = [], []
for c in m['chunks']:
    b = c['bounds']
    patches.append(Rectangle((b['minLongitude'], b['minLatitude']),
                             b['maxLongitude'] - b['minLongitude'],
                             b['maxLatitude'] - b['minLatitude']))
    counts.append(c['triangles'] / 1000)
collection = PatchCollection(patches, cmap='YlGn', linewidth=0)
collection.set_array(counts)
ax.add_collection(collection)
for polygon in getattr(park, 'geoms', [park]):
    ax.plot(*polygon.exterior.xy, color='#273f34', lw=.7)
for polygon in getattr(gaps, 'geoms', [gaps]):
    if not polygon.is_empty:
        ax.fill(*polygon.exterior.xy, color='#d8644b')
ax.set_xlim(park.bounds[0] - .02, park.bounds[2] + .02)
ax.set_ylim(park.bounds[1] - .015, park.bounds[3] + .015)
ax.set_aspect(1 / math.cos(math.radians((park.bounds[1] + park.bounds[3]) / 2)))
ax.set_title(f'{name}\nAdaptive 0.5 m terrain', loc='left', fontsize=18, pad=20)
ax.set_xlabel('Longitude')
ax.set_ylabel('Latitude')
fig.colorbar(collection, ax=ax, shrink=.65, label='Thousands of triangles per native chunk')
fig.text(.12, .025, f"{len(m['chunks']):,} chunks · {m['triangles']/1e6:.1f} million triangles\n"
         f"{coverage:.2f}% prepared coverage · red marks missing data", fontsize=11)
fig.savefig(r / 'coverage.png', dpi=160, bbox_inches='tight')
plt.close(fig)
native_triangles = len(m['chunks']) * 512 * 512 * 2
raw_source = sum(c['sourceByteCount'] for c in m['chunks'])
packed_gpu = sum(c['compactBytes'] - 28 for c in m['chunks'])
rows = [
    ('Park polygon area (British National Grid)', f"{m['parkAreaKm2']:,.2f} km²"),
    ('Prepared 1 m coverage', f'{coverage:.4f}%'),
    ('Missing prepared coverage', f"{m['uncoveredParkAreaKm2']:.3f} km²"),
    ('Native chunks intersecting boundary', f"{len(m['chunks']):,}"),
    ('Native 1 m grid triangles', f'{native_triangles:,}'),
    ('Adaptive triangles', f"{m['triangles']:,}"),
    ('Triangle reduction against native 1 m grid', f"{100*(1-m['triangles']/native_triangles):.2f}%"),
    ('Original int16 heightfield files', f'{raw_source/1e9:.3f} GB'),
    ('Decoded RME1 geometry bytes', f"{m['compactBytes']/1e9:.3f} GB"),
    ('Packed vertex/index buffers, whole park', f'{packed_gpu/1e9:.3f} GB'),
    ('Expanded 48-byte vertices + UInt32 indices, whole park', f"{m['metalGeometryBytes']/1e9:.3f} GB"),
    ('Maximum measured additional surface error', f"{m['maximumMeasuredErrorMetres']:.6f} m"),
    ('Shared edges checked', f"{v['sharedEdgesChecked']:,}"),
    ('Shared-edge height disagreement', f"{v['maxSeamHeightDifferenceMetres']} m"),
]
if a.published:
    published = json.loads((a.published / 'adaptive.json').read_text())
    rows += [
        ('Losslessly compressed adaptive download', f"{published['byteCount']/1e9:.3f} GB"),
        ('Same original heightfields compressed with zlib level 6', f"{published['sourceZlibBytes']/1e9:.3f} GB"),
        ('Adaptive download reduction versus raw source', f"{100*(1-published['byteCount']/raw_source):.2f}%"),
        ('Adaptive download reduction versus compressed source', f"{100*(1-published['byteCount']/published['sourceZlibBytes']):.2f}%"),
    ]
table = '\n'.join(f'| {label} | {value} |' for label, value in rows)
properties = feature.get('properties', {})
summary = f'''# {name} — adaptive 0.5 m

Built from the existing prepared 1 m source. **{coverage:.2f}% of the park boundary is covered**. Missing coverage stays explicitly unavailable; no coarse heights were substituted. Whole native chunks touching the boundary are included, so totals include some land just outside the park.

| Measurement | Result |
| --- | ---: |
{table}

0.5 m is **additional vertical surface error relative to the prepared 1 m terrain**, not a claim of survey accuracy or a 0.5 m sample grid. The unchanged compiler accepts candidate triangles at 0.4999 m, restores native diagonals, and checks every final triangle at source vertices and cell centres. Independent Matplotlib interpolation checks {len(v['independentSamples'])} distributed/extreme chunks for error, full coverage and topology. Every shared native mesh edge is audited. See `validation.json`.

The adaptive mesh keeps detail where the source surface needs it. Smooth terrain uses larger triangles. All native perimeter vertices are retained for deterministic joins. There is no artificial triangle-span limit. It is not claimed to be the smallest possible triangulation.

## Download and app compatibility

Each chunk is independently downloadable. The compact RAT1 encoding stores the subdivision topology and source heights; decoding reconstructs the original RME1 mesh byte for byte. Older publications use zlib-wrapped explicit RME1 geometry. Its record provides bounds, compressed and decoded lengths, both SHA-256 hashes, triangle counts and geometry-memory costs. A downloader can choose an area without downloading or decoding the whole park. Compression does not reduce the resident geometry buffer size.

These are **terrain-only adaptive assets**. They do not include map textures, walking graphs or a horizon layer. The normal app currently uses regular-grid terrain and cannot consume these adaptive codecs yet. They are kept in a separate adaptive catalogue, so the normal selector cannot offer an unusable download. No removed experiment screen is reintroduced. They are not evidence that the entire park fits in one iPad scene; selected scenes still need a memory budget including maps, routes and render overhead.

## Provenance

Boundary: the existing prepared map collection, {properties.get('source', 'recorded source')}, relation {properties.get('relationID', 'recorded in boundary.geojson')}, version {properties.get('relationVersion', 'recorded in boundary.geojson')}. Original properties and licence notices are retained in `boundary.geojson`. Source manifests and every selected 1 m heightfield are checked against their recorded SHA-256 values. Source paths, hashes and compiler hash remain in the private build manifest. Published metadata omits local source paths.

Compiler topology adapts MARTINI (Mapbox, ISC); see the adjacent vendor licence. No source tiles were modified, no new raw LiDAR processing was performed, and no texture quality was reduced to obtain these geometry savings.
'''
(r / 'REPORT.md').write_text(summary)
print(summary[:2500])
