#!/bin/bash
set -euo pipefail
RIDGE_PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIDGE_TEST_DIR="$(mktemp -d -t ridge-download-estimate-tests)"
trap 'rm -rf "$RIDGE_TEST_DIR"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcrun swiftc -O -swift-version 5 -parse-as-library \
 "$RIDGE_PROJECT_ROOT/ridge v3/Core/"*.swift \
 "$RIDGE_PROJECT_ROOT/Tests/AdaptiveDownloadEstimateTests.swift" \
 -o "$RIDGE_TEST_DIR/check"
"$RIDGE_TEST_DIR/check" "$@"
