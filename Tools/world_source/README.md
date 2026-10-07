# Native world prototype

The default Explore screen now opens a textured UK overhead atlas (about 252 MB),
using the world terrain palette instead of green elevation bands. Zoom into the included Snowdon
source, or choose **Explore Snowdon & the Glyderau**, to enter 3D. Moving the camera
changes a bounded set of fine meshes and vector-derived texture pages. Downloads
are separate from that resident working set; **Keep offline** pins source assets.
Saved routes, path following, GPX, and the previous saved-area renderer remain.

## Finish plan for the first TestFlight build — 4 October 2026

The first release milestone is a complete journey through a few connected,
verified regions: explore the overview, enter 3D, move across a region boundary,
plan and save a walking route, export/import GPX, keep the area offline, and reopen
it without a connection. Completing every national source is not a prerequisite
for that beta. Available coverage must be explicit; the overview is not evidence
of fine LiDAR or routing coverage.

The UK overview is complete. The separate adaptive/vector conversion is running;
at this plan's first checkpoint, 144 validated sources occupied about 2.47 GB.
Use the live external `status.json` and `catalog.json` described in [BATCH.md](BATCH.md)
for current progress. This process is bounded to 48 hours and has a disk reserve;
completion and any deferred/failed inputs still need checking. Prepared fine
LiDAR has real coverage gaps, so completing the batch does not mean universal
fine UK terrain coverage.

Implement in this order, with a Git checkpoint and verification at each step:

1. **Serve and load one finished region.** Expose the immutable completed assets
   and catalogue through static HTTP for development and HTTPS for deployment.
   Exercise the real app reader on the phone against a new region, including
   checksums, failed requests, retry and cached reopening. No live map computation
   is required. Pass condition: a region outside the bundled Snowdon fixture opens
   with its adaptive meshes, vectors, places and graph through the server.
2. **Connect the catalogue and neighbouring regions.** Resolve an explored place
   against the published coverage. Keep one camera/world coordinate frame and one
   bounded memory budget across all active regions. Queue work for the current
   view, cancel superseded requests, and keep existing imagery visible while
   replacements arrive. Avoid loading each neighbouring region's entire background
   and map preview before drawing anything. Pass condition: pan across at least
   three neighbouring regions and back without a camera reset, blank transition,
   duplicated surfaces or a growing memory footprint on iPhone and M1 iPad.
3. **Join routing across boundaries.** Audit the retained graph identities and
   clipped boundary edges, then preserve verified real connections in the published
   graph and app's active graph. Do not infer links solely from nearby endpoints or
   silently fall back to straight lines. Verify shared terrain alignment and route
   heights at joins. Graph corrections can be published in a new manifest revision
   while reusing unchanged mesh/vector assets. Pass condition: an independently
   checked walking route crosses two region boundaries and survives save/reopen,
   editing and GPX export/import without a gap or change of path.
4. **Finish keeping areas offline.** Save all assets needed for the chosen area or
   route, including required neighbouring terrain, maps and routing dependencies.
   Show truthful storage/progress, support cancellation and resumption, and expose
   removal of saved data without removing routes. Pass condition: force-quit,
   enable airplane mode, reopen, inspect the landscape and reopen/edit the saved
   route successfully. Failed downloads must retain the previous usable data.
5. **Run the release checks and ship the beta.** Test extended panning, peak memory,
   frame-time stalls, thermal behaviour, poor connectivity, interrupted downloads,
   app backgrounding, upgrades that preserve routes, and GPX round trips on both
   physical devices. Record measurements and fix blockers rather than increasing
   budgets by assumption. Confirm signing, app metadata, privacy disclosures and
   map attribution, then upload a TestFlight build with an explicit coverage list.

Alongside these steps, let the national conversion continue and audit its completed
catalogue, failures and coverage gaps. Publish only verified regions. A running
batch does not automatically publish a server, connect neighbouring regions in the
app, or complete the release checks.

Backlog after the first usable beta: nationwide availability, thin route-corridor
saves, alternative visual themes, automatic route suggestions, and further storage
optimisation beyond the validated working budget. Existing route editing, saved
routes, profiles and GPX support remain part of the core journey.

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
- Memory warnings reduce detail; leaving Explore releases fine prepared tiles,
  retaining the small overview pages for the next entry.
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

### Static hosting pilot

`prepare_hosting_pilot.py` creates a small upload directory from published
regions and their matching previews. It verifies every referenced asset's size
and SHA-256 and checks each preview against its source manifest. It copies the
existing files without recomputing terrain or vectors.

```sh
python3 Tools/world_source/prepare_hosting_pilot.py \
  --world /path/to/world-output --previews /path/to/preview-output \
  --output Tools/PreparedPacks/hosting-pilot \
  --source world-z10-x500-y333-c00-r00
sh Tools/test_world_hosted.sh https://maps.example.com/pilot/sources/world-z10-x500-y333-c00-r00/world.json
```

Supply multiple `--source` arguments to prepare neighbouring regions; the test
accepts multiple manifest URLs. Upload objects listed in `upload-inventory.json`
in order, with manifests/catalogue/landing page after their dependencies. Serve
the exact bytes without setting HTTP `Content-Encoding` on compressed assets.
The inventory is local upload bookkeeping and need not be published.

The native reader test checks decoded fine and background terrain, vector image
rendering, a walking graph segment, cache checksums and offline pin bookkeeping.
It reports cold and cached timings. It does not replace an iPad test in airplane
mode or verify sustained frame rate. The pilot opens each region separately;
automatic movement between catalogue regions remains to be implemented.

On 7 October 2026 the four neighbouring Snowdon regions produced 1,024 cells
and 121,856,580 bytes including previews and metadata. All four regions passed
the native reader test over local HTTP. Cloudflare MCP authentication is complete;
upload and public-network measurements remain pending a Codex restart to load
the connection.

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
- The textured UK overview is complete; validate its transition into each newly
  available detailed region as catalogue integration is added.
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
The retained vector relief is a legacy fallback. The world flow now uses the
shaded image overview described in `../world_atlas/README.md`; neither overview
implies extra hiking-scale LiDAR coverage.

Reproduce physical context using `build_atlas_context.py`, then
`build_atlas_relief.py`. The latter reads Mapzen Terrarium elevation tiles at zoom
6 once during preparation and converts them to vector elevation bands. No raster
pyramid or new live map dependency ships in the app. Natural Earth and Mapzen
source URLs/checksums are retained in `atlas-provenance.json`; attribution is in
Settings. The world outside the UK retains coarse coastline context.

`sh Tools/test_world_gestures.sh` checks gesture intent for jitter, intentional
tilt, off-centre pinches, twists and different initial finger orientations.
Route rendering uses the terrain-material overlay described below; there is no
camera- or tile-driven ribbon rebuild. Label projection runs after the scene renders its camera.

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

## Route surface overlay

The continuous-world route is now vector ink inside the terrain material. A Metal
fragment modifier evaluates distance to the route segments, with round ends/joins,
a light outline and antialiasing. There is no separate ribbon, 5 m height sampling,
2 m lift, or delayed redraw when terrain changes. Waypoint circles use the same
surface overlay. Normal terrain depth testing hides routes behind other mountains.

Each affected tile has a 16 × 16 spatial lookup table and a small Metal buffer of
segment endpoints/waypoint coordinates. The lookup includes a 40 m neighbour
margin; shader widths and antialiasing are capped inside that margin. This avoids
scanning the full route for each fragment. Imported disconnected sections remain
separate; duplicate vertices do not produce invalid segments. Tile buffer data is
built on route edits and reused by replacement terrain materials. Zoom/tilt use
screen derivatives for continuous line width, without rebuilding route geometry.
The width has a world-space cap for extreme distant/grazing views.

The Crib Goch → Yr Wyddfa walking route has 227 points, touches 10 overlay tiles,
and needs 95,568 GPU buffer bytes; its busiest lookup cell contains 37 segments.
This is route payload size, not a complete GPU performance measurement. The
previous saved-area Metal renderer and map-file cartography are unchanged.

```sh
sh Tools/test_world_route_overlay.sh
sh Tools/render_world_background_study.sh /path/to/route-screenshots --route
```

Tests compare spatial lookup results with the original segments across tile edges,
check disconnected GPX sections and corner waypoints, and render the actual Metal
modifier. Render checks cover pixel width through zoom, normal depth occlusion,
clearing the overlay and reusing it after terrain replacement. Fixed-camera Crib
Goch views cover background/fine terrain, wide, close, low-angle and overhead views.

## Overhead-to-terrain transition

The source footprint in the atlas now contains an orthographic render of the same
adaptive background and vector cartography as the 3D scene. It is generated once
on the worker actor from 128 px pages, then reused while browsing. This adds no
published image pyramid or download. The 2048 px overview is approximately 16 MiB
uncompressed; the 256 small pages add approximately 18 MiB before GPU copies.
Preview generation took 0.86 s on the development Mac, not a measured iPad time.

Selecting a place animates atlas centre and scale, then descends from a narrow-FOV
overhead view to the normal terrain camera. Pinching into a viewport less than
7 km high enters the same flight. Zooming out past the 12 km camera-distance
threshold, or using the map button, returns through an overhead view with a
minimum 14 km footprint. These different thresholds prevent mode oscillation.
The atlas zoom limit accommodates large iPad viewports. Atmospheric fade stays
beyond the ground during the high-camera projection change.

Panning, pinching, or a camera command interrupts the flight; Reduce Motion skips
the camera flights. A short opacity handoff remains between the two renderers.
This is a matched regional transition, not a single UK-wide 3D renderer.

`sh Tools/test_world_transition.sh` verifies camera endpoints, monotonic framing,
heading wrap, and geographic footprints across phone/tablet aspect ratios
(1,080 checks). Source checks now include preview preparation (8,490 assertions).

New routes always follow mapped paths. Direct-line controls and their guidance
were removed; existing direct segments remain readable in old saved routes.

Validation for this change: simulator and signed device builds pass, alongside
321 gesture checks and 9,450 terrain-route overlay checks. The entry flight was
visually checked on the 13-inch iPad simulator. The Mac locked before a final
visual check of the return-to-atlas layout fix; physical-device smoothness still
needs confirmation.

## National preparation job (2026-10-04)

The connected drive contains completed corrected fine RAT terrain: 589,443 chunks
across 342 sections. Those meshes are reused. Verified source archives are staged
from retained iCloud products; the resumable batch creates bounded adaptive/vector
world sources and exact overhead previews. See `BATCH.md` for commands, progress
files and restart instructions. Originals remain in place. The UK-wide overview
is already bundled; automatic discovery/loading of new 3D regions and routing
across source boundaries still require app integration.

Simulator QA confirmed opening the shaded UK overview, entering Snowdon in 3D,
and returning to an overhead map centred on the same place. The iPad build was
installed; physical launch was blocked by the device lock.
