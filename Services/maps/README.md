# Map hosting

The initial Ridge pilot uses public R2 directly, with no Worker, D1 database,
App Attest requirement or Workers Paid subscription.

The optional authenticated service prototype is preserved in Git commit
`c6582de`. Its temporary Cloudflare Worker and empty D1 database were removed.
Do not deploy that prototype as part of the public pilot.

See `../../Tools/world_source/README.md` for the active upload and verification
workflow. The public pilot endpoint is a rate-limited development endpoint;
connect an R2 custom domain before a production release.
