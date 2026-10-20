#!/bin/bash
# Build locally with dev version, or pass VERSION from the release workflow.
set -euo pipefail
cd "$(dirname "$0")/../.."
arch="${1:-arm64}"
app="${2:-dist/WorkBuddy2API.app}"
case "$arch" in
  arm64) swift_arch=arm64 ;;
  amd64) swift_arch=x86_64 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
ldflags="-s -w"
if [ -n "${VERSION:-}" ]; then
  ldflags="$ldflags -X main.appVersion=${VERSION}"
fi
CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" \
  go build -trimpath -ldflags="$ldflags" -o "$app/Contents/Resources/wb2api" ./cmd/server
xcrun swiftc -swift-version 5 -O -target "${swift_arch}-apple-macosx12.0" \
  -framework AppKit cmd/macosapp/*.swift -o "$app/Contents/MacOS/WorkBuddy2API"
cp scripts/macos/Info.plist "$app/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "$app/Contents/Info.plist"
fi
# Ad-hoc signing keeps the locally built bundle internally consistent.
codesign --force --sign - "$app/Contents/Resources/wb2api"
codesign --force --sign - "$app"
