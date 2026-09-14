#!/bin/sh
set -eu
RIDGE_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RIDGE_MEDIUM_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ridge-medium-build.XXXXXX")
trap 'rm -rf "$RIDGE_MEDIUM_BUILD"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Terrain/CartographyMediumDecoder.swift" \
  "$RIDGE_PROJECT_ROOT/Tests/CartographyMediumTests.swift" \
  -o "$RIDGE_MEDIUM_BUILD/CartographyMediumTests"
"$RIDGE_MEDIUM_BUILD/CartographyMediumTests"
