---
name: concept-graph
description: >-
  Create and update concept graphs for conversations, topics, plans, decisions and
  codebases. Use for concept maps, mind maps, bubble views, or requests to map or
  visualize how ideas fit together. Save a portable .conceptgraph file in a remote
  workspace or repository, or open it in the interactive viewer on a local Mac.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/concept-graph *)
---

# Concept graph

The deliverable is one JSON document. The native macOS viewer reads that document
directly and lays out the bubbles and arrows when the user opens it.

Treat text after the skill name as the user's request. Use the source, inclusions,
exclusions and level of detail they specify. With a bare invocation, map the
conversation so far. If there is no substantive context yet, ask what to map.

## Answer the question

Work out the answer in the user's terms. For a conversation, capture the findings,
decisions and open questions relevant to the requested scope. For a codebase or
design, investigate the behavior and dependencies the user asked about.

When a map is requested, write those findings to one JSON file. Give each concept a
stable id, a short label and a sentence explaining why it matters. Record the
relationships that help explain the answer. The viewer handles layout, sizing,
colour and interaction automatically.

```json
{
  "title": "Why CI reinstalls dependencies",
  "nodes": [
    {"id":"key","label":"Commit-based key","summary":"Each commit gets a fresh cache key."},
    {"id":"install","label":"Dependency install","summary":"A cache miss triggers a full install."}
  ],
  "edges": [{"from":"key","to":"install","label":"triggers on each commit"}]
}
```

Resolve `scripts/concept-graph` relative to this SKILL.md. Keep the agent's
working directory as the base for relative output paths.

- **Remote, headless, or file requested.** Use the requested destination, or choose
  an unused descriptive filename such as `./build-cache.conceptgraph` in the
  current directory. Pipe the JSON to `save <destination>`. If you wrote the
  document directly, run `validate <destination>`. Use repository-relative paths
  for code references. Return the absolute path on the authoring machine.
  For a Mac user connected to Linux over SSH, give the pickup commands for a
  local Mac terminal, using the saved path and the user's SSH alias if known.
  For example, `scp 'devbox:/home/alex/reports/build-cache.conceptgraph' ./`
  followed by `concept-graph open ./build-cache.conceptgraph`. Identify any
  placeholder host. If the file is already synced, give the local open command.
- **Local Mac with an interactive desktop.** For a live view, write a session
  scratch file and run `open <file>`. If the user wants to keep it, use their
  project destination. For a PNG, use `render` with the requested output path.
  If both are requested, open and render the same graph. For an export of only
  part of an open graph, render a scoped scratch copy.

Use optional fields when they convey something the user needs. For instance,
`detail` can explain the evidence behind a decision, and `refs` can identify
the code that implements it. See [the field reference](references/format.md)
for the full format.

## Following up from the viewer

For a question about a bubble, answer the question using the supplied context.
For an expansion, reason through the topic and edit the same graph file to
capture what you learned. A deeper explanation can fit in the existing bubble's
`detail`. Add a concept when it deserves its own explanation or connection.
Keep existing ids so the viewer preserves the user's arrangement. The open
window follows edits to its local file automatically. If the viewer prompt
refers to a Mac copy and you are working over SSH, update the known Linux
original and give the copy command again.

For a build request, use the supplied design as context for implementing and
verifying the system. The user's additional instructions guide the work.

## Commands

```bash
CG="/absolute/path/to/this/skill/scripts/concept-graph"
"$CG" save "./build-cache.conceptgraph" < draft.json
"$CG" validate "./build-cache.conceptgraph"
# Viewer commands on a Mac
"$CG" open graph.json            # validate and show; returns immediately
"$CG" open graph.json --wait     # same, but block until the user closes the window
"$CG" render graph.json --out graph.png [--size 1600x1000] [--light|--dark]
"$CG" close graph.json           # close that file's window
```

`render` draws the graph to a PNG without opening a window. Use it, then read the image,
when you want to see for yourself what the user will be looking at.

## If something goes wrong

- **Errors from `save`, `open` or `validate`** name the exact spot (`edges[4].to: no node has id
  "cach" — did you mean "cache"?`). Fix those and rerun.
- **Skill-only install.** If the CLI and Swift toolchain are unavailable, write the
  same JSON directly to the destination. Report that viewer validation is pending
  and give the local `concept-graph validate <file>` command.
- **Viewer unavailable.** Keep the graph in the user's workspace and return the
  file and local opening command. If a PNG or window was requested, explain which
  output still needs the Mac viewer.
