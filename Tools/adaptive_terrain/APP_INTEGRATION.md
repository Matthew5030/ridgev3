# Adaptive app integration — 16 September 2026

The production app reads precomputed RAT1 chunks directly. Eryri is published as
one source (`ridge-adaptive-v2-eryri`), with 16,413 native cells across storage
partitions. Fine terrain was not recomputed. Existing maps/path graphs and 8/32 m
context were reused; context transfers use verified 16-row ranges. Other UK
regions have geometry but require map/path publication.

## Validation

- Adaptive codec, exact queries, corruption limits and native axes: 656 checks.
- Existing route, navigation, expansion and tiled-source suites: 135, 125, 68 and
  410 checks respectively.
- Real server catalogue registration, lazy index hydration, native tile selection,
  range-only background transfer, legacy-source filtering and refresh: passed.
- Crib Goch nine-cell save, exact route elevations, GPX roundtrip, distinct second
  area, atomic replacement and offline reopen: passed. Compressed fine geometry
  was 797,025 bytes. With maps pre-cached, preparation was 8.6 s and offline reopen
  1.7 s on the Mac; these are not physical iPad benchmarks.
- Expansion across two storage containers: passed; all 513 common edge heights
  matched.
- Simulator's normal Metal planner: inspected with paths, contours and surroundings.
  24 projected terrain taps hit within 0.74 m of the expected coordinate.
- Final iOS simulator Debug build: passed for arm64 and x86_64.
- After archive: actual HTTP catalogue, hashed index, mesh range, context range,
  map image and walking graph all verified.

## Rollback

`/Volumes/MLB_EXT_4TB/Ridge Rollback/2026-09-16` holds the old `eryri-park`, fourteen
superseded partition-publication drafts, three prototype packages, previous
catalogue and an inventory. Nothing in that directory is served. Restore the old
source folder and catalogue together to roll back downloads; app commit `0fa6a3f`
is the pre-migration checkpoint. Original LiDAR, UK adaptive builds, source maps,
user routes and existing saved areas were retained. Bundled legacy assets remain
readable for compatibility and regression fixtures, but are excluded from new
atlas selections.

Install the updated app and reconnect/refresh Settings → Download server to see
the adaptive source. This migration has not been tested on the physical M1 iPad.

## Selection-index stall regression

The original atlas included its five-second memory revision in the SwiftUI
selection task identity. Foreground budget checks cancelled and restarted a slow
index download indefinitely. Memory admission now updates the existing proposal
independently; it does not restart source hydration. Cached selections skip index
I/O entirely. Index downloads show transferred bytes, use a 15 s inactivity / 90 s
resource limit, and expose an explicit retry after failure.

A simulator harness ran the real ExploreView with an eight-second HTTP response
delay and the foreground budget timer enabled (the test host was screen-locked).
The old view issued nine requests in about 40 seconds and never hydrated the
source. The fixed view completed with one request across repeated timer ticks.
The adaptive catalogue suite additionally checks budget refusal/recovery while
preserving selection metadata, saved references and source errors. The shared
source-download regression suite still passes all 410 assertions.

## Download size accounting

The selection panel now estimates additional network bytes using the same verified
source-cache receipts and file-length checks as the downloader. It separately
shows reused bytes and the surrounding map footprint. Memory rechecks retain this
estimate and do not scan the cache again. Unreceipted assets conservatively count
as missing until the downloader verifies them; selection never hashes gigabytes
of existing imagery. Already saved selections are labelled offline.

Measured around Crib Goch (decimal MB, including full-resolution surroundings):

| Selected cells | Map images | Fine adaptive mesh | All required source files |
|---|---:|---:|---:|
| 1 × 1 | 1,316.60 | 0.10 | 1,355.26 |
| 4 × 4 | 1,308.97 | 1.68 | 1,351.94 |
| 16 × 16 | 1,308.97 | 20.21 | 1,381.39 |

Every selection includes 3,600 native map cells for roughly 30 km of surroundings.
This explains the nearly constant cold-download size. The horizon extent and map
quality have not changed. With the existing nearby integration-test cache, those
three selections needed 0 MB, 15.92 MB and 38.81 MB respectively; cache inspection
took 0.54–0.72 s on the test Mac. This is disk/network accounting, not RAM usage.

`test_tiled_sources.sh` checks fresh, reused, partial, truncated and changed-hash
estimates alongside real downloads and offline reuse (416 assertions).
`test_adaptive_download_estimate.sh` compares the displayed estimate against live
transfer totals using a caller-supplied disposable cache seeded by a nearby
adaptive integration download; it refuses a cold gigabyte-scale test.

## Peak names across the landscape

Adaptive selections now retain source place names over the saved horizon bounds,
not only the fine-mesh rectangle. Older saved areas recover these names on load
from their matching cached `source.json` header, with no network request or terrain
reprocessing. This uses the lightweight registered catalogue rather than parsing
the full mesh index. New saves carry the surrounding names themselves.

The native label overlay considers peaks throughout the loaded landscape as the
camera moves. It reuses at most eight text views and retains terrain occlusion,
screen-edge and overlap checks. The former fixed 24-peak shortlist is removed.
The labels toggle and source-provided elevations remain unchanged.

The catalogue regression checks a real Yr Wyddfa label outside a small Crib Goch
selection, recovery of an older cropped save, repeated recovery without duplicate
names, standalone metadata preservation and rejection of out-of-bounds labels.
The pack integration test checks surrounding names survive save and offline load.

In the simulator, the old nine-cell save containing only Crib Goch recovered 539
landscape places. Yr Wyddfa and Moel Eilio both appeared when viewing their
surrounding terrain; Moel Eilio lay beyond the previous 24-candidate cutoff.
The overlay retained eight reusable label views and passed hide/show checks.

## Follow paths at the detailed-area boundary

Follow paths now remains path-only. Previously, a tap outside the fine rectangle
silently saved a two-point overview sketch while the control still said Follow
paths. It now opens the existing expansion preview without changing the route or
starting a download. New scenes default to Follow paths even when their selected
walking network is empty; Direct line remains an explicit choice. Moving or
inserting a point on an existing path leg cannot silently turn it into a sketch.
Existing saved manual sketches and GPX tracks retain their authored geometry.

Validation: 137 core routing assertions passed and the iOS Simulator build passed.
`bash Tools/test_adaptive_routing.sh <disposable-saved-areas> <source-headers>` uses
the nine-cell Crib Goch fixture from the adaptive pack integration test, with an
isolated route library and preferences and no downloads. It checks a real curved
17-point path, unchanged route plus expansion prompt on an outside tap, rejected
outside path edits, explicit manual sketches, an outside starting point, and a
missing walking network. These are Mac/simulator checks, not physical iPad tests.

## Zooming out over loaded surroundings

The 3D camera limit now uses the full loaded horizon rather than 1.55 times
the detailed area's home framing. An enclosing sphere around the current
target allows the loaded landscape to fit at any orbit angle and accounts for
portrait/landscape aspect ratios and targets near the coverage edge. The
collision-clearance clamp uses the same maximum so it cannot undo the wider
limit. Home continues framing the detailed area; the close texture limit and
finite pan coverage remain unchanged. This changes no downloads, terrain
allocations or mesh detail. The 2D atlas zoom range is unchanged.

`Tools/test_navigation.sh` includes landscape-corner fit checks across viewport
aspects and differently sized detail selections, alongside the existing
geographic camera persistence tests.
