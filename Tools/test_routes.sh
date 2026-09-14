#!/bin/bash
set -euo pipefail
RIDGE_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIDGE_TEST_DIR="$(mktemp -d -t ridge-route-tests)"
trap 'rm -rf "$RIDGE_TEST_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/RouteEngine.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/GPXCodec.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/RouteStore.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/RouteCoreTests.swift" \
  -o "$RIDGE_TEST_DIR/RouteCoreTests"
"$RIDGE_TEST_DIR/RouteCoreTests" "$RIDGE_PROJECT_ROOT/ridge v3/Resources/RidgeData.bundle/regions/snowdon-horseshoe"
