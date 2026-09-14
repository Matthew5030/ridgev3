#!/bin/sh
set -eu
RIDGE_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RIDGE_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ridge-map-render-tests.XXXXXX")
trap 'rm -rf "$RIDGE_TEST_BUILD"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cat "$RIDGE_PROJECT_ROOT/ridge v3/Terrain/CartographyRenderer.swift" "$RIDGE_PROJECT_ROOT/Tests/CartographyRendererTests.swift" "$RIDGE_PROJECT_ROOT/Tests/CartographyShaderChecks.swift" > "$RIDGE_TEST_BUILD/CartographyRendererTests.swift"
xcrun swiftc -swift-version 5 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Terrain/CartographyMediumDecoder.swift" \
  "$RIDGE_TEST_BUILD/CartographyRendererTests.swift" \
  -o "$RIDGE_TEST_BUILD/CartographyRendererTests"
"$RIDGE_TEST_BUILD/CartographyRendererTests" "$RIDGE_PROJECT_ROOT/ridge v3/Terrain/TerrainShaders.metal"
