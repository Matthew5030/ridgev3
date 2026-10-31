# Offline starter release

The starter selection is versioned in `Release/AppStore/offline-starter-plan.json`:
Eryri, Lake District, Peak District, and Chilterns & Thames Valley. The original
full UK source and all Apple pack IDs/publications remain intact.

Prepare the immutable app resource (outside Git):

```sh
python3 Tools/prepare_offline_starter.py \
  --source '/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04' \
  --output '../ReleaseBuilds/offline-starter/OfflineMaps.bundle'
bash Tools/test_world_offline_starter.sh "$PWD/../ReleaseBuilds/offline-starter/OfflineMaps.bundle"
```

The preparer checks source/selection fingerprints, every section pack SHA256,
every decompressed entry SHA256 and the presence of all required terrain, map,
overview and connected routing assets. It records unavailable boundary cells
instead of inventing coverage. A receipt is written beside the resource.

The build phase stages that resource before signing. Override its default path
with the Xcode build setting `RIDGE_OFFLINE_MAPS_BUNDLE` when required. Payload
files stay out of Git. A source checkout needs the external map library or a
verified prepared bundle to reproduce the full app. No map server is required.

Bundled terrain is read directly through the existing bounded section reader,
without importing gigabytes into the encrypted download cache. Cache removal
cannot remove bundled terrain. Existing saved routes, internal map URLs, section
identities, graph format and downloaded pack references remain compatible.
Installed downloaded packs take precedence over the immutable baseline.

## Enabling Apple storage in a later release

1. Keep the same bundle identifier, section IDs and catalogue-relative URLs.
   Do not change the current Apple pack registry or bootstrap ID to version maps.
2. After a successful real Apple-hosted download/offline test, set
   `RidgeAppleDownloadsEnabled`, `BAHasManagedAssetPacks` and `BAUsesAppleHosting`
   to true in `Config/RidgeInfo.plist`.
3. Restore the app target dependency `7319DA30FF9AA23BFEA654DD` and embed phase
   `6EE7DF89CA521F915F8E167F` in `ridge v3.xcodeproj/project.pbxproj`. The downloader
   target, its code, its entitlements and the Apple backend remain in the project.
4. Retain the included baseline while validating upgrades, and test a fresh app,
   an upgrade with saved routes, a changed section version, cancellation/resume,
   cache removal, and cold offline reopen. Cached/downloaded newer manifests
   must agree with the catalogue's routing and pack hashes.
5. Approve the required Apple asset versions and update coverage/listing text.
   An App Store release remains a deliberate owner action.

The release flag prevents the first release from probing Apple's asset manager
on startup. Adding nationwide coverage later does not require replacing routes
or reinstalling the app. Do not promise those downloads until delivery passes.

## Reproduce the submitted build

Use the frozen source commit `2fc50df5a` (PR #12), with the prepared starter
resource available. The submitted build used this archive configuration:

```sh
xcodebuild -project 'ridge v3.xcodeproj' -scheme 'ridge v3' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath '/Volumes/MLB_EXT_4TB/Ridge Releases/1.0-6/derived' \
  -archivePath '/Volumes/MLB_EXT_4TB/Ridge Releases/1.0-6/Ridge-1.0-6.xcarchive' \
  CURRENT_PROJECT_VERSION=6 \
  RIDGE_OFFLINE_MAPS_BUNDLE='/Volumes/MLB_EXT_4TB/Ridge Releases/offline-starter/OfflineMaps.bundle' \
  -allowProvisioningUpdates archive
```

The archive app is development signed for registered devices; the App Store
export is `1.0-6/export/ridge v3.ipa` under the same external release directory.
Install ordinary development updates over the existing bundle identifier to
preserve routes and saved data. Keep enough Mac temporary space for export:
Xcode's distribution pipeline uses its user temporary directory even when the
archive and final IPA are on the external drive. Future uploads need a build
number higher than 6.

Retain the four included areas in the first download-enabled update. Additional
Apple-hosted coverage does not require shrinking or replacing that baseline.
A later smaller-base release needs a separate tested migration/redownload flow.
The product, support and privacy updates are already published; the original
website patch is a historical preparation record.

## Current handover, 31 October 2026

Build **1.0 (6)** is submitted to App Review with **AFTER_APPROVAL** automatic
release. Its source is `2fc50df5a` on `codex/save-route-and-exit` (GitHub PR #12).
It retains the bundled offline baseline, the owner-accepted two-finger tilt fix,
and the Explore save/exit confirmation. An unchanged saved route exits directly;
unfinished edits can be saved, discarded or kept open. Saves run off the main
actor; failed writes retain the editor, and leaving keeps the resident map.

The owner accepted final bundled-build UAT on iPhone/iPad and the gesture fix on
build 5. The owner explicitly chose to skip the final physical-phone check of
build 6 after the Mac connection failed. Build 6 passed 34 route-exit, 33 catalogue
and 473 gesture/camera checks, GitHub workflow 41237756727, native archive/export,
strict signature verification, Apple validation and upload. Its selected build,
review receipt and automatic release setting were verified through Apple’s API.
See `Release/AppStore/evidence/app-store-submission-build6-2026-10-31.json` and
`build6-release.json` for the current record. Build 4’s earlier submission was
canceled; build 5 was not submitted. Public availability still depends on Apple.

The four-area product/support/privacy pages are published and say Awaiting Apple
review. Free UK pricing, eight screenshot uploads, published privacy responses
and the owner-confirmed third-party content rights remain unchanged. The exact
listing and review notes are in `Release/AppStore/submitted-1.0-6-en-GB.json`.
Ongoing working-tree changes for future features were excluded from this binary.

The app works without an AI subscription or a running map server. Keep the full
UK source and prepared starter payload: Git contains code and instructions,
not the multi-gigabyte maps. Release archives/exports for builds 3–6 and the
prepared starter now live under `/Volumes/MLB_EXT_4TB/Ridge Releases`; original
`ReleaseBuilds` paths remain as links. The external drive is needed to reproduce
the bundled build, not to use the installed app. Build 6 was archived with the
explicit settings `CURRENT_PROJECT_VERSION=6` and `RIDGE_OFFLINE_MAPS_BUNDLE`
pointing to the prepared resource. Increment the build number for future uploads.

The TestFlight “not available” failure remains unconfirmed and unresolved.
Keep Apple Support case 103009501518 open independently. Raw device logs and the
unsent follow-up remain private outside Git; no new support message was sent.
Future Apple-hosted map downloads remain disabled until delivery passes a real
Apple-hosted download and cold-offline test. Keep the included baseline and
existing IDs when enabling that later feature.
