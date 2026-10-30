# Ridge 1.0 release preparation

Prepared 27–30 October 2026. **Public release remains on hold.** Nothing in this folder authorizes app submission, asset-pack review or publication.

`en-GB/metadata.json` is the source for the English (UK) listing. `en-GB/review-notes.txt` contains reviewer instructions. Screenshots must be real native app captures, with public demonstration routes only. Preserve their source device, build and capture details in `screenshots/manifest.json`.

## Release gates

- [ ] Fresh TestFlight Apple-hosted map download, interruption/resume and offline cold reopen pass on real hardware.
- [x] Version the existing Apple delivery integration and prepare a uniquely numbered, signed 1.0 (3) archive and local App Store IPA export. Apple's validation passed with no errors. See `evidence/release-archive.json`; build 3 was subsequently uploaded for the owner’s internal TestFlight retry; no App Store build is selected.
- [ ] Final iPhone/iPad smoke test of first open, region downloads, route editing/reopening, cross-section path routing, GPX Files import/export and preview.
- [ ] Investigate measured iPad main-thread camera stalls without changing the approved route-following mathematics.
- [x] Publish the owner-approved Ridge website changes and verify the production product/support/privacy URLs. See `evidence/website-publication.json`.
- [x] Audit actual network paths and retention, save complete Device ID / Other Usage Data questionnaire answers, and check the preview against build 3's manifest. The corrected website policy is live; the declaration remains a draft for final submission preparation.
- [ ] Account Holder accepts outstanding Apple agreements in Business; do not accept on their behalf.
- [x] Save and verify the privately supplied reviewer contact details with Apple. No private phone number is stored here.
- [ ] Confirm DSA trader details and content-rights declarations with the Account Holder. UK-only availability is saved for the proposed first release and remains editable.
- [x] Upload build 3 and add it to the existing private internal group after build 2 failed again. Apple processed it as VALID / IN_BETA_TESTING, but the phone still reports an unavailable/nonexistent app.
- [ ] Resolve TestFlight installation, complete the hardware checks, then select the tested App Store build and approved asset-pack versions.
- [x] Verify all eight screenshot uploads processed as COMPLETE and the saved listing matches its source files.
- [ ] Obtain release approval before submission.

Open `preview.html` for the prepared listing. The five iPhone and three landscape
iPad screenshots are full native captures; `screenshots/manifest.json` records
their source build and public fixture. `evidence/screenshot-upload.json` records
Apple's processing state. The native screenshot fixture does not prove an Apple
download: that remains a separate hardware release gate.

## Deliberate choices

- Free, with clear optional-feedback early-access wording; no promise of permanent free access.
- Manual release after approval; no automatic launch or pre-order.
- UK map coverage only; no worldwide, live-navigation or survey-accuracy claims.
- Keep accessibility support claims unset until each claimed experience has been tested across the whole app.
- The existing one-person internal group now includes build 3 for the authorized retry. Its map-pack versions and group membership are unchanged.

## Authoritative Apple references

- [Required metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties/)
- [Screenshot dimensions](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [App privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
- [Asset-pack review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-apple-hosted-asset-packs/)
- [Manual release](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)
