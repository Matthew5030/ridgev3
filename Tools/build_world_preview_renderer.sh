#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST=${1:?Supply a new output directory for the preview executable}
mkdir -p "$TEST"
xcrun swiftc -swift-version 5 -O -parse-as-library \
 "$ROOT/ridge v3/Core/Models.swift" "$ROOT/ridge v3/Core/AdaptiveTerrain.swift" \
 "$ROOT/ridge v3/Core/AdaptiveArea.swift" "$ROOT/ridge v3/Core/CartographyAtlas.swift" \
 "$ROOT/ridge v3/Core/TileGrid.swift" "$ROOT/ridge v3/Core/TerrainBudget.swift" \
 "$ROOT/ridge v3/Core/PackStore.swift" "$ROOT/ridge v3/Core/AdaptivePackStore.swift" \
 "$ROOT/ridge v3/Core/RouteEngine.swift" \
 "$ROOT/ridge v3/World/WorldPreview.swift" "$ROOT/ridge v3/World/WorldSource.swift" "$ROOT/ridge v3/World/WorldSectionPack.swift" "$ROOT/ridge v3/World/WorldCartography.swift" \
 "$ROOT/ridge v3/World/WorldGeometry.swift" "$ROOT/Tools/world_source/render_batch_preview.swift" -o "$TEST/render-preview"
