# Exact terrain previews in the UK atlas

`composite_previews.py` adds native adaptive-terrain/vector-map snapshots to the
coarse UK atlas. It does not make new fine terrain routable or downloaded in the
app; it improves the overhead map where those snapshots have been generated.

```sh
/tmp/ridge-world-build-env/bin/python Tools/world_atlas/composite_previews.py \
  --base '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-v1' \
  --catalog '/Volumes/MLB_EXT_4TB/Ridge Sources/world-previews-v1-2026-10-04/catalog.json' \
  --world-root '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-detailed-v1' \
  --watch-hours 48 --reserve-gib 35
```

Omit `--watch-hours` for one frozen catalogue snapshot. The observer runs for at
most 48 hours in this command, updates only when the preview catalogue changes,
and stops after the upstream preview job finishes/pauses or free external disk
space falls below 35 GiB. `composite-status.json` records its PID and state. It
never changes files in the app bundle. A file lock prevents duplicate writers.

Each 2048px native preview is reprojected to standard Mercator z13 pages, with
actual inverse-Mercator latitude and 2× sampling before final downsampling.
Sparse z12/z11 pages and all affected z10–z5 ancestors are regenerated from their
children. Missing children come from the immutable coarse UK base; available
neighbours do not disappear. JPEG previews can contain a white matte where no
valid terrain exists, so the compositor verifies each source-manifest hash and
builds a union mask from its actual tile bounds. A two-source-pixel erosion of
that union removes JPEG matte fringes without introducing internal tile seams.

The colour images, masks, and page images share one eight-image LRU. Per-page
fingerprints include overlapping preview and source-manifest hashes. Pages and
checkpoints are written atomically; the inventory is published last. A rerun
skips unchanged pages, repairs interrupted work, and replaces changed previews.
Removed previews also remove their sparse detail pages and restore the coarse
fallback. The base source is never overwritten. Generator policy changes require
bumping `VERSION` and choosing a fresh output directory.

For publication, **stop or pause the observer first**, then copy `index.json` and
its declared images from a stable output into `Resources/WorldAtlas.bundle`.
Checkpoint/status/source-snapshot files do not belong in the application. The
2026-10-04 frozen first publication used 35 exact previews: 5,820 total pages,
22,627,562 bytes, compared with 19,064,485 bytes for the coarse base. This is
partial detailed coverage, not a complete UK fine-data conversion.

Tests:

```sh
/tmp/ridge-world-build-env/bin/python Tools/world_atlas/test_composite_previews.py
```

The fixtures check inverse-Mercator alignment, source-hole masking, incremental
no-op/update/removal, immutable base files, and the shared image-cache bound.
