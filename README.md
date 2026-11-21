# Concept Graph

Concept Graph is a skill for an agent running on your Mac. Ask it to map a conversation, explain a codebase, or sketch a system design. Concept Graph opens the answer in a native Mac window. Click a bubble to read the reasoning, follow an arrow to a related idea, or drag concepts into an arrangement that helps you think. The agent supplies the ideas and relationships. The viewer handles their size, color, and layout.

![Concept Graph showing how Git stores history](docs/screenshot.png)

## Install once on your Mac

You need **macOS 14 or later** and the **Xcode Command Line Tools**. If you need the tools, run `xcode-select --install` in Terminal and let the installer finish.

With Homebrew installed, run:

```bash
brew tap briansynthetaic/concept-graph https://github.com/briansynthetaic/agent-concept-graph.git
brew install briansynthetaic/concept-graph/concept-graph
```

Homebrew prints the next step. Run the command for each agent you use:

| Agent | Run in Terminal |
|---|---|
| Claude Code | `concept-graph link claude` |
| Codex | `concept-graph link codex` |
| Other agent that supports linked skills | `concept-graph link --dir "/path/to/skills"` |

You can see these instructions again with `brew info concept-graph`. If you're switching from a checkout installation, run its `make uninstall` for Claude Code or `make uninstall AGENT=codex` for Codex in the original checkout before linking that agent through Homebrew.

### Install from source

Clone the repository somewhere you plan to keep it. If you already have a checkout, open Terminal in that folder and skip this step.

```bash
git clone https://github.com/briansynthetaic/agent-concept-graph.git
cd agent-concept-graph
```

Choose the install command for the agent you use. Each command builds the viewer and makes the skill available across projects for your Mac user account.

| Agent | Run in the checkout | Installed skill |
|---|---|---|
| Claude Code | `make install` | `~/.claude/skills/concept-graph` |
| Codex | `make install AGENT=codex` | `~/.agents/skills/concept-graph` |

If you use both agents, run both commands. The installed links point back to this checkout. For another local agent that supports symlinked skill directories, run `make install SKILLS_DIR="/path/to/its/skills"` with its actual skills folder. An agent with local shell access can also run the launcher directly.

## Ask your agent for a graph

In the conversation you want to visualize, ask in plain language:

> Show me a concept graph of the two caching approaches we discussed. Include what each one speeds up and why we chose one. Leave out deployment.

You can also invoke the skill directly. Type one of these **in your agent chat** and put what you want drawn after the skill name.

| Agent | Example shortcut |
|---|---|
| Claude Code | `/concept-graph Map only the caching options and our decision.` |
| Codex CLI or IDE | `$concept-graph Map only the caching options and our decision.` |

The agent uses the conversation and opens the graph in a Mac window. In a conversation already underway, invoking the skill by itself maps the discussion so far. If your agent was running during installation and cannot find the skill, start a fresh session.

You can specify the **source**, **scope**, and **output** in the same request:

- **From code:** “Map the checkout request from the HTTP handler to the database. Include retries and skip the UI.”
- **Update an open graph:** “Add the timeout behavior we just agreed on to the payment worker.”
- **Export an image:** “Save a PNG of just the payment flow as `payment-flow.png` in this project.”

## Work through a design with your agent

Right-click a bubble and choose **Compose Agent Prompt…**. For example, on a delivery worker you might ask “What happens if delivery succeeds but recording the outcome fails?” Choose **Copy Prompt**, then paste it into your agent conversation. The toolbar prompt button and ⇧⌘P also open the composer.

| Choose | What the agent receives |
|---|---|
| Ask a question | Your question, the selected concept, and its direct connections. With nothing selected, the context covers the whole graph. |
| Expand the graph | Your request, the relevant concepts, and the file path so the agent can deepen an explanation or add a missing relationship. |
| Build this system | Implementation instructions and the entire design, including concept details and references, even when a bubble is selected. |

The clipboard handoff puts you in control of which conversation receives a prompt. Dragging bubbles changes the view locally. To record a design decision, ask the agent to add it to the graph.

## Navigate the window

| To | Do this |
|---|---|
| Read a concept | Click its bubble. The inspector shows its explanation and connections. |
| Explore its neighborhood | Double-click the bubble to frame it with its neighbors, or click a connected concept in the inspector. |
| Move a bubble or pan | Drag the bubble or the background. |
| Zoom | Pinch or use the toolbar. Zoom in to reveal arrow labels and bubble summaries. |
| Find a concept | Press ⌘F, type a term, then press Return to step through matches. |
| See the whole graph | Press ⌘0. |

The inspector also provides a text outline for VoiceOver. Groups can organize related concepts on the canvas. Each concept is a single bubble.

## Update or uninstall

**Homebrew installation.** Run `brew upgrade concept-graph`, then reopen existing graph windows. Every agent you linked uses the updated skill and viewer. To uninstall, run `concept-graph unlink claude` or `concept-graph unlink codex` for each linked agent (or `unlink --dir` with the custom path), then `brew uninstall concept-graph`.

**Source installation.** From the original checkout, pull the latest changes and rebuild:

```bash
git pull --ff-only && make
```

Close and reopen any running graph windows to use the new viewer. All linked agents use the same updated checkout, so one rebuild covers them all.

To remove the installed link, run `make uninstall` for Claude Code or `make uninstall AGENT=codex` for Codex. For a custom skills folder, pass the same `SKILLS_DIR` you used at install time.

## Use the command line

Homebrew installs the `concept-graph` command on your PATH. The examples below use the source launcher and sample files. Run these examples from the checkout. From another directory, use the launcher's absolute path.

```bash
CG=./skill/scripts/concept-graph
"$CG" validate skill/examples/git-internals.json
"$CG" open skill/examples/git-internals.json
"$CG" render skill/examples/git-internals.json --out git-internals.png
"$CG" close skill/examples/git-internals.json
```

Opening a graph returns control to the terminal immediately. Add `--wait` to wait for the window to close. Opening the same file again brings its window forward. If an edit produces invalid JSON, the viewer shows the last valid graph and explains the error.

For more examples, see the [Git walkthrough](skill/examples/git-internals.json), [conversation map](skill/examples/conversation.json), and [system design](skill/examples/report-delivery.json). The [agent skill](skill/SKILL.md) describes the everyday workflow. The [field reference](skill/references/format.md) documents the full JSON format. Run `make help` for common commands or `make check` to build and test the viewer.
