#!/bin/sh
set -eu
RIDGE_SERVER_SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Keep Docker's small config files outside iCloud-managed Desktop folders.
RIDGE_SERVER_RUNTIME="$HOME/Library/Application Support/Ridge Download Server"
mkdir -p "$RIDGE_SERVER_RUNTIME"
cp "$RIDGE_SERVER_SOURCE/compose.yaml" "$RIDGE_SERVER_RUNTIME/compose.yaml"
cp "$RIDGE_SERVER_SOURCE/nginx.conf" "$RIDGE_SERVER_RUNTIME/nginx.conf"
export RIDGE_SOURCE_DIRECTORY="${1:-/Volumes/MLB_EXT_4TB/Ridge Sources}"
docker compose -f "$RIDGE_SERVER_RUNTIME/compose.yaml" up -d
printf 'Ridge downloads: http://%s.local:%s\n' "$(scutil --get LocalHostName)" "${RIDGE_DOWNLOAD_PORT:-8787}"
