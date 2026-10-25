# Ridge local downloads

This serves immutable prepared terrain and map files over your home network.
It does no LiDAR processing, scene generation or route calculation. Ridge reads
the catalogue, selects data geographically as you explore, and renders the
adaptive terrain and vector maps on the device.

## Start

With the source drive connected:

```sh
sh Tools/download-server/start.sh '/Volumes/MLB_EXT_4TB/Ridge Sources'
```

The default backend is the native, read-only Python server. Docker can stay
closed; `RIDGE_DOWNLOAD_BACKEND=docker` selects the older container backend.
The script prints the Mac's `.local` address. On the same network, enter it in
Ridge → Settings → Map source → Local network, then tap **Save map source**.
Browse or search in Explore and zoom in; no region or tile selection is needed.

The app downloads missing files, verifies SHA-256 checksums and retains completed
files when a request is cancelled. Moving into a new catalogue region loads it
automatically. Keep offline pins the current area for use with the server off.

The server listens on port 8787. Set `RIDGE_DOWNLOAD_PORT` before starting to
use another port. It serves only app asset filenames, hides directories and
build reports, and accepts GET/HEAD. This is a local-network development server.

## Current adaptive/vector library

`/world/catalog.json` aliases `world-v1-2026-10-04/catalog.json` on the drive.
`/world/sources/<id>/…` exposes only world manifests, overview elevation, paths,
compressed adaptive meshes, vector map assets and optional `paths-connected-v1.json` / `paths-connected-v2.json`
routing sidecars. The completed catalogue has 5,001 source sections. Reports
and directory listings are not exposed. Native error requests are recorded in
`~/Library/Application Support/Ridge Download Server/native-server.log`.

```sh
curl http://127.0.0.1:8787/world/catalog.json
```

## Configure a development device without typing the address

Debug builds accept `RIDGE_LOCAL_TEST_SERVER` at launch. The app validates it and
saves Local network plus that address in the usual settings; subsequent launches
keep it and the user can still switch to Cloud. Release builds ignore this flag.

```sh
xcrun devicectl device process launch --device DEVICE_ID --terminate-existing \
  --environment-variables '{"RIDGE_LOCAL_TEST_SERVER":"http://Matthews-MacBook-Pro.local:8787"}' \
  Bilella-Works.ridge-v3
```

The phone must be on the server’s network and permit Ridge local-network access.
Permission sheets no longer cancel map loading; returning from the background
resumes a cancelled terrain load or reconnects a cancelled catalogue request.

## Legacy saved-area publication

The sections below describe the previous pack flow retained for older saves,
not the current Explore source selector.

### Publish adaptive Eryri

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
tail -n 30 "$HOME/Library/Application Support/Ridge Download Server/native-server.log"
python3 Tools/download-server/native_control.py stop
```

The iOS app uses [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
and a local-network usage description for explicit LAN downloads.

### Verify or repair published section packs

`audit_origin.py --report REPORT.json` checks every published section and region
pack through HTTP, including retained sections from earlier publications. A
successful geometry audit alone does not certify download availability.

`repair_pack_links.py` rebuilds unavailable section packs from cached immutable
assets. It verifies each original asset and the exact existing catalog pack
hash before replacing the broken link. `--storage` may be repeated to use both
drives with a 2 GiB reserve; `--zones` and `--priority park-eryri` repair the
selected region first. No original imagery or terrain is downloaded or changed.
Receipts and progress are saved under `--report`. Never deduplicate a source
onto a destination that resolves to the same file or directory: that replaces
the real file with a self-referencing link.


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

## Pack downloads

The app's **Packs** page now downloads a complete schema-2 source into its shared
cache without opening the whole source in 3D. Once saved, **Choose area to explore**
returns to the atlas; smaller scenes and expansions reuse downloaded files.
Downloads can be cancelled and continued. Keep Ridge open during the transfer.
Eryri is currently the available complete pack. The 20 UK regional groups shown
in the app are a publication plan: their nationwide maps and paths still need
preparation. See [regional packs](../adaptive_terrain/REGIONAL_PACKS.md).
