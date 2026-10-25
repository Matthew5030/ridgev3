#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUTPUT=${1:?Supply an output directory}
TEST=$(mktemp -d /tmp/ridge-route-tour-render.XXXXXX)
trap 'rm -rf "$TEST"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -O -parse-as-library \
 "$ROOT/ridge v3/Core/Models.swift" "$ROOT/ridge v3/Core/AdaptiveTerrain.swift" \
 "$ROOT/ridge v3/Core/AdaptiveArea.swift" "$ROOT/ridge v3/Core/CartographyAtlas.swift" \
 "$ROOT/ridge v3/Core/TileGrid.swift" "$ROOT/ridge v3/Core/TerrainBudget.swift" \
 "$ROOT/ridge v3/World/WorldFlightPlan.swift" \
 "$ROOT/ridge v3/World/WorldFlightCorridor.swift" "$ROOT/ridge v3/World/WorldFlightDynamics.swift" \
 "$ROOT/ridge v3/World/WorldCinematicDirector.swift" "$ROOT/ridge v3/World/WorldCinematicLook.swift" "$ROOT/ridge v3/World/WorldCameraRig.swift" \
 "$ROOT/ridge v3/World/WorldRouteTour.swift" "$ROOT/ridge v3/World/WorldRouteTourCamera.swift" \
 "$ROOT/ridge v3/World/WorldCameraTransition.swift" "$ROOT/ridge v3/World/WorldFlightArrival.swift" "$ROOT/ridge v3/World/WorldFlightEntryView.swift" "$ROOT/ridge v3/World/WorldCameraOrientation.swift" "$ROOT/ridge v3/World/WorldRouteTourControls.swift" \
 "$ROOT/ridge v3/Core/RouteEngine.swift" \
 "$ROOT/ridge v3/World/WorldRouteProfile.swift" "$ROOT/ridge v3/World/WorldRouteElevationStrip.swift" "$ROOT/ridge v3/World/WorldRouteToolbar.swift" \
 "$ROOT/ridge v3/World/WorldRouteEditorPanel.swift" \
 "$ROOT/ridge v3/Views/Theme.swift" "$ROOT/Tools/render_world_route_tour.swift" -o "$TEST/run"
RIDGE_FLIGHT_ASSETS="$ROOT/ridge v3/Assets.xcassets" "$TEST/run" "$OUTPUT"
