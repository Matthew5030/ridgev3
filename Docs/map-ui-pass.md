# Map and preview UI — 25 October 2026

The map stays visible until the user deliberately opens more detail.

- iPhone route planning uses a compact bottom bar with distance, Route details, Preview, Undo and Done. It does not automatically open a waypoint panel or elevation chart. Larger iPads keep a collapsible sidebar; narrow iPad windows use the compact layout.
- Route details opens a medium/large system sheet on iPhone, with Waypoints and Elevation tabs. Selecting or moving a waypoint returns to the map. Elevation scrubbing remains interactive while the sheet is open.
- Map legends and secondary camera controls are opened explicitly on compact screens.
- Preview hides search, editing panels and app navigation. A single bottom playback bar provides pause, scrubbing, speed, optional elevation and exit. Ending playback restores the editor and route history.
- Preparation holds the actual browsing camera. A prepared approach blends its position, orientation and field of view into FPV over 2.8–4.2 seconds. There is no speculative camera jump or mandatory loading hold. Scrubbing and resuming do not replay the intro. Reduce Motion retains the short, direct handoff.

## Review and validation

The baseline is preserved on `codex/offline-map-fpv-milestone` and in PR #1. UI changes are isolated on `codex/map-first-route-ui`, with their PR based on the checkpoint. Merge the baseline first, then retarget the UI PR to `main` for final integration. Neither PR is automatically merged.

`Tools/render_world_route_tour.sh Artifacts/map-first-ui-2026-10-25` renders the production SwiftUI components at compact and wide widths, plus synthetic flight-camera fixtures. These are component snapshots, not complete iOS screenshots or measurements of device smoothness. The focused camera/playback checks also run in GitHub Actions.

Physical-device acceptance covers iPhone portrait and landscape, iPad full width and split view, deliberate details/elevation opening, waypoint selection and placement, scrub/pause/resume, cancellation during preparation, returning to editing, Reduce Motion and large text. Check real terrain during the entry; the flat-terrain camera fixtures do not certify clearance over every intervening landscape.
