#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST=$(mktemp -d /tmp/ridge-atlas-test.XXXXXX)
trap 'rm -rf "$TEST"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -O -parse-as-library "$ROOT/ridge v3/World/WorldAtlasIndex.swift" "$ROOT/Tests/WorldAtlasTests.swift" -o "$TEST/run"
"$TEST/run"
