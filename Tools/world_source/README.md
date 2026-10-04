# Native world prototype

The default Explore screen now opens the UK atlas. Zoom into the included Snowdon
source, or choose **Explore Snowdon & the Glyderau**, to enter 3D. Moving the camera
changes a bounded set of fine meshes and vector-derived texture pages. Downloads
are separate from that resident working set; **Keep offline** pins source assets.
Saved routes, path following, GPX, and the previous saved-area renderer remain.

## Included source

`ridge v3/Resources/WorldData.bundle` contains a roughly 8 × 8 km Snowdon/Glyderau
test region: 256 adaptive terrain chunks, 256 compressed semantic vector files,
an 8 m overview, places, and the existing walking graph. Total: 33,803,148 bytes.
It works without the external drive or a server. This is not all of Eryri or the UK.

Terrain is recomputed from the retained original 1 m height field using the
existing 0.5 m maximum-error adaptive compiler, then losslessly encoded as RAT.
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
- The entire region has an 8 m background mesh (16 m on smaller-memory devices),
  built off the main thread. On the development Mac, its geometry source/index
  buffers total 59,777,024 bytes and construction took 0.067 seconds.
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

Residency follow-up: 7,974 world assertions pass, including 90 camera positions
through a forward/backward journey with 736 completed tile replacements, no
missing texture pages after initial fill, and bounded estimated allocations.
Resource-identity checks confirm texture/geometry reuse. This verifies policy and
resource handling, not sustained iPad frame time or total CPU/GPU memory.

`upgrade_overview.py --pack /path/to/original/eryri-grid --world /path/to/local/WorldData.bundle`
refreshes only a local fixture's overview without rebuilding adaptive chunks.
Publish remote updates in a new versioned directory; do not overwrite a live source.
