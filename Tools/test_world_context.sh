#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST=$(mktemp -d /tmp/ridge-world-test.XXXXXX)
trap 'rm -rf "$TEST"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -O -parse-as-library \
 "$ROOT/ridge v3/Core/Models.swift" "$ROOT/ridge v3/Core/AdaptiveTerrain.swift" \
 "$ROOT/ridge v3/Core/AdaptiveArea.swift" "$ROOT/ridge v3/Core/CartographyAtlas.swift" \
 "$ROOT/ridge v3/Core/TileGrid.swift" "$ROOT/ridge v3/Core/TerrainBudget.swift" \
 "$ROOT/ridge v3/Core/PackStore.swift" "$ROOT/ridge v3/Core/AdaptivePackStore.swift" \
 "$ROOT/ridge v3/Core/RouteEngine.swift" \
 "$ROOT/ridge v3/World/WorldPreview.swift" "$ROOT/ridge v3/World/WorldSource.swift" "$ROOT/ridge v3/World/WorldOfflineCoverage.swift" "$ROOT/ridge v3/World/WorldCartography.swift" \
 "$ROOT/ridge v3/World/WorldGeometry.swift" "$ROOT/ridge v3/World/WorldCameraTransition.swift" "$ROOT/ridge v3/Core/TerrainNavigation.swift" "$ROOT/ridge v3/World/WorldCatalog.swift" "$ROOT/ridge v3/World/WorldLandscape.swift" "$ROOT/ridge v3/World/WorldAtlasIndex.swift" "$ROOT/ridge v3/World/WorldDistantTerrain.swift" "$ROOT/ridge v3/World/WorldModel.swift" "$ROOT/ridge v3/World/WorldCameraOrientation.swift" "$ROOT/ridge v3/World/WorldOfflineBoundary.swift" "$ROOT/Tests/WorldDistantTerrainTests.swift" -o "$TEST/run"
"$TEST/run" "$ROOT/ridge v3/Resources/WorldData.bundle" "$@"
