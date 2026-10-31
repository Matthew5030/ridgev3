# Ridge 1.0 release preparation

Prepared 27–31 October 2026. **Public release remains on hold.** Nothing in this folder authorizes app submission, asset-pack review or publication.

`en-GB/metadata.json` is the source for the English (UK) listing. `en-GB/review-notes.txt` contains reviewer instructions. Screenshots must be real native app captures, with public demonstration routes only. Preserve their source device, build and capture details in `screenshots/manifest.json`.

## Offline starter release gates (build 4)

The owner selected a self-contained release including Eryri, Lake District,
Peak District, and Chilterns & Thames Valley. Build 3 and its separate Apple
asset download experiment are retained as historical evidence. Successful Apple
hosted delivery is a gate for enabling future downloads, not for this offline
starter release. See `Tools/OFFLINE-STARTER.md` for the update path.

- [x] Prepare 282 sections / 67,987 tiles; verify all pack and decompressed entry hashes.
- [x] Offline integration checks cover four areas, Aylesbury/Chilterns samples,
  cache removal, and precedence for a later downloaded manifest and pack.
- [x] Existing region geometry reports no missing land rectangles for the four
  selections; the 12 missing catalogue cells at Eryri's boundary do not overlap
  the clipped land shapes. Missing source-tile coverage remains represented.
- [x] Preserve the full UK source library, published Apple pack registry, existing
  route identities and downloader source for a future update.
- [x] Update local listing and reviewer notes to describe four included areas.
- [x] Final build 4 archived/exported: 2,971,448,163 app bytes and 2,847,849,543 IPA bytes. Strict signature verification and Apple distribution validation passed. Uploaded successfully; processing status is recorded in evidence.
- [x] Final physical iPhone/iPad core smoke test: first open, immediate offline terrain,
  route editing/reopening, cross-section routing, GPX import/export and preview.
  Native iPad UI was observed; the owner confirmed the longer iPhone preview
  and airplane-mode cold reopening on both. A real section-crossing route also
  passes the offline integration suite (31 checks; 64 local checks total).
- [x] Save revised listing and select processed build 4 in App Store Connect.
  Apple reports VALID; all four production-source GitHub checks passed.
- [ ] Final privacy/content-rights declarations and Account Holder agreement checks.
- [ ] Obtain owner approval before App Review submission/publication.

The product/support/privacy website and eight listing screenshots are already
prepared. The product page currently describes downloadable maps, so its copy
needs the owner-approved starter-coverage wording before this release.

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
