#!/bin/sh
set -eu
RIDGE_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RIDGE_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ridge-extension-flow.XXXXXX")
trap 'rm -rf "$RIDGE_TEST_BUILD"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 6 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainNavigation.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/PackStore.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AreaCropper.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AreaExtension.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/RouteEngine.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/GPXCodec.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/RouteStore.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AtlasAreaPlanner.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AppStore.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/BudgetFixtures.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/TiledSourceTests.swift" \
  -o "$RIDGE_TEST_BUILD/TiledSourceTests"
"$RIDGE_TEST_BUILD/TiledSourceTests" "$RIDGE_PROJECT_ROOT/ridge v3/Resources/RidgeData.bundle/regions/eryri-grid"
