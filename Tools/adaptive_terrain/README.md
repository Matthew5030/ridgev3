# Offline adaptive terrain tools

Reusable park compilation, coverage auditing and compact static downloads, plus
the original Crib Goch comparison lab. These tools keep source data read-only
and do not change the iOS renderer. Start with
[park builds and downloads](#reusable-park-builds-and-compact-downloads) for the
current batch workflow, or [RAT1](#compact-rat1-topology-format) for the compact
format. The first sections below document the original lab.

## Original two-tile comparison

Requirements: Python 3 with the packages in `requirements.txt`, and Node.js. From the Xcode project directory:

```sh
python3 -m venv /tmp/ridge-adaptive-venv
/tmp/ridge-adaptive-venv/bin/python -m pip install -r Tools/adaptive_terrain/requirements.txt
/tmp/ridge-adaptive-venv/bin/python Tools/adaptive_terrain/run_experiment.py --node /absolute/path/to/node
```

Defaults use the existing `ridge v3/Resources/RidgeData.bundle/regions/eryri-grid` and write to `Tools/reports/crib-goch-adaptive`. Override with `--pack` and `--output`. The experiment intentionally targets local column 6, rows 9 and 10 in that pack; it is not a general pack converter.

To view the finished comparison:

```sh
python3 -m http.server 8769 --bind 127.0.0.1 --directory Tools/reports/crib-goch-adaptive
```

Open http://127.0.0.1:8769. This serves precomputed files locally; the renderer has no terrain refinement or live data service. `REPORT.md`, figures and `metrics.json` contain the results. Large generated assets are in the project's ignored `Tools/reports` directory.

## Algorithm

`vendor/martini.mjs` is upstream MARTINI, unchanged; its pinned URL/hash and ISC licence are adjacent. `build_meshes.mjs` supplies a custom error field, native boundary constraints, and native diagonal preservation. It prepares the error field once, searches for a triangle budget, then emits finished static meshes. Python independently measures the output with Matplotlib's triangle interpolation and checks topology and source hashes.

Default profiles include 0.4999, 1, 2 and 3 m surface-error criteria, plus an adaptive mesh bounded by the 4 m grid's 65,536 triangles. The 0.4999 setting leaves a margin for float32 height representation. Selection of the fine profile uses the independently measured error, not the input threshold.

All native vertices and cell centres are evaluated. These checks cover changes in the existing and RTIN piecewise-planar surfaces, including native diagonal crossings. The report conservatively calls them measured errors; they do not establish survey accuracy. Baseline levels must exactly match the retained 1 m source samples.

The perimeter keeps all native vertices for deterministic joins. The longest triangle edge is at most 8√2 native grid steps. Mesh vertices retain source heights exactly in integer source units. No source smoothing, texture changes or new LiDAR processing occurs.

## Experimental `.rmesh` layout

Little endian, 28-byte header:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | 4 ASCII bytes | `RME1` |
| 4 | UInt32 | Vertex count |
| 8 | UInt32 | Triangle count |
| 12 | UInt32 | Index width, 2 or 4 bytes |
| 16 | UInt32 | Native grid width, 513 |
| 20 | Float32 | Source height scale, 0.1 m |
| 24 | Float32 | Height offset, zero |

Followed by `vertexCount` six-byte records: UInt16 x, UInt16 y, Int16 source height. Then `triangleCount × 3` indices of the declared width. `.rmesh.zlib` is zlib compression of the entire file. All displayed profiles round-trip through this layout in the builder.

Geographic bounds and source provenance are external in `metrics.json`. This format has no production reader, version migration, precomputed normals, spatial index, checksum header or random access. It is deliberately a test payload, not a deployment-ready replacement for the pack.

WebGL files separately use eight float32 values per vertex (position, normal, UV) and uint32 indices. The viewer calculates no new geometry when orbiting. Its geometry bytes differ from the report's estimate using the current Metal vertex layout.

## Limits

This is a two-tile geometry experiment. It is not an M1 iPad benchmark or whole-UK capacity estimate. Texture/decode/startup costs still need measurement in the iOS renderer. The summit is close to a forced native tile edge, so further tests should include ridges in tile interiors. Disk cost may increase even while GPU geometry shrinks.

## Optional viewer verification

With Playwright available to Node and the local server running:

```sh
node Tools/adaptive_terrain/verify_viewer.cjs
```

Set `RIDGE_BROWSER_CHANNEL=chrome` to use an installed Chrome instead of Playwright's bundled Chromium. `NODE_PATH` can point to an existing dependency directory. The test loads all seven profiles, exercises camera and display controls, checks JavaScript/WebGL errors, blocks external requests, and writes screenshots plus `browser-qa.json` into the report directory. It does not measure iPad frame time.

## Larger triangles and rebuilt pack layouts

The current pack grid is not a production constraint: the packs will be rebuilt. To run the additional fixed-2-m-error experiment after the base run:

```sh
/tmp/ridge-adaptive-venv/bin/python Tools/adaptive_terrain/test_pack_layouts.py --node /absolute/path/to/node
```

This adds ten candidates to the existing lab: 8, 16, 32, 64 native-step cell limits and no additional cap, each with either the original two tile boundaries or one joined rectangle. They are test settings, not proposed shipping layers. `LAYOUT-REPORT.md` and `layout-metrics.json` report the results; `layout-triangles.png` and `layout-savings.png` compare topology and costs. The lab starts with original/8 on the left and joined/uncapped on the right.

The joined rectangle removes the internal native-edge constraint and shifts the RTIN origin by one native sample in both axes. This changes triangulation alignment as well as the edge policy; it permits triangles to cross the original internal tile boundary. The physical extent, source data, error tolerance, native outside perimeter and texture are identical. The original 8 m candidate must reproduce the previous 2 m mesh byte-for-byte.

MARTINI accepts square grids, so the rectangular source is embedded in a 2049-square grid with nearest-boundary-height extrusion in the unused area. Dense real perimeter constraints isolate this padding. Only triangles entirely inside the true 513 × 1025 source window survive, and all coordinates are translated back. Validation checks the complete real area, manifold topology, native vertex heights, outer perimeter, triangles crossing the old internal boundary, and all 1,050,113 distinct source vertices/cell centres. No padded surface is displayed or counted in geometry estimates.

The ten profiles all have a 2 m criterion; the preprocessor can stop testing any candidate triangle as soon as it exceeds that tolerance. The final Python evaluator independently checks the completed surface without that early-out. Native cell diagonals are preserved where necessary, as in the base experiment.

The external rim remains native and coordinated in this test. Rebuilding larger production packs, independently joining neighbouring regions, simplifying their shared boundaries or mixing quality levels still needs a defined boundary policy. The measurements do not establish whole-Snowdon cost or device frame times.

Re-running the base experiment resets the viewer to the tolerance comparison; run this layout experiment afterwards to restore the extended lab. `verify_viewer.cjs` discovers the available profile count and checks every profile plus both shortcut groups. Source pack files remain read-only throughout.

## Eryri whole-park 0.5 m stress test

The park compiler is `park_mesh.cpp`, an offline C++ implementation of the same
RTIN surface-error method. It checks candidate triangles at native vertices and
NE–SW cell centres, propagates splits, restores native diagonals, then checks the
finished surface again. It preserves native shared edges and has no triangle-size
cap. It reproduces the Crib Goch 0.5 m triangle counts exactly. This is still an
experimental compiler and format, separate from normal app terrain imports.

```sh
clang++ -O3 -std=c++17 Tools/adaptive_terrain/park_mesh.cpp -o /tmp/ridge-park-mesh
# Install requirements.txt into the experiment venv first.
python Tools/adaptive_terrain/build_park.py \
  --source /path/to/england-wales-precision/2026.09.02-1 \
  --fallback /path/to/uk-national-parks-precision/2026.09.01-1 \
  --boundary /path/to/eryri-boundary.geojson \
  --output /path/outside-iCloud/eryri-park-adaptive \
  --compiler /tmp/ridge-park-mesh
python Tools/adaptive_terrain/verify_park.py /path/outside-iCloud/eryri-park-adaptive
python Tools/adaptive_terrain/report_park.py /path/outside-iCloud/eryri-park-adaptive
python Tools/adaptive_terrain/package_park.py \
  /path/outside-iCloud/eryri-park-adaptive /path/outside-iCloud/EryriAdaptiveTest
```

Keep these large generated files outside Desktop/Documents iCloud storage. The
builder verifies source manifests and source hashes, rejects NoData samples,
resumes verified chunks, and locks its output directory against concurrent runs.
Coverage is calculated against the park polygon, including absent parents. It
does not silently fill source gaps with coarse data. The independent verifier
checks 26 distributed/extreme chunks using Matplotlib's triangle locator and
compares every shared edge from the written meshes.

The measured pack contains 9,010 chunks and 768,136,638 triangles. Prepared 1 m
coverage is missing over 46.58 km² (2.18% of the boundary). Raw RME1 files total
7,022,271,670 bytes. The current renderer's expanded vertex/index representation
would require 28,096,210,968 bytes before maps/routes. See the generated REPORT.md
for the exact method, caveats, and validation results.

`package_park.py` makes a single `terrain.rmeshpack` for practical device transfer.
It concatenates SHA-verified RME1 chunks; each manifest entry has a `byteOffset`
and `compactBytes`. The native reader seeks and reads one chunk at a time during
the initial load, then retains every GPU buffer. This is not runtime streaming.
The package and individual chunk layouts are both supported by the diagnostic.

The separate Eryri diagnostic entry points have been removed from the normal
app at the user's request. The historical package was transferred into
`Documents/EryriAdaptiveTest`; it is not part of the normal download flow. It is a geometry-only diagnostic with relief colouring, not a routable map
pack. The increased-memory-limit entitlement requests additional memory on
supported devices; the test still checks `os_proc_available_memory` and a
512 MiB reserve before loading. Devices without sufficient allowance refuse the
whole scene rather than silently reducing detail. Simulator uses an explicit
1 GiB verification budget because it does not provide the iOS memory reading.

Historical diagnostic runs used `--eryri-stress-test --eryri-auto-test`; these
entry points are not part of the normal app flow.
`Documents/EryriStressResult.json` records the device allowance, load progress,
full resident result, and first completed GPU frame (or GPU error). A successful
small Simulator fixture verifies the loader/shader only; it is not an iPad or
whole-park performance result. The normal fixed-scene planner is unchanged.


## Reusable park builds and compact downloads

The same unchanged 0.5 m compiler now accepts any park feature from the existing
prepared national-parks boundary collection. `build_park.py` derives the park ID
and title from `collectionID` and `displayName`; use `--id` and `--name` to override.
`--plan-only` computes actual native coverage and chunk count without compiling.
It does not acquire new LiDAR. Missing prepared source is reported explicitly.

For example, with a Lake District feature saved as `lake-district.geojson`:

```sh
python build_park.py --source /path/to/precision/product \
  --fallback /path/to/earlier/product \
  --boundary /path/to/lake-district.geojson \
  --output /external/build/lake-district-adaptive-0p5 \
  --compiler /tmp/ridge-park-mesh --workers 3
python verify_park.py /external/build/lake-district-adaptive-0p5
python publish_adaptive.py /external/build/lake-district-adaptive-0p5 \
  '/Volumes/MLB_EXT_4TB/Ridge Sources' --workers 3
python report_park.py /external/build/lake-district-adaptive-0p5 \
  --published '/Volumes/MLB_EXT_4TB/Ridge Sources/lake-district-adaptive-0p5'
```

`publish_adaptive.py` requires an independent validation report matching the
exact source manifest. It checks all source and mesh hashes, then writes one
zlib level-6 compressed RAT1 file per native chunk (reconstructing RME1 exactly). It round-trips every compressed
file before publishing `adaptive.json`. The index includes geographic bounds,
compressed and decoded byte lengths and SHA-256 hashes, triangle counts, packed
and expanded buffer sizes, and original source attribution/licensing metadata.
Source paths, compiler caches and build reports are not served.

Compression is lossless. It reduces disk/transfer bytes; it does not reduce the
resident mesh buffer. The report compares compressed adaptive geometry with
both raw and equally compressed original heightfields. It separately reports
triangle savings versus a native 1 m grid. It does not imply that mesh files
must always be smaller than heightfields or that maps are included.

Published source IDs are immutable. Use a new `--id` and build output directory
for a revised dataset. Completed chunks resume after interrupted builds.
`adaptive.json` and `/adaptive-catalog.json` are published only after completion.
Normal `/catalog.json` remains for sources the current app can read.

**These are terrain assets, not complete normal-app map packs.** The app does
not yet consume `rme1-zlib-v1`. No adaptive experiment entry point is restored.
The next integration must connect these bounded chunk downloads to the normal
textured scene, route-height sampling, memory admission and expansion logic.
Map textures and walking graphs are separate and must retain their own quality.

Run the compiler/publisher regression checks in the same experiment venv:

```sh
RIDGE_PARK_COMPILER=/tmp/ridge-park-mesh python test_adaptive_publish.py
```

They check a real compiled plane with the independent mesh verifier, compression
round-trips, provenance, metadata hashes, damaged source/mesh rejection,
validation-to-manifest matching, immutable revisions, catalogue recovery and
NoData rejection.


### Whole national-park collection

`build_collection.py` accepts the existing FeatureCollection. It first measures
coverage for each park, then compiles, independently verifies, compresses and
reports each eligible park. Zero-coverage parks are recorded as awaiting source,
not published as empty or fake terrain. Individual park failures are retained in
`collection-status.json` and do not hide results from the other parks.

```sh
python Tools/adaptive_terrain/build_collection.py \
  --boundaries /path/to/national-parks.geojson \
  --source /path/to/precision/product --fallback /path/to/earlier/product \
  --output '/Volumes/MLB_EXT_4TB/Ridge Experiments' \
  --downloads '/Volumes/MLB_EXT_4TB/Ridge Sources' \
  --work-directory /tmp/ridge-national-parks-work \
  --compiler /tmp/ridge-park-mesh --jobs 1 --workers 6
```

Run once with `--plan-only` to write `collection-plan.json`. `--exclude` accepts
park keys already handled by an existing build job. An optional local work
directory keeps small intermediate mesh files on the faster internal disk. Only
after publication and copying matching audit records to the external build
folder does the runner remove its temporary `meshes` cache. The losslessly
compressed downloads are the durable geometry. Completed publications are reused.
Use a work directory with enough space for one uncompressed park; increasing
`--jobs` increases both scratch storage and drive contention.

`verify_park.py BUILD --published DOWNLOAD` audits the durable compressed files
directly, including all hashes and seams, so the temporary raw mesh cache is not
required for a later check. New builds measure the compressed-source baseline
while SHA-verified source bytes are already in memory; legacy builds measure it
during publication. The compiler and the 0.5 m acceptance criterion are unchanged.

`report_collection.py BUILD_ROOT DOWNLOAD_ROOT` writes `NATIONAL-PARKS.md` and
`NATIONAL-PARKS.json`, with coverage, download sizes, triangle savings, totals and
explicit missing-source parks. `verify_adaptive_downloads.py SERVER --output FILE`
checks actual HTTP metadata, representative/extreme chunks, lossless decoding,
byte-range responses, private-file exclusion and the separation of catalogues.

## Compact RAT1 topology format

The preferred download encoding is now **RAT1 + zlib**, advertised as
`rat1-zlib-v1`. It represents the same finished 0.5 m adaptive mesh. It changes
neither triangle count nor source heights. The encoder reconstructs the entire
original RME1 file and compares it byte-for-byte before accepting a chunk.

RME1 explicitly stores x/y coordinates and three indices per triangle. For
these canonical RTIN meshes that information can instead be reconstructed from
a compact subdivision tree. RAT1 stores those decisions plus the original
vertex heights. This makes transfer/storage much smaller without asking the
app to rerun adaptive error analysis. Decoding builds the same precomputed mesh;
its geometry-memory requirement is unchanged.

Build the standalone codec and Python shared library:

```sh
sh Tools/adaptive_terrain/build_compact_codec.sh
```

The default library is `/tmp/libridge_compact_mesh.dylib` on macOS, or `.so` on
Linux. Override with `RIDGE_COMPACT_LIBRARY`. `publish_adaptive.py` now defaults
to `--codec rat1`; `--codec rme1` retains the older explicit format. Existing
published IDs remain immutable. `repack_adaptive.py OLD_SOURCE DOWNLOAD_ROOT`
creates a new `-compact-v1` source, preserving the old URLs. The catalogue offers
only the preferred encoding of each landscape, rather than overlapping copies.

### Binary payload before zlib

All integer and floating-point fields are little endian:

| Offset | Type | Meaning |
| ---: | --- | --- |
| 0 | 4 ASCII bytes | `RAT1` |
| 4 | UInt32 | Reconstructed vertex count |
| 8 | UInt32 | Reconstructed triangle count |
| 12 | UInt32 | Reconstructed RME1 index width: 2 or 4 bytes |
| 16 | UInt32 | Native grid width: 513 |
| 20 | Float32 | Original source height scale |
| 24 | Float32 | Original source height offset |
| 28 | UInt32 | Subdivision decision bit count |
| 32 | Bytes | Decision bits, least-significant bit first within each byte |
| After decision bytes | Int16 × vertex count | Original source heights in canonical vertex order |

The decision-byte length is `(bitCount + 7) / 8`. Starting triangles are
`[(0,0),(512,512),(512,0)]` and `[(512,512),(0,0),(0,512)]`. Traverse in that order.
For a triangle `(a,b,c)`, if `abs(a.x-c.x)+abs(a.y-c.y) > 1`, consume one bit.
Zero emits the triangle; one visits `(c,a,mid(a,b))`, then
`(b,c,mid(a,b))`. Unit triangles emit directly without consuming a bit.

Restore every pair of unit-cell triangles to the same native NE–SW diagonal
used by `park_mesh.cpp`, preserving their array positions. Enumerate vertices
by first occurrence while visiting the final triangle array and its corners.
The stored height sequence matches that order. This reconstructs the original
RME1 byte sequence, including vertex/index order and the retained source scale.
`compact_mesh.cpp` contains the encoder and decoder and is usable independently
of Python; `compact_codec.py` calls it in memory for bounded parallel work.
The RTIN topology follows MARTINI (Mapbox, 2019); retain the included
[`vendor/MARTINI-LICENSE`](vendor/MARTINI-LICENSE) when redistributing these tools.

The decoder validates grid/count limits, exact payload length, bit consumption,
triangle count and vertex count. A reader must also verify compressed and
reconstructed hashes and admit the *decoded geometry* against its memory budget.
The index records `topologyByteCount`/`topologySHA256` for the inflated RAT1 bytes;
`decodedByteCount`/`decodedSHA256` describe the reconstructed RME1 mesh. Packed
and expanded geometry costs remain separate from download bytes.

Regression tests include a completely detailed 513-square checkerboard with
32-bit indices, a simplified plane with 16-bit indices, damaged/truncated
headers, noncanonical triangle-order rejection, publication and direct
verification from compressed topology, and immutable legacy repacking with
one preferred catalogue entry. Real-park encoding repeats the exact mesh
round-trip check for every chunk, not just the test samples.

### Reusing an existing concatenated mesh package

Both `verify_park.py` and `publish_adaptive.py` accept `--mesh-package FOLDER`.
The package index must match every private chunk's hash, byte length and bounds.
A shared file descriptor with positional reads avoids reopening thousands of
small files. This reuses the historical Eryri package without recomputing its
adaptive meshes. Source provenance and independent checks are retained.

## Scottish source preparation

The supplied precision products contain no native Scottish park inputs. The
additional source workflow audits the official Scottish public-sector LiDAR
bucket, downloads selected DTMs with ETag/length/SHA-256 checks, and prepares
compatible native chunks. It uses phases 1–6 and the national LiDAR programme's
DTM folders. It does not claim to inventory every Scottish survey. Download
footprint estimates are upper bounds; actual valid-data coverage is measured
only after inspecting and sampling the rasters.

```sh
python -m pip install rasterio==1.5.1
python Tools/adaptive_terrain/scottish_dtm.py audit \
  --boundaries /external/park-boundaries --output /external/scotland-audit.json
python Tools/adaptive_terrain/scottish_dtm.py download \
  --audit /external/scotland-audit.json --output /external/scotland-dtm
```

Place the official PROJ grid `uk_os_OSTN15_NTv2_OSGBtoETRS.tif` from
<https://cdn.proj.org/uk_os_OSTN15_NTv2_OSGBtoETRS.tif> in a coordinate-grid
folder. The September 2026 build used SHA-256
`5d6ed64d2119952c4c559fa1fccbc594b6520fc3ec3ef2fc10be13202c4384fa`.
The preparation script records the grid hash and selected transformation and
refuses a lower-accuracy fallback when the best transformation is unavailable.

```sh
python Tools/adaptive_terrain/prepare_scottish_sources.py \
  --sources /external/scotland-dtm/sources.json \
  --boundaries /external/park-boundaries \
  --coordinate-grids /external/coordinate-grids \
  --output /external/scottish-park-precision/version
```

The TIFFs must be north-up British National Grid DTMs at 1 m or finer. A 10 ppm
allowance handles georeferencing roundoff in historic nominal 1 m files; it does
not admit coarser surveys. A virtual 1 m BNG mosaic joins valid source rasters,
with finer sources taking priority. Bilinear sampling on that continuous mosaic
avoids clamping each TIFF separately at its edge. All mosaic reads use fixed
512-pixel blocks, so neighbouring chunks cannot get slightly different
resampling results at the same coordinate and then quantise to different
heights. A bounded 64-block cache reuses these reads. Sampling onto Ridge's existing
geographic grid adds reprojection/interpolation and 0.1 m height quantisation;
the adaptive 0.5 m criterion applies to this **prepared surface**, not to absolute
survey accuracy. NoData is never filled. Every native chunk with missing samples
is excluded, even if its filename footprint intersects the park.

Original source URLs, checksums, licensing, transformation and preparation are
retained. Frozen input fingerprints protect resumable preparation from mixing
changed source versions. Feed the prepared product into `build_park.py`, then
use the same independent seam/surface verification and compact publication.
`test_scottish_sources.py` checks adjacent raster seams, missing data, finer-source
priority, resolution rejection, checksum-verified download resume, and identical
shared coordinates queried from different windows using synthetic georeferenced
rasters. The window test reproduces a real Scottish source seam failure.

## Whole-UK terrain downloads

The UK build uses the existing fixed z10 grid, with **one owner per native
chunk**. It processes and validates one grid section at a time, then removes
its temporary uncompressed meshes. It does not build a monolithic UK scene.
The public index advertises `rat1-zlib-range-v1`: each section has a
`terrain.ratpack` container, and each chunk has an offset, compressed length,
compressed hash and decoded hash. HTTP byte ranges retrieve only the selected
chunks. The compact encoding is lossless relative to the validated adaptive
mesh; decoded geometry still needs the app's memory admission limit.

There are two different terrain assets:

- `uk-adaptive-0p5-v2/catalog.json`: detailed adaptive sections. The 0.5 m
  tolerance is measured against the prepared 1 m heightfield, not absolute
  survey accuracy. `buildComplete` distinguishes an in-progress catalogue.
- `uk-coarse-background-v2/background.json`: separately labelled coarse global
  elevation, resampled to 513 × 513 per world section, with explicit NoData.
  It provides UK context where detailed LiDAR is unavailable. It does not carry
  the detailed layer's 0.5 m guarantee.

The detailed catalogue includes the background descriptor's path and checksum.
These capabilities are separate from the normal app catalogue. The iOS app
still needs a RAT1 range reader before it can use these new terrain assets.
Textures and routing data are not included or downsampled by this process.

### Source coverage is a required input

An audit of the older EA-derived prepared files found constant −0.3 m chunks
outside the official England survey coverage, including hills in Scotland.
Prepared `available` flags are therefore insufficient. `download_ea_coverage.py`
freezes the official 2022 DTM footprint catalogue, checking all feature IDs,
projection, checksums and the catalogue's edit version. Queries use POST to
avoid URL-length failures on large object-ID lists.

`plan_uk.py` verifies that each EA-derived chunk's full projected envelope,
plus 2 m for interpolation support, lies inside the union of those footprints.
It preserves holes and considers valid fallback sources after a rejection.
Invalid ArcGIS nested rings are repaired using GEOS `make_valid` linework,
which retains the original edges and even-odd holes; no outward buffering is
applied to survey coverage. The acceptance envelope is deliberately
conservative at survey boundaries. Welsh COG and Scottish source preparation
retain their own explicit NoData policy.

The original unfiltered UK publication was withdrawn. The corrected build uses
new immutable URLs ending in `v2`. The UK administrative polygon includes
territorial water, so its polygon coverage percentage must not be presented as
a percentage of UK land with LiDAR.

```sh
python Tools/adaptive_terrain/download_ea_coverage.py /external/ea-2022-coverage
python Tools/adaptive_terrain/plan_uk.py \
  --output /external/uk-build-v2 \
  --source /external/england-wales-native \
  --source /external/earlier-parks-native \
  --source /external/scottish-native \
  --boundary /path/to/uk-boundary.geojson \
  --world-grid /path/to/world-grid.json \
  --ea-coverage /external/ea-2022-coverage
python Tools/adaptive_terrain/build_uk_background.py \
  --build /external/uk-build-v2 \
  --source-lock /path/to/uk-bulk.lock.json \
  --source-root /path/to/mapping/sources \
  --output /external/downloads/uk-coarse-background-v2
python Tools/adaptive_terrain/build_uk.py \
  --build /external/uk-build-v2 \
  --downloads /external/downloads/uk-adaptive-0p5-v2 \
  --background /external/downloads/uk-coarse-background-v2/background.json \
  --work /local/scratch/uk \
  --compiler /path/to/adaptive-compiler \
  --reuse-builds /external/park-builds \
  --reuse-downloads /external/downloads \
  --workers 10
python Tools/adaptive_terrain/verify_uk_downloads.py http://localhost:8787 \
  --local /external/downloads/uk-adaptive-0p5-v2 \
  --require-complete --output /external/uk-build-v2/http-validation.json
python Tools/adaptive_terrain/verify_uk_background.py http://localhost:8787 \
  --output /external/uk-build-v2/background-http-validation.json
```

Resume with the same build command. Plan, selection, compiler and background
identities are frozen; changed inputs require a new revision. Durable private
manifests are archived before publication, allowing recovery if a process stops
between publishing a section and updating the global catalogue. The runner
checks available disk space and retains only bounded scratch meshes. Public
assets have an nginx allowlist; source paths, build reports and locks return 404.
The final verifier hashes every local container and tests actual byte-range
retrieval for representative chunks in every section.

Corrected source revisions may declare `supersedes` in their private manifest.
Their published index retains that relation, so rebuilding the catalogue does
not re-advertise the old source. The old payload bytes remain available for
private audit; known-invalid source revisions can be withdrawn by the server.
North York Moors uses `north-york-moors-adaptive-0p5-coverage-v2` after the UK
survey-footprint check; its previous URL returns 410.
