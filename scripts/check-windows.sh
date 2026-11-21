#!/bin/bash
# Exercise only windows belonging to newly created documents.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
/usr/bin/python3 - "$root" <<'PY'
import concurrent.futures
import hashlib
import json
import pathlib
import re
import select
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
cli = root / "skill/bin/concept-graph"
app = cli.with_name("ConceptGraph.app")
examples = root / "skill/examples"
arrangements = pathlib.Path.home() / "Library/Application Support/Concept Graph/Arrangements"

def run(*args):
    result = subprocess.run([cli, *args], text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr}")
    return result.stdout

def owner(output):
    return int(re.search(r"\(pid (\d+)\)", output).group(1))

def await_condition(predicate, description):
    deadline = time.monotonic() + 10
    while not predicate():
        if time.monotonic() >= deadline:
            raise RuntimeError(description)
        time.sleep(.05)

with tempfile.TemporaryDirectory() as directory:
    graph = pathlib.Path(directory).resolve() / "lifecycle.conceptgraph"
    graph.write_bytes((examples / "conversation.json").read_bytes())
    state = arrangements / (hashlib.sha256(str(graph).encode()).hexdigest() + ".json")
    waiter = None
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(lambda _: run("open", graph), range(2)))
        pid = owner(results[0])
        assert pid > 1 and owner(results[1]) == owner(run("open", graph)) == pid
        waiter = subprocess.Popen([cli, "open", graph, "--wait"], stdout=subprocess.PIPE, text=True)
        # --wait flushes the readiness acknowledgement before blocking.
        assert select.select([waiter.stdout], [], [], 10)[0] and owner(waiter.stdout.readline()) == pid
        edit = graph.with_suffix(".tmp")
        edit.write_text("{")
        edit.replace(graph)
        time.sleep(.9)
        assert waiter.poll() is None
        edit.write_bytes((examples / "report-delivery.json").read_bytes())
        edit.replace(graph)
        expected = {"worker", "schedule", "planner", "runs"}
        await_condition(lambda: state.exists() and set(json.loads(state.read_bytes())["places"]) == expected,
                        "window did not apply the atomic rewrite")
        run("close", graph)
        assert "window was closed" in waiter.communicate(timeout=5)[0] and waiter.returncode == 0
        # Launch Services delivers the same document event used by Finder. Select this build explicitly.
        saved = json.loads(state.read_bytes())
        saved["places"]["worker"] = {"point": [120, -300], "pinned": True}
        saved.update(center=[44, 80], scale=1.25, automaticCamera=False, selection=["worker", "runs"])
        state.write_text(json.dumps(saved))
        # A fresh document-opener process exits after the viewer acknowledges the open.
        subprocess.run(["/usr/bin/open", "-W", "-n", "-a", app, graph], check=True, timeout=20)
        assert "Closed the window" in run("close", graph)
        reopened = json.loads(state.read_bytes())
        assert reopened["places"]["worker"] == saved["places"]["worker"]
        assert reopened["selection"] == saved["selection"] and reopened["center"] == saved["center"]
        assert "No window is open" in run("close", graph)
    finally:
        run("close", graph)
        if waiter is not None:
            waiter.wait(timeout=5)
        state.unlink(missing_ok=True)
print("Concurrent open, reload recovery, wait, close and Finder document open passed.")
PY
