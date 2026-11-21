#!/bin/bash
# Builds the document CLI into skill/bin/ on Linux, and the CLI and viewer on macOS.
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
mkdir -p "$BUILD"
# Keep a kernel lock across compilation, signing, verification and publication.
if [ "${1:-}" != "--locked" ]; then
  exec /usr/bin/perl -MFcntl=:flock,F_SETFD -e '
    open(my $lock, ">>", shift) or die $!;
    flock($lock, LOCK_EX) or die $!;
    fcntl($lock, F_SETFD, 0) or die $!;
    exec @ARGV or die $!;
  ' "$BUILD/install.lock" "$0" --locked "$@"
fi
shift
if [ "${1:-}" = "--if-missing" ] && [ -x "$OUT/concept-graph" ]; then exit 0; fi

stage="$(mktemp -d "$BUILD/install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
case "$(uname -s)" in
  Linux)
    mkdir -p "$OUT"
    swiftc -O -swift-version 5 -module-cache-path "$BUILD/module-cache" \
      "$ROOT/Sources/ConceptGraph/GraphModel.swift" "$ROOT/Sources/ConceptGraph/main.swift" \
      -o "$stage/concept-graph"
    mv "$stage/concept-graph" "$OUT/concept-graph"
    echo "built $OUT/concept-graph (headless)"
    exit 0 ;;
  Darwin) ;;
  *) echo "Building the CLI requires Linux or macOS." >&2; exit 1 ;;
esac

APP="$stage/bin/ConceptGraph.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT"/Sources/ConceptGraph/*.swift \
  -o "$APP/Contents/MacOS/concept-graph"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ConceptGraph.icns" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
cp "$APP/Contents/MacOS/concept-graph" "$stage/bin/concept-graph"
# Publish the CLI and bundle together, including when replacing a nonempty directory.
/usr/bin/python3 - "$stage/bin" "$OUT" <<'PYTHON'
import ctypes
import os
import sys
source, destination = sys.argv[1:]
if os.path.exists(destination):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), 2):  # RENAME_SWAP
        raise OSError(ctypes.get_errno(), "could not swap staged installation")
else:
    os.rename(source, destination)
PYTHON
echo "built $OUT/concept-graph"
