# Bundled UK overhead atlas

`ridge v3/Resources/WorldAtlas.bundle/index.json` describes an offline Web Mercator
XYZ pyramid. The bundle directory is copied intact by Xcode; every page remains
one normal image, not a separate image-set asset.

```json
{
  "schemaVersion": 1,
  "tileSize": 256,
  "minZoom": 5,
  "maxZoom": 10,
  "tiles": ["z5-x15-y10.jpg", "z6-x31-y20.jpg"]
}
```

Files use exactly `z{zoom}-x{x}-y{y}.jpg`. XYZ Y increases southward. `tiles`
is an inventory of existing files, not a promise that all tiles exist at each
zoom. The loader accepts keys without the `.jpg` suffix and ignores unknown
manifest fields, so generation/source/credit metadata can be included. Schema 1
requires 256px pages. Source credits must also be represented in the app's map
attribution; metadata by itself is not a visible attribution mechanism.

The atlas renders available parent pages underneath finer pages. That supports
partial coverage, different maximum zooms by region, and panning while new pages
are being decoded. Missing imagery leaves the existing vector atlas visible.
The existing detailed `WorldPreview` sits on top, preserving the camera handoff
into 3D. A snapshot's presence does not imply fine terrain is installed.

Only visible pages are decoded, off the UI thread. The selected zoom targets
256–512 logical points per page; pinch zoom scales existing pages smoothly.
At most 96 pages are requested at once and the actor cache retains at most 96
256px pages (24 MiB RGBA). During replacement the previous viewport can retain
another 24 MiB until the new images are published. No UK-sized image is decoded.
Invalid tile coordinates and arbitrary paths in a manifest are ignored.

Run `sh Tools/test_world_atlas.sh` to check projection-page selection, memory
bounds, manifest path validation, sparse coverage and parent fallbacks.
