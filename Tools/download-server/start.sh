#!/bin/sh
set -eu
RIDGE_SERVER_SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "${RIDGE_DOWNLOAD_BACKEND:-native}" = native ]; then
    exec python3 "$RIDGE_SERVER_SOURCE/native_control.py" start --root "${1:-/Volumes/MLB_EXT_4TB/Ridge Sources}" --port "${RIDGE_DOWNLOAD_PORT:-8787}"
fi
# Keep Docker's small config files outside iCloud-managed Desktop folders.
RIDGE_SERVER_RUNTIME="$HOME/Library/Application Support/Ridge Download Server"
mkdir -p "$RIDGE_SERVER_RUNTIME"
cp "$RIDGE_SERVER_SOURCE/compose.yaml" "$RIDGE_SERVER_RUNTIME/compose.yaml"
cp "$RIDGE_SERVER_SOURCE/nginx.conf" "$RIDGE_SERVER_RUNTIME/nginx.conf"
export RIDGE_SOURCE_DIRECTORY="${1:-/Volumes/MLB_EXT_4TB/Ridge Sources}"
docker compose -f "$RIDGE_SERVER_RUNTIME/compose.yaml" up -d
docker compose -f "$RIDGE_SERVER_RUNTIME/compose.yaml" exec -T downloads nginx -t
docker compose -f "$RIDGE_SERVER_RUNTIME/compose.yaml" exec -T downloads nginx -s reload
printf 'Ridge downloads: http://%s.local:%s\n' "$(scutil --get LocalHostName)" "${RIDGE_DOWNLOAD_PORT:-8787}"
