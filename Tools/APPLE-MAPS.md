# Apple-hosted Ridge maps

Status (26 October 2026): all 100 packs are uploaded, processed and remotely
verified. Build 2 is **IN_BETA_TESTING** for the account holder in Ridge Internal.
The full existing UK library contains 5,001 sections and 26,299,553,493 packaged
bytes. A real TestFlight device download/offline check remains pending; Cloudflare
is retained until that passes. No public App Store release has been made.

## App installation

Minimum iOS: 26.0. New installations select Apple downloads. Existing local server
preferences remain available for development. `apple-maps.ridge.invalid` is an
internal resource identifier intercepted by WorldAppleAssets, never an HTTP origin.

The initial app includes the UK overview up to zoom 11, coarse elevation/context
and the Snowdon demonstration. The signed build contains 106,389,385 bytes of map
bundles; the exported internal TestFlight IPA is approximately 89 MiB. These are
local measurements, not an App Store download-size prediction. The full original
zoom-13 atlas is preserved in source. `Tools/stage_bundled_overview.py` only filters
the generated app product. Its source atlas has thousands of flat files; listing
all as sandbox input arguments exceeded macOS process limits, so the app target's
build-script dependency sandbox is disabled. This is a build-system setting, not
iOS runtime sandboxing, App Groups, transport security or map encryption.

App Group: `group.com.bilellaworks.ridge.maps`, shared by the app and the
`RidgeMapDownloader` ExtensionKit extension. The essential library is tiny;
metadata and terrain groups use on-demand delivery. Planning fetches metadata
only. Download confirmation accounts for whole geographic groups rather than
misreporting the size of an individual selected section. Apple may retain native
packs; imported sections are also held in the existing encrypted offline cache.
Allow space for both copies while the native packs remain resident.

## Full UK publication and live pack limit

The current source is `/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04`.
The folder date does not identify the latest publication: use the catalogue SHA.
The current source contains 5,001 UK sections, not worldwide coverage.

Apple's published limit is 200 packs, but this app's actual upload API returned
`STATE_ERROR.LIMIT_REACHED`, maximum 100 active background assets. The revised
publication therefore uses exactly the 100 already-created IDs: 23 metadata
packs, 76 terrain packs and one small library. No Apple pack was archived,
deleted or renamed. The largest terrain group is under 963 MB before Apple's
archive compression; actual network size is shown before a terrain download.

The Apple IDs are opaque slots, including IDs whose historical names contain
`metadata` even when they now hold terrain. The frozen `registry.json` maps
geographic groups to those IDs and records the geographic cuts. Preserve that
registry on future map updates; do not create a new namespace for each update.
The bootstrap ID is `ridge-uk-v1-metadata-081-051` and contains the essential
catalogue and section-to-pack index. It must be uploaded last. The app and
publication must agree on this ID.

`Tools/regroup_apple_assets.py` builds the bounded publication from a source
preparation plan, reusing frozen metadata files and resolved section payloads:

```sh
python3 Tools/regroup_apple_assets.py --previous /absolute/preparation \
  --slots /absolute/apple-slot-snapshot.json --output /absolute/publication
python3 Tools/prepare_apple_assets.py --output /absolute/publication --package-only
```

On later updates, also pass `--registry /absolute/current/registry.json` to keep
geographic membership stable. All 10,002 metadata/payload files were checked
against the earlier plan: their paths and SHA256 values are unchanged. The
superseded 184-pack AAR cache was removed to free space, while every original
source file, frozen metadata snapshot, manifest and checksum receipt was kept.
The old cache is reproducible; its 184-pack plan must not be uploaded again.

## Upload and TestFlight gate

App Store Connect app: **Ridge: Offline Walking Maps**, ID `6827223973`.
Installed display name remains **Ridge**. The plain listing name was unavailable.
The existing Mac upload key is used unchanged; its private key stays in Apple's
standard private_keys folder. Do not put private keys or passwords in chat,
command arguments or logs.

```sh
python3 Tools/upload_apple_assets.py --publication /absolute/publication \
  --app-id 6827223973 --key-id KEY_ID --issuer-id ISSUER_UUID
python3 Tools/verify_apple_assets.py --publication /absolute/publication \
  --app-id 6827223973 --key-id KEY_ID --issuer-id ISSUER_UUID
```

The uploader preflights the live slot budget, runs at most four transfers, waits
for Apple's processing, then uploads the bootstrap last. Durable upload intents
and version receipts support resumption. Verification checks every exact Apple
version, iOS availability, processing state, file size, local SHA256 and Apple's
transport MD5. A successful transfer alone is not a ready publication.

The internal group **Ridge Internal** contains only the account holder. Automatic
access to all builds is disabled. Build 1 was superseded during preparation;
only build 2, which uses the 100-slot bootstrap, was added after all packs
were ready and verified. Internal TestFlight uses the latest processed asset
versions automatically. External testing and App Store distribution have their
own Apple review steps; no public release is authorized by this setup.

Install through TestFlight on iOS 26+, select Apple downloads in Ridge Settings,
confirm a region download over Wi-Fi, then reopen terrain and walking routes
in airplane mode. Also check cancel, relaunch, overlap and a changed pack version.
Retain Cloudflare until a real Apple-hosted device test passes. Locally signing
or uploading the app does not prove actual Apple delivery works.

## Checks run

- Signed generic iOS build, release archive and App Store Connect export passed.
- Pilot AARs extracted with Apple's `aa`; all content sizes and hashes matched.
- Every remote AAR: exact current version, iOS, COMPLETE processing, file size,
  local SHA256 and Apple transport MD5 matched.
- Frozen registry: all 100 IDs, source membership and archive input order matched.
- 16 delivery-adapter checks using the actual extracted current-bootstrap pilot: metadata-only
  preview, group deduplication, encrypted import, current routing, offline read,
  corruption rejection, path rejection and cancellation.
- 31 existing section transfer/reuse/resume/corruption checks, using a loopback
  server on port 18787.
- 17 offline-boundary checks.

Run adapter checks after packaging/extracting the pilot:

```sh
bash Tools/test_world_apple_assets.sh /absolute/pilot/extracted
```

A fresh isolated simulator also launched and displayed the compact UK overview.
An unsigned installation now shows an actionable download error instead of
trapping inside Apple’s framework when its shared container is inaccessible.

The adapter fixture verifies app logic. It does not replace a real Apple-hosted
TestFlight download or establish that App Store review has accepted the packs.
