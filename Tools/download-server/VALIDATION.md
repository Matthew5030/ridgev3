# Local source download validation — 14 September 2026

The normal app flow is extended; no adaptive experiment entry point is added.

## Automated checks

- 397 native Swift assertions: catalogue connection, metadata-only registration,
  covered/missing tile selection, exact samples across tile boundaries,
  selected-resolution downloads, checksum rejection without publishing a bad
  cache file, larger-area preparation, cache reuse with the HTTP server stopped,
  and reopening saved terrain through a fresh PackStore while offline.
- 1,150 existing atlas-selection assertions passed.
- 43 extension-flow assertions passed, including route/history/camera preservation
  and recovery after cancellation or preparation failure.
- 27 cartography crop/install/rollback/legacy-upgrade assertions passed.
- 77 PackStore real-data integration assertions passed.
- Debug simulator and Release iOS builds passed.

The fixture uses a real loopback HTTP server and stops it for the offline checks.

## Prepared source and Docker

- Generated 111 × 172 selection cells: 16,410 have complete prepared LiDAR;
  2,682 are unavailable (the source rectangle includes surrounding land and sea).
- Intersecting those complete cells with the supplied park boundary gives
  97.64% park coverage; 50.51 km² of the 2,139.84 km² boundary remains unavailable.
  Unknown elevations were not substituted with invented terrain.
- Created all 19,092 native/preview cartography pairs, 15 walking-graph files
  and one overview. Exact 4 m output seams passed before publishing `pack.json`.
- Height assets occupy 9.427 GB; native and preview maps occupy 5.546 GB on the
  external drive. They are served separately from the app bundle.
- Docker is running on port 8787 with a read-only external-data mount and a
  persistent local config outside iCloud. Health, actual terrain bytes and
  byte-range delivery passed. Build reports return 404; POST requests return 403.
- The catalogue is published and the simulator connected via the Mac's `.local`
  hostname. Normal Explore shows the wider textured coverage and selectable
  tiles near Cadair Idris.

## Measured normal-flow performance

On the host Mac, four real terrain locations loaded distinct heightfields:
Yr Wyddfa, Tryfan, the Rhinogydd and Cadair Idris. Source-index validation was
optimized without removing checks: selection previews fell from roughly
4.4 seconds to 0.08–0.12 seconds. Catalogue inspection fell from 4.73 to 0.37 s.

A separate test used the running Docker container and the actual Eryri source,
with a clean local download cache. It selected one 4 m tile at Cadair Idris and
its admitted mapped horizon (3,969 cartography cells):

| Stage | Seconds |
| --- | ---: |
| Connect/download source index | 0.93 |
| Area preview | 0.13 |
| Download required files | 57.26 |
| Prepare selected terrain | 1.47 |
| Install/validate saved area | 3.07 |
| Load saved terrain | 1.19 |
| Cached selection + fresh-store reopen with unreachable download URL | 2.50 |

These are Mac/core measurements, not physical-iPad frame rate or render time.
The actual download exercised the same transport and crop/install/load code
used by the app. The retained test cache is `/tmp/ridge-park-download-test`.

## Device/visual limits

The final Release app was installed on the physical iPad. The validated source
index, overview and local server address were preloaded into its normal source
cache; terrain and native map files remain on-demand downloads. The Mac locked after
checking the wider normal selector, preventing the final simulator 3D visual
check. Physical-iPad download speed, peak memory and gesture feel still need
hands-on verification. The final physical-device launch was refused because the
iPad was locked; installation succeeded. No claim of measured device frame rate
is made.

The default terrain remains 4 m. This adds normal source coverage and explicit
local downloads; it does not replace the renderer with the separate 0.5 m
adaptive stress-test renderer.
