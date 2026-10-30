#!/bin/bash
# Builds MacMonitor in release mode, wraps it in MacMonitor.app, ad-hoc signs it and installs it to ~/Applications.
# Usage: scripts/bundle.sh [--open]
# No admin rights needed. Quits a running installed copy first so the new one can replace it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release
APP=.build/MacMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacMonitor" "$APP/Contents/MacOS/MacMonitor"
cp "$BIN/macmonitor-mcp" "$APP/Contents/MacOS/macmonitor-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

DEST="$HOME/Applications/MacMonitor.app"
mkdir -p "$HOME/Applications"
if pgrep -f "$DEST/Contents/MacOS/MacMonitor" >/dev/null; then
  pkill -f "$DEST/Contents/MacOS/MacMonitor" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/MacMonitor" >/dev/null || break; sleep 0.5; done
fi
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
echo "MCP binary: $DEST/Contents/MacOS/macmonitor-mcp"
if [[ "${1:-}" == "--open" ]]; then open "$DEST"; fi
