#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
iconset="$PWD/dist/Reclaim.iconset"
mkdir -p "$iconset"
# Preserve the approved artwork; only export the standard macOS pixel sizes.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/Reclaim.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/Reclaim.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o dist/Reclaim.icns
