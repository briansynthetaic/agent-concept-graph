import AppKit
import CoreText

// MARK: - Colours

enum Palette {
    /// System colours adapt to light and dark mode on their own, and are ordered
    /// here so that neighbouring groups get clearly different hues.
    static let named: [(name: String, color: NSColor)] = [
        ("blue", .systemBlue), ("orange", .systemOrange), ("green", .systemGreen),
        ("purple", .systemPurple), ("pink", .systemPink), ("teal", .systemTeal),
        ("yellow", .systemYellow), ("red", .systemRed), ("indigo", .systemIndigo),
        ("mint", .systemMint), ("brown", .systemBrown), ("cyan", .systemCyan),
        ("gray", .systemGray),
    ]
    /// Gray is reserved for "no group", so it is never handed out automatically.
    static let automatic = named.dropLast().map(\.color)

    static func color(_ value: String) -> NSColor? {
        if let hit = named.first(where: { $0.name == value }) { return hit.color }
        guard value.hasPrefix("#"), value.count == 7, let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Decides which colour every group and node gets. Shared by the canvas and the
/// inspector so a bubble and its description always match.
struct GraphStyle {
    private(set) var groupColors: [String: NSColor] = [:]
    private let ungrouped: NSColor

    init(graph: ConceptGraph) {
        let explicit = graph.groups.compactMap { $0.color }
        var pool = Palette.automatic.enumerated()
            .filter { index, _ in !explicit.contains(Palette.named[index].name) }
            .map { $0.element }
        if pool.isEmpty { pool = Palette.automatic }
        var next = 0
        for group in graph.groups {
            if let name = group.color, let color = Palette.color(name) {
                groupColors[group.id] = color
            } else {
                groupColors[group.id] = pool[next % pool.count]
                next += 1
            }
        }
        // With no groups at all, plain blue reads better than a canvas of gray.
        ungrouped = graph.groups.isEmpty ? .systemBlue : .systemGray
    }

    func color(forGroup id: String?) -> NSColor {
        id.flatMap { groupColors[$0] } ?? ungrouped
    }

    func color(for node: ConceptNode) -> NSColor {
        color(forGroup: node.group)
    }
}

/// Colours resolved for the appearance being drawn. Build one per draw pass.
struct Paint {
    let isDark: Bool
    let background: CGColor
    let grid: CGColor
    let edge: CGColor
    let text: CGColor
    let secondaryText: CGColor
    let tertiaryText: CGColor
    private let backgroundRGB: (CGFloat, CGFloat, CGFloat)

    init(appearance: NSAppearance) {
        isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        backgroundRGB = isDark ? (0.110, 0.110, 0.118) : (0.965, 0.965, 0.970)
        background = CGColor(srgbRed: backgroundRGB.0, green: backgroundRGB.1, blue: backgroundRGB.2, alpha: 1)
        let ink: CGFloat = isDark ? 1 : 0
        grid = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: isDark ? 0.10 : 0.11)
        edge = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: isDark ? 0.42 : 0.36)
        text = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: isDark ? 0.92 : 0.88)
        secondaryText = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: isDark ? 0.62 : 0.58)
        tertiaryText = CGColor(srgbRed: ink, green: ink, blue: ink, alpha: isDark ? 0.38 : 0.36)
    }

    /// Must be called while the target appearance is current (i.e. inside `draw`).
    func rgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? .gray
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    func stroke(_ hue: NSColor, alpha: CGFloat = 1) -> CGColor {
        let (r, g, b) = rgb(hue)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    /// An opaque tint of the hue over the canvas, so edges never show through a bubble.
    func fill(_ hue: NSColor) -> CGColor {
        let (r, g, b) = rgb(hue)
        let t: CGFloat = isDark ? 0.30 : 0.17
        let (br, bg, bb) = backgroundRGB
        return CGColor(srgbRed: br + (r - br) * t, green: bg + (g - bg) * t, blue: bb + (b - bb) * t, alpha: 1)
    }

    func backgroundColor(alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: backgroundRGB.0, green: backgroundRGB.1, blue: backgroundRGB.2, alpha: alpha)
    }
}

// MARK: - Fonts

enum Fonts {
    /// SF Rounded sits well inside circles.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

// MARK: - Text

/// Pre-typeset, centred lines of text that can be drawn every frame without
/// laying anything out again. The colour comes from the context's fill colour
/// at draw time, so one block serves every appearance and highlight state.
struct TextBlock {
    let lines: [CTLine]
    let widths: [CGFloat]
    let ascent: CGFloat
    let lineHeight: CGFloat
    /// The text did not fit in `maxLines` and ends in an ellipsis.
    let truncated: Bool
    /// A line break landed in the middle of a word.
    let brokeWord: Bool

    var width: CGFloat { widths.max() ?? 0 }
    var height: CGFloat { lineHeight * CGFloat(lines.count) }

    static func make(_ string: String, font: NSFont, maxWidth: CGFloat, maxLines: Int) -> TextBlock {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let text = string as NSString
        let length = text.length
        var lines: [CTLine] = []
        var truncated = false
        var brokeWord = false
        var start = 0
        while start < length && lines.count < maxLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            guard count > 0 else { break }
            let hasMore = start + count < length
            if hasMore && lines.count == maxLines - 1 {
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                lines.append(CTLineCreateTruncatedLine(rest, Double(maxWidth), .end, ellipsis)
                    ?? CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                truncated = true
                break
            }
            if hasMore && !isBreakPoint(text.character(at: start + count - 1)) && !isBreakPoint(text.character(at: start + count)) {
                brokeWord = true
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0)) }
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let lineHeight = (ascent + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)) * 1.04
        return TextBlock(lines: lines, widths: widths, ascent: ascent, lineHeight: lineHeight,
                         truncated: truncated, brokeWord: brokeWord)
    }

    private static func isBreakPoint(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar) || "-–—/·".unicodeScalars.contains(scalar)
    }

    /// Draws centred on `centerX` with the first line's top edge at `top`, in a flipped (y-down) context.
    func draw(in context: CGContext, centerX: CGFloat, top: CGFloat) {
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: centerX - widths[index] / 2,
                                           y: top + ascent + CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
    }

    /// Does every line fit inside a circle of `radius` when the block is centred in it?
    func fits(inCircleOfRadius radius: CGFloat, margin: CGFloat) -> Bool {
        let top = -height / 2
        for (index, width) in widths.enumerated() {
            let lineTop = top + CGFloat(index) * lineHeight
            let far = max(abs(lineTop), abs(lineTop + lineHeight))
            guard far < radius else { return false }
            let chord = 2 * (radius * radius - far * far).squareRoot()
            if width > chord - margin { return false }
        }
        return true
    }
}
