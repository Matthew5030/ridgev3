# Download areas and park groups

The app loads `ridge v3/Resources/uk-download-zones.json` (schema 3). The map
shows compact, roughly rectangular areas clipped to the coastline. National
parks are separate grouped downloads, available in search and from the area
inspector. Selecting a whole park highlights its footprint without changing the
underlying area layout.

## Area geometry

Each original publication cell contains 3 × 3 source sections. Sections are
collected into blocks of 5 × 5, typically around 35–40 km across. Tiny coastal
remnants join a neighbouring block instead of becoming standalone slivers.
There are 279 area definitions, of which 244 have land footprints. Empty offshore
areas are hidden. Every published source remains in exactly one map area.

Map shapes use the bundled Natural Earth coastline. Individual missing terrain
tiles do not carve holes into the selection map: these are geographic download
areas, not survey-coverage polygons. Availability and byte estimates still come
from the connected server's published catalogue. Downloads only request files
that actually exist in each manifest.

## Park downloads and saved files

The 15 park groups independently select source sections touching their existing
OSM boundary. They do not inherit entire rectangular areas, which would add
unnecessary surrounding countryside. Boundary sections may be shared by parks;
SHA-addressed files are reused, and saved-state counting supports overlapping
groups. Coverage, routes and cached downloads are not rebuilt or invalidated.

## Labels

Area names use a geographic name and a compass suffix, at most two lines. Full
names remain in the inspector. Label anchors are computed on land, but visibility
is based on the area's screen size rather than trying to fit the entire text in
a thin coastline fragment. Labels scale smoothly from 15 to 24 points; the selected
area's name is always shown. At country scale, labels fade to avoid a wall of text.
Thin single borders remain; there is no white border casing.

## Reproduce

With the terrain pipeline's Shapely dependency, from the repository root:

```sh
python3 Tools/region_zones/build_zones.py --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
python3 -m unittest discover -s Tools/region_zones -p 'test_*.py'
sh Tools/test_world_region_packs.sh
```

Inputs: the original `uk-pack-regions.json` grid, `surrounding-areas.json` naming
bands, 15 existing `*-adaptive-0p5/boundary.geojson` files, the published world
catalogue, and the bundled atlas. Boundary provenance and file SHA-256s are
included in the output. No server publication or cloud enablement is required.
