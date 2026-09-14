# Ridge local downloads

This serves immutable prepared terrain and map files over your home network.
It does no LiDAR processing, scene generation, route calculation or camera
streaming. The app downloads the selected detail, its bounded horizon, map
images and walking graph, then prepares the normal offline 3D area.

## Start

With Docker Desktop running and the source drive connected:

```sh
sh Tools/download-server/start.sh '/Volumes/MLB_EXT_4TB/Ridge Sources'
```

Allow Docker's macOS removable-volume prompt. The data mount is read-only.
The script prints the Mac's `.local` address. On the same network, enter it in
Ridge → Settings → Download server → Connect and refresh coverage. Return to
the map, select highlighted tiles and tap **Download & open in 3D**.

The app connects explicitly, downloads only missing files, verifies their
SHA-256 checksums and retains completed files when a download is cancelled.
Download and terrain-preparation progress have separate labels. Moving the
camera never makes requests. Previously saved areas open with the server off.

The server listens on port 8787. Set `RIDGE_DOWNLOAD_PORT` before starting to
use another port. It serves only app asset filenames, hides directories and
build reports, and accepts GET/HEAD. This is a local-network development server.

## Prepare and publish Eryri

Use the existing preparation Python environment with NumPy, Pillow and Shapely:

```sh
python Tools/prepare_park_source.py \
  --boundary '/Volumes/MLB_EXT_4TB/Ridge Experiments/Eryri-adaptive-0p5/boundary.geojson' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Sources/eryri-park' \
  --workers 6
python Tools/download-server/publish_catalog.py '/Volumes/MLB_EXT_4TB/Ridge Sources'
```

The first command reads prepared 1 m heightfields and OSM archives. It creates
a uniform selection grid, independently stored height tiles, cartography,
walking graphs and one overview image. It does not alter original data or
compile an experimental adaptive renderer. Missing LiDAR stays unavailable.
The 4 m default and existing finer/coarser choices remain in the normal app.

The build resumes completed tiles while an unpublished build is in progress. Published source folders are immutable; a new output folder name becomes the next source identifier. `pack.json` is published only after all
assets and terrain seams are checked. The second command publishes the small
server catalogue. Until then the app reports that the server has no published
terrain, rather than advertising a partly generated park.

Published sources are immutable: use a new source identifier for a new data
revision. The app rejects replacing an existing source index, preserving maps
referenced by saved areas. Source caches live in `Documents/RidgeSources`;
saved crops reference those cached maps and own their selected heightfields.

## Checks and shutdown

```sh
curl http://127.0.0.1:8787/health
curl http://127.0.0.1:8787/catalog.json
docker compose -f "$HOME/Library/Application Support/Ridge Download Server/compose.yaml" logs --tail 30
docker compose -f "$HOME/Library/Application Support/Ridge Download Server/compose.yaml" down
```

The read-only bind mount and port configuration follow the [Docker Compose
service reference](https://docs.docker.com/reference/compose-file/services/).
The iOS app uses [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
and a local-network usage description for explicit LAN downloads.
