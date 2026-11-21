#!/bin/bash
# Offscreen AppKit checks and optional timing runs, using the same compiler as the viewer.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sources="$root/Sources/ConceptGraph"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -module-cache-path "$root/.build/module-cache" \
  "$sources"/{Arrangement,CanvasView,GraphFile,GraphModel,InspectorViewController,Launcher,Layout,NodeGeometry,Snapshot,Theme,ViewerChannel}.swift \
  "$root/scripts/check-canvas.swift" -o "$work/check"
"$work/check" "$work" "$root/skill/examples/report-delivery.json" "$@"
