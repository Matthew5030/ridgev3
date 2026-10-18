# Larger download areas — revised boundary proposal, 18 October 2026

The reviewed 84-area layout is now exported to the iOS app through
`install_large_areas.py`. This folder remains its comparison preview; no new
regional pack publication has been performed.
Open `Artifacts/larger-regions-preview/index.html` directly, or serve that folder
locally. The page is self-contained and has no external map/API dependencies.
It compares current and proposed boundaries with search, selection, pan/zoom,
size estimates and an optional terrain-gap overlay (off initially).

## Clearer geography

420 current areas become **84 visible areas**, including all 15 national parks
as separate download groups, named islands and surrounding countryside.
The first 89-area proposal produced stepped park outlines, narrow leftovers
and disconnected fragments because it assigned cells to their nearest place
within the old broad groups. That algorithm has been replaced.

The new layout recursively divides the source grid with straight shared cuts.
It protects the central park extents, uses curated place anchors, avoids narrow
blocks, and removes surrounding-area anchors that would produce coastal
remnants smaller than roughly 200 square kilometres. These are approximate
land areas, not surveyed administrative boundaries. Final outlines are clipped
to the same coastline used previously. Five detached mainland fragments are
reassigned to the neighbouring region they actually touch on land; for example,
the Cumbrian coastal strip now belongs to the Lake District, not Dumfries.
True islands are not moved by that rule. The recorded `coastalTransfers` make
these exceptions auditable and reproducible.

Every original section retains its identifier and bounds and has one display
owner. Total displayed land is unchanged, with no overlapping selection areas.
All 2,531 published sections remain represented. Green outlines are **download
areas around parks**, not legal national-park boundaries.

## Park membership and integration

Each park's `downloadCells` contains its displayed block plus every original
park section. A boundary section can therefore be included by both a park and
its neighbour, even though their selection polygons do not overlap. Consumers
must reuse/deduplicate those shared source IDs. None of the original park
coverage has been dropped to make the outlines simpler.

The app now consumes separate display and download membership. The exporter
strips draft metadata and frozen coverage flags before writing the app resource.
Native tests verify full park coverage, invalid memberships, cache reuse,
selection and saved-state counting. The larger Eryri membership deliberately
does not match the smaller pilot archive; it downloads existing section bundles
until a new matching regional archive is published. Terrain files and server
catalogues have not been rebuilt by this integration.

## Size and coverage

| Proposed area | Estimated current download |
| --- | ---: |
| Eryri | 1,014 MB |
| Lake District | 491 MB |
| Peak District | 428 MB |
| Bannau Brycheiniog | 839 MB |
| Yorkshire Dales | 457 MB |

Estimates sum existing compressed section-pack bytes plus 1% metadata allowance.
Making cleaner blocks includes some surrounding countryside, so these are
larger than exact park-only groups. Eryri exceeds the conservative 1 GB target;
Fens & Cambridgeshire exceeds the current 128-section archive limit. Both are
flagged as needing multiple archive parts while remaining a single map
selection. Multipart publication is not implemented by this preview. The
8 MB compressed-index and 32 MB decoded-metadata limits must also be validated
by the builder before publication; byte estimates alone do not establish
format compatibility.

The library still has 14,156,003,383 unique section bytes. Recutting cannot fill
missing terrain. Twenty-nine proposed areas have no published detailed terrain;
others are partial. Lower unavailable-area counts reflect regrouping, not new
coverage. Selecting an area always shows its coverage status, even when the
optional terrain-gap shading is hidden. The overlay covers both layouts and
is drawn only once. Zero-data areas are labelled unavailable, not advertised
as zero-byte downloads. Scottish sizes are not forecasts of complete coverage.

`regions.json` records the catalogue hash/revision used for these figures.
No cloud service is activated.

## Reproduce and verify

Requires Python and Shapely (tested with Shapely 2.0.7):

```sh
python Tools/region_zones/preview_large_areas.py \
  --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
python -m unittest discover -s Tools/region_zones -p test_large_preview.py
python -m http.server 8776 --bind 127.0.0.1 \
  --directory Artifacts/larger-regions-preview
```

Six tests cover immutable sections and unique ownership; full park and displayed
block download membership; rectangular partitions with recorded coastal
exceptions and no tiny surrounding remnants; unchanged land, no overlaps and
coastal labels; honest size/coverage flags; and named mountain/island locations,
including the corrected Cumbrian coastal strip.

Review shapes before app integration and bulk archive generation. Keep existing
section files during rollout so saved downloads remain reusable and smaller
repairs do not require a whole-region redownload.

## Layout checkpoint before the coverage audit

The 84-area layout is the fixed boundary baseline for the next audit. All six
layout checks pass, including complete park download memberships, unique
section ownership, unchanged land and the repaired coastal fragments. Further
coverage fixes should change what terrain is available inside these blocks,
not silently move their boundaries.

`Artifacts/region-coverage-audit/audit.json` records the exact layout and
catalogue hashes, checks the published source metadata against its masks and
pack-file lengths, and traces gaps back to the frozen preparation plan. Its
companion `REPORT.txt` lists regional coverage and follow-up work. This audit
does not itself rebuild maps or certify every mesh payload. The subsequent
iOS integration changes selection and download membership only. Bulk regional packaging remains after coverage remediation.

The completed local audit found no source-manifest hash discrepancies or
published metadata/mask/pack-length problems. All 589,443 selected tiles are
accounted for across 2,531 published sources. Among the 674 original parent
areas, 220 have no prepared manifest and 112 have no selected native chunks.
The audit's reason flags overlap and are parent-level evidence, not an exact
allocation of missing land to individual causes.

The first acquisition issue to investigate is the rectangular, first-matching
source chooser: Welsh coverage is selected before English coverage, including
at Leominster and Ludlow. Nineteen empty parent areas match both configured
rectangles. `source-selection-review.json` records inspected code/config hashes
and candidates. These rectangles are not survey footprints; some candidates
are coastal, and this finding does not yet prove usable English data exists.
Retain the official-footprint exclusions and seam policy until validated
replacement data is built. No excluded terrain was re-enabled by the audit.

To repeat the read-only metadata audit with the external drive connected:

```sh
python Tools/region_zones/audit_coverage.py \
  --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources' \
  --plan '/Volumes/MLB_EXT_4TB/Ridge Experiments/UK-adaptive-0p5-v3/plan.json'
```
