# Preinstalled native UK map

The app ships the complete 2D map. Browsing does not fetch images or depend on
saved terrain, the catalogue connection or a running download server.

`native_overview.py` reads all 674 verified semantic archives, the UK elevation
background, available source overview heights and the shared illustrative colour
mosaics. It projects the real vector features into `WorldCartography`, then
captures the surface with `WorldPreview`, including the current 3D materials and
lighting. Missing fine heights retain the national elevation background; joins
are feathered over 160 m. Missing colour observations retain the native palette.
The conversion does not change terrain downloads, source assets or routing.
Dense cities are captured in several image rectangles when their combined path
list exceeds the renderer limit. Every pass retains the same full camera,
terrain and ground colour; whole crossing features and an antialiasing margin
are retained before cropping. Runtime tile limits and map detail stay unchanged.

Each section is captured once at 2048 px. It is reprojected to Mercator z13
reference pages; reduced parents provide efficient country browsing. The app
continues to decode at most 96 pages of 256 px. It does no offscreen terrain
rendering to prepare its base map.

Build the renderer with `sh Tools/build_world_terrain_atlas_renderer.sh OUTPUT`.
Then run the generator with Python, numpy and Pillow:

```sh
python Tools/world_atlas/native_overview.py \
  --base '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-v1' \
  --background '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-coarse-background-v2/background.json' \
  --atlas 'ridge v3/Resources/RidgeData.bundle/atlas.json' \
  --style 'ridge v3/World/WorldCartography.swift' \
  --archives '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1' \
  --world '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' \
  --mosaics '/Users/matthewbilella/Documents/Ridge Satellite Cache/uk-2025/mosaics/9c44e3447fb4239f' \
  --mosaics '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-standard-cache-v1/imagery/mosaics/baa59a35e63d7fa8' \
  --renderer OUTPUT/render-atlas --output NEW_ATLAS --workers 6
```

Use a fresh output revision for changed inputs or renderer. Per-section
checkpoints verify page checksums on resume. `--section z10-x500-y333` creates a
sample without publishing a country inventory. The final index is published
after the complete run. Only then stage its declared images and `index.json`
into a new bundle, validate coverage and image dimensions, and replace the app's
prior `WorldAtlas.bundle`. Keep the prior bundle recoverable until verification.

Checks: `test_native_overview.py`, `test_texture_overview.py`,
`Tools/test_world_source.sh` and `Tools/test_world_atlas.sh`.
The running app writes `WorldCache/bundled-atlas-status.json` with the manifest's
renderer, section count and pages actually loaded by the base-map view. Cached
thumbnail images are not proof of the map being displayed.
