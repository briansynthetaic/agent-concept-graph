#!/bin/bash
# Build and deliberately break only a fresh, disposable checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/skill" "$work/scripts"
cp -R "$root/Sources" "$root/Resources" "$work/"
cp -R "$root/skill/scripts" "$root/skill/examples" "$work/skill/"
cp "$root/scripts/build.sh" "$work/scripts/"
/usr/bin/python3 - "$work" <<'PY'
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
validate = [root / "skill/scripts/concept-graph", "validate", root / "skill/examples/conversation.json"]
with ThreadPoolExecutor(max_workers=2) as workers:
    first = list(workers.map(lambda _: subprocess.run(validate, capture_output=True, check=True, timeout=180), range(2)))
assert sum(b"built " in run.stderr for run in first) == 1
install = root / "skill/bin"
bundle = install / "ConceptGraph.app"
def files():
    return {f.relative_to(install): sha256(f.read_bytes()).digest() for f in install.rglob("*") if f.is_file()}
previous = files()
assert (bundle / "Contents/Resources/ConceptGraph.icns").stat().st_size > 0
(root / "Sources/ConceptGraph/IntentionalFailure.swift").write_text('#error("test failed rebuild")')
broken = subprocess.run([root / "scripts/build.sh"], capture_output=True, timeout=120)
assert broken.returncode != 0 and b"test failed rebuild" in broken.stderr and files() == previous
subprocess.run(["codesign", "--verify", "--strict", bundle], check=True)
subprocess.run(validate, check=True)
print("Concurrent first builds and preservation of a signed working installation passed.")
PY
