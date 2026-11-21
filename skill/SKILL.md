---
name: concept-graph
description: >-
  Show ideas and how they relate as an interactive concept graph in a native macOS
  window, with bubbles for concepts, labelled arrows for relationships, zoom, pan and
  click-to-inspect. Use when the user asks for a concept graph, concept map, mind map
  or bubble view; asks to map, project, visualize or "show how this fits together" for
  the conversation so far, any part of it, a topic, a plan, a decision or a codebase;
  or asks to update or extend a graph that is already open. macOS only.
argument-hint: "[what to map — leave blank for the whole conversation]"
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

Requested scope: $ARGUMENTS

If nothing follows "Requested scope:", go by what the user just asked. If they named no
subject at all, map the whole conversation so far.

## Steps

1. **Settle the scope.** It is one of:
   - *The whole conversation* — everything discussed so far.
   - *A component of it* — "the pricing part", "the options we compared", "your last
     answer", "everything about caching". Map that and leave the rest out.
   - *Something outside the conversation* — a topic, a plan, a codebase. Do whatever
     reading or research the question needs first, then map what you found.
2. **Write the graph** as JSON (format below) to a scratch file: your session's scratch
   directory if you have one, otherwise `/tmp/concept-graphs/<short-name>.json`. Use the
   user's project only if they ask to keep the graph.
3. **Open it:**
   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/concept-graph" open /path/to/graph.json
   ```
   This validates the file, shows the window and returns straight away. If it reports
   errors, nothing was opened: fix the file and run it again. Warnings are advice; act on
   the ones that are right.
4. **Tell the user** in a sentence or two what the graph shows and where to start
   looking. Don't repeat its contents in the chat; the window is the answer.

## Projecting a conversation

The user can ask for this at any point, as often as they like, for all of the
conversation or any slice of it. What they want is the *shape* of what has been said:
what it was about, what was established, what was decided, what is still hanging.

- **Bubbles are the things discussed, not the turns.** Goals, questions, ideas, options,
  findings, constraints, decisions, risks, files and artefacts, next steps. A bubble
  called "User asked about X" is a transcript line; the bubble is "X".
- **Arrows say how one thing bore on another:** *led to*, *answers*, *rules out*,
  *depends on*, *refines*, *contradicts*, *chosen over*, *blocked by*. Use
  `"style": "dashed"` for anything tentative, rejected or unresolved.
- **Group by whatever gives two to six honest clusters.** For a working session that is
  often the status of each idea (what we want / what we found / options / decided /
  still open). For an exploratory chat it is usually the topics.
- **Importance follows the conversation's own emphasis.** 5 for the one or two things it
  was really about, 4 for decisions and turning points, 3 by default, 1–2 for asides.
- **`summary` is where the idea stands now**, in the user's own terms. **`detail` is how
  it got there**: the reasoning, who raised it, and whether it is settled, open or
  dropped. Someone who clicks a bubble next week should not need the transcript.
- **Stay faithful.** Map what was said, not what you would have liked to say. If earlier
  parts of the conversation are no longer in your context, say so in the graph's
  `summary` rather than reconstructing them.

`examples/conversation.json` in this skill's directory is a complete example.

## Updating a graph that is open

Rewrite the same file and the window updates within a second: new bubbles pop in,
removed ones disappear, and everything else stays where the user left it. So:

- Keep one file per subject and remember its path for the rest of the session. When the
  user asks to add to, correct or extend the map, or the conversation has moved on and
  they ask to "update the map", edit that file. No need to run `open` again, though it
  is harmless and brings the window back to the front if they have lost it.
- **Keep ids stable.** A bubble is recognised by its `id`. Rename an id and the viewer
  sees a different concept, which loses the position the user gave it.
- A different subject gets a different file, which opens a second window.
- To point at one bubble, set `"focus"` to its id. Changing `focus` in an open graph
  selects that bubble and scrolls to it.

## The graph file

```json
{
  "title": "Why the build is slow",
  "summary": "Three causes, one root: every run starts from a **cold cache**.",
  "groups": [
    { "id": "cause", "label": "Causes" },
    { "id": "fix", "label": "Fixes", "color": "green" }
  ],
  "nodes": [
    {
      "id": "cold-cache",
      "label": "Cold cache",
      "group": "cause",
      "importance": 5,
      "summary": "Every CI run reinstalls and rebuilds its dependencies from nothing.",
      "detail": "The cache key includes the commit hash, so it never hits.\n\n- install: ~6 min\n- native rebuilds: ~15 min",
      "refs": [".github/workflows/ci.yml:41", "https://example.com/ci-caching"]
    },
    { "id": "remote-cache", "label": "Remote cache", "group": "fix",
      "summary": "Share build outputs between runs." }
  ],
  "edges": [
    { "from": "remote-cache", "to": "cold-cache", "label": "fixes" }
  ],
  "focus": "cold-cache"
}
```

| Field | | Meaning |
|---|---|---|
| `title` | required | Names the subject. Shown as the window title. |
| `summary` | | The takeaway in one to three sentences. Heads the outline the user sees before clicking anything. Inline Markdown allowed. |
| `groups[]` | | `id`, `label`, optional `color`. Each group gets a colour and its bubbles are drawn together inside a labelled outline. Colours are assigned automatically; override with `blue` `orange` `green` `purple` `pink` `teal` `yellow` `red` `indigo` `mint` `brown` `cyan` `gray` or `#RRGGBB` only when a colour carries meaning. |
| `nodes[].id` | required | Unique, stable, never shown. Short kebab-case. |
| `nodes[].label` | required | The words in the bubble. One to three words. |
| `nodes[].summary` | | One plain-text sentence. Appears in the outline, at the top of the inspector, and inside the bubble once the user zooms in. |
| `nodes[].detail` | | The full explanation, shown in the inspector. Paragraphs, `- ` bullets, and inline `**bold**`, `*italic*`, `` `code` `` and `[links](https://…)`. |
| `nodes[].group` | | A group `id`. Undeclared groups are created with the id as their label. |
| `nodes[].importance` | | 1–5, default 3. Sets the bubble's size. |
| `nodes[].refs` | | Strings: file paths (`src/a.ts:42`) or URLs. Web URLs are clickable. |
| `edges[].from`, `.to` | required | Node ids. The arrow points at `to`. |
| `edges[].label` | | A short verb phrase that reads *from → to*: "depends on", "produces". |
| `edges[].style` | | `"solid"` (default) or `"dashed"`. |
| `edges[].directed` | | `false` draws a plain line for symmetric relationships. Default `true`. |
| `focus` | | A node id to select when the window opens or the file changes. |

Unknown fields are ignored with a warning, so a misspelt field never fails silently.

## What makes a graph worth looking at

- **8 to 30 bubbles.** Fewer than six is a list; say it in text. More than forty is a
  haystack; merge the minor ones or make two graphs.
- **The relationships are the point.** Label every arrow, and prefer a specific verb
  ("invalidates") to a vague one ("relates to"). Every bubble should connect to
  something; an orphan usually means a missing arrow or a concept that does not belong.
- **Short labels, real summaries.** A bubble holds a few words. Put the thinking in
  `summary` and `detail`, because that is what the user reads when they click, and a
  bubble with nothing behind it is a dead end.
- **Use the whole importance range.** If everything is a 3, nothing stands out. One or
  two 5s tell the eye where to begin.
- **Groups should mean something** to the user: layers, phases, owners, status. Two to
  six of them.

## Commands

```bash
CG="${CLAUDE_SKILL_DIR}/scripts/concept-graph"
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
