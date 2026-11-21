#!/bin/bash
# Builds the viewer into skill/bin/. Needs only the Xcode Command Line Tools
# (swiftc + the macOS SDK) — no Xcode, no SwiftPM, no network.
#
#   skill/bin/concept-graph                                   the command agents run
#   skill/bin/ConceptGraph.app/Contents/MacOS/concept-graph   the same binary, hosting the window
#
# The second copy lives in an app bundle so the window shows up in the Dock and
# menu bar as "Concept Graph" rather than as an anonymous executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/.build"
OUT="$ROOT/skill/bin"
APP="$OUT/ConceptGraph.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — install the Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$BUILD" "$OUT"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT"/Sources/ConceptGraph/*.swift \
  -o "$BUILD/concept-graph"

# Replace rather than overwrite: a window that is open right now keeps running its old copy.
rm -rf "$APP" "$OUT/concept-graph"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/concept-graph" "$APP/Contents/MacOS/concept-graph"
cp "$BUILD/concept-graph" "$OUT/concept-graph"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $OUT/concept-graph"
