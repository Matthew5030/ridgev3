# English LiDAR source-selection repair

The retained acquisition chooser selected the first country rectangle containing
a z10 tile centre. Its Welsh rectangle reached east to longitude −2.45, covering
English land; an empty Welsh result never caused English input to be prepared.
This left the Ludlow and Leominster parent sections empty, plus a wider band of
partial and empty sections. The original acquisition and terrain stay read-only.

`../adaptive_terrain/prepare_english_border.py` corrects the selection for omitted
native children. It preserves every previously selected child, requires each new
child's complete projected envelope plus 2 m interpolation support inside the
checksum-locked official EA 2022 1 m survey polygons, and preserves the existing
explicit Welsh coastal ownership exclusions. It never uses country rectangles
as evidence of actual LiDAR. The plan found 39,312 candidates in 30 parent areas;
only successfully sampled complete children become available terrain.

The original sampler uses integer-aligned WCS subsets, official OSTN15/OSGM15
grids and the EGM96 grid. A retained English reference was reproduced byte for
byte before processing. Original WCS responses and 513 × 513 native arrays are
retained gzip-compressed with SHA-256 receipts. Materialized arrays and decoded
mesh scratch files may be removed after processing; the retained compressed
inputs reconstruct them without another download.

The completed source audit verified 39,233 native arrays and 2,523 WCS rasters.
Seventy-nine planned candidates lacked complete sampled data. Every TIFF block
is decoded before accepting a response: an intact TIFF header alone does not
detect a truncated download. Three native arrays retained from a partially
received response were reproduced exactly from its complete replacement.
`source-cache-audit.json` binds the audit to the plan and native manifest hashes.

Some verified compressed WCS originals are stored under
`/Volumes/MLB_EXT_4TB/Ridge Experiments/English-border-cache-2026-10-20`, with
atomic links preserving their cache paths. `cache-relocation.json` records every
relocated file and checksum. The external drive must be connected to reuse those
inputs. Relocation preserves the original response bytes; satellite originals
remain in their existing permanent cache.

`repair_english_border.py` checks exact native edge and corner heights against new and
previously published neighbours, runs the existing adaptive compiler and
independent triangulation checks, then builds app-format geometry, cartography
and connected OSM routing. Existing published fine meshes, background meshes and
vector maps are preserved. New assets use content-addressed filenames; updated
overview/graph filenames cannot replace previously cached immutable payloads.
Satellite colours use the permanent UK imagery cache and the approved 66% blend.

The Ludlow pilot recovered all 2,304 children; its 4,560 shared edges matched
exactly. A 256-tile app source passed the native loader/render test, including
2,808,942 fine triangles, 4,885 route nodes and 18 places. Further sections use
the same checks. Final cross-section validation is required after all native
preparation completes, before publication.

If an EA recovery disagrees with an existing Welsh survey at a shared edge or corner,
that new child is excluded and recorded in `seam-exclusions.json`, including
the measured height difference and neighbouring source ID. The existing data
is preserved and no heights are blended or fabricated. Any disagreement between
two new EA children remains a hard build failure. Final accepted edges still
require exact equality; source conflicts can leave narrow explicit gaps.

The full repair accepted 38,376 new native children across all 30 parent areas.
The other 857 completely sampled children were excluded for conflicts with
existing survey heights. The final full-plan edge and corner audit passed for
every area, with zero height difference at every accepted contact. Both a new
256-tile source and a mixed 249-tile source passed native app validation,
including their fine meshes, connected routing and places.

Published locally on 20 October 2026: 235 updated sections, including 140 newly
available sections. The catalogue now has 2,671 sources and 627,819 tiles, up
from 589,443 tiles. The actual land-clipped coverage comparison reports about
8,849 km² recovered. Wye Valley & Herefordshire increased from 50.29% to 99.04%
detailed coverage; Shropshire & the Marches from 51.14% to 98.75%; Cheshire &
Staffordshire from 57.92% to 98.58%; Chester & Merseyside from 58.66% to 99.54%.
Small genuine gaps keep these areas classified as partial. The 84-region
availability totals remain 8 available, 47 partial and 29 unavailable.

The installed server configuration is copied separately under
`~/Library/Application Support/Ridge Download Server/nginx.conf`; updating only
the repository copy does not update that running server. Both copies now allow
the new hashed terrain, overview and graph filenames. After a syntax check and
reload, 21 live HTTP assets passed byte-count and SHA-256 checks across three
sources, including whole packs and three partial-download requests. Catalogue
and manifest cache headers and the original catalogue backup were verified.
The cache's `reports/` folder contains `http-publication-audit.json`,
`coverage-comparison.json` and `coverage-before-after.png`.

## Resume the local repair

The active cache is `~/Documents/Ridge Terrain Cache/england-border-repair-2026-10-20`.
Use a Python environment with NumPy, rasterio, pyproj, Shapely, contourpy, Pillow
and Matplotlib. Keep the native preparation and world conversion in separate
processes so they can overlap. Both have exclusive per-phase locks and reuse
verified checkpoints.

```sh
python Tools/adaptive_terrain/prepare_english_border.py \
  --previous OLD_ADAPTIVE_BUILD --mapping ORIGINAL_MAPPING \
  --coverage EA_FOOTPRINT_CACHE --grids LOCAL_COORDINATE_GRIDS \
  --cache REPAIR_CACHE --archive-only --workers 4

python Tools/world_source/repair_english_border.py \
  --previous OLD_ADAPTIVE_BUILD --mapping ORIGINAL_MAPPING \
  --world LIVE_WORLD --archives STAGED_WORLD_ARCHIVES \
  --satellite PERMANENT_SATELLITE_CACHE --cache REPAIR_CACHE \
  --wait-for-native

python Tools/adaptive_terrain/audit_english_source_cache.py \
  --cache REPAIR_CACHE --previous OLD_ADAPTIVE_BUILD \
  --mapping ORIGINAL_MAPPING --grids LOCAL_COORDINATE_GRIDS
```

Add `--tile z10-x504-y336` for a pilot. After staging, repeat the world command
with `--publish-only` to validate and publish without repeating conversion.
The final full-plan invocation with `--publish` or `--publish-only` requires the
completed cache audit, repeats all cross-section seam
and corner checks, and installs verified immutable
objects before replacing metadata. It retains the previous catalogue and source
manifests under `LIVE_WORLD/terrain-repairs/2026-10-20-english-border`. Interrupted
object and metadata installation both resume without replacing that backup.
`world-stage/repair-publication-report.json` is the completion receipt.

Regression checks:

```sh
python -m unittest discover -s Tools/adaptive_terrain -p test_english_border.py
python -m unittest discover -s Tools/world_source -p test_english_repair.py
sh Tools/test_world_batch.sh REPAIR_CACHE/world-stage/sources/SOURCE_ID
```

The local server allowlist includes hashed terrain, overview and graph names.
Source manifests/catalogues revalidate; immutable objects retain long caching.
The existing region layout remains unchanged and computes red gaps from the
new catalogue's actual tile coverage. Scotland and genuine unsupported survey
holes are outside this source-selection repair.
