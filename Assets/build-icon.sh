#!/bin/sh
set -eu
ASSETS="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
DESTINATION="${1:?Pass the destination .icns path}"
ICON_DIR="$(mktemp -d /private/tmp/mzt-player-icon.XXXXXX)"
trap 'rm -rf "$ICON_DIR"' EXIT
ICONSET="$ICON_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$ASSETS/MZTPlayerIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$ASSETS/MZTPlayerIcon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DESTINATION"
