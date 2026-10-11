# Download areas and park groups

The app loads `ridge v3/Resources/uk-download-zones.json` (schema 3). The map
shows compact, roughly rectangular areas clipped to the coastline. National
parks are separate grouped downloads, available in search and from the area
inspector. Selecting a whole park highlights its footprint without changing the
underlying area layout.

## Area geometry

The starting point is published OS Explorer sheet coverage, plus Discoverer
coverage in Northern Ireland, from the public [map browser](https://interactive-map.dash4it.co.uk/).
The checked-in `sheet-reference.json` keeps only geographic titles and geometry;
no map imagery, branding, stock information or app code is reused. The official
[OS sheet finder](https://shop.osmaps.com/map-selector/) is the product reference.

Ridge adapts those footprints into **420 non-overlapping walking areas**. Each
original publication cell contains 3 × 3 source sections. Every section belongs
to exactly one area: prefer the reference sheet containing most of its land,
then proximity to the sheet centre. Where references do not cover offshore bins,
the nearest sheet takes ownership. An empty reference geometry is excluded.
The final outlines therefore differ from the printed sheets: borders snap to
our existing download sections and paper-sheet overlaps are removed.

Names now describe places such as Snowdon & Conwy Valley, Harlech & Bala, Dark
Peak, and White Peak. Snowdon and Tryfan remain in the same area. Northern
Ireland is labelled geographically but remains unavailable until published
terrain exists. This change does not claim additional coverage.

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

Map captions use short geographic names on at most two lines; full names remain
in the inspector. Labels fit an interior land rectangle and fade in smoothly as
there is space, avoiding overlapping captions on small coastal areas. Selected
names stay visible. Thin single borders remain, with no white border casing.

Town and city labels use the bundled OSM settlement index, independently of map
downloads. Cities appear first; towns start at a closer zoom, villages much
closer again. A screen-area budget of 5–12 visible place names plus 85-point
minimum marker separation prevents dense fields of labels. Settlement names
avoid area captions and have a subtle halo for legibility over relief.

## Reproduce

With the terrain pipeline's Shapely dependency, from the repository root:

```sh
python3 Tools/region_zones/build_zones.py --source-root '/Volumes/MLB_EXT_4TB/Ridge Sources'
python3 -m unittest discover -s Tools/region_zones -p 'test_*.py'
sh Tools/test_world_region_packs.sh
```

Inputs: the original `uk-pack-regions.json` grid, `surrounding-areas.json` grid groups, `sheet-reference.json`, 15 existing `*-adaptive-0p5/boundary.geojson` files, the published world
catalogue, and the bundled atlas. Boundary provenance and file SHA-256s are
included in the output. No server publication or cloud enablement is required.
