#!/bin/bash
# Smoke tests for the viewer's command line: the parts an agent depends on.
# Opens no windows. Run via `make check`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CG="$ROOT/skill/scripts/concept-graph"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }

# expect <description> <expected exit status> <text the output must contain> <command…>
expect() {
  local name="$1" status="$2" needle="$3"; shift 3
  local output; output="$("$@" 2>&1)"; local got=$?
  if [ "$got" -ne "$status" ]; then fail "$name (exit $got, wanted $status)"; echo "$output" | sed 's/^/        /'
  elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$output"; then fail "$name (output lacks: $needle)"; echo "$output" | sed 's/^/        /'
  else pass "$name"; fi
}

echo "examples"
for example in "$ROOT"/skill/examples/*.json; do
  output="$("$CG" validate "$example" 2>&1)"; status=$?
  if [ $status -eq 0 ] && ! grep -q "^warning" <<<"$output"; then pass "$(basename "$example") is valid with no warnings"
  else fail "$(basename "$example")"; echo "$output" | sed 's/^/        /'; fi
done

echo "validation"
cat > "$WORK/syntax.json" <<'JSON'
{"title": "x", "nodes": [ {"id": "a" "label": "A"} ]}
JSON
expect "broken JSON is rejected with a position" 1 "line 1" "$CG" validate "$WORK/syntax.json"

cat > "$WORK/typo.json" <<'JSON'
{"title": "t", "nodes": [{"id": "cache", "label": "Cache", "summary": "s"}, {"id": "store", "label": "Store", "summary": "s"}],
 "edges": [{"from": "cach", "to": "store"}]}
JSON
expect "unknown node id suggests the near match" 1 'did you mean "cache"?' "$CG" validate "$WORK/typo.json"

cat > "$WORK/alias.json" <<'JSON'
{"title": "t", "nodes": [{"id": "a", "label": "A", "summary": "s"}, {"id": "b", "label": "B", "summary": "s"}],
 "edges": [{"source": "a", "target": "b"}]}
JSON
expect "foreign field names are explained" 1 'did you mean "from"?' "$CG" validate "$WORK/alias.json"

cat > "$WORK/dupe.json" <<'JSON'
{"title": "t", "nodes": [{"id": "a", "label": "A", "summary": "s"}, {"id": "a", "label": "B", "summary": "s"}]}
JSON
expect "duplicate ids are rejected" 1 'duplicate id "a"' "$CG" validate "$WORK/dupe.json"

cat > "$WORK/untitled.json" <<'JSON'
{"nodes": [{"id": "a", "label": "A", "summary": "s"}]}
JSON
expect "a title is required" 1 "title: missing" "$CG" validate "$WORK/untitled.json"

cat > "$WORK/orphan.json" <<'JSON'
{"title": "t", "nodes": [{"id": "a", "label": "A", "summary": "s"}, {"id": "b", "label": "B", "summary": "s"},
 {"id": "c", "label": "C", "summary": "s"}], "edges": [{"from": "a", "to": "b", "label": "x"}]}
JSON
expect "an unconnected bubble is a warning, not an error" 0 '"c" is not connected' "$CG" validate "$WORK/orphan.json"

expect "a missing file is reported" 1 "no such file" "$CG" validate "$WORK/nope.json"
expect "open refuses an invalid graph" 1 "fix the file" "$CG" open "$WORK/typo.json"
expect "an unknown command is a usage error" 64 "unknown command" "$CG" frobnicate

echo "rendering"
expect "render writes an image" 0 "Rendered" "$CG" render "$ROOT/skill/examples/git-internals.json" --out "$WORK/out.png" --size 1200x800
if [ "$(sips -g pixelWidth "$WORK/out.png" 2>/dev/null | awk '/pixelWidth/ {print $2}')" = "2400" ]; then pass "the image is 1200 points wide at 2x"
else fail "the image is 1200 points wide at 2x"; fi

echo "windows"
expect "close with nothing open says so" 0 "No window is open" "$CG" close "$ROOT/skill/examples/git-internals.json"

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
