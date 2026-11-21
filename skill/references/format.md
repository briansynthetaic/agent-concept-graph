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
