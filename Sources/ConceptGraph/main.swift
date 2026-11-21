import Foundation

let usage = """
concept-graph — show a concept graph (bubbles and labelled arrows) in a native macOS window.

usage:
  concept-graph open <graph.json> [--wait]
      Validate the file and show it. Returns as soon as the window is up; the window
      runs as its own process, reloads whenever the file changes, and exits when the
      user closes it. Running it again on a file that is already open just refreshes
      that window and brings it to the front. --wait blocks until the window is closed.

  concept-graph validate <graph.json>
      Check the file and report every problem, without opening anything.

  concept-graph render <graph.json> --out <image.png> [--size 1600x1000] [--light | --dark]
      Draw the graph to a PNG without opening a window (to check how it will look).

  concept-graph close <graph.json>
      Close the window showing this file, if there is one.

exit status: 0 on success, 1 if the graph has errors or the command failed, 64 for bad usage.
"""

func say(_ text: String) {
    print(text)
}

func complain(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func fail(_ text: String, code: Int32 = 1) -> Never {
    complain("error: " + text)
    exit(code)
}

func badUsage(_ text: String) -> Never {
    complain("error: " + text + "\n\n" + usage)
    exit(64)
}

func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

func describe(_ graph: ConceptGraph) -> String {
    var parts = [plural(graph.nodes.count, "concept"), plural(graph.edges.count, "relationship")]
    if !graph.groups.isEmpty { parts.append(plural(graph.groups.count, "group")) }
    return parts.joined(separator: ", ")
}

/// Loads and checks a graph file, printing every diagnostic. Exits if it cannot be used.
func loadGraph(_ argument: String) -> (path: String, graph: ConceptGraph) {
    guard let path = Launcher.canonicalPath(argument) else { fail("no such file: \(argument)") }
    let result = GraphParser.load(path: path)
    for diagnostic in result.diagnostics { complain(diagnostic.line) }
    guard let graph = result.graph else {
        fail("\(plural(result.errors.count, "error")) in \(path) — fix the file and run the command again")
    }
    return (path, graph)
}

/// Splits arguments into positional values and options. `valued` lists the options that take a value.
func parse(_ arguments: [String], flags: Set<String>, valued: Set<String> = []) -> (positional: [String], options: [String: String]) {
    var positional: [String] = []
    var options: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if valued.contains(argument) {
            guard index + 1 < arguments.count else { badUsage("\(argument) needs a value") }
            options[argument] = arguments[index + 1]
            index += 1
        } else if flags.contains(argument) {
            options[argument] = ""
        } else if argument.hasPrefix("--") {
            badUsage("unknown option \(argument)")
        } else {
            positional.append(argument)
        }
        index += 1
    }
    return (positional, options)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    say(usage)
    exit(64)
}
arguments.removeFirst()

switch command {
case "open":
    let (positional, options) = parse(arguments, flags: ["--wait"])
    guard positional.count == 1 else { badUsage("open takes exactly one graph file") }
    let (path, graph) = loadGraph(positional[0])
    if let pid = Launcher.viewerPID(for: path) {
        kill(pid, SIGUSR1)
        say("Already open: refreshed the window for \"\(graph.title)\" and brought it to the front (pid \(pid)).")
    } else {
        do {
            let pid = try Launcher.spawnViewer(file: path)
            say("Opened \"\(graph.title)\": \(describe(graph)) (pid \(pid)).")
        } catch {
            fail("\(error)")
        }
    }
    say("The window follows \(path): rewrite the file to update it. It closes when the user closes it.")
    if options["--wait"] != nil {
        Launcher.waitUntilClosed(file: path)
        say("The window was closed.")
    }

case "validate":
    let (positional, _) = parse(arguments, flags: [])
    guard positional.count == 1 else { badUsage("validate takes exactly one graph file") }
    let (_, graph) = loadGraph(positional[0])
    say("ok: \"\(graph.title)\" — \(describe(graph))")

case "render":
    let (positional, options) = parse(arguments, flags: ["--light", "--dark"], valued: ["--out", "--size"])
    guard positional.count == 1 else { badUsage("render takes exactly one graph file") }
    guard let out = options["--out"] else { badUsage("render needs --out <image.png>") }
    var size = CGSize(width: 1600, height: 1000)
    if let text = options["--size"] {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, (400...6000).contains(parts[0]), (300...6000).contains(parts[1]) else {
            badUsage("--size must look like 1600x1000 (between 400x300 and 6000x6000)")
        }
        size = CGSize(width: parts[0], height: parts[1])
    }
    let dark: Bool? = options["--dark"] != nil ? true : (options["--light"] != nil ? false : nil)
    let (_, graph) = loadGraph(positional[0])
    do {
        try Snapshot.render(graph: graph, to: out, size: size, dark: dark)
        say("Rendered \"\(graph.title)\" (\(describe(graph))) to \(out)")
    } catch {
        fail("\(error)")
    }

case "close":
    let (positional, _) = parse(arguments, flags: [])
    guard positional.count == 1 else { badUsage("close takes exactly one graph file") }
    // The file itself may already be gone; the window can still be found by its path.
    let path = Launcher.canonicalPath(positional[0]) ?? URL(fileURLWithPath: positional[0]).standardizedFileURL.path
    guard let pid = Launcher.viewerPID(for: path) else {
        say("No window is open for \(path).")
        break
    }
    kill(pid, SIGTERM)
    Launcher.waitUntilClosed(file: path)
    say("Closed the window for \(path).")

case "__viewer":
    // Internal: the detached process that `open` starts. Runs until the window closes.
    guard arguments.count == 1, let path = Launcher.canonicalPath(arguments[0]) else { fail("__viewer needs a graph file") }
    let result = GraphParser.load(path: path)
    guard let graph = result.graph else {
        for diagnostic in result.errors { complain(diagnostic.line) }
        exit(1)
    }
    ViewerController.run(path: path, graph: graph)

case "help", "--help", "-h":
    say(usage)

default:
    badUsage("unknown command \"\(command)\"")
}
