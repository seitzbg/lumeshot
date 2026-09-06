#!/usr/bin/env bash
# Rebuild the macOS icon from the full-resolution artwork.
set -euo pipefail
cd "$(dirname "$0")/.."
read -r width height < <(sips -g pixelWidth -g pixelHeight Resources/AppIcon.png | awk '/pixelWidth/ {w=$2} /pixelHeight/ {print w, $2}')
if [ "$width" -ne "$height" ] || [ "$width" -lt 1024 ]; then
    echo "error: AppIcon.png must be square and at least 1024 pixels wide" >&2
    exit 1
fi
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
ICONSET="$ICON_WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Built Resources/AppIcon.icns"
