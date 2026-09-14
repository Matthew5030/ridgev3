# Ridge

A native iPhone and iPad route planner built around fixed offline terrain tiles. Browse or search the 2D atlas, draw a rectangle, then save and open it directly in 3D. Tile boundaries remain internal storage details. A broad surround of coarser terrain carries the view toward a fading horizon. SwiftUI handles the interface; Metal renders the terrain, independent cartography, routes and map boundary. Moving the camera makes no network requests.

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

Open `ridge v3.xcodeproj` in Xcode, select the **ridge v3** scheme and an iPhone or iPad simulator, then Run. The deployment target is **iOS 18**. No package-manager setup or server is required. The existing Bilella Works bundle identifier and signing team have been retained; running on an actual phone requires access to that team's signing credentials, or selecting your own team in Xcode.

From Terminal, with Xcode installed at its usual location:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project 'ridge v3.xcodeproj' -scheme 'ridge v3' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/ridge-v3-build CODE_SIGNING_ALLOWED=NO build
```

Start with **Eryri** or search for a place. Tap **Select area**, drag a rectangle or tap two opposite corners, then adjust its corner handles or drag inside to move it. **Use centre of map**, **Smaller** and **Larger** provide alternatives to drawing. The outline aligns outward to the prepared data so the saved terrain covers the whole request. Dimensions, estimated saved size and live device admission appear in the same panel. **Save & open in 3D** shows progress there and opens the selected scene automatically; an exact saved selection offers **Open in 3D**.

The main atlas journey holds terrain at 4 m and rejects oversized selections instead of silently lowering detail. Surroundings are included when available and admitted. Current source data is bundled or imported, so the UI says no download is needed; outside complete prepared coverage it explains the limitation instead of inventing a hosted download. Saved areas are shaded on the atlas. Areas cut from a bundled source reference its signed, immutable cartography directly; imported sources retain verified copies that are shared between overlapping areas. Terrain crops and graphs remain separate. Removing one area does not remove maps used by another.

When `Documents/EryriAdaptiveTest` contains the park-wide adaptive manifest and `terrain.rmeshpack`, Explore also offers **Eryri adaptive**. It presents the whole prepared park as a lightweight coverage map and starts with one draggable 8 km planning rectangle. The displayed terrain size and chunk count come from the exact intersecting chunks. Ridge admits the selection against the device's current memory allowance, then loads that fixed set once; camera movement performs no file reads and allocates no new terrain. **Expand area** releases the current scene, grows the rectangle and returns to the same admission screen before the replacement scene is opened. The current adaptive path is a terrain and memory experiment; production cartography, routes and horizon bands remain in the regular area renderer.

In 3D, drag one finger to move across the map, two fingers to rotate and tilt, and pinch to zoom. Settings can swap the touch counts. **Expand area** opens the same full-screen atlas with the current area and route visible; saving returns to 3D with the route and geographic camera preserved. It retains the current terrain spacing. Routes support saved local copies, undo/redo, waypoint editing, reversal, elevation profiles and GPX import/export. Imported GPX tracks remain tracks rather than being silently rerouted onto OSM paths.

**Expand area** is always visible on the 3D map. Looking or tapping beyond detailed coverage reveals an explanation and opens expansion around that location; the saved landscape's outer edge has its own coverage-limit message. A subtle dashed boundary appears near the edge of detail and while planning. Map textures keep the same styling and detail across that boundary. Soft blue daylight and warmer slope lighting carry the landscape into a gentler distant haze.

Route points placed outside detailed coverage are saved immediately as manual sketches. Their overview sections are dashed; incomplete elevations are not presented as complete ascent or walking-time estimates. **Add detail along route** previews the current area plus a rectangle around the route, with a 250 m, 500 m, 1 km or 2 km margin, estimated saved size and device memory allowance. **Add detail here** previews the viewed location. Browsing and placing points never trigger a download.

**Save detail** prepares the preview from a compatible local source and restores the route, undo/redo history and geographic camera view. Existing sketch lines remain manual connections after adding elevation; they are not silently rerouted onto paths. The current loader expands rectangles rather than thin route corridors, and margins stop at available source coverage. If the source is missing, the sketch remains saved and the app explains that a compatible pack is needed.

This first extension flow uses prepared data already on the device. The source must cover the entire current area, actual route geometry and new point; the visible horizon alone does not supply a walking graph. Outside available prepared coverage, the app explains that a compatible pack is needed. It does not invent a download endpoint or a connecting path. Route-shaped corridors and a nationwide download catalogue are not part of this version.

## Included data

The app bundles approximately **1.29 GB** of prepared source data. Its main source is a **16 × 16 grid of 256 original precision cells** covering approximately 7.8 × 7.8 km across Eryri, including Yr Wyddfa, the Glyderau and Ogwen. The complete source occupies **1.25 GB** and includes genuine 1, 2, 4, 8, 16 and 32 m terrain levels, one walking graph, broad prepared surrounding terrain and an independent map covering approximately 27.4 × 27.4 km. The new map images occupy **704.1 MB** on disk. The older primary, overview and band-map assets remain in the source for compatibility; new saves copy only the admitted terrain, required independent map cells and clipped paths. Disk size is shown before saving and is separate from the bounded renderer allocation.

New Eryri saves include approximately **2 km of nearby terrain at 8 m** and a **32 m outer band targeting 15 km beyond each side of the selection, clipped to prepared coverage**. Both are cropped from real prepared terrain covering roughly 27.4 × 27.4 km and joined to the selected surface. With both bands present, the primary and nearby terrain remain haze-free; gentle haze builds over 12 km beyond the nearby band, with a separate 2 km fade at the finite outer edge. The edge fade is capped to the available margin on each side so it does not fade the primary area. Existing saves use the new atmosphere when reopened; re-select an older rectangle to prepare the broader surroundings if available. The entire view uses one independent cartographic atlas with approximately **0.48 m native map pixels**. There is no primary/near/far image-density change and no overview substitution when an area grows. Terrain admission can coarsen or omit surrounding geometry without changing the map source.

Initial map previews upload in batches of 32 through one reusable 1.125 MiB staging buffer, within the existing map working reserve. Each PNG is still checked and decoded individually.

The saved map has a fixed local texture cache: a continuous preview mosaic covers the whole scene, while up to 192 medium and 16 native image pages serve the visible map according to projected screen size. One worker reads and checks local PNGs; it makes no network request or LiDAR allocation. All image scales derive from the same pixels, with shared neighbour gutters and mip filtering. Existing saved Eryri areas use compatible current bundled cartography on reopen without rewriting their terrain or route files.

The original three prototype source regions remain bundled for saved-route compatibility and regression checks:

| Area | Coverage | Terrain resolutions |
|---|---|---|
| Yr Wyddfa | Approximately 5.9 × 5.9 km, including the Snowdon horseshoe | 4, 8, 16, 32 m |
| Ogwen Valley | Approximately 3.9 × 3.9 km, including Tryfan and the Glyderau | 4, 8, 16, 32 m |
| Summit study | Approximately 490 × 490 m at Yr Wyddfa | 1, 2, 4, 8, 16, 32 m |

These are genuine prepared Welsh Government LiDAR heightfields and source-backed OpenStreetMap features and walking graphs. Map textures use original contour cartography, not satellite imagery. Selecting coarser terrain does not reduce texture resolution. The main atlas selector uses **4 m** for lighter geometry and faster preparation; it never silently switches detail. The older import/detail sheet retains its resolution controls: its initial choice prefers 4 m, falling back to an available coarser level when necessary. Manual 1 m and 2 m remain available; the explicit Auto button recommends the finest available terrain level that fits the current device allowance. Existing saved areas reopen at their saved spacing; save the selection at 4 m to replace its terrain. The app checks available process memory, Metal graphics limits and thermal state before loading; a level can exist in a source pack while its complete footprint is too large for a device. The full Eryri source at 1 m contains 8193 × 8193 samples and must be opened as smaller selections. One fixed precision cell is only 513 × 513 samples at 1 m. Cropping never creates finer terrain absent from its source. Selecting a resolution manually keeps that choice; Auto updates when the selected area changes. Live memory pressure can reduce its recommendation, and each save/load performs a fresh check. The active terrain remains a fixed mesh with no progressive streaming.

The independent map retains **1024 × 1024 inner map pixels per geographic cell** throughout the prepared landscape. Native PNGs include four pixels of neighbouring content on each side; previews use the same source. A save copies the complete map cells covering its selected terrain and admitted horizon, with no resampling tied to terrain spacing. Old overview and band-map assets remain in the source for compatibility and 2D previews; new atlas installations omit them. Labels and route overlays remain independent of map textures.

The small vector atlas covers the world with more detailed UK/Ireland outlines. Its England/Wales availability overlay describes the external source pack's recorded coverage. **The whole UK's detailed terrain is not bundled**, and available source cells are not automatically downloadable regions. The ready-to-use fixed-cell source covers Eryri; other locations require prepared data to be imported or explicitly downloaded.

## Import or prepare another area

**My areas** offers a Files importer for prepared folders and `.ridgepack` packages, plus a direct HTTPS `pack.json` downloader. Selecting a local folder or package first opens the area preview: choose its full extent or a smaller rectangle, select the terrain resolution, review the size and then tap **Save & open in 3D**. Only that selected terrain level and the matching map/path assets are installed. Files are checked, staged and validated before replacing an installed area; a cancelled or corrupt import preserves the previous working copy.

`Tools/PreparedPacks/` contains directory copies of the three example regions. A `.ridgepack` here is a **directory package, not a ZIP**; a plain folder with the same contents also works. Copy the complete prepared directory into Files and select its folder or `.ridgepack` package through the importer. Its internal `pack.json` manifest and all declared heightfield, PNG and graph files must stay together. The Files picker does not accept `pack.json` as a standalone import. Direct downloads use a static HTTPS link to `pack.json`, with its sibling files at the declared paths. No public download endpoint or hosted catalog is configured in this project.

The complete fixed-grid source is the directory `ridge v3/Resources/RidgeData.bundle/regions/eryri-grid`. It can also be copied into Files as a prepared source folder; no second complete source copy is kept under Tools.

Tile and rectangle selection operate on local bundled or imported data. They are unavailable in a remote-manifest preview: first download that prepared area, then select a subset from its local copy. A download installs only the requested terrain level, so that saved copy cannot offer finer levels it did not download. Crops preserve sample values and map pixel detail, and retain only paths and labels inside the new boundary. A crop with no eligible walking edges opens in manual-planning mode.

Atlas browsing, cropping, terrain exploration, route calculation and local GPX handling all work offline. Network requests occur only when the user explicitly opens an HTTPS pack link and downloads its complete static files. The app neither streams terrain while moving nor asks a service to generate a region.

The preparation CLI reads the existing external precision product and old project's prepared OSM archives; it does not repeat raw LiDAR processing or modify the sources. Install its Python dependencies once:

```sh
python3 -m venv .venv
.venv/bin/pip install -r Tools/requirements.txt
```

Rebuild the main fixed-grid source, including all 256 verified 1 m precision cells:

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
