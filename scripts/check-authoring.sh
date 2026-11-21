#!/bin/bash
# Exercise the installed skill entry point from an unrelated working directory.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/skills" "$work/remote project" "$work/local copy"
ln -s "$root/skill" "$work/skills/concept-graph"
cli="$work/skills/concept-graph/scripts/concept-graph"
source="$root/skill/examples/report-delivery.json"

cd "$work/remote project"
document="./delivery flow.conceptgraph"
"$cli" save "$document" < "$source"
cmp "$source" "$document"
cp "$document" "$work/local copy"
(cd "$work/local copy" && "$cli" validate "$document")

# Reject an invalid revision before touching an existing or new destination.
for target in "$document" "missing.json"; do
  if "$cli" save "$target" >"$work/stdout" 2>"$work/errors" <<'JSON'
{"title":"X","nodes":[{"id":"a","label":"A"}],"edges":[{"from":"a","to":"missing"}]}
JSON
  then echo "accepted a dangling edge" >&2; exit 1; fi
  grep -Fq 'edges[0].to' "$work/errors"
done
cmp "$source" "$document"
test ! -e missing.json

# New fields can produce a warning and must survive a successful replacement.
cat > "$work/revision" <<'JSON'
{"title":"Revision","nodes":[{"id":"a","label":"A","summary":"Résumé"}],"futureField":42}
JSON
"$cli" save "$document" < "$work/revision" 2>"$work/warnings"
grep -Fq 'warning: futureField' "$work/warnings"
cmp "$work/revision" "$document"
echo "Portable document checks passed."
