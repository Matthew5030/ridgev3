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
