# Release preparation evidence, 30 October 2026

## Current candidate: offline starter, build 4 (31 October)

This supersedes the build-3 download-dependent launch plan below. Four selected
walking areas are now included in the app: Eryri, Lake District, Peak District,
and Chilterns & Thames Valley. The full UK library and Apple delivery source are
preserved for a future update. See `Tools/OFFLINE-STARTER.md` and the
`offline-starter-*` evidence files for the current release candidate.

- Prepared 282 sections / 67,987 tiles; every pack and decompressed entry checksum
  passed. No missing land rectangles in the four current selection shapes.
- 31 offline-starter integration checks, 16 Apple delivery adapter checks and
  17 offline-boundary checks pass (64 checks total). The starter suite calculates
  a real walking route across two Chilterns sections with networking disabled.
- Final build 4 is signed and exported: 2,971,448,163 app bytes, below 4 GB.
  Strict archive signature verification and Apple distribution validation passed.
  The exact 2,847,849,543-byte IPA uploaded successfully; its SHA256 and delivery
  UUID are in `evidence/offline-starter-release.json`. Apple processing is VALID;
  build 4 is selected for the version 1.0 draft.
- Native Simulator checks verified first open, the included-map walkthrough and
  the refined four-area map without the red unavailable-UK overlay.
- The listing and review notes are saved in App Store Connect for this coverage.
- App Review submission succeeded on 31 October at 18:43:26 UTC for build 4;
  Apple reports WAITING_FOR_REVIEW. The owner subsequently requested automatic
  release, saved and API-verified as AFTER_APPROVAL. Submission ID:
  `8d46cb3f-7210-4809-821f-e690ce7a24d3`. Public release has not occurred.
  Successful Apple-hosted
  downloads are a gate for enabling that future feature, not the starter release.
- Build 4 is installed over the existing app on both physical devices. iPad
  Lake District terrain, route creation/save/catalogue reopen, GPX export and
  reimport, and preview completion/scrubbing/exit were observed. The owner
  confirmed the longer iPhone route/preview and airplane-mode cold reopening
  into detailed terrain on both devices. Existing iPad routes remain visible.
- All four GitHub checks passed for the production-source candidate. The native
  evidence distinguishes observed checks from owner-reported checks.
- TestFlight build 1.0 (4) is VALID / IN_BETA_TESTING, in the internal group with
  an ACCEPTED tester. The owner's screenshot confirms build 4 and compatibility;
  the owner reports the same “not available” error after tapping Install.
  The included-only payload has therefore not resolved Apple-delivered install
  failure. Native Console captured the failed retry at 16:12:22.199445 UTC:
  `Error Downloading Install Data`, `ProcessingInstallInitiateResponse`, no
  download progress, TF error `-1` / `serverCode=200` (not independently verified
  as an HTTP status). The underlying cause remains unconfirmed. The redacted
  evidence is in `evidence/testflight-build4-install-failure.json`; raw logs remain
  private outside Git. Keep case 103009501518 open; the updated friendly support
  draft has not been sent.
- Removed the temporary local-download test CA trust, certificate, test identity
  and generated private keys. The phone had no installed test profile.
- The owner accepted final iPhone UAT and explicitly confirmed both final Apple
  declarations and submission. Privacy is published (Device ID and Other Usage
  Data, app functionality, linked, no tracking); Content Rights is saved as
  USES_THIRD_PARTY_CONTENT. Free UK pricing and all eight COMPLETE screenshots
  were verified. App Information still identifies the developer as a trader.
- Matching product, support and privacy pages are published; the public website
  now says Awaiting Apple review. The full static-site validator passes. See
  `evidence/app-store-submission-2026-10-31.json` for the submission receipt.
- Free Apps Agreement is active. Business also displays an updated Paid
  Applications Schedule for the Account Holder to review; no paid agreement
  was accepted as part of this free-app submission.

## Historical preparation for build 3


## Completed

- English (UK) name, subtitle, description, promotional text, keywords, support
  URL, marketing URL, copyright and review notes saved in App Store Connect;
  exact copy checked again through Apple's API on 30 October.
- Navigation primary category, Travel secondary category; Apple calculated and
  saved a 4+ content rating. Not designated Made for Kids.
- Free price schedule and manual release saved. Mac and Vision Pro compatibility
  distribution disabled for this iPhone/iPad launch. UK-only availability saved
  as the proposed initial territory; Apple shows Available on App Release.
  No pre-order was created.
- No sign-in requirement. Reviewer name, email and the phone supplied privately
  by the owner are saved and verified. Private contact values are excluded here.
- Complete privacy questionnaire saved as an unpublished draft: Device ID and
  Other Usage Data, App Functionality only, device-linked, no tracking. The
  product-page preview and signed archive's manifest match this declaration.
- Five iPhone and three landscape iPad native screenshots captured from real
  bundled Snowdon data, visually reviewed and uploaded. Provenance, source hashes
  and Apple's processing receipts are in `screenshots/manifest.json` and
  `evidence/screenshot-upload.json`. All eight states are COMPLETE, with no errors.
- Help, privacy and optional email feedback links added to native Settings;
  native Settings smoke check confirmed their presence. Feedback has no automatic
  route/diagnostic attachment and is not required for free access.
- Website product, support and privacy corrections prepared locally, with the
  actual app icon. Static site validation passed; the scoped binary/text patch
  was reverse-checked against the local website changes. The owner approved
  publication on 30 October; website PR #1 was merged and production deployment
  succeeded. Live product, support redirect, policy and privacy-index checks
  passed. Unrelated local website work was preserved.
- All 100 internal map-pack versions rechecked on 30 October against the frozen,
  checksum-verified publication: all unchanged, unarchived and COMPLETE for
  processing. This is not public-review approval. Proposed batches of ten are
  recorded in `asset-pack-review-plan.json`; none was submitted.
- Existing Apple-hosted delivery integration versioned separately in Git. Signed
  iOS Release and Simulator Release builds passed. Unique build 1.0 (3) archived,
  exported for App Store distribution, passed strict code-signature checking and
  Apple's distribution validation with no errors.
  Its app and downloader extension versions agree. On the owner’s TestFlight
  retry, build 3 was uploaded, processed as VALID and added to the existing
  one-person internal group. It still failed installation with the same error;
  no map-pack version or group membership was changed. The evidence receipts
  identify the exact local IPA and failed hardware retry.
- 16 Apple adapter checks, 36 walking-plan assertions, 9,465 bundled world-source
  assertions, 17 offline-boundary checks and 31 section-pack transfer/indexed
  offline/reuse/resume/corruption checks passed. Logs are in `evidence/checks/`.
  The first section-pack attempt had no local origin; the successful rerun used
  the dedicated read-only loopback server. This does not measure phone throughput.
- Native iPad route reopen, details, Before you go, flight start/scrub/exit and
  Settings were exercised; compact iPhone details and nested walking sheet were
  exercised during capture. These checks do not replace the hardware matrix below.

## Outstanding release gates

1. Complete the actual TestFlight Apple-hosted download, interruption/resume and
   airplane-mode cold reopen on hardware. Keep the retained delivery fallback
   until that passes. Do not revive the cancelled local-certificate experiment.
2. Run the final iPhone/iPad matrix: fresh walkthrough and Skip, downloads, route
   editing/reopening across sections, GPX Files import/export, and preview.
   Investigate the previously measured iPad main-thread camera gaps if they are
   still reproducible; renderer callback rate alone is not proof of smooth motion.
3. The reviewed website policy is now live. Publish the saved matching App Store
   privacy declaration during final submission preparation; it remains a draft.
4. The Account Holder must review Apple's outstanding agreements. App Store
   Connect currently reports an updated Developer Program License Agreement;
   the earlier Paid Applications Schedule notice must also be resolved if present.
   No agreement was accepted by the agent.
5. Confirm DSA trader details and rights to redistribute the included third-party
   content. UK-only availability is saved, matching current map coverage; change
   it before submission if a broader first launch is desired.
   Do not select “no third-party content”. See `content-rights-review.md`.
6. Build 3 is now uploaded for internal testing. Resolve its installation error
   and complete the hardware checks before selecting the App Store build and
   submitting the appropriate map packs. No app or pack review was requested.
7. Obtain explicit submission/release approval. The app remains PREPARE_FOR_SUBMISSION
   with MANUAL release; there is no public launch date or pre-order.

## Reviewable handoff

- `preview.html`: local listing preview with the actual screenshot sets.
- `en-GB/metadata.json` and `review-notes.txt`: exact listing/reviewer copy.
- `privacy-evidence.md`: audited app/service behaviour and retention.
- `website-update.patch` / `website-update.md`: prepared, scoped site changes.
- `evidence/`: safe verification receipts, original captures and local test logs.

The public release remains on hold. “Prepared” does not mean Apple delivery has
passed its real-device test or that App Review has approved the app/map packs.
