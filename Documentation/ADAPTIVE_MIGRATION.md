# Adaptive pack migration

Requested 16 September 2026. Replace the normal fixed-spacing download flow with
prepared adaptive 0.5 m terrain. Keep bounded, explicitly selected scenes and
independent cartography. No camera-triggered terrain downloads or meshing.

## Work and verification

- Decode RAT1/zlib, including range containers; validate all size limits and
  compressed, topology and reconstructed mesh hashes against real UK assets.
- Resolve map and walking-graph assets independently. Retain source attribution,
  coverage gaps and the coarse background's distinct quality/datum.
- Admit selected geometry, maps, CPU sampling/index data and load headroom using
  actual mesh counts. Decode only selected chunks, with cancellation.
- Render the precomputed triangles in the existing textured planner. Surface
  picking, route draping and elevation queries must use those triangles.
- Use the existing atlas selection, saved routes, expansion and GPX flows.
  Remove spacing choices; show selected area, download size and fit feedback.
- Migrate catalogues and archive generated legacy terrain packs with a recovery
  inventory. Preserve raw/source LiDAR, cartography, walking paths and routes.
- Validate real selected areas, joins, corruption/cancellation, offline reopen,
  route preservation and the complete iOS build before retiring old assets.

## Initial findings

The normal app currently loads regular heightfields. The drive contains complete
`uk-adaptive-0p5-v3` (589,443 chunks, ~7.0 GB compressed geometry) and
`uk-coarse-background-v2`. These are geometry assets, not complete routable packs.
The normal server catalogue advertises only legacy `eryri-park`. Existing maps and
walking graphs must be reused or prepared separately; do not delete them with
obsolete heightfields. National adaptive partitions use `rat1-zlib-range-v1`.

Git checkpoint before migration: `0fa6a3f`.
