#!/bin/bash
# Regenerate the bundled icon from its editable master.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
icons="$stage/ConceptGraph.iconset"
mkdir "$icons"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    pixels=$((size * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    sips -s format png -z "$pixels" "$pixels" "$root/Resources/ConceptGraph.svg" --out "$icons/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$icons" -o "$root/Resources/ConceptGraph.icns"
