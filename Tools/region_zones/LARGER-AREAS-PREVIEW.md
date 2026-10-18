# Larger download areas — boundary proposal, 18 October 2026

This is a **preview**, not a replacement app index or a pack publication.
Open `Artifacts/larger-regions-preview/index.html` directly, or serve that folder
locally. The self-contained page has no external map/API dependencies. It
compares the current and proposed boundaries with search, selection, pan/zoom,
size estimates and an independent terrain-gap overlay.

## Proposal

- 420 current areas become 89 visible areas: all 15 parks, separate island
  groups, and larger surrounding countryside regions.
- Existing park download memberships are retained, including the tested Eryri
  archive. Skye/Raasay, Anglesey, Arran, Orkney, Shetland and other island groups
  have separate selection areas.
- Every original source section retains its identifier and bounds and has one
  display owner. All 2,531 published sections remain represented.
- Display areas do not overlap. The coastline and total displayed land are
  unchanged. Boundaries snap to existing source sections; they are draft
  download footprints, not administrative or exact national-park boundaries.
- Surrounding areas use curated names anchored to existing walking-map labels,
  with nearest-anchor assignment inside the existing broad geographic groups.
  This is deterministic and avoids inventing new terrain or cartographic data.

Three source sections touch both the Lakes and Dales park groups. Their display
owner is whichever actual OSM park boundary intersects more of the section.
Both parks retain the full edge terrain in `downloadCells`; a future consumer
must deduplicate those shared files. The Eryri membership is unchanged.

**Do not copy this draft into the app unchanged.** Its `cells` define disjoint
display ownership; `downloadCells`, where present, define the full download.
The current app loader assumes globally unique `cells` and does not yet consume
this draft's separate download membership. Integrating the accepted proposal
needs explicit loader/selection/coverage tests for this distinction.

## Size and coverage

| Area | Download |
| --- | ---: |
| Eryri | 892 MB, actual tested archive |
| Lake District | about 411 MB |
| Peak District | about 287 MB |
| Bannau Brycheiniog | about 523 MB |
| Yorkshire Dales | about 355 MB |

Other estimates use existing compressed section-pack bytes plus 1% metadata
allowance. Every current estimate is below 1 GB and every available group has
at most 128 published sections. Full builder validation (including the 8 MB
index and 32 MB decoded-metadata limits) is still required before publication;
a byte estimate alone is not a format-compatibility guarantee.

The library still has the same 14,156,003,383 unique section bytes. Recutting
cannot fill missing terrain. Thirty proposed areas have no published detailed
terrain; others are partial. A smaller unavailable-area count than before is
only a consequence of larger groupings. The terrain-gap overlay is independent
of the boundary mode and stays visible over both layouts. Zero-data areas are
labelled unavailable, never advertised as a free/zero-byte download. Low sizes
in Scotland must not be interpreted as sizes for future complete coverage.

`regions.json` records the source catalogue hash/revision used for these figures.
The build does not alter source packs, the server catalogue, installed apps or
user downloads. No cloud service is activated.

## Reproduce and verify

Requires Python and Shapely (tested with Shapely 2.0.7):

```sh
python Tools/region_zones/preview_large_areas.py \
  --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
python -m unittest discover -s Tools/region_zones -p test_large_preview.py
python -m http.server 8776 --bind 127.0.0.1 \
  --directory Artifacts/larger-regions-preview
```

Five tests pass: immutable source cells/unique ownership, full park download
membership, equal total land/no visual overlaps/coastal labels, honest size and
availability reporting, and recognisable mountain/island grouping. Browser
checks exercised map selection, current/proposed switching, coverage controls,
and zoom. The saved Lake District screenshot shows the actual rendered preview.

Review the shapes and names before app integration and bulk archive generation.
Keep the existing section files during rollout so current downloads remain
reusable and smaller repairs do not require a whole-region redownload.
