# UK standard terrain fallback

This rollout adds terrain only where the reviewed UK download zones lack native
LiDAR tiles. Existing mesh, background and map descriptors are retained verbatim.
Standard areas are blue in the coverage map; red continues to mean missing data.
The catalog carries optional `standardTerrain` rectangles and `standardTileCount`.
Old catalogs remain readable.

## Source and accuracy

The free Copernicus DEM GLO-30 source is a roughly 30 m **surface** model. Its trees
and buildings may affect heights. Adaptive compilation does not recover LiDAR
features from it. The 0.5 m mesh tolerance measures approximation of the prepared
surface, not absolute survey accuracy. Original EGM2008 heights are converted to
EGM96 using the cached official EGM2008 and EGM96 geoid grids.

The compiler uses the same RTIN algorithm as the existing adaptive terrain. A
fixed canonical raster sampling grid makes shared inputs reproducible. New edges
beside existing LiDAR copy all 513 decoded boundary samples exactly. Shared new
edges use a common baseline with common corner corrections. A fourth-power blend
carries boundary corrections into the new tile; old LiDAR stays unchanged.
Per-source metadata records the maximum correction. Invalid DEM coverage or
conflicting boundaries are deferred, never replaced with a flat tile.

OSM features and walk graphs come from the cached original semantic archives.
New cells retain paths and 20 m contours. Sentinel-2 colours influence ground
materials at strength 0.66 beneath the vector cartography. They provide broad
colour variation, not reconstructed fine photographic texture. Existing LiDAR
map assets retain their previously approved imagery treatment.

## Durable inputs and bounded storage

Working root:
`/Users/matthewbilella/Documents/Ridge Terrain Cache/uk-standard-terrain-v1`

Original DEM TIFFs, geoid grids, STAC discovery, geographic RGB/SCL/valid windows,
checksums and mosaics are retained. Existing UK imagery originals are reused from
`/Users/matthewbilella/Documents/Ridge Satellite Cache/uk-2025`.
The processed colour grid is 0.0002 degrees; its provenance records that value.
Downloads never use a paid API. A resumed request reuses checked saved inputs.

`standard_storage.py` copies completed assets to
`/Volumes/MLB_EXT_4TB/Ridge Sources/uk-standard-cache-v1`, verifies their full SHA-256,
and replaces their working paths with links. Large files use lossless APFS
compression. Storage receipts record the original path, target, size and SHA.
Original logical bytes remain unchanged. Only superseded, unpublished derived
packs/maps can be removed after the replacement is complete; source downloads
are retained. Existing outputs retain stable links; future source directories and new coloured
map assets write directly to the external cache. The imagery window cache also
resolves there. A 3 GiB build reserve protects that output volume, a 2 GiB
relocation reserve protects copies, and a separate 1.5 GiB reserve protects
internal audit/checkpoint storage.

The host download service resolves links on both volumes. Start it with
`sh Tools/download-server/start.sh`; repeat after a reboot. It inherits the
invoking Terminal/app's authorized folder access and runs detached until shutdown.
`native_control.py` verifies the actual catalog, not merely the health endpoint.
`RIDGE_DOWNLOAD_BACKEND=docker` retains the original Docker option; additional
supplemental paths would require corresponding Docker mounts.

## Resumable stages

Use the prepared root and original live world paths; each stage supports resume:

1. `standard_world.py`: immutable builder/input identity, completed source
   checkpoints, parent records and exact shared-edge receipts.
2. `standard_colour.py`: checked source windows, per-source repair journals,
   approved colours and rebuilt section packs.
3. `standard_storage.py`: checked lossless relocation while stages finish.
4. `standard_publish.py`: complete source/input and seam audit, payload checks,
   immutable old asset checks, backup metadata, catalog switch last.

Publication must wait for every planned terrain and colour batch, storage
completion and native reader tests. The old catalog remains live until then.
The final report must use actual catalog masks clipped to zone land polygons;
a planned tile count is not evidence that all red has cleared.

## Checks

`test_standard.py` freezes CLI/shared-library compiler parity, datum conversion,
canonical sampling and retained/new shared boundaries. Every prepared mesh is
read back and its full perimeter checked. At least one surface per parent also
uses independent triangulation/interpolation checks. The final audit reconciles
all four edges for every standard tile, every new/new seam and every retained
LiDAR contact. Native batch tests validate source decoding, mesh loading, graph
integrity, vector rendering and overview rendering. Region download tests cover
quality masks alongside transfer, repair and offline behavior. Native origin tests
cover exact downloads, byte ranges, cache headers and the public path allowlist.

`standard_rollout.py` resumes the geometry stage, waits for colour and storage,
runs native reader/regression checks, audits and publishes, then checks the
served catalog/packs and generates `reports/coverage.json` and `coverage.png`.
`rollout-status.json` and `rollout-error.json` distinguish completion from a
paused or failed pipeline. `standard_report.py` compares actual catalog masks;
`coverage-projection.json` is only an unpublished plan check.

## Live progress view

`standard_tracker.py --root <working-root> --study <sentinel-study-folder>`
serves the study pages on port 8786 and a read-only `/uk-coverage/live.json` API.
The tracker counts completed fallback tiles and verified source sections inside
active batches. Batch counts remain secondary because batches differ greatly in
size. Its worker-update time comes from the coordinator, not the browser's poll
clock. Process checks distinguish stopped workers from a long native audit that
has not yet emitted another progress record. Missing status files and connection
errors are visible; the last saved counts remain on screen.

Backend tests: `python Tools/global_source/test_standard_tracker.py`.
Browser status tests: `node --test ../sentinel-study/uk-coverage/tracker.test.mjs`.
