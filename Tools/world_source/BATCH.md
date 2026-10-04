# New adaptive/vector world batch

`batch_world.py` converts the **audited corrected** `uk-adaptive-0p5-v3` selection into bounded sources for the current app. It does not remake the 0.5 m terrain, alter old packs, fill missing LiDAR, or publish network URLs. Each source covers 16 × 16 native 513-sample tiles (at most 256 tiles, roughly 8 km across). Missing complete source tiles remain absent. The UK overview is generated separately and does not imply detailed LiDAR coverage.

For each source it:

- Reuses exact existing fine RAT byte ranges, verifies compressed/topology/decoded checksums and matching raw-heightfield provenance.
- Compiles 2 m maximum-error adaptive backgrounds from the retained 1 m native samples. The compiler checks the resulting surface; the lossless codec verifies its own round-trip.
- Clips the retained semantic OSM geometries into vector pages in the app's format, derives 10 m/index 50 m contours from native terrain, preserves named places and source credits.
- Converts the existing graph, retaining actual edges with endpoints on available terrain. It does not manufacture cross-source routing connections. Seamless multi-source routing is separate app work.
- Creates an 8 m sample overview for route statistics; absent overview values are zero for the current reader, but never count as available tiles.
- Independently decodes both meshes for every tile, checks geometry bounds, and enforces the app's 256 MiB background resident estimate before publication.

The 2026-10-04 pilot was `world-z10-x500-y333-c00-r00`: 256 tiles, 26,010,315 bytes including all fine/background/vector/graph assets, 21,858,340 fine triangles, 12,080 graph nodes and 49 places. Native app validation decoded every mesh, rendered every vector page, built the complete adaptive background and produced its 2048 px overhead preview. Fine geometry remains subject to the existing app working-set limit; this triangle count is not an instruction to load all fine meshes at once.

## Run and resume

Dependencies: Python 3, NumPy, Shapely 2, contourpy, clang++. The prepared environment is `/tmp/ridge-world-build-env` (temporary; recreate if removed).

```sh
/tmp/ridge-world-build-env/bin/python Tools/world_source/batch_world.py \
  --selection '/Volumes/MLB_EXT_4TB/Ridge Experiments/UK-adaptive-0p5-v3/selection' \
  --fine '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-adaptive-0p5-v3' \
  --public '/Users/matthewbilella/Desktop/ProjectFatRidge/mapping/build/public' \
  --staged-public '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' \
  --workers 2 --reserve-gib 35
```

Use `--section z10-x500-y333 --limit-sources 1` for a pilot. The output must stay on the external drive. A single-process file lock prevents overlapping jobs. Tiles have resumable validated checkpoints under `.work`; final source directories are renamed atomically and never overwritten. `catalog.json` lists only completely validated sources. `status.json` records current progress, deferred iCloud/missing input and failures. `toolchain.json` records current builder/compiler hashes. Same-output resume requires the same frozen inputs and source partition size.

`batch_run.py` is a bounded supervisor for one batch while `stage_archives.py` stages verified source archives. It reruns conversion only when the ready-archive count increases, stops when staging completes, when the free-space guard triggers, or after its time limit. It uses its own exclusive lock. `supervisor.json` records the supervising PID/state; `batch.log` holds output when launched with the example below. Neither script evicts iCloud files or starts a recurring automation.

```sh
/usr/bin/caffeinate -i /tmp/ridge-world-build-env/bin/python Tools/world_source/batch_run.py \
  --staging-status '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1/status.json' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' --hours 48 -- \
  --selection '/Volumes/MLB_EXT_4TB/Ridge Experiments/UK-adaptive-0p5-v3/selection' \
  --fine '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-adaptive-0p5-v3' \
  --public '/Users/matthewbilella/Desktop/ProjectFatRidge/mapping/build/public' \
  --staged-public '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1' \
  --workers 2 --reserve-gib 35
```

Progress files are on the output drive, so unplugging it interrupts the job. Reconnect and repeat the command to resume. A Mac restart likewise requires rerunning the command. To stop, terminate the supervisor **and the builder PID in `.batch.lock`**; completed sources remain usable. The supervisor does not automatically restart after a crash.

## Verification

```sh
/tmp/ridge-world-build-env/bin/python Tools/world_source/test_batch_world.py
sh Tools/test_world_batch.sh '/path/to/published/source'
```

The native test uses the real `WorldSourceStore`, adaptive codec, vector drawing and preview renderer. It runs against any completed source, without assuming the original Snowdon study tile IDs. Production catalog delivery, automatic selection of neighbours, source-edge routing and the remaining unavailable LiDAR coverage are separate work; the batch files alone do not turn on those capabilities.

## Exact overhead snapshots

`render_batch_preview.swift` calls the actual app background and preview renderers, including the same light, camera and vector palette. It does not decode fine geometry. `batch_previews.py` watches only fully published world sources and produces one 2048 px-high JPEG at a time, with bounds and image/source/style hashes in a separate catalog. The source directory remains immutable. It stops when world conversion stops, after the time bound, or below the disk reserve. A failed source is recorded and retried on a later invocation.

```sh
sh Tools/build_world_preview_renderer.sh /tmp/ridge-world-preview-renderer
/tmp/ridge-world-build-env/bin/python Tools/world_source/batch_previews.py \
  --world-root '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-previews-v1-2026-10-04' \
  --renderer /tmp/ridge-world-preview-renderer/render-preview --hours 48
```

Changing the renderer/style requires a new preview output directory; this prevents silently mixing palettes across a mosaic. These detailed snapshots are separate from the lower-resolution UK overview. Sources with missing terrain cells still contain uncovered cells in their snapshots; the coverage metadata must control where detailed imagery overlays the nationwide map.
