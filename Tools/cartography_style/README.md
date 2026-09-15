# Ridge landscape style: evidence and preview

This is a **candidate style**, not a published pack or application change. It is entirely deterministic Python/Pillow/NumPy cartography. It uses no AI-generated textures, habitat inference, satellite imagery or new LiDAR processing.

## Visual approach

Use the preserved OpenStreetMap `source.tags` to distinguish grassland, heath, scrub, woodland, bare rock, scree, sand, shingle and wetlands. Give each a restrained colour and, where useful, a sparse cartographic pattern. Patterns indicate a mapped class; they are not observed individual rocks, reeds or trees.

Use LiDAR elevation for a continuous green/oat/grey background tint, and slope/aspect only for gentle relief shading. Elevation tint means **height**, not vegetation or geology. Do not turn steep slopes into mapped cliffs, infer scree from high altitude, or infer dryness, snow, tree lines or access. Unknown land cover keeps the neutral elevation tint. Latitude is a coordinate for positioning data, not a habitat classifier.

`style.json` is the candidate palette and legend source. Fixed elevation stops avoid neighbouring tiles independently choosing their colour ranges. Pattern locations use a fixed world-coordinate lattice. Correct polygon holes preserve the land underneath. The test uses the same four Crib Goch source cells and the same terrain geometry, camera, lighting, resolution and 16× sampler settings as the prior texture lab. **The comparison baseline is now the previous style at 2×**, so the difference shown is styling rather than pixel count. Every candidate cell is 2× throughout.

Patterns, tint and shading are baked before ASTC encoding. At a fixed texture size, they add no extra texture layers or terrain vertices in the app. Visual complexity may increase compressed download sizes and ASTC colour error, so measure again after the style is agreed. The renderer still uses the existing contour and path geometry. It cannot smooth inaccuracies inherent in those source lines.

## What the existing source actually contains

Inspected archive: normal app's Snowdon source, z10 500/333, revision 2026.08.24-2, SHA-256 `f782c752241870eda521f4d20d0e32fb876434abcff5822977c213a0c7401f03`.

It has 30,514 retained feature pieces across 14 coarse kinds. Raw OSM tags are preserved inside each feature. The current renderer uses mostly `kind`, leaving useful distinctions unused. There are 1,250 `natural=bare_rock`, 833 `natural=scree`, 176 `natural=heath` and 325 `natural=wetland` pieces. These are clipped pieces, not unique OSM objects or surface-area measurements. `audit.py` records the full retained-tag inventory without guessing missing values.

Two concrete current issues:

- Rock, scree, heath and grass largely share the same `openLand` paint.
- Wetlands share `water` with lakes and can be rendered as solid blue water.

The two application legends are independently hardcoded and incomplete; the planner's generic path swatch also differs from the renderer. Replace them with the same versioned style/legend manifest once the style is accepted.

## Legend and data coverage plan

The preview implements the land-cover palette and existing contours/lines. The remaining items below are **planned**, not claimed as implemented or present everywhere.

| Family | Legend / inspection entries | Evidence and treatment |
| --- | --- | --- |
| Relief | Elevation tint, 10 m contours, 50 m index contours, elevation labels | From prepared heightfield. Height colours explicitly labelled as height. Labels collision-managed at useful scales. |
| Land cover | Grass/meadow, heath, scrub, woodland, bare rock, scree, sand, shingle, wetland, unknown cover | Preserved OSM tags; unknown remains unknown. Add farmland/orchards and woodland subtypes only where imported. |
| Water | Open water, streams/rivers, wetlands, coastline, intermittent water, crossings | Preserve natural/water/waterway/wetland/intermittent/tidal distinctions. Do not turn wetlands into lakes or culverts into surface streams. |
| Ways | Road classes, track, footpath, bridleway, steps, unclassified way, rail | Keep highway subtype; source currently collapses several. Steps and rail need explicit style rules and ingestion review. |
| Crossings / obstacles | Bridges, tunnels, fords, gates, stiles, walls, fences, cliffs | Evidence only. Some way bridge/tunnel/ford tags survive; many standalone obstacle/cliff features are dropped by the earlier classifier. |
| Access | Explicit mapped designations, permissive, private/no access, unknown; conditional restrictions | Keep raw access/foot/horse/bicycle/designation/conditional tags separately. A mapped path or `foot=yes` alone is not a definitive public right of way. Access overlay must not replace land-cover fill. |
| Walking attributes | Surface, smoothness, track grade, SAC scale, trail visibility | Show on selecting a way, rather than painting every attribute simultaneously. Difficulty and visibility are separate; absent is unknown. |
| Places / facilities | Named peaks and elevations, settlements, passes, parking, toilets, water points, shelters, campsites | Preserve names including Welsh/English. Peak/settlement records already exist; standalone amenities and passes need ingestion expansion. Drinking water must be explicitly tagged, not inferred from a stream. |
| Route planning | Planned route, waypoints, start/end, manual versus followed segments, overview versus detailed coverage | App state rather than OSM. Keep separate from the base-map symbology. |

Keep the visible legend compact by grouping families and showing symbols applicable to the downloaded area. Offer a complete legend and tap-to-inspect details. Paint and legend samples should come from one style specification, so their colours, dash spacing and meanings cannot drift apart.

## Preserve data without displaying every tag

“All possible OSM data” is open-ended. Define an explicit supported feature list, preserve raw tags on selected features, and report what is omitted. The original `mapping/converter/transformer.py` discards unsupported kinds and geometry types **before** packs are written. For example, a bare `natural=cliff` line, a parking polygon or a standalone gate is not covered by the current classifier. Reading existing packs cannot restore those missing objects; re-extract the relevant OSM features from the retained raw source when expanding coverage. This is separate from the unchanged LiDAR meshes.

For a production build, emit counts for each stage: source features selected, retained, rendered, available only in inspection, deliberately omitted, unsupported, and invalid geometry. Fail or flag unhandled supported categories. Preserve IDs, source revision and tag evidence. Keep distinct feature semantics even where zoom-level generalisation uses the same symbol. Do not use the preview's broad fallback categories as a new routing or access classifier.

## Run the preview

Use the Python environment and ASTC encoder documented in `Tools/texture_lab/README.md`:

```sh
python Tools/cartography_style/preview.py \
  --source '/Volumes/MLB_EXT_4TB/Ridge Sources/eryri-park' \
  --baseline '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-landcover-style-v1' \
  --encoder /tmp/ridge-astcenc-5.7.0/bin/astcenc
/tmp/ridge-texture-lab-render '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-landcover-style-v1'
python Tools/texture_lab/verify.py '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-landcover-style-v1'
python Tools/cartography_style/audit.py SOURCE.ridgetile OUTPUT/source-audit.json
```

Large artifacts stay on the external drive. `source.json` records the style checksum, source features, compression error and unchanged geometry hashes. `gpu.json` records native Metal allocations. This is a Mac preview, not physical iPad validation. Before publishing, validate seams, invalid height boundaries, overlapping land-cover precedence, coastline/tunnel rendering, line contrast, and label density on a larger area with woodland and wetland as well as the ridge. The Crib Goch sample cannot exercise every legend class.

Sources: [OSM scree](https://wiki.openstreetmap.org/wiki/Tag:natural%3Dscree), [heath](https://wiki.openstreetmap.org/wiki/Tag:natural%3Dheath), [SAC scale](https://wiki.openstreetmap.org/wiki/Key:sac_scale), and the inspected local converter/source records. Map data © OpenStreetMap contributors; retain the existing LiDAR source attribution on derived packs.

## Preview verification — 15 September 2026

The native Metal ASTC texture still allocates 22,380,544 bytes (21.34 MiB), with unchanged geometry hashes. Flat Metal readbacks match the HD PNG and Arm ASTC CPU reference exactly. In the close terrain view, ASTC versus uncompressed candidate style has mean absolute channel error 0.01135/255 and maximum 10/255. The full flat source's ASTC mean error is 0.00928/255 and maximum 18/255. The small average error does not guarantee every fine symbol is lossless.

Semantic checks confirmed that unclassified open land does not become rock, explicit wetland stays distinct from water, and bare rock uses the actual source tag. Polygon-hole and deterministic-pattern checks passed. The four-cell sample contains real land-cover boundaries; their sharper colour transitions are mapped polygon edges, not inferred bands.

Generated remote-review images: `style-comparison.jpg` (old/new at matching 2× resolution) and `legend-preview.png` in the experiment directory. This legend image shows the candidate land-cover subset; full navigation symbology remains the implementation plan above.

## Material direction — supersedes the symbol preview

The user rejected the flat fill and repeated-symbol treatment. `materials.py` is a new candidate with **no land-cover icons**: continuous grass, rock and scree materials; multi-scale world-coordinate colour/grain; subtle mineral streaks; and stronger relief lighting. The tiny grain/streaks are synthetic appearance, not real surveyed objects. The LiDAR and mapped land-cover placement are reused unchanged. Real heightfield differences supply local cavity shading. A small 1.2 m mask feather softens polygon edges; it is a visual treatment, not higher-resolution land-cover evidence.

Use the same preview command with `--materials` and output `Crib-Goch-materials-v1`. The baseline for this run is `Crib-Goch-landcover-style-v1`, so its `current` images show the rejected symbol treatment at the same 2× resolution. Render with `/tmp/ridge-texture-lab-render OUTPUT --material-lighting` to enable the warmer directional light and cooler ambient fill on the candidate only. Default renderer behaviour is preserved for earlier studies. Geometry and cameras stay identical; **style and lighting both change** in this comparison.

The immersive material pass hides contours and makes path lines thinner. `--contours` enables a quiet contour overlay for a planning-style comparison. The navigation lines still depict mapped ways; the materials do not fabricate physical dirt trails. This CLI option is not yet an app setting. The app's production renderer and packs are unchanged.

Python dependencies now include SciPy (`scipy.ndimage.gaussian_filter`) for weighted heightfield smoothing. Run `python Tools/cartography_style/test_materials.py` for world-coordinate noise continuity, repeatability and immutable input height checks.

Actual Apple M4 Pro results: ASTC allocation remains **21.34 MiB**; the close-view GPU render pass is about **0.151 ms** (small isolated test, not physical iPad profiling). Full flat GPU readbacks again match the original and ASTC CPU reference exactly. Candidate compressed versus uncompressed close render: mean absolute channel error **0.0705/255**, maximum **6/255**. Full texture compression error: mean **0.1461/255**, maximum **10/255**.

**Storage tradeoff:** high-frequency material variation compresses less efficiently. Zlib-compressed ASTC mip files total **21.01 MB** for this ~1 km² sample, versus ~7.23 MB in the original simple-map texture experiment. GPU allocation is unchanged, but this fully baked prototype is not the proposed nationwide distribution format. Before rollout, evaluate a small shared material texture library plus compact per-area land-cover masks and separate cartographic ink. That can avoid storing unique material grain for every square kilometre, but changes the app shader and requires a new measured GPU budget. Do not promise the same memory or these timings for that unimplemented architecture.

Generated native screenshots are in `/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-materials-v1`: `close-astc.png` and `wide-astc.png`. Existing geometry hash checks and ASTC readback verification pass. The candidate needs visual approval and larger-area seam/missing-data checks before any production integration or reprocessing.

## Transition study — material v2

The user rejected the harsh cut-out boundaries and coarse noise of material v1. Material v2 normalizes neighbouring material weights across a roughly **24 m visual band** (12 m each side, with minor deterministic variation), reduces grass/rock hue contrast and coarse grain, removes repeated vein marks, and reduces baked cavity contrast. Source polygons, terrain, paths and hard water/building masks remain unchanged; the blending is a rendering choice, not more precise survey evidence. Tests cover bounded complementary transition weights, untouched source arrays, and world-noise determinism.

Generate using `--materials`, baseline `Crib-Goch-materials-v1`, output `Crib-Goch-materials-v2`. Render with `--material-lighting-all` so both previous and candidate materials receive identical illumination. The test renderer's previous options/default behaviour remain available. Native ASTC and RGBA readbacks are checked with the existing verifier.

Visual assessment: edges are less abrupt, but the result is still too soft/painted for the user's desired game-like terrain. **Do not treat this as an accepted final style.** Stop increasing baked colour noise. The next useful experiment is a small set of reusable material albedo/normal/roughness maps with compact per-area masks, terrain-aware/triplanar sampling, subtle normal strength and preserved map ink. Material normals would change lighting, not measured geometry. This is a proposed next experiment, not implemented functionality or measured memory usage. Water/building boundaries and route semantics need distinct handling; avoid using the broad blend as an access/land-cover query.

This remains isolated from the production application. No nationwide reprocessing has started.

## Illustrated / matte experiment

The user requested a deliberately stylized, deliverable direction instead of semi-realistic materials. `illustrated.py` removes **all noise, icons and baked relief shading**. It uses a small sage/warm-stone/blue palette, quiet source-driven land-cover tints and the normalized soft transitions. Water/building geometry and mapped line positions remain fixed. Optional `--contours` draws understated planning contours; the reviewed screenshots use contours off. Geometry positions, normals, indices and camera are unchanged from the original texture lab.

Reproduce with the existing preview command using `--illustrated` instead of `--materials`, baseline `Crib-Goch-materials-v2`, output `Crib-Goch-illustrated-v1`. `--illustrated` and `--materials` are mutually exclusive. Compile the updated Swift test renderer, then:

```sh
/tmp/ridge-texture-lab-render '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-illustrated-v1' --material-lighting-all --illustrated-lighting
python Tools/texture_lab/verify.py '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-illustrated-v1'
```

The candidate uses soft stepped diffuse illumination (two smooth lighting transitions), cool shadow tint and warm sunlight, plus a blue-to-pale sky gradient. The `current` variant retains the previous material lighting; all views share the sky. This is a comparison of **art direction including lighting**, not an isolated texture-resolution or timing comparison. The sky is a background draw, not haze obscuring the terrain. No cast-shadow, displacement, new mesh or physical vegetation system is claimed.

Apple M4 Pro results: **21.34 MiB** ASTC texture allocation, **4.53 MiB** unchanged geometry allocation, ~**0.159 ms** isolated close-view GPU render pass including the background. ASTC mip bundle compresses with zlib to **2,315,153 bytes**, much less than the earlier noisy material-v1 test's 21,008,932 bytes. This is a measured ~1 km² sample, not a nationwide size prediction.

Flat GPU readbacks exactly match both the HD source and Arm's ASTC CPU reference. Candidate ASTC versus uncompressed close-view mean absolute colour-channel difference is **0.000925/255**, maximum **2/255**. Constant-elevation unknown terrain is verified as a uniform matte colour (no noise), with deterministic rerendering and unchanged height inputs. No physical iPad testing or production integration has occurred.

Remote-review screenshots: `close-astc.png` and `wide-astc.png` in the illustrated experiment directory. The overview is the deliberately small fixed test cutout, not a change to the app's horizon. This remains a candidate awaiting the user's visual assessment; no UK rebuild has started.
