# Park download zones

The app loads `ridge v3/Resources/uk-download-zones.json`. This replaces the old
44 broad regions with 216 selectable areas: compact parks, compass quarters of
larger parks, and smaller surrounding countryside/coast areas. A split park also
has a whole-park selection in its inspector and in map search.

The areas reference existing `world-*` sources; no terrain or map rebuild is
required. SHA-addressed saved files and per-source receipts remain compatible.
No server publication or cloud enablement is part of this change.

## Reproduce

From the repository root, with the terrain pipeline's Shapely dependency:

```sh
python3 Tools/region_zones/build_zones.py --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
python3 -m unittest discover -s Tools/region_zones -p 'test_*.py'
sh Tools/test_world_region_packs.sh
```

Inputs are the original `uk-pack-regions.json` background grid, the 15 existing
`*-adaptive-0p5/boundary.geojson` park boundaries, and the published world
catalogue. Boundary provenance and file SHA-256s are retained in the new index.
`surrounding-areas.json` preserves the previous geographic band definitions.

Each old grid cell is divided into the existing 3 × 3 source sections (16 × 16
terrain tiles each), using the same latitude interpolation as `batch_world.py`.
All published source IDs and bounds must match before an index is written.

Sections touching a park go to that park; if two parks touch the same section,
the greater polygon overlap wins. Remaining sections retain their old geographic
group, divided into compass quarters. Groups of 24 sections or fewer stay whole.
The resulting 6,066 cells include unpublished coverage; availability still comes
from the connected server catalogue. No additional Scottish coverage is implied.

These are approximate download footprints, not legal park boundaries. A section
can contain countryside outside a park, and a shared boundary section has a single
owner. Keeping whole source sections preserves routes, cache reuse and the fast
catalogue-only size offer without another server format or asset reprocessing.

October 2026 catalogue upper estimates (terrain + maps + routing):

| Area | NW | NE | SW | SE |
| --- | ---: | ---: | ---: | ---: |
| Eryri | 440 MB | 252 MB | 304 MB | 375 MB |
| Lake District | 291 MB | 215 MB | 194 MB | 208 MB |
| Peak District | 309 MB | 138 MB | 164 MB | 142 MB |

Actual transfer skips verified saved files. Whole-park selection is the union of
its smaller areas, never a separate duplicate pack.
