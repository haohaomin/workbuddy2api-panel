#!/bin/bash
# Rebuild all macOS icon resolutions from the WorkBuddy PNG used in README.
set -euo pipefail
cd "$(dirname "$0")/../.."
assets="scripts/macos/assets"
mkdir -p "$assets"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
iconset="$temp_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$assets/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$assets/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$assets/AppIcon.icns"
