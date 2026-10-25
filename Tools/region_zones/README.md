# Download areas

The app now loads **84 coast-clipped blocks** from
`ridge v3/Resources/uk-download-zones.json` (schema 3,
revision `coastal-blocks-2026-10-18`). These are the reviewed larger areas from
the browser preview, including 15 national parks and surrounding countryside.
Park regions appear directly on the map; selecting one already includes its
whole prepared park footprint, so there is no second overlapping park boundary.

## Display ownership and downloads

`cells` has one unique owner per source section and controls map selection and
visible coverage. `mapShapes` clips those cells to the coastline. `downloadCells`,
when present, includes both the displayed block and every original park edge
section. Shared source IDs use the same cached files and count toward each
region's saved state without duplicate transfers. The Explore destination stays
inside the displayed area even if a neighbouring park edge is cached too.

The loader validates that download sections are known, unique, have unchanged
bounds, and include every displayed section. Red coverage masks and download
availability come from the live/cached server catalogue, not frozen preview
statistics. Recutting the selection map does not add missing terrain.

Existing section bundles remain usable. A regional archive is selected only
when its source-ID set matches the entire requested download. In particular,
the old Eryri pilot archive is not offered as a complete download of the larger
Eryri block. Until new archives are built, these areas use existing section
bundles with the same progress, resume, offline and repair behaviour.

## Reproduce

`baseline-download-zones.json` preserves the previous 420-area index as an
immutable geometry input and legacy archive regression fixture. It is not
bundled in the iOS app. `preview_large_areas.py` reads that baseline, the curated
anchors, atlas and current catalogue; it never reads its own app output.

```sh
python Tools/region_zones/preview_large_areas.py \
  --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
# After reviewing the preview, export its boundaries and membership to the app:
python Tools/region_zones/install_large_areas.py
python -m unittest discover -s Tools/region_zones -p 'test_*.py'
sh Tools/test_world_region_packs.sh
sh Tools/test_world_region_archive.sh
```

The export strips preview-only statistics and coverage flags, adds park artwork
and user-facing descriptions, and records the reviewed layout SHA-256. The
legacy `build_zones.py` requires an explicit output path so it cannot silently
restore the old 420-area app resource.

The original baseline adapted published OS walking-map sheet footprints into
non-overlapping source ownership. Its retained references are geometry and
place names, not map imagery or branding. The revised blocks use straight
shared cuts, the bundled Natural Earth coastline, and recorded coastal repairs.
See `LARGER-AREAS-PREVIEW.md` for geometry and coverage-audit details.

## Verification

Native regional tests cover exact 84-area loading, all park edge sections,
invalid memberships, single map ownership, download cache reuse, progress,
partial coverage, offline rendering, corruption repair and pause/resume.
Legacy archive tests use the frozen baseline to verify existing archives remain
readable. App integration does not republish source files or enable cloud access.
