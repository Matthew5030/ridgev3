# Textured UK overview

`texture_overview.py` draws the retained semantic OSM data directly onto the UK
hillshade. It does not depend on fine adaptive terrain conversion completing.
The close-up app still renders its vector data on the adaptive terrain; these
images are a small offline cache for the overhead map.

The source is the **verified staging cache** produced by
`../world_source/stage_archives.py`. That stager verifies the complete archive
against the descriptor before publishing it. This renderer additionally checks
archive size, manifest/descriptor identity and the semantic member's SHA-256,
size, coordinate system and bounds. Do not point it at unverified downloaded ZIPs.

All 674 staged UK sections were ready on 2026-10-04. The overview uses real
woodland, open land, access land, water, buildings, roads and paths. It retains
polygon holes. Bogs are identified using original `natural=wetland` tags and
painted muted green, not lake blue. The retained semantic vocabulary does not
contain every farmland/residential land-use category. Blank base colour does not
mean missing elevation or a downloadable detail area. Coastlines still come from
the existing geographic context, refined with elevation.

A section is rendered at 1,024 pixels (z12) with 2x antialiasing, then divided into
256px pages; z11/z10 are derived from that same image. Coarser parents use the full
UK base rectangle. Roads use the same ground widths as the native renderer:
3.35 m major roads, 2.4 m minor roads, and a 1.43 m casing addition. Fractional
pixel coverage makes distant roads naturally fade rather than rounding them up
to wide stripes. Other overview line styles and close-up vector styling are unchanged. Terrain derivatives use neighbouring source
heights and global pixel centres. Colour margins extend the clipped edge before
filtering to avoid a pale seam at source boundaries.

## Build

Use a new output revision after changing renderer, palette or inputs:

```sh
python3 Tools/world_atlas/texture_overview.py \
  --base '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-v1' \
  --background '/Volumes/MLB_EXT_4TB/Ridge Sources/uk-coarse-background-v2/background.json' \
  --atlas 'ridge v3/Resources/RidgeData.bundle/atlas.json' \
  --style 'ridge v3/World/WorldCartography.swift' \
  --archives '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/world-atlas-textured-v3'
```

Two workers process one section each, recycling after eight sections to release
memory from dense city JSON. Section checkpoints verify every output page on
resume and repair partial/corrupt images. Status is written after every section;
the final index appears only after the whole pyramid exists. Default external
disk reserve is 35 GiB. Original source files and the running adaptive conversion
are not modified.

`--section z10-x500-y333 --section z10-x501-y333` creates a regional test in its own
output revision. It still supplies the untextured UK context outside that test.

## Check and publish

```sh
python3 Tools/world_atlas/test_build.py
python3 Tools/world_atlas/test_texture_overview.py
sh Tools/test_world_atlas.sh
```

Check source count and inspect mountain, coastal and urban samples before copying
only the completed index and its declared JPEG files into `WorldAtlas.bundle`.
Remove old unlisted atlas JPEGs from the app bundle so a prior sparse preview
snapshot is not accidentally retained. Never copy an actively published pyramid.
The app's existing off-main decoder keeps at most 96 decoded pages (24 MiB), with
up to another viewport retained during replacement. Extra geographic coverage
increases the installed image cache, not the number of pages drawn at once.
