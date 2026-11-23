import AppKit
import CoreText
import QuartzCore

/// The zoomable, pannable surface the graph is drawn on.
///
/// Coordinates: the layout works in "graph units"; the camera maps them to view
/// points with `view = graph * scale + offset`. The view is flipped (y grows down).
final class CanvasView: NSView {

    var wholeGraphDrag = ViewerPreferences.defaults.bool(forKey: "wholeGraphDrag")
    var shape = NodeShape(rawValue: ViewerPreferences.defaults.integer(forKey: "nodeShape")) ?? .circle
    var reduceMotion: Bool {
        ViewerPreferences.defaults.bool(forKey: "reduceMotion") || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    enum LabelMode: Int { case automatic, neighborhood, always }
    var labels = LabelMode.automatic { didSet { needsDisplay = true } }
    var showsGroups = true { didSet { needsDisplay = true } }
    var onStateChanged: (() -> Void)?
    private var additionalSelection: Set<String> = []
    var selectionIDs: [String] {
        (selectedID.map { [$0] } ?? []) + additionalSelection.sorted()
    }

    // MARK: Scene

    private struct Node {
        var model: ConceptNode
        var radius: CGFloat
        var hue: NSColor
        var group: Int
        var label: TextBlock
        var labelSize: CGFloat
        /// Shown inside the bubble once the user has zoomed in far enough to read it.
        var summary: TextBlock?
        var summarySize: CGFloat
        var neighbors: Set<Int> = []
        /// When the bubble was added by a live update (it pops in); 0 if it was there from the start.
        var born: CFTimeInterval = 0
    }

    private struct Edge {
        var model: ConceptEdge
        var source: Int
        var target: Int
        var label: TextBlock?
    }

    private struct Group {
        var model: ConceptGroup
        var hue: NSColor
        var members: [Int] = []
        var label: TextBlock
    }

    private enum Metrics {
        static let radius: [CGFloat] = [32, 39, 47, 57, 70]
        static let labelSize: [CGFloat] = [10.5, 11.5, 12.5, 14, 16]
        static let edgeLabelSize: CGFloat = 11
        static let minScale: CGFloat = 0.05
        static let maxScale: CGFloat = 8
        static let popDuration: CFTimeInterval = 0.45
    }

    private var nodes: [Node] = []
    private var edges: [Edge] = []
    private var groups: [Group] = []
    private var indexByID: [String: Int] = [:]
    private var layoutSignature: [String] = []
    private let layout = ForceLayout()

    private(set) var graph: ConceptGraph?
    private(set) var style = GraphStyle(graph: ConceptGraph(title: "", summary: "", groups: [], nodes: [], edges: [], focus: nil))

    /// Called when the user (or a search, or a link in the inspector) changes the selection.
    var onPrompt: (() -> Void)?
    var onSelectionChanged: ((String?) -> Void)?

    /// A problem to show across the top of the canvas, e.g. a live update that failed to parse.
    var banner: String? {
        didSet { if banner != oldValue { needsDisplay = true } }
    }

    /// The one-line "how to move around" hint shown until the user first interacts.
    var showsHint = true

    // MARK: State

    private var scale: CGFloat = 1
    private var offset = CGPoint.zero { didSet { onStateChanged?() } }
    /// Until the user moves the camera themselves, it keeps the whole graph in view.
    private var userMovedCamera = false
    private var hasInteracted = false

    private var selected: Int?
    private var hovered: Int?
    private var query = ""
    private var matches: Set<Int>?
    private var matchOrder: [Int] = []
    private var matchCursor = -1

    private enum Drag {
        case none
        case pan(start: CGPoint, last: CGPoint, moved: Bool)
        case node(index: Int, grab: CGPoint, start: CGPoint, moved: Bool)
    }
    private var drag = Drag.none

    private struct CameraAnimation {
        var fromCenter: CGPoint
        var fromScale: CGFloat
        var toCenter: CGPoint
        var toScale: CGFloat
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }
    private var cameraAnimation: CameraAnimation?
    private var displayLink: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private var simulationDebt = 0.0

    private var zoomLabel: (percent: Int, block: TextBlock)?
    private lazy var hint = TextBlock.make("Scroll or pinch to zoom   ·   Drag to pan   ·   Click a bubble to inspect it",
                                           font: .systemFont(ofSize: 11.5), maxWidth: 2000, maxLines: 1)

    var selectedID: String? { selected.map { nodes[$0].model.id } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Views no longer clip their drawing by default; without this, bubbles near the
        // edge of the canvas would be painted over the inspector.
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Concept graph")
        setAccessibilityHelp("Press Return to explore a neighborhood, use the arrow keys to select a concept, and press Escape to return.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CanvasView is created in code")
    }

    /// Strokes and arrowheads thicken more slowly than the bubbles do when zooming in,
    /// so a close-up stays crisp instead of turning into thick outlines.
    private var strokeScale: CGFloat { scale > 1 ? 1 / scale.squareRoot() : 1 }

    // MARK: - Loading a graph

    /// Shows `newGraph`. The first call lays everything out from scratch; later
    /// calls (live updates) keep every surviving bubble where it was and let the
    /// new ones settle in around them.
    func setGraph(_ newGraph: ConceptGraph, fullySettle: Bool = false) {
        let previous = graph
        var oldPlaces: [String: ForceLayout.Node] = [:]
        for (i, node) in nodes.enumerated() { oldPlaces[node.model.id] = layout.nodes[i] }
        let oldSelection = selectedID

        graph = newGraph
        style = GraphStyle(graph: newGraph)

        var groupIndex: [String: Int] = [:]
        groups = newGraph.groups.enumerated().map { i, model in
            groupIndex[model.id] = i
            return Group(model: model, hue: style.color(forGroup: model.id),
                         label: TextBlock.make(model.label, font: .systemFont(ofSize: 11, weight: .semibold),
                                               maxWidth: 260, maxLines: 1))
        }

        indexByID = [:]
        nodes = newGraph.nodes.enumerated().map { i, model in
            indexByID[model.id] = i
            let fitted = Self.fitLabel(model.label, importance: model.importance, shape: shape)
            let group = model.group.flatMap { groupIndex[$0] } ?? -1
            if group >= 0 { groups[group].members.append(i) }
            let summarySize = max(4.4, fitted.radius * 0.105)
            return Node(model: model, radius: fitted.radius, hue: style.color(for: model), group: group,
                        label: fitted.block, labelSize: fitted.size,
                        summary: summaryBlock(model.summary, radius: fitted.radius, size: summarySize, label: fitted.block),
                        summarySize: summarySize)
        }

        let edgeFont = NSFont.systemFont(ofSize: Metrics.edgeLabelSize, weight: .medium)
        var edgeLabels: [String: TextBlock] = [:]
        func edgeLabel(_ text: String) -> TextBlock? {
            guard !text.isEmpty else { return nil }
            if let block = edgeLabels[text] { return block }
            let block = TextBlock.make(text, font: edgeFont, maxWidth: 170, maxLines: 1)
            edgeLabels[text] = block
            return block
        }
        edges = newGraph.edges.compactMap { model in
            guard let s = indexByID[model.from], let t = indexByID[model.to] else { return nil }
            nodes[s].neighbors.insert(t)
            nodes[t].neighbors.insert(s)
            return Edge(model: model, source: s, target: t, label: edgeLabel(model.label))
        }

        // Anything that changes the forces means the layout has to move.
        let signature = nodes.map { "\($0.model.id)|\($0.radius)|\($0.group)" }
            + edges.map { "\($0.source)>\($0.target)|\(Int($0.label?.width ?? 0))" }
        let isFirst = previous == nil
        let structureChanged = signature != layoutSignature
        layoutSignature = signature

        // Place the bubbles: survivors stay put, newcomers start beside something they connect to.
        let now = CACurrentMediaTime()
        var placed: [ForceLayout.Node?] = nodes.map { node in
            guard var old = oldPlaces[node.model.id] else { return nil }
            old.radius = node.radius
            old.group = node.group
            return old
        }
        var centre = (x: 0.0, y: 0.0)
        let survivors = placed.compactMap { $0 }
        if !survivors.isEmpty {
            centre = (survivors.map(\.x).reduce(0, +) / Double(survivors.count),
                      survivors.map(\.y).reduce(0, +) / Double(survivors.count))
        }
        for i in nodes.indices where placed[i] == nil {
            let seed = ForceLayout.seed(i)
            var x = centre.x + seed.x, y = centre.y + seed.y
            let anchors = nodes[i].neighbors.compactMap { placed[$0] }
            if !isFirst, !anchors.isEmpty {
                let reach = Double(nodes[i].radius) + 120
                let angle = Double(i) * 2.399963
                x = anchors.map(\.x).reduce(0, +) / Double(anchors.count) + reach * cos(angle)
                y = anchors.map(\.y).reduce(0, +) / Double(anchors.count) + reach * sin(angle)
            }
            placed[i] = ForceLayout.Node(x: x, y: y, radius: nodes[i].radius, group: nodes[i].group)
            if !isFirst && !reduceMotion { nodes[i].born = now }
        }
        layout.shape = shape
        layout.nodes = placed.compactMap { $0 }
        layout.setLinks(edges.map {
            ForceLayout.Link(source: $0.source, target: $0.target, gap: Double(min($0.label?.width ?? 0, 110)) * 0.55)
        })

        // Selection survives an update; a changed `focus` in the file moves it.
        selected = oldSelection.flatMap { indexByID[$0] }
        var focusChanged = false
        if let focus = newGraph.focus, focus != previous?.focus, let i = indexByID[focus] {
            selected = i
            focusChanged = true
        }
        additionalSelection.formIntersection(indexByID.keys)
        if selected == nil, let next = additionalSelection.sorted().first { selected = indexByID[next] }
        if let selectedID { additionalSelection.remove(selectedID) }
        if let anchor = focusAnchor, indexByID[anchor] == nil { leaveNeighborhood() }
        updateAccessibleSelection()
        hovered = nil
        // An update can arrive mid-drag; node indices may no longer mean what they did.
        drag = .none
        layout.endDrag()
        recomputeMatches()

        if isFirst {
            layout.settle(timeBudget: fullySettle ? .infinity : 0.025)
            if layout.isActive { startAnimating() }
            userMovedCamera = false
            if let target = fitTarget() { setCamera(center: target.center, scale: target.scale) }
        } else {
            if structureChanged { layout.reheat(0.5) }
            if focusChanged, let i = selected { reveal(i) }
            startAnimating()
        }
        needsDisplay = true
    }

    private static let fittingAttempts: [(grow: Int, shrink: Int)] = {
        var attempts: [(grow: Int, shrink: Int)] = []
        for grow in 0...6 { for shrink in 0...3 { attempts.append((grow, shrink)) } }
        return attempts.sorted { ($0.grow + $0.shrink, $0.shrink) < ($1.grow + $1.shrink, $1.shrink) }
    }()

    /// Picks a radius and type size for a label: the bubble's size comes from its
    /// importance, and only grows if the words genuinely cannot fit.
    private static func fitLabel(_ text: String, importance: Int, shape: NodeShape) -> (radius: CGFloat, size: CGFloat, block: TextBlock) {
        let level = min(max(importance, 1), 5) - 1
        let baseRadius = Metrics.radius[level], baseSize = Metrics.labelSize[level]
        // Try the gentlest adjustments first, trading a slightly bigger bubble against slightly
        // smaller type, so one long word neither balloons the bubble nor shrinks to a whisper.
        var last: (CGFloat, CGFloat, TextBlock)?
        for attempt in fittingAttempts {
            let radius = (baseRadius * (1 + 0.08 * CGFloat(attempt.grow))).rounded()
            let size = baseSize * (1 - 0.06 * CGFloat(attempt.shrink))
            let block = TextBlock.make(text, font: Fonts.rounded(size, .semibold), maxWidth: shape.geometry(radius).labelWidth, maxLines: 3)
            last = (radius, size, block)
            if !block.truncated && !block.brokeWord && (shape == .circle ? block.fits(inCircleOfRadius: radius, margin: 10) : block.height < shape.geometry(radius).halfHeight * 2 - 12) {
                return (radius, size, block)
            }
        }
        return last!
    }

    private func summaryBlock(_ text: String, radius: CGFloat, size: CGFloat, label: TextBlock) -> TextBlock? {
        guard !text.isEmpty else { return nil }
        let font = Fonts.rounded(size, .regular)
        let room = radius * 1.34 - label.height - radius * 0.07
        let lines = Int(room / (size * 1.27))
        guard lines >= 2 else { return nil }
        return TextBlock.make(text, font: font, maxWidth: shape == .circle ? radius * 1.42 : shape.geometry(radius).labelWidth, maxLines: min(lines, 6))
    }

    // MARK: - Camera

    private func position(_ index: Int) -> CGPoint {
        CGPoint(x: layout.nodes[index].x, y: layout.nodes[index].y)
    }

    private func graphPoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - offset.x) / scale, y: (viewPoint.y - offset.y) / scale)
    }

    private func viewPoint(_ graphPoint: CGPoint) -> CGPoint {
        CGPoint(x: graphPoint.x * scale + offset.x, y: graphPoint.y * scale + offset.y)
    }

    private var cameraCenter: CGPoint { graphPoint(CGPoint(x: bounds.midX, y: bounds.midY)) }

    private func setCamera(center: CGPoint, scale newScale: CGFloat) {
        scale = newScale
        offset = CGPoint(x: bounds.midX - center.x * newScale, y: bounds.midY - center.y * newScale)
        needsDisplay = true
    }

    private func moveCamera(center: CGPoint, scale target: CGFloat, animated: Bool) {
        guard animated, !reduceMotion, window != nil else {
            cameraAnimation = nil
            setCamera(center: center, scale: target)
            return
        }
        cameraAnimation = CameraAnimation(fromCenter: cameraCenter, fromScale: scale, toCenter: center, toScale: target,
                                          start: CACurrentMediaTime(), duration: 0.32)
        startAnimating()
    }

    /// The camera that frames the given bubbles (all of them by default) with comfortable margins.
    private func fitTarget(_ indices: [Int]? = nil, maxScale: CGFloat = 1.1) -> (center: CGPoint, scale: CGFloat)? {
        let list = indices ?? Array(nodes.indices)
        guard !list.isEmpty, bounds.width > 40, bounds.height > 40 else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for i in list {
            let p = position(i), geometry = shape.geometry(nodes[i].radius)
            let rx = geometry.halfWidth + 22, ry = geometry.halfHeight + 22
            minX = min(minX, p.x - rx); maxX = max(maxX, p.x + rx)
            minY = min(minY, p.y - ry); maxY = max(maxY, p.y + ry)
        }
        // The vertical margin leaves room for the group names that sit on the clusters' outlines.
        let fitted = min(maxScale, max(bounds.width - 72, 60) / (maxX - minX), max(bounds.height - 96, 60) / (maxY - minY))
        return (CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2), max(Metrics.minScale, fitted))
    }

    func zoomToFit(animated: Bool = true) {
        guard let target = fitTarget() else { return }
        userMovedCamera = false
        moveCamera(center: target.center, scale: target.scale, animated: animated)
    }

    func zoomIn() { zoom(by: 1.35, around: CGPoint(x: bounds.midX, y: bounds.midY), animated: true) }
    func zoomOut() { zoom(by: 1 / 1.35, around: CGPoint(x: bounds.midX, y: bounds.midY), animated: true) }

    func zoomToActualSize() {
        userMovedCamera = true
        moveCamera(center: cameraCenter, scale: 1, animated: true)
    }

    private func zoom(by factor: CGFloat, around point: CGPoint, animated: Bool = false) {
        let from = cameraAnimation?.toScale ?? scale
        let target = max(Metrics.minScale, min(Metrics.maxScale, from * factor))
        let anchor = graphPoint(point)
        // Keep the graph point under `point` where it is.
        let center = CGPoint(x: anchor.x + (bounds.midX - point.x) / target, y: anchor.y + (bounds.midY - point.y) / target)
        userMovedCamera = true
        moveCamera(center: center, scale: target, animated: animated)
    }

    /// Pans (and, if the text would be unreadably small, zooms) so a bubble is comfortably in view.
    private func reveal(_ index: Int) {
        let p = viewPoint(position(index)), geometry = shape.geometry(nodes[index].radius)
        let rx = geometry.halfWidth * scale, ry = geometry.halfHeight * scale
        let comfortable = bounds.insetBy(dx: min(60, bounds.width / 4), dy: min(60, bounds.height / 4))
        let visible = comfortable.contains(CGPoint(x: p.x - rx, y: p.y - ry))
            && comfortable.contains(CGPoint(x: p.x + rx, y: p.y + ry))
        if visible && scale >= 0.6 { return }
        userMovedCamera = true
        moveCamera(center: position(index), scale: max(scale, 0.85), animated: true)
    }

    /// Frames a bubble together with everything it connects to.
    private func focus(on index: Int) {
        if focusAnchor == nil { previousCamera = (cameraCenter, scale, userMovedCamera) }
        focusAnchor = nodes[index].model.id
        select(index: index)
        guard let target = fitTarget([index] + Array(nodes[index].neighbors), maxScale: 1.7) else { return }
        userMovedCamera = true
        moveCamera(center: target.center, scale: target.scale, animated: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        guard old != newSize else { return }
        if !userMovedCamera, cameraAnimation == nil, let target = fitTarget() {
            setCamera(center: target.center, scale: target.scale)
        } else {
            // Keep whatever is in the middle of the canvas in the middle.
            offset.x += (newSize.width - old.width) / 2
            offset.y += (newSize.height - old.height) / 2
        }
        needsDisplay = true
    }

    // MARK: - Selection and search

    func select(id: String?, reveal shouldReveal: Bool) {
        let index = id.flatMap { indexByID[$0] }
        select(index: index)
        if shouldReveal, let index { reveal(index) }
    }

    private func select(index: Int?) {
        if !additionalSelection.isEmpty { additionalSelection.removeAll() }
        else if index == selected { return }
        selected = index
        needsDisplay = true
        selectionChanged()
    }

    /// Dims everything that does not match. Returns the number of matching bubbles.
    @discardableResult
    func setSearch(_ text: String) -> Int {
        query = text.trimmingCharacters(in: .whitespaces)
        matchCursor = -1
        recomputeMatches()
        needsDisplay = true
        return matchOrder.count
    }

    /// Steps the selection through the search results.
    func selectNextMatch() {
        guard !matchOrder.isEmpty else { return }
        matchCursor = (matchCursor + 1) % matchOrder.count
        let index = matchOrder[matchCursor]
        select(index: index)
        reveal(index)
    }

    private func recomputeMatches() {
        guard !query.isEmpty else {
            matches = nil
            matchOrder = []
            return
        }
        func hit(_ text: String) -> Bool {
            text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        let byLabel = nodes.indices.filter { hit(nodes[$0].model.label) }
        let byText = nodes.indices.filter { i in
            !byLabel.contains(i) && (hit(nodes[i].model.summary) || hit(nodes[i].model.detail) || hit(nodes[i].model.id))
        }
        matchOrder = byLabel + byText
        matches = Set(matchOrder)
    }

    func refreshLayout() {
        layout.reheat(0.6)
        startAnimating()
    }

    func export(to url: URL, source: String, wholeGraph: Bool) throws {
        let oldOffset = offset, oldScale = scale, oldHint = showsHint, oldBanner = banner
        defer {
            scale = oldScale
            offset = oldOffset
            needsDisplay = true
            showsHint = oldHint
            banner = oldBanner
        }
        showsHint = false
        banner = nil
        if wholeGraph, let fit = fitTarget() { setCamera(center: fit.center, scale: fit.scale) }
        try Snapshot.write(view: self, source: source, to: url)
    }

    private func isSelected(_ index: Int) -> Bool {
        index == selected || additionalSelection.contains(nodes[index].model.id)
    }

    private func updateAccessibleSelection() {
        let names = selectionIDs.compactMap { indexByID[$0].map { nodes[$0].model.label } }
        setAccessibilityValue(names.joined(separator: ", "))
    }

    private func selectionChanged() {
        updateAccessibleSelection()
        needsDisplay = true
        onSelectionChanged?(selectedID)
        onStateChanged?()
        if let selected, window != nil {
            let label = nodes[selected].model.label
            let announcement = additionalSelection.isEmpty ? label : "\(label), \(additionalSelection.count + 1) concepts selected"
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: announcement, .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }

    private func toggleSelection(_ index: Int) {
        var ids = selectionIDs
        let id = nodes[index].model.id
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.insert(id, at: 0) }
        selected = ids.first.flatMap { indexByID[$0] }
        additionalSelection = Set(ids.dropFirst())
        selectionChanged()
    }

    private var previousCamera: (CGPoint, CGFloat, Bool)?
    private var focusAnchor: String?

    func enterNeighborhood() {
        if let index = selected ?? nodes.indices.first { focus(on: index) }
    }

    func leaveNeighborhood() {
        focusAnchor = nil
        if let (center, zoom, moved) = previousCamera {
            userMovedCamera = moved
            moveCamera(center: center, scale: zoom, animated: true)
        }
        previousCamera = nil
        needsDisplay = true
    }

    private func navigate(backwards: Bool, extending: Bool) {
        let choices = focusAnchor.flatMap { indexByID[$0] }.map { nodes[$0].neighbors.union([$0]).sorted() } ?? Array(nodes.indices)
        guard !choices.isEmpty else { return }
        let cursor = selected.flatMap { choices.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
        let index = choices[(cursor + (backwards ? -1 : 1) + choices.count) % choices.count]
        if extending {
            if let selectedID { additionalSelection.insert(selectedID) }
            selected = index
            additionalSelection.remove(nodes[index].model.id)
            selectionChanged()
        } else { select(index: index) }
        reveal(index)
    }

    var arrangement: Arrangement {
        var places: [String: Arrangement.Place] = [:]
        for i in nodes.indices {
            places[nodes[i].model.id] = .init(point: position(i), pinned: layout.nodes[i].pinned)
        }
        return Arrangement(places: places, center: cameraCenter, scale: scale,
                           automaticCamera: !userMovedCamera, selection: selectionIDs)
    }

    func restore(_ state: Arrangement) {
        var restored = 0
        for i in nodes.indices {
            guard let place = state.places[nodes[i].model.id] else { continue }
            layout.nodes[i].x = place.point.x
            layout.nodes[i].y = place.point.y
            layout.nodes[i].vx = 0
            layout.nodes[i].vy = 0
            layout.nodes[i].pinned = place.pinned
            restored += 1
        }
        guard restored > 0 else { return }
        if restored == nodes.count { layout.stop() } else { layout.reheat(0.5); startAnimating() }
        userMovedCamera = !state.automaticCamera
        cameraAnimation = nil
        setCamera(center: state.center, scale: min(Metrics.maxScale, max(Metrics.minScale, state.scale)))
        let ids = state.selection.filter { indexByID[$0] != nil }
        selected = ids.first.flatMap { indexByID[$0] }
        additionalSelection = Set(ids.dropFirst())
        selectionChanged()
    }

    func resetLayout() {
        guard let graph else { return }
        let before = arrangement
        undoManager?.registerUndo(withTarget: self) { $0.restore(before) }
        undoManager?.setActionName("Reset Layout")
        for i in nodes.indices {
            let seed = ForceLayout.seed(i)
            layout.nodes[i].x = seed.x
            layout.nodes[i].y = seed.y
            layout.nodes[i].vx = 0
            layout.nodes[i].vy = 0
            layout.nodes[i].pinned = false
        }
        leaveNeighborhood()
        setGraph(graph)
        layout.reheat(1)
        zoomToFit(animated: false)
        startAnimating()
    }

    @objc private func unpinBubble(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let index = indexByID[id] else { return }
        layout.nodes[index].pinned = false
        layout.reheat(0.4)
        startAnimating()
        onStateChanged?()
    }

    // MARK: - Animation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        if window != nil, needsAnimation { startAnimating() }
    }

    private var needsAnimation: Bool {
        layout.isActive || cameraAnimation != nil || nodes.contains { $0.born > 0 }
    }

    private func startAnimating() {
        guard window != nil else { return }
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            lastStep = CACurrentMediaTime()
        }
        if displayLink?.isPaused == true { lastStep = CACurrentMediaTime() }
        displayLink?.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        link.isPaused = !advanceFrame(at: CACurrentMediaTime())
    }

    @discardableResult
    func advanceFrame(at now: CFTimeInterval) -> Bool {
        let frameStart = CACurrentMediaTime()
        let elapsed = min(max(0, now - lastStep), 0.05)
        lastStep = now
        var busy = false

        if layout.isActive {
            // Advance the simulation at a steady 60 steps a second whatever the display's refresh rate.
            simulationDebt = min(0.05, simulationDebt + elapsed)
            var steps = 0
            while simulationDebt >= 1.0 / 60 && steps < 3 && CACurrentMediaTime() - frameStart < 0.008 {
                layout.tick()
                simulationDebt -= 1.0 / 60
                steps += 1
            }
            if !userMovedCamera, cameraAnimation == nil, let target = fitTarget() {
                let current = cameraCenter
                setCamera(center: CGPoint(x: current.x + (target.center.x - current.x) * 0.2,
                                          y: current.y + (target.center.y - current.y) * 0.2),
                          scale: scale + (target.scale - scale) * 0.2)
            }
            busy = true
        }

        if let animation = cameraAnimation {
            let t = (now - animation.start) / animation.duration
            if t >= 1 {
                setCamera(center: animation.toCenter, scale: animation.toScale)
                cameraAnimation = nil
            } else {
                let eased = CGFloat(1 - pow(1 - t, 3))
                // Zoom geometrically so the motion looks even at every scale.
                let zoom = animation.fromScale * pow(animation.toScale / animation.fromScale, eased)
                setCamera(center: CGPoint(x: animation.fromCenter.x + (animation.toCenter.x - animation.fromCenter.x) * eased,
                                          y: animation.fromCenter.y + (animation.toCenter.y - animation.fromCenter.y) * eased),
                          scale: zoom)
                busy = true
            }
        }

        for i in nodes.indices where nodes[i].born > 0 {
            if now - nodes[i].born >= Metrics.popDuration { nodes[i].born = 0 } else { busy = true }
        }

        needsDisplay = true
        return busy
    }

    /// How far a newly added bubble has grown, 0…1 with a slight overshoot.
    private func pop(_ index: Int, _ now: CFTimeInterval) -> CGFloat {
        let born = nodes[index].born
        guard born > 0 else { return 1 }
        let t = (now - born) / Metrics.popDuration
        if t >= 1 { return 1 }
        if t <= 0 { return 0.01 }
        let u = t - 1
        return CGFloat(max(0.01, 1 + 2.70158 * u * u * u + 1.70158 * u * u))
    }

    // MARK: - Input

    private func node(at viewLocation: CGPoint) -> Int? {
        let p = graphPoint(viewLocation)
        // Topmost first: the selected bubble is drawn last.
        if let s = selected, shape.geometry(nodes[s].radius).contains(dx: p.x - position(s).x, dy: p.y - position(s).y) { return s }
        for i in nodes.indices.reversed() {
            let c = position(i)
            if shape.geometry(nodes[i].radius).contains(dx: p.x - c.x, dy: p.y - c.y) { return i }
        }
        return nil
    }

    private func noteInteraction() {
        if !hasInteracted {
            hasInteracted = true
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func updateHover(at location: CGPoint) {
        let hit = node(at: location)
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
        (hit == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil {
            hovered = nil
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = node(at: convert(event.locationInWindow, from: nil)) else { return nil }
        if !isSelected(index) { select(index: index) }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Compose Agent Prompt…", action: #selector(promptFromBubble), keyEquivalent: "")
        item.target = self
        if layout.nodes[index].pinned {
            let unpin = menu.addItem(withTitle: "Unpin", action: #selector(unpinBubble(_:)), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = nodes[index].model.id
        }
        return menu
    }

    @objc private func promptFromBubble() { onPrompt?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        noteInteraction()
        let location = convert(event.locationInWindow, from: nil)
        if let index = node(at: location) {
            let p = graphPoint(location), c = position(index)
            drag = .node(index: index, grab: CGPoint(x: p.x - c.x, y: p.y - c.y), start: location, moved: false)
        } else {
            drag = .pan(start: location, last: location, moved: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case let .pan(start, last, moved):
            let nowMoved = moved || hypot(location.x - start.x, location.y - start.y) > 3
            if nowMoved {
                cameraAnimation = nil
                userMovedCamera = true
                offset.x += location.x - last.x
                offset.y += location.y - last.y
                NSCursor.closedHand.set()
                needsDisplay = true
            }
            drag = .pan(start: start, last: nowMoved ? location : last, moved: nowMoved)
        case let .node(index, grab, start, moved):
            guard moved || hypot(location.x - start.x, location.y - start.y) > 3 else { return }
            let p = graphPoint(location)
            if !moved, !wholeGraphDrag { layout.beginLocalDrag(index) }
            cameraAnimation = nil
            layout.moveDraggedNode(index, x: p.x - grab.x, y: p.y - grab.y)
            needsDisplay = true
            userMovedCamera = true
            drag = .node(index: index, grab: grab, start: start, moved: true)
            startAnimating()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            break
        case let .pan(_, _, moved):
            if !moved { select(index: nil) }
        case let .node(index, _, _, moved):
            if moved {
                layout.endDrag()
            } else if event.modifierFlags.contains(.shift) {
                toggleSelection(index)
            } else if event.clickCount >= 2 {
                focus(on: index)
            } else {
                select(index: index)
            }
        }
        drag = .none
        onStateChanged?()
        updateHover(at: location)
    }

    override func scrollWheel(with event: NSEvent) {
        noteInteraction()
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise, abs(dx) > abs(dy), event.modifierFlags.isDisjoint(with: [.command, .option]) {
            cameraAnimation = nil
            userMovedCamera = true
            offset.x += dx
            needsDisplay = true
        } else if dy != 0 {
            let amount = precise ? dy * 0.01 : max(-8, min(8, dy)) * 0.06
            zoom(by: exp(amount), around: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        noteInteraction()
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        noteInteraction()
        if let index = node(at: convert(event.locationInWindow, from: nil)) {
            focus(on: index)
        } else {
            zoomToFit()
        }
    }

    override func keyDown(with event: NSEvent) {
        if (123...126).contains(event.keyCode), focusAnchor != nil || event.modifierFlags.contains(.shift) {
            navigate(backwards: event.keyCode == 123 || event.keyCode == 126, extending: event.modifierFlags.contains(.shift))
            return
        }
        let pan: CGFloat = 70
        switch event.keyCode {
        case 36: enterNeighborhood()
        case 53: if focusAnchor != nil { leaveNeighborhood() } else { select(index: nil) }                                   // esc
        case 123: nudge(dx: pan, dy: 0)                               // ←
        case 124: nudge(dx: -pan, dy: 0)                              // →
        case 125: nudge(dx: 0, dy: -pan)                              // ↓
        case 126: nudge(dx: 0, dy: pan)                               // ↑
        default: super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        noteInteraction()
        cameraAnimation = nil
        userMovedCamera = true
        offset.x += dx
        offset.y += dy
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paint = Paint(appearance: effectiveAppearance)
        context.setFillColor(paint.background)
        context.fill(bounds)
        drawGrid(context, paint)

        guard !nodes.isEmpty else {
            drawBanner(context, paint)
            return
        }

        let now = CACurrentMediaTime()
        // With a search or a selection active, everything outside it steps back.
        let picked = selectionIDs.compactMap { indexByID[$0] }
        let emphasis: Set<Int>? = focusAnchor.flatMap { indexByID[$0] }.map { nodes[$0].neighbors.union([$0]) }
            ?? matches ?? (picked.isEmpty ? nil : Set(picked.flatMap { nodes[$0].neighbors.union([$0]) }))
        let hot = selected ?? hovered
        let hulls = showsGroups ? groups.map { hull(of: $0, now: now) } : []

        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: scale, y: scale)
        let curves = edges.map { curve(for: $0, now: now) }
        drawHulls(context, paint, hulls)
        drawEdges(context, paint, curves, emphasis: emphasis, hot: hot)
        drawNodes(context, paint, emphasis: emphasis, now: now)
        drawEdgeLabels(context, paint, curves, emphasis: emphasis, hot: hot)
        context.restoreGState()

        drawGroupLabels(context, paint, hulls)
        drawOverlay(context, paint)
        drawBanner(context, paint)
    }

    /// A dot grid that moves with the camera, so panning and zooming feel anchored to something.
    private func drawGrid(_ context: CGContext, _ paint: Paint) {
        var spacing = 28 * scale
        while spacing < 18 { spacing *= 2 }
        while spacing > 72 { spacing /= 2 }
        let startX = offset.x.truncatingRemainder(dividingBy: spacing)
        let startY = offset.y.truncatingRemainder(dividingBy: spacing)
        let path = CGMutablePath()
        var y = startY - spacing
        while y < bounds.height + spacing {
            var x = startX - spacing
            while x < bounds.width + spacing {
                path.addRect(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                x += spacing
            }
            y += spacing
        }
        context.addPath(path)
        context.setFillColor(paint.grid)
        context.fillPath()
    }

    private struct Hull {
        var path: CGPath
        /// Where the group's name goes: the top or bottom of the outline, whichever faces away
        /// from the middle of the graph. Arrows mostly run inward, so the outer side is clear.
        var anchor: CGPoint
    }

    /// The outline that wraps every bubble of a group.
    private func hull(of group: Group, now: CFTimeInterval) -> Hull? {
        guard !group.members.isEmpty else { return nil }
        let outline = layout.dragOutline(for: group.members[0]) ?? GroupBoundary.outline(group.members.flatMap { member in
            shape.geometry(nodes[member].radius * pop(member, now)).rim(at: position(member), padding: 22)
        })
        guard outline.count > 2, let top = outline.min(by: { $0.y < $1.y }), let bottom = outline.max(by: { $0.y < $1.y }) else {
            return nil
        }
        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        let middle = layout.nodes.map(\.y).reduce(0, +) / Double(max(layout.nodes.count, 1))
        let own = group.members.map { layout.nodes[$0].y }.reduce(0, +) / Double(group.members.count)
        return Hull(path: path, anchor: own > middle + 30 ? bottom : top)
    }

    private func drawHulls(_ context: CGContext, _ paint: Paint, _ hulls: [Hull?]) {
        for (group, hull) in zip(groups, hulls) {
            guard let hull else { continue }
            context.addPath(hull.path)
            context.setFillColor(paint.stroke(group.hue, alpha: paint.isDark ? 0.075 : 0.06))
            context.fillPath()
            context.addPath(hull.path)
            context.setStrokeColor(paint.stroke(group.hue, alpha: paint.isDark ? 0.30 : 0.26))
            context.setLineWidth(1 / scale)
            context.strokePath()
        }
    }

    private func drawGroupLabels(_ context: CGContext, _ paint: Paint, _ hulls: [Hull?]) {
        for (group, hull) in zip(groups, hulls) {
            guard let hull else { continue }
            let anchor = viewPoint(hull.anchor)
            let label = group.label
            let pill = CGRect(x: anchor.x - label.width / 2 - 8, y: anchor.y - label.lineHeight / 2 - 3,
                              width: label.width + 16, height: label.lineHeight + 6)
            let shape = CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
            context.addPath(shape)
            context.setFillColor(paint.background)
            context.fillPath()
            context.addPath(shape)
            context.setFillColor(paint.stroke(group.hue, alpha: paint.isDark ? 0.20 : 0.14))
            context.fillPath()
            context.addPath(shape)
            context.setStrokeColor(paint.stroke(group.hue, alpha: 0.45))
            context.setLineWidth(1)
            context.strokePath()
            context.setFillColor(paint.isDark ? paint.text : paint.stroke(group.hue.blended(withFraction: 0.45, of: .black) ?? group.hue))
            label.draw(in: context, centerX: anchor.x, top: pill.minY + 3)
        }
    }

    private struct Curve {
        var start: CGPoint
        var control: CGPoint
        var end: CGPoint
        var tip: CGPoint
        var middle: CGPoint
        var direction: CGPoint
    }

    /// A gently bowed arrow between two bubbles. Bowing means A→B and B→A never sit on top of each other.
    private func curve(for edge: Edge, now: CFTimeInterval) -> Curve? {
        let a = position(edge.source), b = position(edge.target)
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let bend = min(length * 0.10, 30)
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / length * bend, y: (a.y + b.y) / 2 + dx / length * bend)
        func step(from: CGPoint, toward: CGPoint, by distance: CGFloat) -> CGPoint {
            let l = max(hypot(toward.x - from.x, toward.y - from.y), 0.001)
            return CGPoint(x: from.x + (toward.x - from.x) / l * distance, y: from.y + (toward.y - from.y) / l * distance)
        }
        let ra = shape.geometry(nodes[edge.source].radius * pop(edge.source, now)).reach(dx: control.x - a.x, dy: control.y - a.y)
        let rb = shape.geometry(nodes[edge.target].radius * pop(edge.target, now)).reach(dx: control.x - b.x, dy: control.y - b.y)
        guard length > ra + rb + 6 else { return nil }
        let start = step(from: a, toward: control, by: ra + 3)
        let tip = step(from: b, toward: control, by: rb + 3)
        let end = edge.model.directed ? step(from: b, toward: control, by: rb + 3 + 7 * strokeScale) : tip
        let unit = step(from: .zero, toward: CGPoint(x: tip.x - control.x, y: tip.y - control.y), by: 1)
        let middle = CGPoint(x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
                             y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y)
        return Curve(start: start, control: control, end: end, tip: tip, middle: middle, direction: unit)
    }

    private func drawEdges(_ context: CGContext, _ paint: Paint, _ curves: [Curve?], emphasis: Set<Int>?, hot: Int?) {
        let hairline = max(1.2 * strokeScale, 1 / scale)
        // Cold edges first so the highlighted ones always end up on top.
        for pass in 0...1 {
            for (edge, curve) in zip(edges, curves) {
                let highlighted = hot == edge.source || hot == edge.target
                guard highlighted == (pass == 1), let curve else { continue }
                let color = highlighted ? paint.stroke(nodes[hot!].hue) : paint.edge
                context.setAlpha(!highlighted && emphasis != nil ? (paint.isDark ? 0.42 : 0.3) : 1)
                context.setStrokeColor(color)
                context.setFillColor(color)
                context.setLineWidth(highlighted ? hairline * 1.7 : hairline)
                context.setLineCap(.round)
                context.setLineDash(phase: 0, lengths: edge.model.dashed ? [5 * strokeScale, 4.5 * strokeScale] : [])
                context.move(to: curve.start)
                context.addQuadCurve(to: curve.end, control: curve.control)
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])

                if edge.model.directed {
                    let length = (highlighted ? 11 : 9.5) * strokeScale, half = (highlighted ? 4.8 : 4.2) * strokeScale
                    let d = curve.direction
                    let base = CGPoint(x: curve.tip.x - d.x * length, y: curve.tip.y - d.y * length)
                    context.move(to: curve.tip)
                    context.addLine(to: CGPoint(x: base.x - d.y * half, y: base.y + d.x * half))
                    context.addLine(to: CGPoint(x: base.x + d.y * half, y: base.y - d.x * half))
                    context.closePath()
                    context.fillPath()
                }
            }
        }
        context.setAlpha(1)
    }

    /// Arrow labels appear once they are big enough to read, and always on highlighted arrows.
    /// Each one slides along its arrow to the spot that covers the least: ideally nothing,
    /// otherwise a bubble's rim rather than another label. Highlighted arrows choose first.
    private func drawEdgeLabels(_ context: CGContext, _ paint: Paint, _ curves: [Curve?], emphasis: Set<Int>?, hot: Int?) {
        let onScreen = Metrics.edgeLabelSize * scale
        var taken: [CGRect] = []
        var placements: [(edge: Int, center: CGPoint, boost: CGFloat, highlighted: Bool)] = []
        for wantHot in [true, false] {
            for (index, edge) in edges.enumerated() {
                let highlighted = hot == edge.source || hot == edge.target
                guard highlighted == wantHot, let label = edge.label, let curve = curves[index] else { continue }
                switch labels {
                case .automatic where !highlighted && (emphasis != nil || onScreen < 6.5): continue
                case .neighborhood where !isSelected(edge.source) && !isSelected(edge.target): continue
                default: break
                }
                let boost = onScreen > 13.5 ? 13.5 / onScreen : (highlighted ? max(1, 11 / onScreen) : 1)
                let size = CGSize(width: (label.width + 10) * boost, height: (label.lineHeight + 3) * boost)
                var best: (cost: Int, point: CGPoint, box: CGRect)?
                for t in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8] as [CGFloat] {
                    let u = 1 - t
                    let point = CGPoint(x: u * u * curve.start.x + 2 * u * t * curve.control.x + t * t * curve.end.x,
                                        y: u * u * curve.start.y + 2 * u * t * curve.control.y + t * t * curve.end.y)
                    let box = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                    let roomy = box.insetBy(dx: -3, dy: -2)
                    var cost = taken.contains(where: { $0.intersects(roomy) }) ? 2 : 0
                    for i in nodes.indices {
                        let c = position(i)
                        let nearest = CGPoint(x: min(max(c.x, box.minX), box.maxX), y: min(max(c.y, box.minY), box.maxY))
                        if shape.geometry(nodes[i].radius + 2).contains(dx: nearest.x - c.x, dy: nearest.y - c.y) {
                            cost += 1
                            break
                        }
                    }
                    if best == nil || cost < best!.cost { best = (cost, point, box) }
                    if cost == 0 { break }
                }
                // Nowhere to go without covering another label: leave it out rather than show half
                // of it. It comes back as soon as either of its bubbles is hovered or selected.
                guard let best, labels != .automatic || highlighted || best.cost < 2 else { continue }
                taken.append(best.box)
                placements.append((index, best.point, boost, highlighted))
            }
        }
        for placement in placements.reversed() {
            guard let label = edges[placement.edge].label else { continue }
            context.saveGState()
            context.translateBy(x: placement.center.x, y: placement.center.y)
            context.scaleBy(x: placement.boost, y: placement.boost)
            let pill = CGRect(x: -label.width / 2 - 5, y: -label.lineHeight / 2 - 1.5,
                              width: label.width + 10, height: label.lineHeight + 3)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.setFillColor(paint.backgroundColor(alpha: 0.92))
            context.fillPath()
            context.setFillColor(placement.highlighted ? paint.text : paint.secondaryText)
            label.draw(in: context, centerX: 0, top: -label.lineHeight / 2)
            context.restoreGState()
        }
    }

    private func drawNodes(_ context: CGContext, _ paint: Paint, emphasis: Set<Int>?, now: CFTimeInterval) {
        var fills: [Int: CGColor] = [:], strokes: [Int: CGColor] = [:]
        // The selected bubble goes last so nothing overlaps its ring.
        let order = nodes.indices.filter { $0 != selected } + (selected.map { [$0] } ?? [])
        for i in order {
            let node = nodes[i]
            let grow = pop(i, now)
            let c = position(i), radius = node.radius * grow
            let dimmed = emphasis.map { !$0.contains(i) } ?? false
            let isSelected = isSelected(i), isHovered = i == hovered
            if fills[node.group] == nil {
                fills[node.group] = paint.fill(node.hue)
                strokes[node.group] = paint.stroke(node.hue)
            }
            let geometry = shape.geometry(radius)
            let outline = geometry.path(at: c)

            let fade: CGFloat = paint.isDark ? 0.42 : 0.3
            context.setAlpha(dimmed ? fade : 1)
            if isSelected {
                context.setStrokeColor(paint.stroke(node.hue, alpha: 0.32))
                let halo = max(5 * strokeScale, 5 / scale)
                context.setLineWidth(halo)
                context.addPath(geometry.path(at: c, padding: halo * 0.9))
                context.strokePath()
            }
            context.setFillColor(fills[node.group]!)
            context.addPath(outline)
            context.fillPath()
            let weight: CGFloat = isSelected ? 3 : (isHovered ? 2.4 : 1.5)
            context.setStrokeColor(strokes[node.group]!)
            context.setLineWidth(max(weight * strokeScale, weight * 0.7 / scale))
            context.addPath(outline)
            context.strokePath()

            // Text is skipped while a bubble is still popping in, and once it is too small to read.
            guard grow > 0.97, node.labelSize * scale >= 5 else { continue }
            var summaryAlpha: CGFloat = 0
            if node.summary != nil {
                // The summary fades in as its type grows from 8.5pt to 10.5pt on screen.
                let t = max(0, min(1, (node.summarySize * scale - 8.5) / 2))
                summaryAlpha = t * t * (3 - 2 * t)
            }
            let gap = node.radius * 0.07
            let extra = node.summary.map { summaryAlpha * ($0.height + gap) } ?? 0
            let top = c.y - (node.label.height + extra) / 2
            context.setFillColor(paint.text)
            node.label.draw(in: context, centerX: c.x, top: top)
            if let summary = node.summary, summaryAlpha > 0.01 {
                context.setAlpha((dimmed ? fade : 1) * summaryAlpha)
                context.setFillColor(paint.secondaryText)
                summary.draw(in: context, centerX: c.x, top: top + node.label.height + gap)
            }
        }
        context.setAlpha(1)
    }

    private func drawOverlay(_ context: CGContext, _ paint: Paint) {
        let percent = Int((scale * 100).rounded())
        if zoomLabel?.percent != percent {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            zoomLabel = (percent, TextBlock.make("\(percent)%", font: font, maxWidth: 200, maxLines: 1))
        }
        if let label = zoomLabel?.block {
            context.setFillColor(paint.tertiaryText)
            label.draw(in: context, centerX: 16 + label.width / 2, top: bounds.height - 14 - label.lineHeight)
        }
        if focusAnchor != nil {
            TextBlock.make("Neighborhood  ·  Arrow keys to explore  ·  Esc to return", font: .systemFont(ofSize: 12),
                           maxWidth: bounds.width - 80, maxLines: 1).draw(in: context, centerX: bounds.midX, top: bounds.height - 30)
        } else if showsHint, !hasInteracted, bounds.width > hint.width + 160 {
            context.setFillColor(paint.tertiaryText)
            hint.draw(in: context, centerX: bounds.midX, top: bounds.height - 14 - hint.lineHeight)
        }
    }

    private func drawBanner(_ context: CGContext, _ paint: Paint) {
        guard let banner, bounds.width > 120 else { return }
        let block = TextBlock.make(banner, font: .systemFont(ofSize: 12, weight: .medium),
                                   maxWidth: min(bounds.width - 80, 760), maxLines: 3)
        let box = CGRect(x: bounds.midX - block.width / 2 - 14, y: 14, width: block.width + 28, height: block.height + 16)
        let shape = CGPath(roundedRect: box, cornerWidth: 9, cornerHeight: 9, transform: nil)
        context.addPath(shape)
        context.setFillColor(paint.background)
        context.fillPath()
        context.addPath(shape)
        context.setFillColor(paint.stroke(.systemOrange, alpha: paint.isDark ? 0.24 : 0.18))
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(paint.stroke(.systemOrange, alpha: 0.7))
        context.setLineWidth(1)
        context.strokePath()
        context.setFillColor(paint.text)
        block.draw(in: context, centerX: bounds.midX, top: box.minY + 8)
    }
}
