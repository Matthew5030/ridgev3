# Offline adaptive terrain experiment

A bounded, reproducible two-tile comparison around Crib Goch. This tool writes only to its output directory. It neither edits source data nor changes the iOS app.

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
