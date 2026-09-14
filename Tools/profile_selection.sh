#!/bin/sh
set -eu
RIDGE_PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RIDGE_PROFILE_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ridge-selection-profile.XXXXXX")
trap 'rm -rf "$RIDGE_PROFILE_BUILD"' EXIT HUP INT TERM
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/Models.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TileGrid.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/CartographyAtlas.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/TerrainBudget.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/PackStore.swift" \
  "$RIDGE_PROJECT_ROOT/ridge v3/Core/AreaCropper.swift" \
  "$RIDGE_PROJECT_ROOT/Tools/SelectionPerformance.swift" \
  -o "$RIDGE_PROFILE_BUILD/SelectionPerformance"
"$RIDGE_PROFILE_BUILD/SelectionPerformance" "${1:-$RIDGE_PROJECT_ROOT/ridge v3/Resources/RidgeData.bundle}"
