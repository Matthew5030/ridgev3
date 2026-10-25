# Free Scottish adaptive terrain pilot

The Ben Nevis experiment uses free Copernicus GLO-30 public DSM rasters and
checksum-verified OSM semantics/routing already cached by Ridge. It does not
modify the live UK catalogue, replace existing LiDAR or use a paid service.

The area is approximately 13.4 × 13.3 km. Sixteen app-format tiles contain
989,972 fine adaptive triangles, 20 m contours, 29,616 route nodes and 149 places.
The world-source files total about 9.2 MB. Original DEM TIFFs total 54.4 MB and
remain in `~/Documents/Ridge Terrain Cache/scotland-copdem30-test-v1/dem-originals`
with URL, length and SHA-256 receipts. Cache reuse verifies these receipts.

This is a roughly 30 m **surface model**, including vegetation/buildings where
present. The 513-sample codec grids resample that surface; they do not add survey
detail. Fine mesh tolerance is 0.5 m against the resampled, decimetre-quantised
surface, not 0.5 m real-world accuracy. Background mesh tolerance is 2 m.
Copernicus heights retain their EGM2008 datum; this test is deliberately separate
from the existing UK elevation sources and does not claim a validated join to
their EGM96 heights.

All 16 fine meshes passed independent triangle-location checks at every grid
sample and cell centre; the largest measured error was approximately 0.494 m. All 24 shared
fine mesh edges matched exactly. Codec checks, ten pipeline regression tests,
and the real native app loader passed. The browser comparison decodes the same
fine meshes and provides orbit, zoom, triangle, path, contour and label controls.
Its lighting is an approximation; `native-preview.jpg` uses the actual app
renderer. No new satellite colour imagery is used in this geometry experiment.

Run from the repository with the global-source Python dependencies plus
Matplotlib and Pillow:

```sh
python Tools/global_source/scotland_test.py \
  --root "$HOME/Documents/Ridge Terrain Cache/scotland-copdem30-test-v1" \
  --archives '/Volumes/MLB_EXT_4TB/Ridge Experiments/world-source-archives-v1' \
  --viewer ../sentinel-study/scotland-test

sh Tools/test_world_batch.sh \
  "$HOME/Documents/Ridge Terrain Cache/scotland-copdem30-test-v1/world/sources/world-scotland-copdem30-ben-nevis"
```

With the existing study server running, open
<http://127.0.0.1:8786/scotland-test/>. The root's `world/validation.json` and the
browser's `report.json` retain the source checksums, attribution and validation.
The cached OSM archive has its own original survey-independent graph identities;
this pilot does not advertise connections to neighbouring published sections.

Data: [Copernicus public registry](https://registry.opendata.aws/copernicus-dem/),
[Copernicus DSM layout](https://copernicus-dem-30m.s3.amazonaws.com/readme.html).
