#!/usr/bin/env bash
# Builds GH Watcher.app into ./build. Usage: Scripts/build-app.sh [debug|release]
# VERSION=1.2.0 stamps the version (defaults to the latest git tag).
# UNIVERSAL=1 builds one binary for Apple Silicon and Intel.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/GH Watcher.app"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0)}"
VERSION="${VERSION#v}"

if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Built per architecture and merged, since `--arch a --arch b` needs full Xcode.
  BINS=()
  for ARCH in arm64 x86_64; do
    swift build -c "$CONFIG" --triple "$ARCH-apple-macosx26.0"
    BINS+=("$(swift build -c "$CONFIG" --triple "$ARCH-apple-macosx26.0" --show-bin-path)/GHWatcher")
  done
  mkdir -p build
  BIN="build/GHWatcher-universal"
  lipo -create "${BINS[@]}" -output "$BIN"
else
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/GHWatcher"
fi

if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build
  swift Scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GHWatcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP ($VERSION)"
