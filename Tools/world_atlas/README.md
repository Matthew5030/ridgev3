# UK overhead map

The app's `WorldAtlas.bundle` replaces the green UK context with shaded geographic
terrain. It is a low-resolution **overview**, not additional fine LiDAR coverage.
It uses the checksum-verified existing `uk-coarse-background-v2` elevations,
retained Natural Earth coastlines/lakes/rivers, and the base palette and directional
light orientation from the current world renderer. Fine OSM mapping and adaptive
terrain still appear through the regional renderer. The overview does not invent
woodland, paths or survey coverage where those inputs have not been prepared.

The published 2026-10-04 overview contains 5,460 JPEG pages (19,064,485 bytes),
256 × 256 pixels, standard Web Mercator zooms 5–10. It includes a surrounding
rectangle so parents are complete. Elevation coverage is the United Kingdom;
Ireland and mainland Europe in that rectangle retain plain coastline context.
Only visible pages and their parents are decoded by the app, with a bounded cache.
The 19 MB download size is not the decoded/rendering memory footprint.

## Reproduce

Python dependencies: NumPy and Pillow. Build outside the repository, then copy
only `index.json` and its declared JPEG pages into `Resources/WorldAtlas.bundle`.

```sh
/tmp/ridge-world-build-env/bin/python Tools/world_atlas/build.py \
  --background '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-coarse-background-v2/background.json' \
  --atlas 'ridge v3/Resources/RidgeData.bundle/atlas.json' \
  --style 'ridge v3/World/WorldCartography.swift' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-v1'
/tmp/ridge-world-build-env/bin/python Tools/world_atlas/test_build.py
sh Tools/test_world_atlas.sh
```

A source/generator fingerprint prevents mixing revisions. Per-page verified
checkpoints allow a stopped build to resume and repair corrupt pages; the final
index is written atomically after all pages and parents exist. Shared global pixel
coordinates and neighbouring elevation samples avoid hillshade discontinuities at
tile edges. The self-contained fixture checks those shared samples, corrupt input
rejection, output dimensions and checkpoint repair. No original pack is changed.

Detailed adaptive/vector conversion is documented in `../world_source/BATCH.md`.
The archive stager hydrates retained iCloud sources into an external verified
cache; the converter reuses corrected 0.5 m fine meshes and creates the new 2 m
background and vector map pages. New detailed coverage is not automatically made
available in the shipping app by generating this overview or that catalogue.
Automatic neighbour loading and cross-source route continuity remain separate
integration work.
