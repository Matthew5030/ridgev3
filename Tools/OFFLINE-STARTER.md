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

## Build, install and finish the release

From the `texture-study-code` checkout, after preparing the bundle:

```sh
xcodebuild -project 'ridge v3.xcodeproj' -scheme 'ridge v3' \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath '../ReleaseBuilds/1.0-4/Ridge-1.0-4.xcarchive' \
  -allowProvisioningUpdates archive
```

The prepared archive and export are under `project-ridgeV3/ReleaseBuilds/1.0-4`.
The app inside the archive is development signed and can be installed on the
registered iPhone/iPad with Xcode or `xcrun devicectl device install app` while
unlocked. The distribution export is `export/ridge v3.ipa`. Never uninstall Ridge
as part of an ordinary update; install over the existing bundle identifier so
routes and downloaded data stay in the app container. Development installations
have signing/profile expiry; they are not permanent App Store installations.

The App Store draft remains version 1.0, free, UK-only with manual release.
Description, promotional text and reviewer notes now describe four included
areas. The saved screenshot set remains eight real native captures. Product-page
wording for the offline starter is prepared in
`Release/AppStore/website-offline-update.patch` and is not yet published.

Before submission, finish the physical phone/tablet checks and final declarations,
select the processed build, and get owner approval. No successful Apple-hosted
terrain download is required for the included-only release; keep that delivery
feature disabled until separately verified. App Store review and account-service
availability still depend on Apple. Do not treat a passed upload as approval.

Included packs currently live only in the app bundle. Keep that baseline in the
first download-enabled update: removing it would remove those local maps, even
though routes and downloaded data remain. A later smaller-base release needs a
separate, tested migration/redownload flow. Enabling additional Apple coverage
alone does not require shrinking or replacing this starter bundle.

The prepared product-page patch uses zero context; from a clean website checkout,
validate it with `git apply --check --unidiff-zero /absolute/path/to/website-offline-update.patch`
before applying and reviewing the page. Publication still needs owner approval.

## Current handover, 31 October 2026

Build 1.0 (4) has uploaded, processed as VALID and been selected in the App Store
draft. It is installed on the registered iPhone and iPad. Core hardware checks
passed, including owner-confirmed airplane-mode cold opening on both devices;
native route/GPX/preview checks and the 31-check real-bundle integration results
are recorded in `Release/AppStore/evidence/offline-starter-*.json`.

The app, prepared maps, archive and IPA are local files and do not depend on an
AI subscription or a running map server. The full source library remains on
`MLB_EXT_4TB`; the prepared bundle and signed release artifacts remain under
`project-ridgeV3/ReleaseBuilds`. Keep those files: Git contains the code and
reproduction instructions, not the multi-gigabyte map payload. The development
profile currently expires on 26 October 2027; an App Store installation is still
the intended distribution path.

Remaining owner actions are content-rights confirmation, privacy publication,
approval of the prepared website copy and approval to submit App Review.
The unresolved TestFlight account/install error is not proven fixed by this
upload. Build 4 is now available to the owner's internal TestFlight group; the
phone locked before an Apple-delivered install could be verified. No App Review
submission or public launch has occurred. The saved
release setting is manual, so an approval from Apple will not launch it by itself.

The prepared website copy is applied in the isolated `website-publish` worktree
and verified in a local browser. Ridge-specific checks pass. The full website
validator stops on an unchanged Chitchat privacy-text assertion; that unrelated
page has not been changed. See `website-offline-preparation.json` for scope.
