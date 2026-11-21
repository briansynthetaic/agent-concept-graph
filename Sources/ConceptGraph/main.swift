import Foundation

let authoringUsage = """
  concept-graph save <destination.conceptgraph>
      Read graph JSON from standard input, validate it, and atomically replace the destination.

  concept-graph validate <graph>
      Check a .conceptgraph or .json document without opening a window.
"""

#if os(macOS)
let viewerUsage = """
  concept-graph open <graph.json> [--wait]
      Validate the file and show it. Returns as soon as the window is up; the window
      runs as its own process, reloads whenever the file changes, and exits when the
      user closes it. Running it again on a file that is already open just refreshes
      that window and brings it to the front. --wait blocks until the window is closed.

  concept-graph render <graph.json> --out <image.png> [--size 1600x1000] [--light | --dark]
      Draw the graph without opening a window. Size is in points, at 2 pixels per point.

  concept-graph close <graph.json>
      Close the window showing this file, if there is one.
"""
#else
let viewerUsage = "  Open the saved file on a Mac with concept-graph open <graph>."
#endif

let usage = """
usage:
\(authoringUsage)

\(viewerUsage)

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

func checkedGraph(_ result: ParseResult, source: String) -> ConceptGraph {
    for diagnostic in result.diagnostics { complain(diagnostic.line) }
    guard let graph = result.graph else {
        fail("\(plural(result.errors.count, "error")) in \(source) — fix the file and run the command again")
    }
    return graph
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
    #if os(macOS)
    if Bundle.main.bundleURL.pathExtension == "app" { DocumentOpener.run() }
    #endif
    say(usage)
    exit(64)
}
arguments.removeFirst()

switch command {
case "save":
    let (positional, _) = parse(arguments, flags: [])
    guard positional.count == 1 else { badUsage("save takes one destination and reads graph JSON from standard input") }
    let destination = URL(fileURLWithPath: positional[0])
    do {
        let bytes = try FileHandle.standardInput.readToEnd() ?? Data()
        let graph = checkedGraph(GraphParser.parse(data: bytes), source: "standard input")
        try bytes.write(to: destination, options: .atomic)
        say("Saved \"\(graph.title)\" (\(describe(graph))) to \(destination.path)")
    } catch { fail("could not save \(destination.path): \(error.localizedDescription)") }

case "validate":
    let (positional, _) = parse(arguments, flags: [])
    guard positional.count == 1 else { badUsage("validate takes exactly one graph file") }
    let path = positional[0]
    guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }
    let graph = checkedGraph(GraphParser.load(path: path), source: path)
    say("ok: \"\(graph.title)\" — \(describe(graph))")

#if os(macOS)
case "open":
    let (positional, options) = parse(arguments, flags: ["--wait"])
    guard positional.count == 1 else { badUsage("open takes exactly one graph file") }
    let (path, graph) = loadGraph(positional[0])
    do {
        let (connection, existing) = try Launcher.openViewer(file: path, wait: options["--wait"] != nil)
        say("\(existing ? "Already open" : "Opened"): \(graph.title) — \(describe(graph)) (pid \(connection.pid)).")
        say("The window follows \(path): rewrite the file to update it. It closes when the user closes it.")
        if options["--wait"] != nil {
            fflush(stdout)
            try connection.waitUntilClosed()
            say("The window was closed.")
        }
    } catch { fail("\(error)") }

case "render":
    let (positional, options) = parse(arguments, flags: ["--light", "--dark"], valued: ["--out", "--size"])
    guard positional.count == 1 else { badUsage("render takes exactly one graph file") }
    guard let out = options["--out"] else { badUsage("render needs --out <image.png>") }
    var size = CGSize(width: 1600, height: 1000)
    if let text = options["--size"] {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, (400...6000).contains(width), (300...6000).contains(height) else {
            badUsage("--size must look like 1600x1000 (between 400x300 and 6000x6000)")
        }
        size = CGSize(width: width, height: height)
    }
    guard options["--light"] == nil || options["--dark"] == nil else { badUsage("choose either --light or --dark") }
    let dark: Bool? = options["--dark"] != nil ? true : (options["--light"] != nil ? false : nil)
    let (path, graph) = loadGraph(positional[0])
    do {
        try GraphFile.requireDistinct(source: path, destination: URL(fileURLWithPath: out))
        try Snapshot.render(graph: graph, source: path, to: out, size: size, dark: dark)
        say("Rendered \"\(graph.title)\" (\(describe(graph))) to \(out)")
    } catch {
        fail("\(error)")
    }

case "close":
    let (positional, _) = parse(arguments, flags: [])
    guard positional.count == 1 else { badUsage("close takes exactly one graph file") }
    // The file itself may already be gone; the window can still be found by its path.
    let path = Launcher.documentPath(positional[0])
    do {
        if try Launcher.closeViewer(file: path) {
            say("Closed the window for \(path).")
        } else {
            say("No window is open for \(path).")
        }
    } catch { fail("\(error)") }

case "__viewer":
    // Internal: the detached process that `open` starts. Runs until the window closes.
    guard arguments.count == 1, let path = Launcher.canonicalPath(arguments[0]) else { fail("__viewer needs a graph file") }
    do {
        guard let lock = try InstanceLock(file: path) else { exit(0) }
        let file = try GraphFile(path)
        guard let graph = file.result.graph else {
            file.result.errors.forEach { complain($0.line) }
            exit(1)
        }
        ViewerController.run(path: path, graph: graph, file: file, lock: lock)
    } catch { fail(error.localizedDescription) }
#else
case "open", "render", "close":
    fail("\(command) requires the macOS viewer. Use save to create a document and open it on your Mac.")
#endif

case "help", "--help", "-h":
    say(usage)

default:
    badUsage("unknown command \"\(command)\"")
}

#if os(macOS)
/// Viewer processes and window ownership use the canonical path to a document.
func loadGraph(_ argument: String) -> (path: String, graph: ConceptGraph) {
    guard let path = Launcher.canonicalPath(argument) else { fail("no such file: \(argument)") }
    return (path, checkedGraph(GraphParser.load(path: path), source: path))
}
#endif
