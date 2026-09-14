# Ridge offline area format

Ridge opens one finite planning area at one fixed terrain spacing, with optional coarser surrounding terrain saved alongside it. No camera movement downloads data, creates a higher-resolution mesh, or expands the active scene's bounds.

The Xcode target bundles `ridge v3/Resources/RidgeData.bundle`. It contains:

```text
catalog.json                 Array of RegionManifest objects
atlas.json                   World/UK selector vector geometry and source coverage
regions/<area-id>/pack.json  One RegionManifest
regions/<area-id>/terrain-8m.bin
regions/<area-id>/map-0-0.png
regions/<area-id>/graph.json
```

A standalone area is the same region directory, conventionally named `<area-id>.ridgepack`. It is a **directory package, not a ZIP archive**. The app's Files importer stages and validates it before activating it. Ready-to-import copies of all three included regions are under `Tools/PreparedPacks/`.

An explicitly entered HTTPS URL can point to the same `pack.json`, with all declared assets alongside it. That action downloads static files and installs one requested terrain level. No public pack host is configured. The app has no live map, routing or terrain-generation service; camera movement and route planning remain entirely local.

## Coordinate and height conventions

All geographic bounds and points are WGS84 decimal degrees. Bounds use `minLatitude`, `minLongitude`, `maxLatitude`, `maxLongitude`. Graph and place coordinates use explicit `latitude` and `longitude` fields. Atlas rings use `[longitude, latitude]`.

Each terrain file is exactly `width × height × 2` bytes of signed Int16, little endian, row major. Row zero is north; column zero is west. Both exterior rows and columns are included. Heights in metres equal `sample × heightScale`; current packs use `heightScale: 0.1`. The value `-32768` is missing data, not an elevation. Do not interpolate through it or substitute zero.

The source product records EGM96 / EPSG:5773 output elevations, converted from the Welsh LiDAR's ODN / EPSG:5701 source. The pack retains this evidence in `verticalDatum`; preparation here does not repeat or independently recalibrate that conversion. The renderer uses physical horizontal and vertical metres without an elevation exaggeration.

The labels 1/2/4/8/16/32 m describe **nominal sample spacing**, not survey accuracy. The source grid is geographic, so actual horizontal spacing varies with latitude. Exact measured east/west and north/south spacing for every generated level is retained in `Tools/reports/<id>-source.json`. Here nominal 1 m is approximately 0.957 m.

## Manifest

The authoritative Codable definitions are in `ridge v3/Core/Models.swift`.

`pack.json` is a `RegionManifest` with `schemaVersion: 1`:

- Identity: `id`, `name`, `subtitle`, `summary`, `version`.
- Terrain: `bounds`, `sourceResolution`, `heightScale`, `noDataValue`, `verticalDatum`, `defaultSpacing`.
- `levels`: each has `spacing`, `width`, `height`, `file`, `byteCount`, `sha256`.
- `textures`: each has `file`, `width`, `height`, `bounds`, `byteCount`, `sha256`.
- Optional `detailTextures`: a second, independently complete source map set with the same texture record fields, used for small selections.
- Optional walking data: `graphFile`, `graphSHA256`, `graphByteCount`.
- Optional original-grid identity: `grid` with `gridID`, `worldTileID`, `originColumn`, `originRow`, `columns`, `rows`.
- Optional surrounding terrain: `horizon`, containing optional `near` and `far` backdrop records. Each backdrop has its own `bounds`, `levels` and `textures`, using the same terrain and texture record fields above.
- Optional independent map: `cartography`, defined by `Core/CartographyAtlas.swift` and described below. It replaces primary and surrounding texture layers in 3D.
- `places`: source-backed names with `id`, `name`, `coordinate`, `kind`, optional `elevation`.
- `sources`: each has `name`, `attribution`, `license`, `url`.

File hashes are lowercase SHA-256 over exact file bytes. Resource names are relative to the region directory. File sizes describe encoded disk bytes, not decoded memory. The manifest is not self-hashed.

Textures point north at their top edge and cover exactly their declared geographic bounds. Broad-area cartography is 4096 × 4096 pixels split into four 2048 × 2048 PNGs; the summit uses one 2048 × 2048 PNG. Cartography is independent of terrain sample count. The app can filter and mipmap it without loading denser terrain. These are finite-resolution images: unlimited close zoom cannot reveal absent detail. Labels and route lines are drawn independently in the app.

The Eryri source additionally supplies sixteen **4096 × 4096** detail PNGs, one for each original approximately 2 km parent. Every parent contains 4 × 4 precision cells, so a single precision cell has **1024 × 1024 source map pixels**, approximately 0.48 m per cartographic pixel. This is a separately rendered fine map, not an enlargement of the overview. It uses existing OSM semantic features and native 4 m LiDAR anchors for contours and hillshade; no raw LiDAR is reprocessed.

For legacy packs without `cartography`, `detailTextures` cover the complete source without overlap, independently of `textures`. These are alternatives; the legacy cropper uses fine maps for a small selection and overview maps for a larger one. This compatibility path is not used by current Eryri 3D scenes. The older source assets remain available for 2D previews and third-party legacy imports.

## Independent cartography

`cartography` contains `columns`, `rows`, ascending `longitudeEdges`, descending `latitudeEdges`, and row-major `tiles`. Each tile contains `image` and `preview` records with the same fields as `MapTexture`. The grid may contain at most 64 columns and 64 rows, for 4096 cells. Every record's `bounds` is exactly its inner geographic cell; image dimensions also include neighbour gutters. Native images are 1032² pixels: 1024² inner pixels plus four gutter pixels on each side. Previews are 72²: 64² inner pixels plus four gutter pixels. Geographic edges retain the prepared source's nonuniform latitude spacing. All assets have distinct safe flat filenames, exact byte sizes and SHA-256 hashes. Region manifests are capped at 16 MB.

Eryri provides 56 × 56 cells across the complete 27.4 km context, all at approximately 0.48 m per native map pixel. Existing primary detail masters are reused; surrounding masters use the same cartographic renderer. Every preview is filtered from the canonical source and every gutter includes actual neighbouring pixels. Native and preview files are independent of LiDAR spacing, selected-area size and primary/near/far terrain boundaries.

A saved area retains the minimal whole-cell rectangle covering its admitted terrain and horizon. Images are copied without resampling; `textures`, `detailTextures` and backdrop `textures` are omitted or emptied in an atlas installation. Before activation, every atlas file is hashed and decoded individually under a bounded autorelease pool. On opening, previews are verified immediately; native pages are checked when the local worker reads them. An older saved area with matching original-grid identity can use a compatible bundled atlas on reopen without rewriting its saved manifest, heights or route association.

The 64² preview cores form one continuous GPU mosaic, at most 4096² pixels, with mipmaps generated after assembly. Initial preview uploads use batches of 32 and a single reusable 1.125 MiB buffer inside the existing decode/upload reserve; integrity checks and individual PNG decoding remain in place. Screen-space demand chooses pages in fixed medium and native arrays: at most 192 medium images (264², with a 256² core and four-pixel gutter assembled from canonical neighbouring cells) and 16 native images (1032²). Only one decode/upload job runs at once; neighbour images are decoded sequentially into a bounded canvas and reduced on a fixed 4 × 4 grid in linear sRGB. Geographic sampling, explicit texture gradients, neighbour gutters and mip filtering are shared over every terrain band. Page transitions do not create terrain meshes, add routing coverage or access the network. Atlas memory is budgeted independently from height spacing, including device texture-allocation sizes, one worker's staging and page tables, with a 384 MiB absolute ceiling for map resources.

## Fixed surrounding terrain

`horizon` is optional and older packs retain their finite relief presentation. Backdrops inherit the primary `heightScale`, `noDataValue` and vertical datum. Their bounds must contain the primary area; when both exist, the far backdrop must contain the near backdrop. Each source backdrop may offer alternative levels, but an installed backdrop contains only its chosen level and maps. All context paths, dimensions, hashes, coverage and decoded-memory limits are validated alongside the primary assets.

Eryri supplies 8 m and 16 m near alternatives and a 32 m far surface over approximately 27.4 × 27.4 km. Saving an area crops the near source to approximately 2 km beyond the selection and the far source to approximately 10 km, clipping to available coverage and snapping outward to exact common source anchors. Each backdrop supports up to 256 complete, non-overlapping map tiles of at most 4096 pixels per axis. Eryri provides 196 original-parent tiles per band: near maps at 1024² and far maps at 512², derived from the same cartographic masters. They retain the primary map's palette, contours, paths, roads, buildings and land cover. Map pixel density depends on the prepared map source, independently of chosen LiDAR spacing; native cropped map pixels are not reduced by a near/far terrain cap. Cropping processes one map image at a time. Cropping streams exact prepared terrain rows and preserves their heights; the desktop context mosaic itself resamples existing prepared 8 m data onto a shared geographic grid, as documented in [HORIZON_PROVENANCE.md](HORIZON_PROVENANCE.md).

The scene is admitted as one combined allocation. Preference is near 8 m plus far 32 m, then near 16 m plus far 32 m, then far only, then near only if that fits, then primary only. Primary spacing never changes as a side effect of this context fallback. Auto can separately choose a coarser primary level when the primary area itself does not fit. The renderer creates compact rings outside the inner bounds, with stitched collars matching the finer boundary positions and heights. It retains the decoded context height arrays for construction and visibility checks, and budgets them in full. Actual ring geometry is checked again before GPU allocation.

Context is not implicit routing coverage: committed route graphs and route editing remain within the primary bounds. Camera navigation and exact surface picking extend over loaded context, with a pending pin offering an explicit area extension. A subtle boundary marks the planning area; its slab walls are hidden when context exists. All terrain uses the same texture material and lighting. Haze and the real coverage-edge fade vary continuously with geographic position, without a colour wash at a terrain-resolution boundary. Legacy packs split geometry at their map-image boundaries. Independent cartography uses one geographic atlas over every terrain band. There is no invented terrain continuation or camera-triggered LiDAR loading or refinement.

## Walking graph

`graph.json` is a `WalkingGraph`:

```json
{
  "nodes": [{"id": 1, "coordinate": {"latitude": 53.07, "longitude": -4.07}, "elevation": 900.0}],
  "edges": [{"from": 1, "to": 2, "distance": 20.0, "bidirectional": true, "access": "public", "kind": "footpath"}]
}
```

The example illustrates shape only; every real edge must reference two real nodes. Preparation retains existing source-backed OSM edges only when both endpoints are inside the area. It invents no boundary connector and does not connect disconnected components. Original access and path classifications are preserved. Private and prohibited edges remain classified and must be excluded by routing. An unknown-access edge is not evidence of a public right of way. Straight off-path planning and source-backed path following are distinct app modes.

Graph elevations are resampled from the prepared LiDAR surface, rather than retaining the older broad-area DEM's height values. Distances and directionality come from the existing OSM graph. Source arrays contain 20 m-scale path subdivisions; imported GPX and manually drawn routes can have other point spacing.

## Original fixed tiles and in-app selections

The main `eryri-grid` source uses the original precision-cell hierarchy:

1. A global `ridge-web-mercator-z10-v1` world tile is addressed as `z10-xX-yY` on the original z10 grid.
2. It contains 12 × 12 parents addressed locally as `cXX-YY`.
3. Each parent contains 4 × 4 precision cells addressed locally as `pXX-YY`. There are therefore 48 × 48 fixed precision cells per world tile.

A globally unique precision-cell identity combines all three components, for example `z10-x500-y333-c04-00-p00-00`. Precision column equals `parentX × 4 + childX`; row equals `parentY × 4 + childY`, counting southward from the world tile's north edge. These boundaries come from the external processed product; they are not new arbitrary named areas.

The Eryri source records:

```json
{"gridID":"ridge-web-mercator-z10-v1","worldTileID":"z10-x500-y333","originColumn":16,"originRow":0,"columns":16,"rows":16}
```

Its bounds are longitude `[-4.1015625, -3.984375]`, latitude `[53.04990420466113, 53.120405283106564]`. One cell is approximately 490 m across and has exact nested grids of 513² / 257² / 129² / 65² / 33² / 17² samples at nominal 1 / 2 / 4 / 8 / 16 / 32 m spacing. The 1 m bytes are genuine processed LiDAR. The full source is 8193² at 1 m: an array from which bounded selected windows are read, not a mesh loaded wholesale at 1 m.

`Core/AreaCropper.swift` prepares a subset of a local region. `AreaSelection` uses normalized `minU`, `minV`, `maxU`, `maxV`, with `(0, 0)` at the northwest corner and `(1, 1)` southeast. The UI draws a rectangle on the local 2D map, previews its area and estimated size, and then saves the chosen resolution as a new 3D area. Whole-area selection leaves the source footprint intact.

Selections from sources with grid metadata use whole original precision cells. Legacy sources without grid metadata can be cropped to smaller rectangles: those bounds snap outward to shared native 32 m grid anchors where the source dimensions permit, or other exact common anchors for compatible imported grids. All included LODs must agree at those anchors; incompatible grids fail rather than being interpolated. Invalid, inverted or very small rectangles are rejected. The preview and prepared pack use identical snapped geographic bounds.

Preparation streams exact row windows from the selected Int16 file after verifying its source hash. It never interpolates terrain or reads raw LiDAR. Only the requested level is written, and no new finer resolution is invented. A central-quarter Snowdon crop is 769 × 769 samples at native 4 m spacing; the complete source is 1537 × 1537. Whether either is offered depends on the current device allowance rather than a universal sample count.

For legacy packs without an independent atlas, each source map image is intersected with the new bounds and processed separately. Integral crops preserve source pixels; fractional intersections are drawn into an image at least as dense as the source, with bounds matching the exact geographic intersection. Final texture rectangles fully cover the selected area without interior overlap. Places are pruned to the bounds. Graph edges survive only when both original endpoints remain inside; unused nodes are removed. If no eligible walking edge remains, `graphFile`, `graphSHA256` and `graphByteCount` are omitted so the saved selection advertises manual planning.

A grid selection keeps a deterministic original-grid identity. A single cell uses the combined `worldTileID-cXX-YY-pXX-YY` identifier; a rectangle uses `worldTileID-rCC-RR-WWxHH`, recording its precision-column/row origin and dimensions. Its `grid` metadata is reduced to those selected cells, so later selections preserve the original boundaries. Legacy crops without grid metadata receive a source-prefixed UUID and a name ending in `· selected area`. Source attributions and the vertical datum are retained. Every generated file has a fresh exact byte count and SHA-256. The preview's encoded map/graph sizes are estimates; final installed metadata uses measured values. Memory is checked before preparation and again against the result. A temporary directory is removed after production `PackStore` installation, or when preparation fails or is cancelled.

Cropping works on bundled, imported or already downloaded local data. A remote-manifest preview offers its complete prepared footprint; it cannot remotely generate a subset. A local copy contains only terrain levels actually installed. To obtain a finer level absent from that copy, use a source pack that contains it.

## Extending a planning area

`Core/AreaExtension.swift` computes a proposal from one compatible local source. Required coverage includes all corners of the existing area, every route segment point and waypoint, and the pending destination. Original-grid selections snap to full cells and add a one-cell halo around the destination only, clipped to source coverage. Compatible legacy sources use a bounded rectangle. Horizon bounds and remote URLs cannot qualify as planning sources. Source preference keeps the original grid, independent cartography, finest source spacing, full detail-map source and available LOD alternatives before considering an equally capable installed crop, avoiding map or detail regressions from an older saved subset.

The proposal retains raw crop metadata so each detail choice uses the same current memory snapshot without repeated source validation. The user reviews the total estimated saved size and selected spacing; any change applies to the complete new planning rectangle and is shown explicitly. No prefetching happens on camera movement or an outside tap. The current catalogue has no static per-tile download endpoint, so unavailable coverage is explained rather than silently downloaded.

On confirmation, `AppStore` keeps only route/history, metadata and a geographic camera pose, retires the old Metal view, waits for its release acknowledgement, then prepares and installs one replacement. The camera stores a geographic target, absolute target elevation, yaw, pitch and distance in metres so a changed mesh origin and scale do not reset the viewpoint. Route association and undo/redo entries move to the new area without changing existing geometry. An editing destination is routed only after loading succeeds; a missing/disconnected path leaves the saved route unchanged. Cancellation and preparation failure reopen the unchanged previous installation on a recovery task and retain the proposal. The original saved area is kept.

Pending pins and proposed tile outlines sample the actual rendered surface, depth-test against it and break around NoData. Exact ray traversal chooses the nearest primary or context triangle, preserving terrain occlusion. The outline does not add route coverage or fabricate a path. Route-shaped corridors remain a separate future composition feature.

## Included areas and measured sizes

The primary original-grid source is:

| Source | Original cells | Full-source terrain grids | Pack bytes |
|---|---:|---|---:|
| Eryri | 16 × 16 = 256 | 8193² (1 m), 4097² (2 m), 2049² (4 m), 1025² (8 m), 513² (16 m), 257² (32 m), plus context | 545,235,539 |

Terrain files occupy 178,977,804 bytes; the four shared 2048² overview textures occupy 13,573,192 bytes; sixteen optional 4096² detail textures occupy 96,204,780 bytes; the shared graph is 3,136,977 bytes with 16,290 nodes and 16,456 edges. Sharing cartography and graph data across the grid avoids embedding a copy in every bundled cell. Individual installations contain their selected terrain window, one chosen set of cropped cartography and the clipped graph. All 256 source children and 480 complete internal seams were verified, and the joined heightfield has no missing samples.

Context adds 33,743,366 bytes of terrain (3585² at 8 m, 1793² at 16 m and 897² at 32 m) and 219,466,061 bytes of maps. Its 196 prepared parents span six world tiles; 364 adjoining parent seams and complete valid coverage were checked. The old context maps remain compatibility assets. The independent atlas adds 704,072,627 bytes of imagery; with updated metadata, the complete data bundle occupies 1,288,770,796 bytes. Disk figures include source alternatives; a saved scene contains only chosen cropped terrain, the covering independent map cells and clipped paths.

The following original prototype sources remain for saved-route compatibility and regression checks:

| Area | Terrain grids (nominal spacing) | Walking nodes / edges | Pack bytes |
|---|---|---:|---:|
| Yr Wyddfa / Snowdon horseshoe | 1537² (4 m), 769² (8 m), 385² (16 m), 193² (32 m) | 9,565 / 9,636 | 19,736,956 |
| Ogwen Valley | 1025² (4 m), 513² (8 m), 257² (16 m), 129² (32 m) | 4,924 / 4,980 | 12,641,951 |
| Summit study | 513² (1 m), 257² (2 m), 129² (4 m), 65² (8 m), 33² (16 m), 17² (32 m) | 173 / 176 | 2,642,098 |

These tables describe complete bundled sources, including all supplied LODs. An installed subset is smaller because it contains only its chosen level. The two older large prototype sources omit 1 and 2 m; the new Eryri grid includes both across all 256 cells. A device can reject any selection whose decoded memory or vertex count exceeds the configured limit. Those limits still require physical-device validation. Merely existing on disk is not permission to load an oversized scene. Every bundled source has complete terrain within its bounds; national source coverage remains partial.

The atlas is 478,920 bytes and contains coarse world polygons, detailed UK/Ireland polygons, locator labels and 424 external source-availability cells: 224 available, 176 partial and 24 unavailable. These are recorded England/Wales source-product classifications, not a claim of complete UK LiDAR coverage. **Source availability is not an installed-area or download guarantee.** Only bundled, imported or explicitly downloaded regions and their locally prepared subsets can be opened. The selector contains neither detailed worldwide roads nor worldwide terrain. The external data drive is a preparation input; the installed app does not read or depend on it.

## Preparation

`Tools/prepare_grid.py` builds the primary fixed-cell source using the original precision children. It checks that every child exists before creating output, verifies its 1 m source checksum, compares every shared boundary row and column, joins samples once at each edge and derives 2–32 m levels by exact nested decimation. It reuses the old OSM semantic map and graph and renders one shared cartographic surface. Terrain hillshade and contours use exact 4 m anchors to avoid expanding the full 1 m source into large temporary float arrays. Graph heights retain the 1 m terrain values.

```sh
python3 Tools/prepare_grid.py
```

Add or refresh only the high-detail cartography in an existing grid source, preserving all terrain and overview bytes:

```sh
python3 Tools/prepare_grid.py --detail-only
```

This verifies the existing prepared 4 m heightfield and source OSM archive, renders each original parent separately, stages all new PNGs and then publishes their optional manifest metadata. `Tools/reports/eryri-grid-detail-source.json` records the input evidence and every detail-image hash. A full grid rebuild includes these detail maps automatically.

The default is original tile `500 333`, parent origin `4 0`, shape `4 4`. `--precision`, `--old`, `--tile`, `--parent`, `--shape`, `--id` and `--name` make the build reproducible for another complete existing source rectangle. No raw LiDAR is read and no source files are changed. `Tools/reports/eryri-grid-source.json` retains every original precision-cell ID, coordinate bounds, file path, byte count and SHA-256. The catalog gains the grid entry while older entries are preserved.

`Tools/prepare_packs.py` requires Python 3, NumPy and Pillow. It reads the existing external precision product and the old project's prepared OSM `.ridgetile` archives without modifying either. It checks source hashes, joins complete parent grids with seam checks, derives 32 m by exact decimation, selects OSM features and walking edges, renders cartography and writes manifests and provenance. It does not reopen raw LiDAR, regenerate an OSM extract, or start a server.

Rebuild the older prototype regions and atlas, then restore the primary fixed-grid catalog entry:

```sh
python3 Tools/prepare_packs.py --starters
python3 Tools/prepare_grid.py
```

After rebuilding the primary Eryri source, restore its wider context mosaic:

```sh
python3 Tools/prepare_horizon.py
```

This verifies 196 existing 8 m parent files across six world tiles and matching OSM archives, stages the mosaic and publishes optional horizon assets without changing primary terrain, maps or graph. See `HORIZON_PROVENANCE.md` for exact inputs and resampling checks.

To refresh just the surrounding cartography in an existing horizon source, use `python3 Tools/prepare_horizon.py --maps-only`. It verifies and reuses the existing context heightfields. Masters share the primary detail renderer; overlapping original parents reuse existing primary detail pixels. Every far tile is a filtered reduction of its corresponding near tile, retaining geographic line placement and styling. Source maps are prepared one parent at a time.

Prepare a custom finite rectangle within any prepared z10 tile:

```sh
python3 Tools/prepare_packs.py \
  --id my-snowdon-area --name 'My Snowdon area' \
  --tile 500 333 --parent 4 1 --shape 3 3 \
  --output Tools/PreparedPacks/my-snowdon-area.ridgepack
```

Prepare one genuine precision child, including 1 and 2 m levels:

```sh
python3 Tools/prepare_packs.py \
  --id summit-detail --name 'Summit detail' \
  --tile 500 333 --parent 4 2 --shape 1 1 --child 3 3 \
  --output Tools/PreparedPacks/summit-detail.ridgepack
```

Parent indices are 0–11 within a z10 tile; precision-child indices are 0–3 within a parent. `--shape` is columns then rows. Rectangles are limited to 4 × 4 parents per invocation to bound preparation memory. Cross-world-tile mosaics are not yet supported. Incomplete parents fail explicitly. A valid old OSM tile must exist for the same area. `--precision` and `--old` override the default read-only source roots. Re-running replaces only the selected output area after successful staging.

Verify a prepared directory:

```sh
python3 Tools/prepare_packs.py --verify Tools/PreparedPacks/summit-detail.ridgepack
```

Run native integration checks against the bundled assets:

```sh
sh Tools/test_packs.sh
sh Tools/test_routes.sh
sh Tools/test_crops.sh
sh Tools/test_horizon.sh
```

Reports in `Tools/reports/` retain the exact source paths, byte sizes, SHA-256 hashes, actual sample spacing, height ranges, source feature counts and graph counts. Preview JPEGs are review artifacts and are not used in the terrain renderer.

On the first atlas build, the script fetches Natural Earth's public-domain country GeoJSON from the author's `natural-earth-vector` repository. Exact downloaded bytes and hashes are retained in `Tools/source-cache/` and `Tools/reports/atlas-source.json`; subsequent builds reuse those bytes. This is a development-time source acquisition, not a runtime service. The app has no dependency on those URLs. Natural Earth credits and terms: https://www.naturalearthdata.com/about/terms-of-use/.

The cartography uses OpenStreetMap © contributors, Open Database License 1.0. Terrain uses Welsh Government 1 m LiDAR DTM, Open Government Licence 3.0. Attribution is carried in every region manifest. Styling is original Ridge cartography, not an Ordnance Survey map or rights-of-way certification.

## Device allowance and automatic detail

The user selects a finite area first. Auto chooses its finest available terrain level that fits the current admission policy. A manual spacing remains selected until the user chooses Auto. Recommendation upgrades happen only when the area changes or Auto is selected; new memory pressure can lower an automatic recommendation. The UI refreshes advisory capacity while visible and on foreground/thermal/memory events. Save, loading and renderer preparation check again before allocating. No terrain is streamed or refined while the camera moves.

The policy combines 20% of physical RAM, 50% of Metal’s recommended working set when reported, and 65% of process allocation headroom after a 64 MiB reserve. Real iOS devices use `os_proc_available_memory`; zero Metal working-set metadata is treated as unavailable. Nominal/fair/serious/critical thermal factors are 100/85/65/50%. Conservative geometry ceilings also depend on Metal feature support and actual maximum buffer length. These are engineering safeguards, not measured frame-rate guarantees or the OS termination limit.

A normal mesh is estimated at roughly 80 bytes per source sample, including final Metal vertices and indices, retained Float heights and small working arrays. Map memory includes mipmaps and preparation headroom; paths and fixed scene overhead are included separately. Vertices and indices are written directly into their final shared Metal buffers, eliminating full-size duplicate CPU arrays. The renderer rechecks the exact expanded grid after inserting texture boundaries. A later check credits the known resident height allocation to avoid charging it twice.

Combined context accounting includes all retained height samples, compact ring geometry, context maps and staging, one shared graph and app baseline, and an 8 MiB seam allowance. The primary geometry ceiling is unchanged; the combined mesh may use a bounded 25% additional geometry allowance for coarse surroundings, within the same total memory and individual Metal buffer limits. That reserve is a heuristic requiring real-device frame-rate validation. A fallback can omit context; it never authorizes an oversized primary mesh.

The Simulator exposes its Mac host’s resources and may omit Metal advisory values. Its policy uses a bounded simulation profile and respects actual reported buffer limits; its behavior does not establish real iPhone or iPad capacity.
