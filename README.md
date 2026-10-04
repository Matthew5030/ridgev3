# Ridge

The current adaptive/vector world flow and ordered first-release plan are in
[World app and finish plan](Tools/world_source/README.md). The UK overview is now
textured; national detailed-source preparation and multi-region app integration
are separate milestones. The sections below describe the earlier fixed-area flow
and its compatibility features.

A native iPhone and iPad route planner built around fixed offline terrain tiles. Browse or search the 2D atlas, select a visible block of tiles, then save and open it directly in 3D. A broad surround of coarser terrain carries the view toward a fading horizon. SwiftUI handles the interface; Metal renders the terrain, independent cartography, routes and map boundary. Moving the camera makes no network requests.

## Run

The bundled offline maps and heightfields use Git LFS (about 1.2 GB). Install Git LFS before cloning, then fetch the assets:

```sh
brew install git-lfs
git lfs install
git clone https://github.com/Matthew5030/ridgev3.git
cd ridgev3
git lfs pull
```

If you already cloned the repository, run `git lfs install` and `git lfs pull` inside it before building. GitHub's source ZIP does not reliably include the full LFS assets; use a Git clone.

Open `ridge v3.xcodeproj` in Xcode, select the **ridge v3** scheme and an iPhone or iPad simulator, then Run. The deployment target is **iOS 18**. No package-manager setup is required. New adaptive downloads require the local download server; saved areas work offline. The existing Bilella Works bundle identifier and signing team have been retained; running on an actual phone requires access to that team's signing credentials, or selecting your own team in Xcode.

From Terminal, with Xcode installed at its usual location:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project 'ridge v3.xcodeproj' -scheme 'ridge v3' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ridge-v3-build CODE_SIGNING_ALLOWED=NO build
```

Start with **Eryri** or search for a place. The atlas shows the prepared tile grid when zoomed in. Tap **Select area**, then tap one tile or drag across a block. Handles resize in whole tiles; moving the block preserves its row and column count and stops at prepared edges. The panel shows the selected tile count. **Draw new** clears the block, **Select centre tile** starts with one tile, and **Smaller/Larger** change its size. Search moves the selection to the chosen place. One finger pans in browse mode; two fingers pan and pinch zoom works in either mode. During selection, **Move map** also enables one-finger pan without editing the block. **Save & open in 3D** opens the selected scene automatically; an exact saved selection offers **Open in 3D**.

The normal atlas now downloads precomputed adaptive terrain, fitted to within 0.5 m of the prepared source surface. This is a mesh approximation tolerance, not survey accuracy. There is no 1/2/4/8 m choice for new areas. Selection follows the native adaptive cells; the app admits a fixed scene using actual vertex/triangle counts, map working memory, routing and surroundings. Moving the camera never downloads or rebuilds terrain.

Connect through **Settings → Download server** and refresh coverage. The lightweight catalogue loads first; the verified chunk index is fetched when selecting a source. Saving downloads only missing, checksummed mesh ranges, maps, paths and coarse context strips. The normal renderer draws those exact triangles and uses them for route heights and picking. Legacy saved areas and imports remain readable, but old regular-grid sources are excluded from new atlas selections.

The currently published complete source is **Eryri**: 16,413 native chunks across a continuous 111 × 171 selection grid, with missing coverage left unavailable. The rest of the UK has prepared adaptive geometry, but still needs matching cartography and walking graphs published before it becomes a complete app download. See [local download setup](Tools/download-server/README.md).

In 3D, drag one finger to move across the map, two fingers to rotate and tilt, and pinch to zoom. Settings can swap the touch counts. **Expand area** opens the same full-screen atlas with the current area and route visible; saving returns to 3D with the route and geographic camera preserved. Adaptive expansion keeps the same mesh tolerance. Routes support saved local copies, undo/redo, waypoint editing, reversal, elevation profiles and GPX import/export. Imported GPX tracks remain tracks rather than being silently rerouted onto OSM paths.

**Expand area** is always visible on the 3D map. Looking or tapping beyond detailed coverage reveals an explanation and opens expansion around that location; the saved landscape's outer edge has its own coverage-limit message. A subtle dashed boundary appears near the edge of detail and while planning. Map textures keep the same styling and detail across that boundary. Soft blue daylight and warmer slope lighting carry the landscape into a gentler distant haze.

In **Follow paths** mode, a point outside detailed coverage opens the area-expansion preview without changing the route. **Direct line** explicitly allows manual sketches outside coverage. Their overview sections are dashed; incomplete elevations are not presented as complete ascent or walking-time estimates. **Add detail along route** previews the current area plus a rectangle around the route, with a 250 m, 500 m, 1 km or 2 km margin, estimated saved size and device memory allowance. **Add detail here** previews the viewed location. Browsing and placing points never trigger a download.

**Save detail** prepares the preview from a compatible local source and restores the route, undo/redo history and geographic camera view. Existing sketch lines remain manual connections after adding elevation; they are not silently rerouted onto paths. The current loader expands rectangles rather than thin route corridors, and margins stop at available source coverage. If the source is missing, the sketch remains saved and the app explains that a compatible pack is needed.

The extension flow uses local source data or explicitly downloads missing files from the configured source server. The source must cover the entire current area, actual route geometry and new point; the visible horizon alone does not supply a walking graph. Outside available prepared coverage, the app explains that a compatible pack is needed. It does not fetch data while browsing or invent a connecting path. Route-shaped corridors and a nationwide download catalogue are not part of this version.

## Included data

New adaptive Eryri scenes reuse the existing independent map images and walking graphs. Map fidelity does not depend on triangle density. Each scene includes cropped 8 m nearby terrain (about 3 km beyond the selected area) and 32 m distant terrain, bounded by a map window of up to 60 × 60 cells, roughly 30 km across, and available source coverage. The server sends verified row strips of these coarse surfaces rather than their complete park-wide files.

The renderer keeps a fixed local texture cache: a continuous preview mosaic covers the scene, with up to 192 medium and 16 native pages selected by projected screen size. All scales derive from the same cartographic source with shared neighbour gutters and mip filtering. This only reads saved images and makes no network requests.

Older bundled Eryri heightfields and the three prototype sources remain compatibility fixtures for existing saved areas and regression checks. They are no longer choices for new atlas downloads. Source LiDAR and map masters are preserved. Retired server packs are outside the served directory in `Ridge Rollback/2026-09-16` on the source drive.

## Import or prepare another area

**My areas** offers a Files importer for prepared folders and `.ridgepack` packages, plus a direct HTTPS `pack.json` downloader. Selecting a local folder or package first opens the area preview: choose its full extent or a smaller rectangle, select the terrain resolution, review the size and then tap **Save & open in 3D**. Only that selected terrain level and the matching map/path assets are installed. Files are checked, staged and validated before replacing an installed area; a cancelled or corrupt import preserves the previous working copy.

`Tools/PreparedPacks/` contains directory copies of the three example regions. A `.ridgepack` here is a **directory package, not a ZIP**; a plain folder with the same contents also works. Copy the complete prepared directory into Files and select its folder or `.ridgepack` package through the importer. Its internal `pack.json` manifest and all declared heightfield, PNG and graph files must stay together. The Files picker does not accept `pack.json` as a standalone import. Direct downloads use a static HTTPS link to `pack.json`, with its sibling files at the declared paths. No public download endpoint or hosted catalog is configured in this project.

The complete fixed-grid source is the directory `ridge v3/Resources/RidgeData.bundle/regions/eryri-grid`. It can also be copied into Files as a prepared source folder; no second complete source copy is kept under Tools.

Tile and rectangle selection work with bundled, imported and locally cached server source indexes. For legacy single-pack HTTPS links, selection is unavailable in the remote-manifest preview: download that prepared area first, then select a subset from its local copy. A download installs only the requested terrain level, so that saved copy cannot offer finer levels it did not download. Crops preserve sample values and map pixel detail, and retain only paths and labels inside the new boundary. A crop with no eligible walking edges opens in manual-planning mode.

Atlas browsing, cropping, terrain exploration, route calculation and local GPX handling all work offline. Network requests occur only when the user connects a source server, confirms an area download/expansion, or downloads a legacy HTTPS pack link. The app neither streams terrain while moving nor asks a service to generate a region.

The preparation CLI reads the existing external precision product and old project's prepared OSM archives; it does not repeat raw LiDAR processing or modify the sources. Install its Python dependencies once:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Tools/requirements.txt
```

For legacy compatibility fixtures only, rebuild the fixed-grid source with all 256 precision cells (new adaptive publication uses `Tools/adaptive_terrain/publish_eryri_app.py`):

```sh
.venv/bin/python Tools/prepare_grid.py
```

To refresh fine map images without regenerating any heightfields or overview images:

```sh
.venv/bin/python Tools/prepare_grid.py --detail-only
```

This joins original world tile `z10-x500-y333`, parents `c04..07` and rows `00..03`, into a shared source without changing cell boundaries. All source checksums, 480 adjoining child seams and exact coarser decimations are checked. Other complete source rectangles can be specified with `--tile`, `--parent`, `--shape`, `--id` and `--name`; a maximum of 4 × 4 parents keeps the desktop preparation bounded.

After rebuilding Eryri, add its wider surroundings from the existing prepared 8 m product:

```sh
.venv/bin/python Tools/prepare_horizon.py
```

This separate preparation supports the cross-world-tile context mosaic. It preserves the selected area's terrain and maps. Exact source coverage, resampling and checks are recorded in [HORIZON_PROVENANCE.md](HORIZON_PROVENANCE.md).

The older preparation command can also create a finite rectangle from matching, already-prepared source data:

```sh
.venv/bin/python Tools/prepare_packs.py \
  --id my-area --name 'My area' \
  --tile 500 333 --parent 4 1 --shape 3 3 \
  --output Tools/PreparedPacks/my-area.ridgepack
```

`--shape` is columns then rows within that tile's 12 × 12 parent grid. Complete source coverage and a matching OSM tile are required. Rectangles are limited to 4 × 4 parents per invocation; cross-tile mosaics are not yet supported. Use `--shape 1 1 --child 3 3` to prepare one genuine 1 m precision child. `--old` and `--precision` override the original-project and external-product roots. Full schema, source conventions and commands are in [PACK_FORMAT.md](PACK_FORMAT.md).

## Development performance

Debug builds use Swift `-O` while retaining debug symbols, because preparing millions of height samples without optimization materially slows opening a scene. Optimized code can limit local-variable inspection and Xcode canvas previews; temporarily select `-Onone` for those debugging tasks. Release optimization is unchanged.

`sh Tools/profile_scene_load.sh` reports 4 m capacity for injected hardware profiles. Optionally pass a saved `Areas` directory and area ID to measure read-only pack loading and map setup on the Mac. These measurements exclude primary terrain mesh construction and are not iPad timings.

`sh Tools/profile_selection.sh 'ridge v3/Resources/RidgeData.bundle'` times the real preview, crop, installation and reopen path for representative Eryri rectangles. It verifies the fixed cost of the full cartographic horizon separately from the selected terrain size. Bundled selections borrow their immutable map files and validate the atlas metadata once; local imports retain per-file integrity checks.

## Checks and release readiness

```sh
sh Tools/test_budget.sh
sh Tools/test_packs.sh
sh Tools/test_routes.sh
sh Tools/test_crops.sh
sh Tools/test_horizon.sh
sh Tools/test_extensions.sh
sh Tools/test_extension_flow.sh
sh Tools/test_navigation.sh
sh Tools/test_cartography.sh
sh Tools/test_cartography_allocation.sh
sh Tools/test_cartography_packs.sh
sh Tools/test_cartography_medium.sh
sh Tools/test_cartography_renderer.sh
sh Tools/test_atlas_real.sh
.venv/bin/python Tools/prepare_packs.py --verify 'ridge v3/Resources/RidgeData.bundle/regions/eryri-grid'
xcrun swift Tools/render_icon.swift
```

The budget suite injects device capacity, available process memory, graphics limits and thermal state to test deterministic resolution recommendations. The pack suite exercises actual bundled data: install/load, resolution replacement, cancellation, hash corruption, path traversal and escaping symlinks, malformed images and graphs, incomplete terrain and preservation of a previous valid area. The route suite covers routing, GPX handling and local persistence. The crop suite verifies exact source-height windows, map pixels and north orientation, graph clipping, geographic elevation alignment, fractional texture coverage, budget checks and installation of a real selected area. The app icon is reproducible native vector artwork.

Observed build and simulator results are recorded in [VALIDATION.md](VALIDATION.md).

The horizon suite checks real cropped context rows, unchanged primary geometry and bounds, combined memory accounting, atomic installation, hashes and invalid context rejection.

Simulator and command-line checks do not establish physical-device performance. Before release, measure peak memory, sustained frame rate, camera responsiveness, thermal behavior and repeated area replacement on the oldest supported iPhone; test Files access, GPX sharing, interrupted downloads and device signing there as well. The memory estimates are safeguards, not measured hardware guarantees.

Ridge currently focuses on offline exploration and route planning. It does not provide turn-by-turn guidance, background track recording or an automatically populated national download service. OSM path data does not certify access, mountain difficulty or safety; access classifications remain attached to the source graph. Terrain and OSM attributions are retained in every area manifest.

The wider Eryri normal-flow source is served separately from the application bundle. See [download-server setup](Tools/download-server/README.md) and its [validation record](Tools/download-server/VALIDATION.md).
