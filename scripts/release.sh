#!/bin/bash
# Builds a release MacMonitor.app (Apple Silicon), ad-hoc signs it and zips it for a GitHub Release.
# Usage: scripts/release.sh <version>    e.g. scripts/release.sh 1.0.0
# Output: .build/release-zip/MacMonitor-<version>.zip and its SHA-256. Does not install anything.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(pwd)"

# Map the build folder to "." so no local path ends up inside the binaries.
swift build -c release --arch arm64 \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." \
  -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=." \
  -Xcc -ffile-prefix-map="$ROOT=."
BIN=$(swift build -c release --arch arm64 --show-bin-path)
APP=.build/release-zip/MacMonitor.app
rm -rf .build/release-zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacMonitor" "$BIN/macmonitor-mcp" "$APP/Contents/MacOS/"
strip -S -x "$APP/Contents/MacOS/MacMonitor" "$APP/Contents/MacOS/macmonitor-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

ZIP=".build/release-zip/MacMonitor-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
