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
