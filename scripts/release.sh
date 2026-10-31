#!/bin/bash
# Builds a release MacMonitor.app (Apple Silicon), ad-hoc signs it and zips it for a GitHub Release.
# Usage: scripts/release.sh <version>    (the version without a "v", for example the one in Resources/Info.plist)
# Output: .build/release-zip/MacMonitor-<version>.zip, MacMonitor-<version>.zip.sha256 and MacMonitor-<version>.zip.sig.
# Does not install anything.
# Upload all three to the GitHub release: the app's "Update now" refuses a release without the .sha256 or the .sig.
# Signing needs the project key: the login Keychain item from `swift scripts/release-key.swift new`, or a key file
# named by MACMONITOR_SIGNING_KEY_FILE. See README "Release signing".
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(pwd)"

# The public key built into the app. A release must verify with it, or the app will refuse to install it.
PUBKEY=$(sed -n 's/.*projectPublicKeyBase64 = "\(.*\)".*/\1/p' Sources/MonitorCore/Update/ReleaseSignature.swift)
case "$PUBKEY" in
  ""|PLACEHOLDER*)
    echo "error: ReleaseSignature.projectPublicKeyBase64 is not set. Do the release key step first (README, Release signing)." >&2
    exit 1 ;;
esac

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

ZIP_NAME="MacMonitor-$VERSION.zip"
ZIP=".build/release-zip/$ZIP_NAME"
ditto -c -k --keepParent "$APP" "$ZIP"
# Standard `shasum -a 256` line, with the zip's bare name so it checks from any folder.
(cd .build/release-zip && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")
cat "$ZIP.sha256"
# Ed25519 signature of the exact zip bytes, then check it with the key in the app source. Fails the release if not.
swift scripts/release-key.swift sign "$ZIP"
swift scripts/release-key.swift verify "$ZIP" "$PUBKEY"
echo "$ZIP"
echo "$ZIP.sha256"
echo "$ZIP.sig"
