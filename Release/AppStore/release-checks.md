# Release preparation evidence, 30 October 2026

## Completed

- English (UK) name, subtitle, description, promotional text, keywords, support
  URL, marketing URL, copyright and review notes saved in App Store Connect;
  exact copy checked again through Apple's API on 30 October.
- Navigation primary category, Travel secondary category; Apple calculated and
  saved a 4+ content rating. Not designated Made for Kids.
- Free price schedule and manual release saved. Mac and Vision Pro compatibility
  distribution disabled for this iPhone/iPad launch.
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
  was reverse-checked against the local website changes. No website was deployed.
- All 100 internal map-pack versions rechecked on 30 October against the frozen,
  checksum-verified publication: all unchanged, unarchived and COMPLETE for
  processing. This is not public-review approval. Proposed batches of ten are
  recorded in `asset-pack-review-plan.json`; none was submitted.
- Existing Apple-hosted delivery integration versioned separately in Git. Signed
  iOS Release and Simulator Release builds passed. Unique build 1.0 (3) archived,
  exported for App Store distribution, passed strict code-signature checking and
  Apple's distribution validation with no errors.
  Its app and downloader extension versions agree; no build upload or TestFlight
  group change was made. `evidence/release-archive.json` identifies the local IPA.
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
3. Get owner approval to publish the prepared website changes. Verify live
   support/privacy URLs, then publish the matching App Store privacy declaration.
4. The Account Holder must review Apple's outstanding agreements. App Store
   Connect currently reports an updated Developer Program License Agreement;
   the earlier Paid Applications Schedule notice must also be resolved if present.
   No agreement was accepted by the agent.
5. Confirm launch territories (UK-first is proposed because coverage is UK-only),
   DSA trader details and rights to redistribute the included third-party content.
   Do not select “no third-party content”. See `content-rights-review.md`.
6. After testing, upload and select the validated distribution build; submit
   the appropriate map packs for their review. Current internal build 2 and its
   pack versions remain unchanged. No app or pack review has been requested.
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
