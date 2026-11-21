import Foundation

enum PromptTask: Int, CaseIterable {
    case explain, expand, build

    var title: String {
        switch self {
        case .explain: return "Ask a question"
        case .expand: return "Expand the graph"
        case .build: return "Build this system (whole graph)"
        }
    }

    func compose(graph: ConceptGraph, path: String, focus: ConceptNode?, question: String) -> String {
        compose(graph: graph, path: path, selection: focus.map { [$0.id] } ?? [], neighbors: true, question: question)
    }

    func compose(graph: ConceptGraph, path: String, selection: [String], neighbors: Bool, question: String) -> String {
        let selected = Set(selection)
        let subjects = graph.nodes.filter { selected.contains($0.id) }
        let wholeGraph = self == .build || subjects.isEmpty
        let scope = wholeGraph ? graph.title : subjects.map { "\($0.label) [\($0.id)]" }.joined(separator: ", ")
        let note = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction: String
        switch self {
        case .explain:
            instruction = note.isEmpty ? "Explain \(scope)." : "Context for my question about \(scope):"
        case .expand:
            instruction = "Explore \(scope) in more depth. Update its explanation in the graph file below with what you learn. Add concepts or relationships where they clarify the answer. Preserve existing IDs and unrelated content."
        case .build:
            instruction = "Implement the system described by this design. Map each component and relationship to behavior, interfaces and data flow. Identify unresolved decisions, inspect the existing project, and verify the implementation against the design."
        }
        var parts = note.isEmpty ? [instruction] : [note, instruction]
        parts += ["Graph file\n" + path, "Design\n" + graph.title]
        if !graph.summary.isEmpty { parts.append(graph.summary) }
        let edges = graph.edges.filter { edge in
            if wholeGraph { return true }
            let from = selected.contains(edge.from), to = selected.contains(edge.to)
            return neighbors ? from || to : from && to
        }
        let ids = Set(edges.flatMap { [$0.from, $0.to] })
        let groups = Dictionary(uniqueKeysWithValues: graph.groups.map { ($0.id, $0.label) })
        for node in graph.nodes where wholeGraph || selected.contains(node.id) || ids.contains(node.id) {
            var lines = ["\(node.label) [\(node.id)]"]
            if let group = node.group { lines.append("Group: " + (groups[group] ?? group)) }
            lines += [node.summary, node.detail].filter { !$0.isEmpty }
            lines += node.refs.map { "Reference: " + $0 }
            parts.append(lines.joined(separator: "\n"))
        }
        if !edges.isEmpty {
            parts.append("Relationships\n" + edges.map {
                "\($0.from) \($0.directed ? "→" : "↔") \($0.to)  \($0.label)"
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
