---
name: concept-graph
description: >-
  Show ideas and how they relate as an interactive concept graph in a native macOS
  window, with bubbles for concepts, labelled arrows for relationships, zoom, pan and
  click-to-inspect. Use when the user asks for a concept graph, concept map, mind map
  or bubble view; asks to map, project, visualize or "show how this fits together" for
  the conversation so far, any part of it, a topic, a plan, a decision or a codebase;
  or asks to update or extend a graph that is already open. macOS only.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/concept-graph *)
---

# Concept graph

This skill lets you answer in a picture instead of a wall of text. You decide what the
concepts are and how they relate, and write that down as one JSON file. A native macOS
viewer does everything else: it sizes and colours the bubbles, lays them out, and gives
the user a window they can zoom, pan, search and click around in. You never choose
coordinates or colours, so your attention stays on the thinking.

The window is its own process. It appears when you run `open`, follows the JSON file for
as long as it is up, and exits when the user closes it.

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

Use a session scratch file or `/tmp/concept-graphs/<short-name>.json` unless the
user asks to keep the graph in their project. Resolve `scripts/concept-graph` relative
to this SKILL.md. By default, run it with `open /path/to/graph.json` to validate
and show the interactive graph. For a PNG request, use `render` with the requested
output path and return the image location. If the user asks for both, open and
render the same graph. For an export of only part of an open graph, render a
scoped scratch copy so the full working graph stays available.

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
window follows edits automatically.

For a build request, use the supplied design as context for implementing and
verifying the system. The user's additional instructions guide the work.

## Commands

```bash
CG="/absolute/path/to/this/skill/scripts/concept-graph"
"$CG" open graph.json            # validate and show; returns immediately
"$CG" open graph.json --wait     # same, but block until the user closes the window
"$CG" validate graph.json        # check only; lists every problem with its JSON path
"$CG" render graph.json --out graph.png [--size 1600x1000] [--light|--dark]
"$CG" close graph.json           # close that file's window
```

`render` draws the graph to a PNG without opening a window. Use it, then read the image,
when you want to see for yourself what the user will be looking at.

## If something goes wrong

- **Errors from `open` or `validate`** name the exact spot (`edges[4].to: no node has id
  "cach" — did you mean "cache"?`). Fix those and rerun.
- **First run in a new checkout** compiles the viewer, which takes about half a minute
  and needs the Xcode Command Line Tools (`xcode-select --install`).
- **Not on macOS, or the viewer cannot start:** say so plainly and give the same content
  as a short outline in the chat instead.
