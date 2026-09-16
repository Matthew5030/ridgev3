# Regional offline packs

Downloading a pack stores immutable map, path and terrain assets. It does not
construct a scene and is not limited by the scene RAM allowance. The user then
chooses a smaller rectangle in Explore. Native mesh chunks, map images and
context strips are reused from the shared source cache.

## UK grouping

`build_regional_packs.py` groups the audited UK-v3 terrain and UK-v2 background
into 20 named geographic regions. It assigns each of the 674 existing storage
sections exactly once, using fixed geographic anchors. These are approximate
geographic groups, not national park or county boundaries. Names and membership
are recorded in `ridge v3/Resources/uk-pack-regions.json`. All 342 detailed
sections are retained; missing detailed survey coverage remains a gap over the
coarse background. No geometry is regenerated and assets are not duplicated.

```sh
python3 Tools/adaptive_terrain/build_regional_packs.py \
  --root '/Volumes/MLB_EXT_4TB/Ridge Sources' \
  --output 'ridge v3/Resources/uk-pack-regions.json'
```

The file is explicitly a **publication plan**, not a downloadable map catalogue.
Per-region sizes include existing fine terrain, its section indexes and coarse
background, but exclude textures and walking graphs. Do not present them as
complete download sizes. National map/path publication is still outstanding.
Eryri remains the only complete app source; it is not the entire North Wales
region. The app shows this distinction on Packs. Large future regions should
group bounded app sources, rather than increase the scene/index size limits.

## App behavior

Packs replaces the old My areas tab. Saved 3D areas remain accessible from that
page with their existing opening, import and removal actions. The available-pack
card checks the full asset list, shows missing bytes and previously saved bytes,
and offers Download/Continue download or Choose area to explore.

Whole-pack asset enumeration includes all independent textures, adaptive chunks,
walking graphs and full 8/32 m context strips. It has no geometry decoding,
texture allocation, scene folder creation or terrain-memory admission step.
Eryri currently contains 55,474 assets totalling 6,636,881,608 bytes, excluding
small catalogue/index/overview files fetched during source registration/checking.

The existing transport retains completed verified files on cancellation and
checks available storage. Transfers are foreground operations: keep Ridge open;
a retry reuses completed files. This does not add an iOS background-download
service. Removing a pack clears its source asset cache while preserving metadata,
the overview and saved 3D areas, whose hard links keep their files alive. Routes
are untouched. Consequently removing a source need not release all its storage
when saved scenes still use it.

Selecting a cached area still performs local scene preparation. The redundant
full-file hash pass after verified transport has been removed; imported local
sources still receive full verification. This is not camera-driven streaming.

## Validation

`bash Tools/test_offline_packs.sh <published-Eryri-directory>` checks the full
asset total and uses an isolated small real-data fixture (less than 40 MB) to
exercise the app download action. It checks no scene is created, cached retry
and area preparation work with an unreachable server, and removal preserves a
saved area's terrain/maps/paths. It does not download all 6.6 GB during testing.
The adaptive pack integration suite checks area selection, scene reopening,
path routing, GPX and cross-partition seams after the verification fast path.
