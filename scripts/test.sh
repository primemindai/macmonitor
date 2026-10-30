#!/bin/bash
# Runs the test suite with swift-testing on a Command Line Tools only Mac.
# Plain `swift test` builds a runner that cannot find Testing.framework and runs ZERO tests
# while exiting 0, so always use this script. Extra args pass through (for example --filter SMCTests,
# or --skip-tags style filters are not supported, use --skip <regex>).
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F -Xswiftc "$F" \
  -Xlinker -rpath -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$L" \
  "$@"
