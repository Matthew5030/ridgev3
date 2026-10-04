# Native world prototype

The default Explore screen now opens the UK atlas. Zoom into the included Snowdon
source, or choose **Explore Snowdon & the Glyderau**, to enter 3D. Moving the camera
changes a bounded set of fine meshes and vector-derived texture pages. Downloads
are separate from that resident working set; **Keep offline** pins source assets.
Saved routes, path following, GPX, and the previous saved-area renderer remain.

## Included source

`ridge v3/Resources/WorldData.bundle` contains a roughly 8 × 8 km Snowdon/Glyderau
test region: 256 fine adaptive terrain chunks, 256 adaptive background chunks,
256 compressed semantic vector files, an 8 m height-query overview, places,
and the existing walking graph. Total: 35,268,614 bytes.
It works without the external drive or a server. This is not all of Eryri or the UK.

Terrain is recomputed from the retained original 1 m height field using the
existing 0.5 m maximum-error adaptive compiler, then losslessly encoded as RAT.
The background uses the same compiler at 2 m maximum surface error, verified
against the original 1 m surface. These are error tolerances, not sample spacing.
Both visible terrain levels are adaptive. The 8 m height field remains for shared
route statistics and compatibility; it does not render this source's background.
Contours are generated from a 4 m sampling of that field at 10 m intervals,
with 50 m index contours. Roads, paths, water and land features come from the
retained OSM source. No synthetic geographic features are added.

There is one vector source per cell. Core Graphics draws texture pages at the
required resolution on a worker actor. These are transient GPU inputs, not
multiple published image levels. Style changes live in `WorldCartography.swift`.

## Runtime limits

- One tile is fetched/decoded/drawn at a time; superseded results are discarded.
- Fine meshes use up to 192 MiB estimated residency on devices with at least
  6 GiB physical RAM; other devices retain the 96 MiB limit. Distance and budget
  determine admission, with a retention margin to avoid boundary churn.
- The entire region has a 2 m-error adaptive background, built off the main thread.
  Its geometry buffers including seam skirts total 39,817,892 bytes. Retained
  compact mesh and height-query bucket payloads add 23,105,762 bytes, excluding
  collection/framework overhead and driver copies. Decode/build took 0.56–0.62 s
  on the development Mac; this is not an iPad timing measurement.
- Background edges may simplify independently. Twenty-metre skirts cover joins
  between background neighbours (at most 4 m surface difference) and fine tiles
  (at most 2.5 m). The original fine compiler still retains native seam vertices.
- Older remote sources without background chunks retain the grid fallback.
- At most eight 1024 px pages and 24 additional 512 px pages; all other cells
  retain a 256 px page, plus gutters. Memory pressure can reduce these further.
- The 256-tile fixture's tested worst-case texture allocation with mipmaps is
  163,315,704 bytes; fine mesh estimate is 201,324,442 bytes. These are policy estimates,
  not measured total app memory; CPU data, SceneKit and transient copies add cost.
- Camera movement releases obsolete fine geometry, but keeps each map image
  visible until its replacement is ready. Map resolution changes reuse geometry;
  geometry changes reuse the image. Hidden fallback meshes release their images.
- The load queue fills background pages first, then reduces obsolete allocations
  before admitting higher-detail pages. Zooming out no longer removes all fine
  terrain at a single threshold.
- Memory warnings reduce detail; leaving Explore releases its prepared tiles.
- Remote files have byte-count/SHA-256 checks. Unpinned disk cache is evicted
  toward 256 MiB; explicitly saved files can exceed this limit.

The new incremental renderer uses SceneKit. The prior fixed-area Metal renderer
is retained. This avoids coupling the prototype to a rewrite of route storage or
the previous area-loading pipeline.

## Reproduce and test

Generate into an empty directory (Python: numpy, shapely, contourpy; Apple clang):

```sh
python3 Tools/world_source/build.py --pack /path/to/original/eryri-grid \
  --map /path/to/map-data.json --output /path/to/new/WorldData.bundle
sh Tools/test_world_source.sh
sh Tools/test_route_ux.sh
sh Tools/test_routes.sh /path/to/snowdon-horseshoe
```

For local HTTP/cache integration, serve the source on port 8776, then run
`sh Tools/test_world_source.sh --http`. On iOS, Settings → World source accepts
the full `world.json` URL; blank restores the bundled source. A physical iPad
requires an address it can reach, rather than the Mac's localhost.

Validation on 4 October 2026: simulator and signed iOS Release builds succeeded;
6,409 world checks, 17 route UX assertions and 137 core route assertions passed.
Simulator inspection confirmed terrain/vector alignment, ridge route draping,
labels, and saved-route reopening after replacing the app without uninstalling.
Signed Release installed on Matthew's M1 iPad Pro over USB without uninstalling
the existing app. Device Hub inspection confirmed the atlas opens and Snowdon
loads in 3D with contours, paths and peak labels. Sustained device performance
and thermal behaviour are not yet verified.

## Before extending or releasing

- Publish a region index and wider coverage. This prototype opens one source with
  at most 256 tiles, fetches its whole graph, and has only that source's horizon.
- Measure sustained panning, transient CPU/GPU memory and frame time on the M1
  iPad. Tune from measurements before expanding the resident limits.
- Make the atlas-to-3D projection transition continuous; current views crossfade.
- Retain dash phase through vector clipping; it currently restarts at cell edges.
- Add offline-area management, storage estimates, removal, and explicit coverage.
- Use fine elevations consistently for route statistics. The shared route terrain
  currently uses the 8 m overview; displayed routes sample resident fine meshes.
- Complete cross-source graph continuity from the retained routing bug report
  before promising routes across national source boundaries.
- Finish representative GPX, offline cold-launch, poor-network and interrupted
  download device tests. Existing automated GPX/route regressions still pass.

The original packs and route files are not deleted or migrated by this prototype.

## Gesture and overview follow-up

The world camera now uses one-finger ground-plane dragging and a single
intent-locked two-finger recognizer: a parallel drag changes heading horizontally
and pitch vertically. Spreading zooms; twisting never changes the viewing angle. Pinching no longer changes pitch.
The compass returns to a north-up overhead view. Camera pose survives tab changes.
Heading rotation is enabled; camera roll is locked to world-up, so the horizon stays level. Legacy scenes also permit heading rotation. Rotation preferences are no longer exposed.

The atlas now opens fitted to the UK, anchors pinch zoom at the fingers, and waits
until navigation ends before entering 3D. The included source has a tappable
marker. Land/sea colours, lakes, rivers, range names and UK elevation bands provide
geographic context. `atlas.json` is 2,144,537 bytes, including the existing atlas.
The UK relief is a smoothed overview, not extra hiking-scale LiDAR coverage.

Reproduce physical context using `build_atlas_context.py`, then
`build_atlas_relief.py`. The latter reads Mapzen Terrarium elevation tiles at zoom
6 once during preparation and converts them to vector elevation bands. No raster
pyramid or new live map dependency ships in the app. Natural Earth and Mapzen
source URLs/checksums are retained in `atlas-provenance.json`; attribution is in
Settings. The world outside the UK retains coarse coastline context.

`sh Tools/test_world_gestures.sh` checks gesture intent for jitter, intentional
tilt, off-centre pinches, twists and different initial finger orientations.
Route rebuilding is removed from the camera-movement loop; tile-driven route
updates are coalesced. Label projection runs after the scene renders its camera.

Camera regression: `test_world_gestures.sh` now also verifies the actual SceneKit
camera basis through a full heading sweep at three pitch angles. All 321 checks
pass: screen-right remains horizontal and the camera faces its orbit target.
The world renderer constructs that basis explicitly, rather than allowing roll
to be inferred by SceneKit look-at orientation.

Residency follow-up: 8,488 world assertions pass, including 90 camera positions
through a forward/backward journey with 736 completed tile replacements, no
missing texture pages after initial fill, and bounded estimated allocations.
Resource-identity checks confirm texture/geometry reuse. This verifies policy and
resource handling, not sustained iPad frame time or total CPU/GPU memory.

## Adaptive background experiment

Full-region comparison from the retained native source:

| Background | Surface triangles | Geometry buffers, including skirts | Compressed terrain |
| --- | ---: | ---: | ---: |
| Previous 8 m grid | 2,097,152 | 59,777,024 B | 6,288,295 B height JSON, uncompressed |
| Adaptive, 2 m maximum error | 1,249,125 | 39,817,892 B | 1,316,138 B |
| Adaptive, 4 m maximum error | 348,484 | 12,262,560 B | 403,810 B |

The app uses the 2 m option, plus the unchanged fine 0.5 m meshes. Only those two
adaptive versions ship. The 4 m result stays in the local study. Geometry savings
are not total app memory savings: the adaptive background also retains exact mesh
data for displayed-route draping and label/camera heights. Shared route statistics
still use the retained overview. `background-study.json` records the source hash
and results; the original fine compiler's output hash is unchanged in regression.

The compiler validates the complete adaptive surface before compression, including
native vertices and diagonal intersections, and the RAT codec verifies exact
reconstruction. Legacy fine descriptors still reject errors above 0.5 m. Background
descriptors explicitly allow the declared tolerance and require complete coverage.

To reproduce a background without rebuilding fine terrain or map vectors:

```sh
python3 Tools/world_source/build_background.py --pack /path/to/original/eryri-grid \
  --world /path/to/WorldData.bundle --output /path/to/new-background --tolerance 2
sh Tools/render_world_background_study.sh /path/to/screenshots
```

The full `build.py` also generates and includes the adaptive background. The still
comparison uses the app's SceneKit geometry and vector drawing at fixed cameras,
with identical textures/lighting; it isolates background geometry without nearby
fine overlays. Review both wide and ridge views. Signed Release builds and installs
successfully; physical-device panning/thermal checks remain outstanding while the
iPad is locked. All 349 legacy adaptive codec checks pass.

`upgrade_overview.py --pack /path/to/original/eryri-grid --world /path/to/local/WorldData.bundle`
refreshes only a local fixture's overview without rebuilding adaptive chunks.
Publish remote updates in a new versioned directory; do not overwrite a live source.
