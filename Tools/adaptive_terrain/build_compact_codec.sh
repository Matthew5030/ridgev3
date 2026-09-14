#!/bin/sh
set -eu
RIDGE_CODEC_SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RIDGE_CODEC_OUTPUT=${1:-/tmp}
mkdir -p "$RIDGE_CODEC_OUTPUT"
clang++ -O3 -std=c++17 "$RIDGE_CODEC_SOURCE/compact_mesh.cpp" -o "$RIDGE_CODEC_OUTPUT/ridge-compact-mesh"
case "$(uname -s)" in
  Darwin) clang++ -O3 -std=c++17 -dynamiclib "$RIDGE_CODEC_SOURCE/compact_mesh.cpp" -o "$RIDGE_CODEC_OUTPUT/libridge_compact_mesh.dylib" ;;
  *) clang++ -O3 -std=c++17 -shared -fPIC "$RIDGE_CODEC_SOURCE/compact_mesh.cpp" -o "$RIDGE_CODEC_OUTPUT/libridge_compact_mesh.so" ;;
esac
