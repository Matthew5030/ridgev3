# Map UI component review — 25 October 2026

These PNGs render the production SwiftUI route controls and editor with a synthetic route. They are not full iOS screenshots. macOS and iOS render some system controls differently; the system sheet, its detents and its map interaction require device assessment.

- `quiet-route-editing-320.png`, `quiet-route-saved-390.png`: the compact route bar. Route details opens deliberately; Undo, Preview and Done stay reachable while editing.
- `quiet-player-320.png`, `quiet-player-844.png`: the compact playback bar. Speed opens separately and elevation is collapsed by default.
- `phone-details-waypoints.png`, `phone-details-elevation.png`: the two deliberate details views at 390 × 440 points, with no automatic elevation plot on the map.
- `arrival-0.png`, `arrival-45.png`, `arrival-80.png`, `arrival-100.png`: the actual entry camera mathematics over a synthetic SceneKit valley, starting at a browsing pose and lens, then joining the prepared FPV flight. This is not real terrain or a device frame-rate measurement.

Reproduce with `sh Tools/render_world_route_tour.sh Artifacts/map-first-ui-2026-10-25`. Only the focused UI/entry snapshots are committed; other output from the shared fixture is disposable.
