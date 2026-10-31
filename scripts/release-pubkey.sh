#!/bin/bash
# Prints the release public key built into the app (ReleaseSignature.projectPublicKeyBase64).
# Exits 1 while it is the placeholder, missing, or found more than once, so release.sh never signs
# against a key the app does not trust. Tests run it on a copy of the source file.
# Usage: scripts/release-pubkey.sh [path to ReleaseSignature.swift]
set -euo pipefail
SRC="${1:-$(dirname "$0")/../Sources/MonitorCore/Update/ReleaseSignature.swift}"
# Only the declaration line, never a comment that mentions the name.
KEYS=$(sed -n 's/^[[:space:]]*public static let projectPublicKeyBase64 = "\([^"]*\)"[[:space:]]*$/\1/p' "$SRC")
COUNT=$(printf '%s' "$KEYS" | grep -c . || true)
case "$KEYS" in
  ""|PLACEHOLDER*)
    echo "error: ReleaseSignature.projectPublicKeyBase64 is not set. Do the release key step first (README, Release signing)." >&2
    exit 1 ;;
esac
if [ "$COUNT" != 1 ]; then
  echo "error: found $COUNT projectPublicKeyBase64 declarations in $SRC, expected 1." >&2
  exit 1
fi
printf '%s\n' "$KEYS"
