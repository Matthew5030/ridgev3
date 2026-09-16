#!/bin/bash
set -euo pipefail
RIDGE_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIDGE_TEST_DIR="$(mktemp -d -t ridge-adaptive-pack-tests)"
trap 'rm -rf "$RIDGE_TEST_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -O -swift-version 5 -parse-as-library \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/AdaptiveTerrain.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/AdaptiveArea.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/AdaptivePackStore.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/PackStore.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/AreaCropper.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/RouteEngine.swift" \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/GPXCodec.swift" \
 "$RIDGE_PROJECT_ROOT/Tests/AdaptivePackIntegration.swift" \
 -o "$RIDGE_TEST_DIR/check"
"$RIDGE_TEST_DIR/check" "$@"
