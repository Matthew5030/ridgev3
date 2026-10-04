#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
RUN=$(mktemp /tmp/ridge-gesture-test.XXXXXX)
trap 'rm "$RUN"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library "$ROOT/ridge v3/World/WorldGestureIntent.swift" "$ROOT/Tests/WorldGestureTests.swift" -o "$RUN"
"$RUN"
