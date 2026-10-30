# Prepared Ridge website update

Prepared 27–30 October 2026. The local website checkout contains these changes;
**nothing was deployed or pushed**. The website has other pre-existing work, so
do not publish its entire dirty working tree as part of this handoff.

`website-update.patch` contains only the scoped changes made for Ridge here:

- Ridge product copy: actual offline planning/preview/GPX features, Apple map
  downloads, free early access with optional feedback, unreleased status retained.
- Ridge privacy page: local place search, optional one-shot location, Apple map
  delivery, reachable alternative App Attest service and its actual retention.
- Ridge section of the shared support page and summary on the privacy index.
- Updated actual Ridge app icon and the validator's matching Ridge section title.

The patch is relative to `/Users/matthewbilella/Documents/ChatGPT/Bilella Works Web`.
It includes the icon as a Git binary patch. Its text baselines preserve the
pre-existing unrelated website edits. The local checkout already has this patch
applied; `git apply --reverse --check` passes there. Review the six exact paths
before committing/deploying. Use the existing website's deployment process only
after the owner authorizes publication. Do not accept new service agreements.

`evidence/website-product-draft.jpg` and `website-privacy-draft.jpg` show the
prepared pages. `bash Scripts/validate-site.sh` passed. Once authorized, verify
these production URLs and the revised policy text before publishing Apple's
privacy declaration:

- https://bilellaworks.com/apps/ridge/
- https://bilellaworks.com/apps/ridge/support/
- https://bilellaworks.com/apps/ridge/privacy/

The public pages currently exist, but the corrected text is still a local draft.
