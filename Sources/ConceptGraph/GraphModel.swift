import Foundation
import CoreFoundation

// MARK: - Model
//
// This is the whole contract between an agent and the viewer: the agent writes
// one JSON object of this shape, the viewer does everything else (sizing,
// colouring, layout, interaction).

struct ConceptNode: Equatable {
    var id: String
    var label: String
    var summary: String
    var detail: String
    var group: String?
    var importance: Int
    var refs: [String]
}

struct ConceptEdge: Equatable {
    var from: String
    var to: String
    var label: String
    var dashed: Bool
    var directed: Bool
}

struct ConceptGroup: Equatable {
    var id: String
    var label: String
    var color: String?
}

struct ConceptGraph: Equatable {
    var title: String
    var summary: String
    var groups: [ConceptGroup]
    var nodes: [ConceptNode]
    var edges: [ConceptEdge]
    var focus: String?
}

// MARK: - Diagnostics

struct Diagnostic {
    enum Severity: String { case error, warning }
    var severity: Severity
    var path: String
    var message: String

    var line: String {
        path.isEmpty ? "\(severity.rawValue): \(message)" : "\(severity.rawValue): \(path): \(message)"
    }
}

struct ParseResult {
    /// Present only when there are no errors.
    var graph: ConceptGraph?
    var diagnostics: [Diagnostic]

    var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    var warnings: [Diagnostic] { diagnostics.filter { $0.severity == .warning } }
}

// MARK: - Parser

enum GraphParser {
    static let colorNames = ["blue", "orange", "green", "purple", "pink", "teal", "yellow",
                             "red", "indigo", "mint", "brown", "cyan", "gray"]

    private static let rootKeys: Set<String> = ["title", "summary", "groups", "nodes", "edges", "focus"]
    private static let nodeKeys: Set<String> = ["id", "label", "summary", "detail", "group", "importance", "refs"]
    private static let edgeKeys: Set<String> = ["from", "to", "label", "style", "directed"]
    private static let groupKeys: Set<String> = ["id", "label", "color"]

    /// Field names agents commonly reach for, mapped to the one this format uses.
    private static let aliases: [String: [String]] = [
        "source": ["from"], "src": ["from"], "start": ["from"],
        "target": ["to"], "dst": ["to"], "dest": ["to"], "end": ["to"],
        "name": ["label", "title"], "text": ["label"], "relation": ["label"], "type": ["group", "style", "label"],
        "description": ["summary"], "desc": ["summary"],
        "details": ["detail"], "body": ["detail"], "content": ["detail"], "notes": ["detail"],
        "weight": ["importance"], "size": ["importance"], "priority": ["importance"], "rank": ["importance"],
        "category": ["group"], "cluster": ["group"],
        "links": ["edges", "refs"], "relationships": ["edges"], "relations": ["edges"], "connections": ["edges"],
        "concepts": ["nodes"], "vertices": ["nodes"], "bubbles": ["nodes"],
        "references": ["refs"], "sources": ["refs"], "urls": ["refs"],
        "kind": ["style", "group"], "dashed": ["style"], "colour": ["color"],
        "selected": ["focus"], "categories": ["groups"], "clusters": ["groups"],
    ]

    static func load(path: String) -> ParseResult {
        guard let data = FileManager.default.contents(atPath: path) else {
            return ParseResult(graph: nil, diagnostics: [
                Diagnostic(severity: .error, path: "", message: "cannot read \(path)"),
            ])
        }
        return parse(data: data)
    }

    static func parse(data: Data) -> ParseResult {
        var diags: [Diagnostic] = []
        func err(_ path: String, _ message: String) {
            diags.append(Diagnostic(severity: .error, path: path, message: message))
        }
        func warn(_ path: String, _ message: String) {
            diags.append(Diagnostic(severity: .warning, path: path, message: message))
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let ns = error as NSError
            let why = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            err("", "not valid JSON — \(why)")
            return ParseResult(graph: nil, diagnostics: diags)
        }
        guard let obj = root as? [String: Any] else {
            err("", "the top level must be an object with \"title\", \"nodes\" and \"edges\", got \(describe(root))")
            return ParseResult(graph: nil, diagnostics: diags)
        }

        func checkKeys(_ dict: [String: Any], _ allowed: Set<String>, _ path: String) {
            for key in dict.keys.sorted() where !allowed.contains(key) {
                let where_ = path.isEmpty ? key : "\(path).\(key)"
                if let hint = suggestion(for: key, in: allowed) {
                    warn(where_, "unknown field, ignored — did you mean \"\(hint)\"?")
                } else {
                    warn(where_, "unknown field, ignored (allowed: \(allowed.sorted().joined(separator: ", ")))")
                }
            }
        }
        /// Reads an optional string field; reports a type error and returns nil if it is something else.
        func string(_ dict: [String: Any], _ key: String, _ path: String) -> String? {
            guard let raw = dict[key], !(raw is NSNull) else { return nil }
            guard let s = raw as? String else {
                err("\(path).\(key)".trimmingDot, "must be a string, got \(describe(raw))")
                return nil
            }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func required(_ dict: [String: Any], _ key: String, _ path: String) -> String? {
            let before = diags.count
            let value = string(dict, key, path)
            if let value, !value.isEmpty { return value }
            if diags.count == before {
                err("\(path).\(key)".trimmingDot, value == nil ? "missing (required)" : "must not be empty")
            }
            return nil
        }

        checkKeys(obj, rootKeys, "")
        let title = required(obj, "title", "") ?? ""
        let summary = string(obj, "summary", "") ?? ""

        // Groups (optional). Groups that nodes mention without declaring are created on the fly.
        var groups: [ConceptGroup] = []
        var groupIndex: [String: Int] = [:]
        if let raw = obj["groups"], !(raw is NSNull) {
            if let list = raw as? [Any] {
                for (i, item) in list.enumerated() {
                    let path = "groups[\(i)]"
                    guard let dict = item as? [String: Any] else {
                        err(path, "must be an object like {\"id\": \"…\", \"label\": \"…\"}, got \(describe(item))")
                        continue
                    }
                    checkKeys(dict, groupKeys, path)
                    guard let id = required(dict, "id", path) else { continue }
                    if groupIndex[id] != nil {
                        err("\(path).id", "duplicate group id \"\(id)\"")
                        continue
                    }
                    let label = string(dict, "label", path).flatMap { $0.isEmpty ? nil : $0 } ?? id
                    var color = string(dict, "color", path)?.lowercased()
                    if let c = color, !isValidColor(c) {
                        warn("\(path).color", "\"\(c)\" is not a known colour, picking one automatically "
                            + "(use #RRGGBB or one of: \(colorNames.joined(separator: ", ")))")
                        color = nil
                    }
                    groupIndex[id] = groups.count
                    groups.append(ConceptGroup(id: id, label: label, color: color))
                }
            } else {
                err("groups", "must be an array of group objects, got \(describe(raw))")
            }
        }
        let declaredGroups = groups.count

        // Nodes.
        var nodes: [ConceptNode] = []
        var nodeIndex: [String: Int] = [:]
        if let raw = obj["nodes"], !(raw is NSNull) {
            if let list = raw as? [Any] {
                if list.isEmpty { err("nodes", "must contain at least one node") }
                for (i, item) in list.enumerated() {
                    let path = "nodes[\(i)]"
                    guard let dict = item as? [String: Any] else {
                        err(path, "must be an object like {\"id\": \"…\", \"label\": \"…\"}, got \(describe(item))")
                        continue
                    }
                    checkKeys(dict, nodeKeys, path)
                    let id = required(dict, "id", path)
                    let label = required(dict, "label", path)
                    let nodeSummary = string(dict, "summary", path) ?? ""
                    let detail = string(dict, "detail", path) ?? ""
                    let group = string(dict, "group", path).flatMap { $0.isEmpty ? nil : $0 }

                    var importance = 3
                    if let rawImportance = dict["importance"], !(rawImportance is NSNull) {
                        if let number = rawImportance as? NSNumber, !isBool(number) {
                            importance = Int(min(5, max(1, number.doubleValue.rounded())))
                            if Double(importance) != number.doubleValue {
                                warn("\(path).importance", "must be a whole number from 1 to 5, using \(importance) instead of \(number)")
                            }
                        } else {
                            err("\(path).importance", "must be a number from 1 (minor) to 5 (central), got \(describe(rawImportance))")
                        }
                    }

                    var refs: [String] = []
                    if let rawRefs = dict["refs"], !(rawRefs is NSNull) {
                        if let list = rawRefs as? [Any] {
                            for (j, ref) in list.enumerated() {
                                if let s = ref as? String {
                                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty { refs.append(trimmed) }
                                } else {
                                    err("\(path).refs[\(j)]", "must be a string (a URL or a file path), got \(describe(ref))")
                                }
                            }
                        } else {
                            err("\(path).refs", "must be an array of strings, got \(describe(rawRefs))")
                        }
                    }

                    guard let id, let label else { continue }
                    if let first = nodeIndex[id] {
                        err("\(path).id", "duplicate id \"\(id)\" (already used by nodes[\(first)])")
                        continue
                    }
                    if label.count > 40 {
                        warn("\(path).label", "\(label.count) characters is long for a bubble — keep labels to a few words "
                            + "and put the rest in \"summary\"")
                    }
                    if nodeSummary.count > 220 {
                        warn("\(path).summary", "\(nodeSummary.count) characters is long for a summary — keep it to one sentence "
                            + "and move the rest to \"detail\"")
                    }
                    if nodeSummary.contains("**") || nodeSummary.contains("`") {
                        warn("\(path).summary", "summaries are shown as plain text, so Markdown here appears literally — "
                            + "use it in \"detail\" instead")
                    }
                    if nodeSummary.isEmpty && detail.isEmpty {
                        warn(path, "\"\(id)\" has no summary or detail, so there is nothing to read when the user inspects it")
                    }
                    if let group, groupIndex[group] == nil {
                        groupIndex[group] = groups.count
                        groups.append(ConceptGroup(id: group, label: group, color: nil))
                    }
                    nodeIndex[id] = nodes.count
                    nodes.append(ConceptNode(id: id, label: label.singleLine, summary: nodeSummary, detail: detail,
                                             group: group, importance: importance, refs: refs))
                }
            } else {
                err("nodes", "must be an array of node objects, got \(describe(raw))")
            }
        } else {
            err("nodes", "missing (required) — an array of {\"id\", \"label\", …} objects")
        }

        // Edges (optional, but a graph without them is just a list).
        var edges: [ConceptEdge] = []
        var degree = [Int](repeating: 0, count: nodes.count)
        let nodeErrors = diags.contains { $0.severity == .error && $0.path.hasPrefix("nodes") }
        if let raw = obj["edges"], !(raw is NSNull) {
            if let list = raw as? [Any] {
                for (i, item) in list.enumerated() {
                    let path = "edges[\(i)]"
                    guard let dict = item as? [String: Any] else {
                        err(path, "must be an object like {\"from\": \"…\", \"to\": \"…\", \"label\": \"…\"}, got \(describe(item))")
                        continue
                    }
                    checkKeys(dict, edgeKeys, path)
                    let from = required(dict, "from", path)
                    let to = required(dict, "to", path)
                    let label = (string(dict, "label", path) ?? "").singleLine

                    var dashed = false
                    if let style = string(dict, "style", path) {
                        switch style.lowercased() {
                        case "solid", "": dashed = false
                        case "dashed": dashed = true
                        default: err("\(path).style", "must be \"solid\" or \"dashed\", got \"\(style)\"")
                        }
                    }
                    var directed = true
                    if let rawDirected = dict["directed"], !(rawDirected is NSNull) {
                        if let number = rawDirected as? NSNumber, isBool(number) {
                            directed = number.boolValue
                        } else {
                            err("\(path).directed", "must be true or false, got \(describe(rawDirected))")
                        }
                    }

                    guard let from, let to else { continue }
                    var endpointsOK = true
                    for (key, id) in [("from", from), ("to", to)] where nodeIndex[id] == nil {
                        endpointsOK = false
                        // Don't pile "no such node" on top of the node error that caused it.
                        if nodeErrors { continue }
                        let near = nearest(to: id, in: Array(nodeIndex.keys))
                        err("\(path).\(key)", "no node has id \"\(id)\"" + (near.map { " — did you mean \"\($0)\"?" } ?? ""))
                    }
                    guard endpointsOK, let s = nodeIndex[from], let t = nodeIndex[to] else { continue }
                    if s == t {
                        warn(path, "connects \"\(from)\" to itself, ignored")
                        continue
                    }
                    if label.count > 32 {
                        warn("\(path).label", "\(label.count) characters is long for an arrow — a short verb phrase reads best")
                    }
                    degree[s] += 1
                    degree[t] += 1
                    edges.append(ConceptEdge(from: from, to: to, label: label, dashed: dashed, directed: directed))
                }
            } else {
                err("edges", "must be an array of edge objects, got \(describe(raw))")
            }
        }

        var focus = string(obj, "focus", "").flatMap { $0.isEmpty ? nil : $0 }
        if let f = focus, nodeIndex[f] == nil, !nodeErrors {
            let near = nearest(to: f, in: Array(nodeIndex.keys))
            warn("focus", "no node has id \"\(f)\", ignored" + (near.map { " — did you mean \"\($0)\"?" } ?? ""))
            focus = nil
        }

        // Whole-graph advice, only worth giving once the structure is sound.
        if !diags.contains(where: { $0.severity == .error }) {
            if nodes.count > 1 && edges.isEmpty {
                warn("edges", "there are no edges — the relationships between concepts are the point of the graph")
            } else if nodes.count > 1 {
                for (i, node) in nodes.enumerated() where degree[i] == 0 {
                    warn("nodes[\(i)]", "\"\(node.id)\" is not connected to anything")
                }
            }
            for (i, group) in groups.enumerated() where i < declaredGroups && !nodes.contains(where: { $0.group == group.id }) {
                warn("groups[\(i)]", "no node uses group \"\(group.id)\"")
            }
            if nodes.count > 60 {
                warn("nodes", "\(nodes.count) nodes is a lot to take in — 8 to 40 reads best; "
                    + "merge minor concepts or split this into several graphs")
            }
        }

        guard !diags.contains(where: { $0.severity == .error }) else {
            return ParseResult(graph: nil, diagnostics: diags)
        }
        let graph = ConceptGraph(title: title.singleLine, summary: summary, groups: groups,
                                 nodes: nodes, edges: edges, focus: focus)
        return ParseResult(graph: graph, diagnostics: diags)
    }

    // MARK: Helpers

    static func isValidColor(_ value: String) -> Bool {
        if colorNames.contains(value) { return true }
        guard value.hasPrefix("#"), value.count == 7 else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let number as NSNumber: return isBool(number) ? "\(number.boolValue)" : "the number \(number)"
        case let s as String: return "the string \"\(s.count > 24 ? String(s.prefix(24)) + "…" : s)\""
        case is [Any]: return "an array"
        case is [String: Any]: return "an object"
        default: return "\(type(of: value))"
        }
    }

    private static func suggestion(for key: String, in allowed: Set<String>) -> String? {
        if let candidates = aliases[key.lowercased()], let hit = candidates.first(where: { allowed.contains($0) }) {
            return hit
        }
        return nearest(to: key, in: Array(allowed))
    }

    /// The closest candidate by edit distance, if it is close enough to be a plausible typo.
    private static func nearest(to value: String, in candidates: [String]) -> String? {
        let target = value.lowercased()
        var best: (String, Int)?
        for candidate in candidates.sorted() {
            let distance = editDistance(target, candidate.lowercased())
            if best == nil || distance < best!.1 { best = (candidate, distance) }
        }
        guard let (candidate, distance) = best else { return nil }
        let shorter = min(target.count, candidate.count)
        return distance < shorter && distance <= max(1, shorter / 3) ? candidate : nil
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

private extension String {
    /// Collapses any run of whitespace (including newlines) to a single space.
    var singleLine: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "".key paths come out as ".key"; root-level fields should read as just "key".
    var trimmingDot: String {
        hasPrefix(".") ? String(dropFirst()) : self
    }
}
