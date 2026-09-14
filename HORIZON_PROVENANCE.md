# Eryri surrounding terrain

`Tools/prepare_horizon.py` adds a fixed, locally prepared surrounding landscape to the existing Eryri source. The primary 16 × 16 precision-cell grid, all six primary terrain levels, overview and detail maps, and walking graph remain byte-for-byte unchanged. Context adds no routing graph or new selectable precision coverage.

The backdrop covers approximately 27.4 × 27.4 km, extending five original parents, approximately 9.8 km, beyond each side of the primary grid. Its exact WGS84 bounds are:

| Boundary | Degrees |
|---|---:|
| West | −4.248046875 |
| East | −3.837890625 |
| South | 52.961777856604336 |
| North | 53.208100158069264 |

The 14 × 14 original-parent rectangle starts at global parent column 5999, row 3991. It uses existing prepared products from `z10-x499-y332`, `z10-x500-y332`, `z10-x501-y332`, `z10-x499-y333`, `z10-x500-y333` and `z10-x501-y333`. All 196 selected parents are available. All 364 shared valid source edges agree exactly. The result contains 12,852,225 known samples and no NoData samples, with heights from −3.0 to 1084.2 metres. This is evidence about this finite rectangle, not a guarantee of coverage elsewhere.

The read-only terrain source is:

```text
/Volumes/MLB_EXT_4TB/Project Ridge External/ridge-precision/
  england-wales-precision/products/england-wales-precision/2026.09.02-1/
  tiles/10/<x>/<y>/parents/c<column>-<row>/base/lod-8m.bin
```

Each complete tile manifest is verified against `COMPLETE.json`; every selected terrain file is verified against its recorded byte count and SHA-256. The source is the prepared Welsh Government LiDAR DTM, with 0.1 m Int16 encoding, `-32768` NoData and EGM96 / EPSG:5773 vertical datum. The original LiDAR datum and attribution remain recorded in the primary pack.

Original z10 tiles have different north/south latitude steps. Simply joining their rows into a single uniformly spaced bounds rectangle would displace geographic features by up to 4.036 source rows here. The builder therefore joins and checks the original prepared 8 m samples, then linearly interpolates only the latitude axis onto uniform WGS84 bounds. Every contributing sample must be known; an unknown sample never becomes zero or interpolated terrain. Context 16 m and 32 m files are exact nested decimations of that corrected 8 m grid. Nominal 8 m spacing measures approximately 7.643 m east/west and 7.642 m north/south at the context centre. This is preparation of existing terrain products; no raw LiDAR is reopened or processed.

## Contract and measured cost

The terrain and near/far map records below are retained for compatibility. When
the independent `cartography` atlas described below is present, the native 3D
renderer uses that atlas across all terrain bands. The legacy near/far texture
sizes no longer determine map sharpness at the terrain boundaries.

The optional `RegionManifest.horizon` object has `near` and `far` backdrops. Each contains `bounds`, `levels: [TerrainLOD]` and `textures: [MapTexture]`; height scale, NoData and vertical datum are inherited from the primary manifest. Every filename is unique within the pack. The primary `bounds`, `grid`, `levels` and `textures` retain their original meaning.

| File | Dimensions | Bytes |
|---|---:|---:|
| `horizon-near-8m.bin` | 3585 × 3585 | 25,704,450 |
| `horizon-near-16m.bin` | 1793 × 1793 | 6,429,698 |
| `horizon-far-32m.bin` | 897 × 897 | 1,609,218 |
| `horizon-near-g<column>-<row>-map.png` | 196 tiles, each 1024 × 1024 | 165,007,412 total |
| `horizon-far-g<column>-<row>-map.png` | 196 tiles, each 512 × 512 | 54,458,649 total |

The 395 legacy horizon files total **253,209,427 bytes**, including **219,466,061 bytes** of map tiles and the unchanged **33,743,366 bytes** of heightfiles. Before adding the independent atlas, the Eryri source occupied **545,235,539 bytes** and the complete bundled resources occupied **580,885,625 bytes**. These are source files on disk, not a single resident scene allocation. Context selection and scene admission belong to the native app: it crops the available backdrop around the selected area and loads a finite choice of levels. Camera movement does not fetch or refine terrain. The context cannot supply terrain outside these recorded bounds. Legacy near maps retain approximately 1.9 m per pixel and far maps approximately 3.8 m per pixel; these are compatibility images rather than the map-detail limits of the independent atlas.

The tiled maps use the same original Ridge cartography as the detailed planning area, from the six matching, already prepared OSM `.ridgetile` archives under:

```text
/Users/matthewbilella/Desktop/ProjectFatRidge/mapping/build/public/
  tiles/10/<x>/<y>/2026.08.24-2.ridgetile
```

Archive size and SHA-256 are verified before reading `map-data.ridgemap`. Feature kinds are no longer reduced for the horizon. The shared `prepare_packs.render_texture` renderer keeps the primary detail-map palette, woodland, open and access land, water, buildings, roads, dashed footpaths, bridleways, tracks, unknown paths and boundaries, together with 10 m contours, 50 m index contours and gentle relief. There are no satellite images or additional routing graph. Place labels remain native app overlays, as in the primary map.

Every tile has the exact bounds of an original prepared parent. The 16 parents overlapping the primary grid reuse the existing 4096 × 4096 detail-map master pixels, including their original contour and relief rendering. The 180 surrounding parents render through the same function at the same 4096-pixel parent scale. Their contour and relief input is a geographically sampled view of the saved 8 m context heightfield; the terrain files themselves are never changed by a map refresh. Near maps are reduced to 1024 pixels with Lanczos filtering; far maps are reduced from those same near images to 512 pixels. This retains one legend and one set of feature positions across bands, with reduced raster density only at distance. It also avoids rerendering the far map with a different line weight or palette. The larger-area primary overview remains its existing separate cartographic scale; no existing primary image is rewritten.

The builder validates all 196 tiles in each band against their original parent bounds, proves adjacency without gaps across both axes, verifies the total texture coverage equals the recorded terrain coverage, and checks that near and far bounds match exactly. Independent output checks also verified every far image equals a filtered reduction of its near image and all 16 primary overlaps equal reductions of the existing primary masters. Geographic sampling tests verify a known sloping heightfield and preservation of NoData contributors. Original z10 latitude rows have slightly different sizes; texture placement uses each map's exact geographic bounds rather than assuming uniformly spaced parent rows. The source retains **40,163 features** after exact-geometry deduplication, including 4,629 footpaths, 1,999 tracks and 161 bridleways. Distinct tile-clipped pieces of an OSM element remain intact. OSM attribution and the Open Database License remain in the pack's existing sources list.

## Reproduce and inspect

With Python 3, NumPy and Pillow installed:

```sh
python3 Tools/prepare_horizon.py
```

The command verifies inputs, stages the terrain and tiled maps, checks their hashes and dimensions, verifies every existing primary file stayed unchanged, then publishes the optional horizon in `pack.json` and `catalog.json`. It removes obsolete generated horizon assets only after the updated manifests are published. It has no network dependency and never writes to the old project or external drive. A full `prepare_grid.py` rebuild replaces the source directory; run this horizon command afterwards to restore the optional context.

To refresh cartography without reopening or rewriting prepared terrain:

```sh
python3 Tools/prepare_horizon.py --maps-only
```

This uses the existing horizon's 8 m heightfile and preserves the hashes and byte counts of all three horizon terrain files. It requires the matching saved source report so the original terrain evidence remains attached to the output.

`--stage-only` prepares and verifies without publishing. `--id`, `--margin`, `--precision` and `--old` support another existing parent-aligned grid and read-only source roots. Preparation is bounded to 18 original parents per axis. Missing processed parents remain NoData; incompatible encodings or disagreeing known seams fail explicitly. Prepared OSM archives must exist for every intersecting world tile.

The local development report `Tools/reports/eryri-grid-horizon-source.json` records all six source manifests, every terrain path/hash/bounds, source and result NoData counts, corrected sample spacing, OSM archive evidence and feature kinds, every map tile's source or reused primary image, output metadata, and all 27 preserved primary file hashes. `Tools/reports/eryri-grid-horizon-preview.png` is a reduced mosaic of the complete near-map coverage for visual review. Reports are not required at runtime and are excluded from git by the existing repository policy.

## Independent cartographic atlas

`Tools/prepare_cartography_atlas.py` adds one canonical map covering the complete
surrounding landscape. Its pixel coordinates depend on geography, not on the
selected LiDAR spacing or the primary/near/far terrain bands. The existing
primary, overview and horizon map files, all terrain levels, graph and places
remain unchanged.

The atlas divides each of the 14 × 14 original parents into 4 × 4 map cells,
giving **56 columns × 56 rows**, or **3,136 cells**. Each cell covers roughly
490 metres and contains **1,024 × 1,024 canonical pixels**, approximately
0.48 metres per pixel. Every cell also has a **64 × 64 preview** derived from
the same canonical image. Both images include **four pixels of gutter** on
every side: the saved PNG dimensions are therefore **1,032 × 1,032** and
**72 × 72** respectively. Runtime texture residency and filtering are independent
of terrain sample spacing; all source imagery is stored locally.

The native atlas PNGs total **683,498,395 bytes** and the previews total
**20,574,232 bytes**, adding **704,072,627 bytes** of imagery. With atlas metadata,
the Eryri source occupies **1,251,214,438 bytes** and the complete bundled
resources occupy **1,288,770,796 bytes**. These are disk totals; the renderer
does not load the complete native atlas into memory. The largest native PNG is
563,404 bytes and the largest preview is 11,230 bytes, below the native app's
16 MiB and 1 MiB encoded-image bounds respectively.

The optional `RegionManifest.cartography` object contains `columns`, `rows`,
`longitudeEdges`, `latitudeEdges` and row-major `tiles`. Longitude edges ascend;
latitude edges descend. Each tile contains `image: MapTexture` and
`preview: MapTexture`. Their `bounds` describe the **inner geographic cell**,
excluding gutters, while `width` and `height` include the gutters. The edge
arrays preserve the actual original-parent latitude boundaries, including the
slight change in latitude step between world tiles. Flat filenames such as
`cartography-c000-r000.png` and `cartography-c000-r000-preview.png` retain the
pack's existing safe-filename rules.

The 16 primary parents reuse their existing 4,096 × 4,096 detail-map master
pixels exactly. The remaining 180 masters use the same `render_texture`
function, palette, feature types and physical stroke scale. Their terrain
relief and contours come from the saved 8 m context grid, geographically sampled
to each parent. Existing primary masters retain their original 4 m contour and
relief input. This small provenance difference is fixed in the source map and
does not change when the user chooses a different LiDAR mesh spacing. No raw
LiDAR is processed and no terrain file is rewritten.

Full-image gutters copy actual canonical pixels from neighbouring masters,
including diagonal neighbours at corners. Only the true outside edge of
coverage uses edge clamping. Preview generation first samples a 1,280-pixel
square from the canonical landscape, including 128 pixels beyond each side of
the 1,024-pixel cell. It applies a 16:1 Lanczos reduction, then removes four
additional filter pixels on each side to retain a 72-pixel image. This extra
filter margin ensures that neighbouring previews have identical gutter pixels;
the preview is never redrawn with a separate cartographic style.

Preparation caches at most nine decoded parent masters and stores temporary
masters on disk. It never allocates a full-resolution landscape mosaic.
Verification rereads each PNG to check its hash, dimensions, exact canonical
pixels and preview reduction, and compares shared gutter strips across every
horizontal and vertical boundary. Existing asset hashes are checked before
publication. The source report records each reused or rendered master,
feature-source evidence, atlas metadata, checks and preserved-file hashes:
`Tools/reports/eryri-grid-cartography-atlas.json`.

The completed source build took **507.48 seconds**. It verified **6,272 PNG
files**, **3,136 exact canonical-image matches**, **3,136 exact preview
reductions**, and **6,160 horizontal plus 6,160 vertical shared-gutter matches**.
All **422 existing source assets** remained byte-identical, including all
primary files, all three surrounding heightfields and the existing near/far
map tiles. Synthetic checks additionally exercised diagonal parent neighbours,
true outside-edge clamping and preview filtering on noisy data. The decoded
master cache held at most nine images.

To reproduce the atlas after preparing the grid and horizon:

```sh
python3 Tools/prepare_cartography_atlas.py
```

`--stage-only` creates and verifies the atlas without updating bundled
manifests. Temporary masters are removed after successful publication; failed
or staged output remains in its dedicated staging directory for inspection.
