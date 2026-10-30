# Ridge website update: published 30 October 2026

The owner explicitly approved publication. [Website PR #1](https://github.com/Matthew5030/bilella-works-website/pull/1)
was merged and Cloudflare production deployment succeeded at commit
`c5539a65bcdee9084c667e73b71eec3b0fd02425`. Ridge remains **in development**;
no app or map pack was submitted or released.

An isolated checkout of the latest production source was used. The original
website checkout and all its unrelated local changes were preserved. Only six
paths changed: Ridge product and privacy pages, the Ridge section of support,
the Ridge privacy-index summary, its actual app icon and the validator's Ridge
section title. No hosting configuration or permissions changed.

The complete static-site validator and whitespace checks passed. Cloudflare's
preview and production checks both passed. Live browser verification confirmed:

- https://bilellaworks.com/apps/ridge/ shows the current features, real app icon,
  free early-access wording and unreleased status.
- https://bilellaworks.com/apps/ridge/support/ redirects to `/support/#ridge`,
  where the revised download, route, GPX and feedback help is available.
- https://bilellaworks.com/apps/ridge/privacy/ is effective 30 October 2026 and
  describes offline search, Apple map delivery and the retained alternative
  security service, including its actual retention.
- https://bilellaworks.com/privacy/ has the matching Ridge summary.

`evidence/website-publication.json` records the deployment. The `website-*-live.jpg`
files show production pages. The original `website-update.patch` and draft
screenshots are retained as preparation evidence; publication advanced the
policy date from 27 to 30 October. Do not reapply the historical patch to the
already-updated production source.

The matching App Store privacy questionnaire is still an unpublished draft for
final submission preparation. The app itself remains on hold for TestFlight
checks and the remaining owner/review steps.
