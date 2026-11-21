import AppKit

/// The reading pane beside the canvas. With nothing selected it is an outline
/// of the whole graph; with a bubble selected it shows everything the agent
/// wrote about that concept and how it connects to the others.
final class InspectorViewController: NSViewController, NSTextViewDelegate {
    /// Called with a node id when the user clicks a concept's name in the text.
    var onNavigate: ((String) -> Void)?

    private var textView: NSTextView!
    private static let nodeLinkPrefix = "concept:"

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        guard let text = scroll.documentView as? NSTextView else { fatalError("scrollableTextView has no text view") }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 13, height: 18)
        text.isAutomaticLinkDetectionEnabled = false
        // Links keep the colours given in the text; they only change the cursor.
        text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        text.delegate = self
        textView = text
        view = scroll
    }

    func show(graph: ConceptGraph, selected: String?, style: GraphStyle) {
        _ = view
        let content: NSAttributedString
        if let selected, let node = graph.nodes.first(where: { $0.id == selected }) {
            content = Self.describe(node, in: graph, style: style)
        } else {
            content = Self.outline(of: graph, style: style)
        }
        textView.textStorage?.setAttributedString(content)
        textView.scrollToBeginningOfDocument(nil)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let text = link as? String, text.hasPrefix(Self.nodeLinkPrefix) {
            if let id = String(text.dropFirst(Self.nodeLinkPrefix.count)).removingPercentEncoding { onNavigate?(id) }
            return true
        }
        // Graph files are written by an agent, so only ordinary web links are ever opened.
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    // MARK: - Content

    private static func outline(of graph: ConceptGraph, style: GraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(line(graph.title, font: .systemFont(ofSize: 20, weight: .bold), color: .labelColor, after: 3))
        let counts = "\(count(graph.nodes.count, "concept")) · \(count(graph.edges.count, "relationship"))"
        out.append(line(counts, font: .systemFont(ofSize: 12), color: .secondaryLabelColor, after: 12))
        if !graph.summary.isEmpty {
            out.append(prose(graph.summary, size: 13.5, color: .labelColor, after: 4))
        }

        func list(_ nodes: [ConceptNode]) {
            let ordered = nodes.enumerated().sorted {
                $0.element.importance == $1.element.importance ? $0.offset < $1.offset : $0.element.importance > $1.element.importance
            }
            for (_, node) in ordered {
                out.append(nodeLink(node, style: style, size: 13, after: node.summary.isEmpty ? 7 : 1, dot: false))
                if !node.summary.isEmpty {
                    out.append(line(node.summary, font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                    after: 9, lineSpacing: 1.5))
                }
            }
        }
        if graph.groups.isEmpty {
            out.append(heading("Concepts"))
            list(graph.nodes)
        } else {
            for group in graph.groups {
                let members = graph.nodes.filter { $0.group == group.id }
                guard !members.isEmpty else { continue }
                out.append(heading(group.label, color: style.color(forGroup: group.id)))
                list(members)
            }
            let loose = graph.nodes.filter { $0.group == nil }
            if !loose.isEmpty {
                out.append(heading("Other"))
                list(loose)
            }
        }
        return out
    }

    private static func describe(_ node: ConceptNode, in graph: ConceptGraph, style: GraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let hue = style.color(for: node)
        if let groupID = node.group, let group = graph.groups.first(where: { $0.id == groupID }) {
            let chip = NSMutableAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: hue,
                                                                              .baselineOffset: 1.5])
            chip.append(NSAttributedString(string: group.label.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6,
            ]))
            chip.addAttribute(.paragraphStyle, value: paragraph(after: 6), range: NSRange(location: 0, length: chip.length))
            out.append(chip)
        }
        out.append(line(node.label, font: .systemFont(ofSize: 20, weight: .bold), color: .labelColor, after: 8))
        if !node.summary.isEmpty {
            // Plain text, like the copy of it inside the bubble.
            out.append(line(node.summary, font: .systemFont(ofSize: 14), color: .labelColor, after: 10, lineSpacing: 2.5))
        }
        if !node.detail.isEmpty {
            out.append(prose(node.detail, size: 13, color: .labelColor.withAlphaComponent(0.82), after: 4))
        }

        let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let touching = graph.edges.filter { $0.from == node.id || $0.to == node.id }
        if !touching.isEmpty {
            out.append(heading("Connections"))
            for edge in touching {
                let outgoing = edge.from == node.id
                guard let other = byID[outgoing ? edge.to : edge.from] else { continue }
                let row = NSMutableAttributedString()
                let quiet: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
                let arrow = !edge.directed ? "–" : (outgoing ? "→" : "←")
                row.append(NSAttributedString(string: arrow + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
                // Reads as a sentence about this concept: "→ feeds Cache", "← Parser produces".
                if outgoing || !edge.directed {
                    if !edge.label.isEmpty { row.append(NSAttributedString(string: edge.label + "  ", attributes: quiet)) }
                    row.append(nodeLink(other, style: style, size: 13, after: 0, newline: false))
                } else {
                    row.append(nodeLink(other, style: style, size: 13, after: 0, newline: false))
                    if !edge.label.isEmpty { row.append(NSAttributedString(string: "  " + edge.label, attributes: quiet)) }
                }
                row.append(NSAttributedString(string: "\n"))
                row.addAttribute(.paragraphStyle, value: paragraph(after: 6, indent: 19, firstLineIndent: 0),
                                 range: NSRange(location: 0, length: row.length))
                out.append(row)
            }
        }

        if !node.refs.isEmpty {
            out.append(heading("References"))
            for ref in node.refs {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph(after: 5, lineBreak: .byCharWrapping),
                ]
                if let url = URL(string: ref), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    attributes[.link] = url
                    attributes[.foregroundColor] = NSColor.linkColor
                }
                out.append(NSAttributedString(string: ref + "\n", attributes: attributes))
            }
        }
        return out
    }

    // MARK: - Building blocks

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func paragraph(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
                                  lineSpacing: CGFloat = 0, lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        style.lineSpacing = lineSpacing
        style.lineBreakMode = lineBreak
        return style
    }

    private static func line(_ text: String, font: NSFont, color: NSColor, after: CGFloat, indent: CGFloat = 0,
                             lineSpacing: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: paragraph(after: after, indent: indent, lineSpacing: lineSpacing),
        ])
    }

    private static func heading(_ text: String, color: NSColor? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let color {
            out.append(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: color,
                                                                       .baselineOffset: 1.5]))
        }
        out.append(NSAttributedString(string: text.uppercased() + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6,
        ]))
        out.addAttribute(.paragraphStyle, value: paragraph(before: 18, after: 8), range: NSRange(location: 0, length: out.length))
        return out
    }

    /// A concept's name as a clickable link, with a dot in its colour.
    private static func nodeLink(_ node: ConceptNode, style: GraphStyle, size: CGFloat, after: CGFloat,
                                 newline: Bool = true, dot: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if dot {
            out.append(NSAttributedString(string: "●  ", attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.6), .foregroundColor: style.color(for: node), .baselineOffset: size * 0.12,
            ]))
        }
        let encoded = node.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? node.id
        out.append(NSAttributedString(string: node.label, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor,
            .link: nodeLinkPrefix + encoded,
        ]))
        if newline {
            out.append(NSAttributedString(string: "\n"))
            out.addAttribute(.paragraphStyle, value: paragraph(after: after), range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    /// Body text with inline Markdown (**bold**, *italic*, `code`, [links](https://…)) and "- " bullets.
    private static func prose(_ source: String, size: CGFloat, color: NSColor, after: CGFloat) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size)
        let out = NSMutableAttributedString()
        let lines = source.components(separatedBy: .newlines)
        for (index, raw) in lines.enumerated() {
            var text = raw.trimmingCharacters(in: .whitespaces)
            // A blank line is a paragraph break: it only adds space after the previous paragraph.
            guard !text.isEmpty else { continue }
            var bullet = false
            for marker in ["- ", "* ", "• "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
                bullet = true
                break
            }
            let piece = NSMutableAttributedString()
            if bullet { piece.append(NSAttributedString(string: "•\t")) }
            piece.append(inlineMarkdown(text))
            piece.append(NSAttributedString(string: "\n"))

            let isLast = !lines[(index + 1)...].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let followedByBlank = index + 1 < lines.count && lines[index + 1].trimmingCharacters(in: .whitespaces).isEmpty
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2.5
            style.paragraphSpacing = isLast ? after : (followedByBlank ? 9 : (bullet ? 3.5 : 5))
            if bullet {
                style.headIndent = 13
                style.tabStops = [NSTextTab(textAlignment: .left, location: 13)]
            }
            let whole = NSRange(location: 0, length: piece.length)
            piece.addAttribute(.paragraphStyle, value: style, range: whole)
            piece.enumerateAttributes(in: whole) { attributes, range, _ in
                var resolved = font
                if let raw = attributes[.inlinePresentationIntent] as? NSNumber {
                    let intent = InlinePresentationIntent(rawValue: raw.uintValue)
                    if intent.contains(.code) {
                        resolved = .monospacedSystemFont(ofSize: size * 0.93, weight: .regular)
                    }
                    var traits: NSFontDescriptor.SymbolicTraits = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    if !traits.isEmpty {
                        let descriptor = resolved.fontDescriptor.withSymbolicTraits(resolved.fontDescriptor.symbolicTraits.union(traits))
                        resolved = NSFont(descriptor: descriptor, size: resolved.pointSize) ?? resolved
                    }
                }
                piece.addAttribute(.font, value: resolved, range: range)
                piece.addAttribute(.foregroundColor, value: attributes[.link] == nil ? color : NSColor.linkColor, range: range)
            }
            out.append(piece)
        }
        return out
    }

    private static func inlineMarkdown(_ text: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? NSAttributedString(markdown: text, options: options, baseURL: nil)) ?? NSAttributedString(string: text)
    }
}
