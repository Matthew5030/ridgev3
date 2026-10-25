# Satellite-guided ground colour

The native cartography renderer blends illustrative ground colour in linear light
at **66%**, then draws the existing woodland, water, building, contour and path
features. Place labels and routes stay on their existing app overlays. Geometry,
height sampling, adaptive detail selection and texture-page budgets are unchanged.
There is no runtime satellite request or extra GPU texture.

The rollout covers all 2,531 available UK source sections (589,443 map tiles),
including every source listed in the local catalogue. All tiles have a colour
sample map. Satellite usable-data coverage is 99.62% tile-weighted and at least
91.07% in each section; unusable pixels fall back to the original palette.
The updated sources and downloadable region packs are in the local world source.
Existing offline downloads need refreshing to receive the new assets. This is
not a TestFlight release.

The source is Sentinel-2 L2A scene `S2C_30UVD_20250712_0_L2A`, 12 July 2025.
Ground colour follows approximately 10 m observed variation; it does not invent
fine texture or classify rock, grass or bogs. Vegetation, bare-land and water SCL
classes are accepted; other classes and missing data fall back to the original
palette. Excluded samples are expanded by about 30 m before use. The conservative
mask leaves 96.57% of this source usable. Classification is not a guarantee of
cloud-free imagery.

## Preparing another source

Use Python with numpy, Pillow and rasterio. Obtain a suitable Sentinel-2 L2A STAC
item (including `visual` and `scl` COG assets), inspect its date and local coverage,
and save its JSON. Prepare into a **new directory**:

```sh
python prepare_ground_colour.py --source SOURCE --output NEW_SOURCE \
  --item SCENE.json --cache WINDOW_CACHE
python check_ground_colour.py SOURCE NEW_SOURCE
```

Each map gains optional versioned RGBA samples with neighbour gutters. Alpha zero
means no usable colour. Preparation shares one sampling grid across the whole
source. The palette's reference luminance is fixed to the approved comparison,
not independently normalised per tile. Map filenames include their content hash;
map checksums and decoded lengths are updated. Existing maps without samples
continue to decode and render. The source manifest contains attribution; scene
metadata and preparation statistics accompany the output.

All UK parents use one sampling grid and common scene choices across their shared
footprints. The national QA compares 594 neighboring mosaics; the worst 99th
percentile RGB-channel difference is 3 of 255, with a rare isolated maximum of
24. Source tile gutters are checked separately by `check_ground_colour.py`.

## Local publication

```sh
python stage_ground_colour_publish.py --world WORLD_ROOT \
  --prepared NEW_SOURCE --output NEW_STAGE
python install_ground_colour_publish.py --world WORLD_ROOT \
  --staged NEW_STAGE --backup NEW_BACKUP
```

Staging rebuilds the changed section and every published region archive containing
it, preserving exact region membership and connected routing. Installation checks
that the live catalogue and source have not changed, verifies new assets, retains
old immutable maps/packs, backs up metadata, then publishes the manifest and
catalogue. The server must first accept `cNN-rNN-ground-<16 hex>.map` and serve
source manifests with `Cache-Control: no-cache`; the download-server nginx
configuration includes both changes. Update any other hosting allowlist before
publishing there.

Rollback: atomically restore the backup `world.json` to the path recorded in
`source-path.txt`, and restore the backup `catalog.json`. Old immutable assets
remain available. Regenerate section/region receipts if running packaging tools
after rollback; they are build caches rather than the app's source of truth.

## Validation

`Tools/test_world_source.sh` covers legacy maps, exact no-data fallback, north-up
orientation, protected water, path ink, gutters at every LOD, malformed samples,
plus the existing terrain, offline, route and memory-budget assertions.
`check_ground_colour.py` checks every map/mesh hash, unchanged vectors and geometry,
and matching neighbour samples. Native SceneKit renders were visually inspected.
The iOS simulator Debug build passes. A 1024-pixel page took about 14 ms on the
Mac; physical-device performance and TestFlight delivery remain separate checks.

## UK batch and permanent imagery cache

The national pipeline is `batch_ground_colour.py`. Scene selection accounts for
both no-data footprint and cloud cover: a cloud-free strip covering 4% of a tile
must not displace a nearly complete observation. Up to three distinct summer 2025
acquisition dates are selected per MGRS tile. Source pixels are combined only where
SCL and validity masks allow them. All parents use one virtual geographic raster
frame so independently processed windows share the same warp grid.

Original RGB and SCL GeoTIFFs are retained in
`~/Documents/Ridge Satellite Cache/uk-2025/assets`, with URL, size, ETag and SHA-256
receipts. `.part` downloads resume from their saved position. Completed originals
are reused for new crops and style changes. The earlier Snowdon windows remain in
`~/Documents/Ridge Satellite Cache/snowdon-2025`. These are source data and are not
part of disposable build-directory cleanup.

The cache also retains `candidates.json`, `scene-plan.json`, derived geographic
mosaics, and any initial raw crop windows. The UK inputs used 282 original
GeoTIFFs totalling 35,644,733,897 bytes. Their checksums and raster metadata were
verified offline after download; the cache and receipts are retained for future
reprocessing without downloading the imagery again. The selected original-file
sizes and URLs are recorded in `asset-sizes.json`.

```sh
python cache_satellite_scenes.py --cache CACHE --workers 12
python batch_ground_colour.py --world WORLD_ROOT --stage NEW_STAGE \
  --cache CACHE --candidates CANDIDATES.json --workers 4 --local-only
python audit_satellite_cache.py --cache CACHE
python check_ground_mosaic_seams.py MOSAIC_FOLDER --report NEW_STAGE/seams.json
python publish_uk_ground_colour.py --world WORLD_ROOT --stage NEW_STAGE \
  --backup NEW_BACKUP
# After reviewing coverage, checksums, seams and representative native renders:
python publish_uk_ground_colour.py --world WORLD_ROOT --stage NEW_STAGE \
  --backup NEW_BACKUP --publish
```

The batch can run alongside the original-file downloader. With `--local-only` it
waits for the files needed by each parent and makes no remote raster requests.
Completed source receipts and mosaics are reused on restart. Changing the scene
plan requires a new staging directory; downloaded originals remain reusable.

The completed rollout adds about 25.6 GB of maps, section packs and region packs.
Publication retains all old immutable assets, backs up every source manifest,
and copies all new objects before publishing metadata. Interrupted copies resume
from per-section receipts. Existing region-archive membership is preserved; if a
combined archive would exceed the app's 1 GiB cap, that region uses the existing
section-download path instead. Source and section-pack publication locks protect
against concurrent catalogue writers. A new catalogue is not published while any
section preparation is missing or has no usable satellite colour.
