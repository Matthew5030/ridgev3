#!/bin/sh
set -eu
RIDGE_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RIDGE_TEST_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ridge-crop-build.XXXXXX")
trap 'rm -rf "$RIDGE_TEST_BUILD"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/PackStore.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AreaCropper.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/BudgetFixtures.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/CropTests.swift" \
  -o "$RIDGE_TEST_BUILD/CropTests"
"$RIDGE_TEST_BUILD/CropTests" "$RIDGE_PROJECT_ROOT/ridge v3/Resources/RidgeData.bundle"
