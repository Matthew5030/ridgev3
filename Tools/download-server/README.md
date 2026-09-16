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

## Publish adaptive Eryri

The normal `/catalog.json` uses schema 2 and advertises `ridge-adaptive-v2-eryri`.
It joins the audited UK-v3 RAT1 chunks to existing Eryri maps, walking graphs and
8/32 m surroundings without recomputing the fine terrain. Native cell edges are
retained across storage partitions. Sources have immutable IDs.

```sh
python Tools/adaptive_terrain/publish_eryri_app.py --help
```

Use the existing map source (now in `Ridge Rollback/2026-09-16/eryri-park`) as
`--maps`, the served `Ridge Sources` directory as `--root`, and `--activate`
only when ready to replace the catalogue. Without activation, publication is
staged in `catalog-adaptive-next.json`. The publisher hardlinks verified assets,
so publication must be on the same filesystem as its inputs.

The old regular-grid publisher refuses to overwrite an active adaptive catalogue.
App registration fetches the small catalogue and overview, then lazily verifies
the full selection index. Mesh and context requests must return exact HTTP 206
ranges; the client checks lengths and hashes before use. Saved scenes contain
only their selected adaptive chunks, cropped surroundings, maps and paths.

Currently Eryri is the complete map-and-routing source. The nationwide catalogue
contains terrain geometry only; other regions need map/path publication before
being advertised in the normal app. Reconnect the server after installing the
updated app. Existing offline saves remain readable.

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


## Precomputed adaptive terrain

`/adaptive-catalog.json` lists independently compressed adaptive terrain chunks.
This geometry-only catalogue is separate from the complete map sources in
`/catalog.json`. The app now has a verified RAT1 reader, but geometry alone
is insufficient for a textured, routable download.
Each source exposes `adaptive.json`, `mesh-*.rat.zlib` (or legacy `mesh-*.rmesh.zlib`), `boundary.geojson` and
`coverage-gaps.geojson`. Downloads are static files; there is no live meshing.
The publisher and format are documented in
[the adaptive tools](../adaptive_terrain/README.md#reusable-park-builds-and-compact-downloads).

The preferred RAT1 encoding losslessly reconstructs the same RME1 geometry from
subdivision decisions and heights. It reduces transfer bytes, not the resident
geometry budget. Repacked legacy URLs remain valid; the adaptive catalogue
selects one preferred encoding per landscape.

### Whole-UK terrain assets

The server also exposes `/uk-adaptive-0p5-v3/catalog.json` and
`/uk-coarse-background-v2/background.json`. The former lists independently
validated adaptive grid sections, with chunk byte ranges inside each
`terrain.ratpack`; the latter supplies separately labelled coarse background
heightfields. These remain distinct from the normal app's `/catalog.json`.
The app reads selected RAT1 ranges through complete schema-2 app sources; it
does not register this geometry-only catalogue directly.

A detailed catalogue may be published incrementally: inspect `buildComplete`.
Only completed section indices appear in it. The older unfiltered
`/uk-adaptive-0p5/` revision is no longer served because its prepared source
availability flags included unsupported terrain. The corrected source audit,
formats and verification commands are documented in
[the whole-UK tooling](../adaptive_terrain/README.md#whole-uk-terrain-downloads).
