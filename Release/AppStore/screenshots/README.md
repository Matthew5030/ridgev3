# Native screenshot capture plan

Use the dedicated Ridge Simulator fixtures, not a person's route library. The
fixture script copies checksum-verified bundled Snowdon assets into a Simulator
cache and creates a labelled example from the real walking graph. This is not a
TestFlight download test and must not be reported as one.

Capture full native viewports with `simctl io … screenshot`. The app's own
controls, maps, route and text must remain intact. `export_screenshot.swift`
only converts the capture to an opaque RGB PNG at its original dimensions.
Keep originals under `evidence/raw-captures` for provenance.

## Planned order

1. `01-terrain-and-route.png`: a framed ridge route on the actual 3D landscape.
2. `02-flight-preview.png`: pause a useful FPV view with the elevation plot open.
3. `03-before-you-go.png`: walking pace, breaks, finish estimate and map coverage.
4. `04-saved-routes.png`: local route library with its real map thumbnail.
5. `05-waypoints-and-elevation.png`: route details or the elevation/waypoint editor.

iPhone: 1320 × 2868, `APP_IPHONE_67` (Apple's largest Dynamic Island bucket).
iPad: 2752 × 2064 landscape or 2064 × 2752 portrait,
`APP_IPAD_PRO_3GEN_129`. Do not stretch a smaller phone capture to this size.

The screenshot uploader only creates draft screenshot records. It never submits
the app, submits the map packs, publishes privacy answers or releases a version.
It resumes identical filenames/checksums and refuses to overwrite different
existing artwork. Upload URLs and credentials are never written to receipts.

Check every final image visually and confirm Apple's processing state is
`COMPLETE`. `UPLOAD_COMPLETE` confirms transfer only.
