# Map hosting

Ridge uses R2 directly with a custom domain, HTTPS and a scoped Cloudflare
Cache Rule. The current preparation does not need a Worker, D1 database,
App Attest service or Workers Paid subscription.

## Prepared production address — 24 October 2026

`maps.bilellaworks.com` is attached to the existing `ridge-maps-private` bucket
in the same Cloudflare account as `bilellaworks.com`. The historical bucket
name does not determine its access settings. Public access on the custom domain
is **disabled** while the release is prepared, and its minimum TLS version is
1.2. Cloudflare reports certificate and domain ownership **active**; public DNS
resolves and an HTTPS catalogue request returns HTTP 401 while access is disabled.
The `r2.dev` development address remains disabled.

`hosting.json` records the target account, zone, bucket and deliberate access
state; it contains no credentials and does not execute deployment or uploads.
The owner has explicitly deferred the full map-data upload. No upload job or
scheduled publication is part of this setup.

`cache-rule.json` records the active Cache Rule for the zone's
`http_request_cache_settings` phase, saved and confirmed in the dashboard.
It matches only `maps.bilellaworks.com`
and paths beginning `/pilot-` or `/releases/`. Eligible responses use their
origin Cache-Control headers; responses without those headers bypass caching.
Browser TTL follows the origin and strong ETags are retained for conditional
requests. Existing website requests are outside this rule's expression.
Append the rule to an existing ruleset; never replace unrelated zone rules.

## Publication, when authorized

Publish each release under a fresh `releases/<revision>/` prefix. Upload and
verify dependencies before manifests and the catalogue. Keep the existing
pilot and previous releases recoverable. Do not overwrite an immutable key
with different bytes.

Use `Cache-Control: public, max-age=31536000, immutable` on versioned objects.
A future mutable release pointer needs a short TTL or revalidation; keep it
outside the versioned download rule. Compressed terrain and pack files must
retain their exact bytes and must not acquire HTTP Content-Encoding metadata.

Before enabling public access, audit the entire bucket for publishable contents
and verify the upload inventory against current manifests, connected routing
sidecars, section packs and loose assets used by sparse repair. Domain access
exposes bucket object keys, not just the current catalogue. The old pilot
exporter predates current packaging and needs updating before national use.

After publication and access activation, verify GET/HEAD, exact HTTP 206 ranges,
Content-Length, SHA-256, ETags and cache reuse on the custom domain. Existing
tools provide the app-reader and pack audits:

```sh
sh Tools/test_world_hosted.sh https://maps.bilellaworks.com/pilot-2026-10-07/sources/world-z10-x500-y333-c00-r00/world.json
python3 Tools/download-server/audit_origin.py \
  --base https://maps.bilellaworks.com/releases/REVISION/ \
  --verify-content --report /tmp/ridge-cloud-audit.json
```

The production catalogue must pass the app tests before changing
`WorldLibrary.cloud` and the default source mode. The current app still points
at the historical pilot and defaults to LAN. Device verification must include
interrupted/resumed transfers, cross-section routes, relaunch and airplane mode.

## Cost

Checked against Cloudflare's pricing on 24 October 2026. This design uses the
existing domain and Free zone plan. R2 Standard includes 10 GB-month storage,
one million Class A operations and ten million Class B operations per month,
shared across the account. Internet egress is free. Additional storage costs
US$0.015/GB-month, Class A US$4.50/million and Class B US$0.36/million, with
billing-unit rounding. A 26 GB library retained for a month is approximately
US$0.24 for storage after the full 10 GB allowance, before other objects,
retained releases, request overages and taxes. The allowance is not a hard cap.

- [R2 pricing](https://developers.cloudflare.com/r2/pricing/)
- [R2 public buckets and custom domains](https://developers.cloudflare.com/r2/buckets/public-buckets/)
- [Cache Rule settings](https://developers.cloudflare.com/cache/how-to/cache-rules/settings/)

## Earlier pilot

The optional authenticated service prototype is preserved in Git commit
`c6582de`. Its temporary Cloudflare Worker and empty D1 database were removed.
Do not deploy that prototype as part of the public pilot.

See `../../Tools/world_source/README.md` for the earlier pilot upload and
verification workflow. Its `r2.dev` endpoint is for development and is currently
disabled; production downloads should use the prepared custom domain.
