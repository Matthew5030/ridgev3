#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST=$(mktemp -d /tmp/ridge-flight-motion.XXXXXX)
trap 'rm -rf "$TEST"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -O -parse-as-library \
 "$ROOT/ridge v3/Core/Models.swift" "$ROOT/ridge v3/Core/AdaptiveTerrain.swift" \
 "$ROOT/ridge v3/Core/AdaptiveArea.swift" "$ROOT/ridge v3/Core/CartographyAtlas.swift" \
 "$ROOT/ridge v3/Core/TileGrid.swift" "$ROOT/ridge v3/Core/TerrainBudget.swift" \
 "$ROOT/ridge v3/World/WorldFlightPlan.swift" \
 "$ROOT/ridge v3/World/WorldFlightCorridor.swift" "$ROOT/ridge v3/World/WorldFlightDynamics.swift" \
 "$ROOT/ridge v3/World/WorldCinematicDirector.swift" "$ROOT/ridge v3/World/WorldCinematicLook.swift" "$ROOT/ridge v3/World/WorldCameraRig.swift" \
 "$ROOT/ridge v3/World/WorldRouteTour.swift" "$ROOT/ridge v3/World/WorldRouteTourCamera.swift" \
 "$ROOT/ridge v3/World/WorldRouteProfile.swift" \
 "$ROOT/ridge v3/World/WorldCameraOrientation.swift" "$ROOT/Tests/WorldFlightMotionTests.swift" -o "$TEST/run"
"$TEST/run"
