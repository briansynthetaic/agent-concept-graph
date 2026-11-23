import AppKit
import QuartzCore

private func check(_ condition: @autoclosure () -> Bool, line: UInt = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("Canvas check failed at line \(line)\n".utf8))
        exit(1)
    }
}

/// Drives the actual views in an offscreen window. Input events go straight to this canvas.
private struct Scene {
    let window: NSWindow
    let canvas: CanvasView
    let inspector: InspectorViewController
    let bitmap: NSBitmapImageRep

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 940, height: 720))
        inspector = InspectorViewController()
        inspector.view.frame = NSRect(x: 940, y: 0, width: 340, height: 720)
        content.addSubview(canvas)
        content.addSubview(inspector.view)
        bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    }

    func draw() {
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        content.cacheDisplay(in: content.bounds, to: bitmap)
    }

    func load(_ graph: ConceptGraph) {
        canvas.setGraph(graph)
        inspector.show(graph: graph, selected: canvas.selectedID, style: canvas.style)
        draw()
    }

    func location(of id: String) -> CGPoint {
        let state = canvas.arrangement, p = state.places[id]!.point
        return canvas.convert(CGPoint(x: canvas.bounds.midX + (p.x - state.center.x) * state.scale,
                                      y: canvas.bounds.midY + (p.y - state.center.y) * state.scale), to: nil)
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: canvas.mouseDown(with: event)
        case .leftMouseDragged: canvas.mouseDragged(with: event)
        case .leftMouseUp: canvas.mouseUp(with: event)
        default: preconditionFailure("Unexpected mouse event")
        }
    }

    func scroll(_ unit: CGScrollEventUnit, dy: Int32, dx: Int32 = 0, at point: CGPoint) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: unit, wheelCount: 2,
                            wheel1: dy, wheel2: dx, wheel3: 0)!
        event.flags = []
        // A windowless NSEvent uses screen coordinates. Deliver it only to the test canvas.
        event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y)
        canvas.scrollWheel(with: NSEvent(cgEvent: event)!)
    }
}

@main
enum CanvasChecks {
    private static func checkBubbleDragging(_ original: ConceptGraph) {
        let scene = Scene(), canvas = scene.canvas
        var graph = original
        graph.groups = [.init(id: "team", label: "Team", color: nil)]
        for i in graph.nodes.indices where ["worker", "planner"].contains(graph.nodes[i].id) {
            graph.nodes[i].group = "team"
        }
        scene.load(graph)
        var initial = canvas.arrangement
        initial.center = .zero
        initial.scale = 1
        initial.places["worker"]!.point = CGPoint(x: -300, y: -180)
        initial.places["planner"]!.point = CGPoint(x: -80, y: -160)
        initial.places["planner"]!.pinned = true
        initial.places["runs"]!.point = CGPoint(x: 80, y: -190)
        initial.places["schedule"]!.point = CGPoint(x: 320, y: 250)
        var now = CACurrentMediaTime()
        for wholeGraph in [false, true] {
            now += 2
            canvas.wholeGraphDrag = wholeGraph
            canvas.restore(initial)
            let start = scene.location(of: "worker")
            var end = CGPoint(x: start.x + 400, y: start.y)
            scene.mouse(.leftMouseDown, at: start)
            scene.mouse(.leftMouseDragged, at: end)
            func checkGroupOffset() {
                let places = canvas.arrangement.places
                let anchor = places["worker"]!.point, member = places["planner"]!.point
                check(hypot(member.x - anchor.x - 220, member.y - anchor.y - 20) <= 4.000001)
                check(places["planner"]!.pinned)
            }
            if !wholeGraph { checkGroupOffset() }
            canvas.advanceFrame(at: now + 0.05)
            let following = canvas.arrangement
            if !wholeGraph {
                check(following.places["runs"]!.point != initial.places["runs"]!.point)
                check(following.places["schedule"]!.point == initial.places["schedule"]!.point)
                check(following.places["planner"]!.point.x > initial.places["planner"]!.point.x)
                canvas.advanceFrame(at: now + 0.10)
                check(canvas.arrangement.places["planner"]!.point.x > following.places["planner"]!.point.x)
                end = CGPoint(x: start.x + 60, y: start.y + 80)
                scene.mouse(.leftMouseDragged, at: end)
                checkGroupOffset()
            }
            scene.mouse(.leftMouseUp, at: end)
            let dropped = canvas.arrangement
            for i in 1...60 { canvas.advanceFrame(at: now + 0.10 + Double(i) / 60) }
            if wholeGraph {
                check(canvas.arrangement.places["schedule"]!.point != dropped.places["schedule"]!.point)
            } else {
                for (id, place) in dropped.places {
                    check(canvas.arrangement.places[id]!.point == place.point)
                }
            }
        }
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let work = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        if args.contains("--benchmark") {
            try benchmark(work: work)
            return
        }
        let original = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let source = work.appendingPathComponent("source.json"), target = work.appendingPathComponent("saved.conceptgraph")
        try original.write(to: source)
        let file = try GraphFile(source.path), graph = file.result.graph!
        defer { if let url = try? Arrangement.url(for: target.path) { try? FileManager.default.removeItem(at: url) } }

        checkBubbleDragging(graph)
        let scene = Scene(), canvas = scene.canvas
        scene.load(graph)
        let pointer = scene.location(of: "worker")
        let startScale = canvas.arrangement.scale
        for unit in [CGScrollEventUnit.line, .pixel] {
            scene.scroll(unit, dy: 3, at: pointer)
            check(canvas.arrangement.scale > startScale)
            let afterZoom = scene.location(of: "worker")
            check(hypot(afterZoom.x - pointer.x, afterZoom.y - pointer.y) < 1e-8)
            scene.scroll(unit, dy: -3, at: pointer)
            check(abs(canvas.arrangement.scale - startScale) < 1e-8)
        }
        scene.scroll(.pixel, dy: 0, dx: 12, at: pointer)
        let afterPan = scene.location(of: "worker")
        check(abs(afterPan.x - pointer.x - 12) < 1e-8 && abs(afterPan.y - pointer.y) < 1e-8)
        for shape in NodeShape.allCases {
            canvas.shape = shape
            scene.load(graph)
            let geometry = shape.geometry(50)
            for degree in 0..<360 {
                let angle = CGFloat(degree) * .pi / 180
                let dx = cos(angle), dy = sin(angle), edge = geometry.reach(dx: dx, dy: dy)
                for delta: CGFloat in [-1, 1] {
                    let point = CGPoint(x: (edge + delta) * dx, y: (edge + delta) * dy)
                    check(geometry.path(at: .zero).contains(point) == geometry.contains(dx: point.x, dy: point.y))
                }
            }
            let p = scene.location(of: "worker"), moved = CGPoint(x: p.x + 30, y: p.y + 50)
            scene.mouse(.leftMouseDown, at: p)
            scene.mouse(.leftMouseDragged, at: moved)
            scene.mouse(.leftMouseUp, at: moved)
            check(canvas.arrangement.places["worker"]!.pinned)
            canvas.select(id: "worker", reveal: false)
            let second = scene.location(of: "runs")
            scene.mouse(.leftMouseDown, at: second, modifiers: .shift)
            scene.mouse(.leftMouseUp, at: second, modifiers: .shift)
            check(Set(canvas.selectionIDs) == ["worker", "runs"])
            let before = canvas.arrangement
            var zoomed = before
            zoomed.automaticCamera = false
            zoomed.center = before.places["worker"]!.point
            zoomed.scale = 2.5
            canvas.restore(zoomed)
            let exportCenter = canvas.arrangement.center
            try canvas.export(to: work.appendingPathComponent("current.png"), source: source.path, wholeGraph: false)
            try canvas.export(to: work.appendingPathComponent("whole.png"), source: source.path, wholeGraph: true)
            let current = try Data(contentsOf: work.appendingPathComponent("current.png"))
            let whole = try Data(contentsOf: work.appendingPathComponent("whole.png"))
            check(current != whole && NSBitmapImageRep(data: current)?.pixelsWide == 1880)
            check(canvas.arrangement.scale == zoomed.scale && canvas.arrangement.center == exportCenter)
            check(canvas.arrangement.places["worker"]!.point == before.places["worker"]!.point)
            let undo = scene.window.undoManager!
            undo.beginUndoGrouping()
            canvas.resetLayout()
            undo.endUndoGrouping()
            check(!canvas.arrangement.places["worker"]!.pinned)
            undo.undo()
            check(canvas.arrangement.places["worker"]!.pinned && canvas.arrangement.scale == zoomed.scale)
            var reduced = graph
            reduced.nodes.removeAll { $0.id == "runs" }
            reduced.edges.removeAll { $0.to == "runs" || $0.from == "runs" }
            scene.load(reduced)
            check(canvas.selectionIDs == ["worker"] && canvas.arrangement.places["worker"]!.pinned)
            scene.load(graph)
            canvas.restore(before)
            let center = canvas.arrangement.center
            check(hypot(center.x - before.center.x, center.y - before.center.y) < 1e-8 && Set(canvas.selectionIDs) == ["worker", "runs"])
        }
        let state = canvas.arrangement
        let saved = try file.saveCopy(of: source.path, to: target, arrangement: state) { false }
        let roundTrip = try Data(contentsOf: target)
        check(saved && roundTrip == original && Arrangement.load(for: target.path)!.places["worker"]!.pinned)
        try Data("{".utf8).write(to: source, options: .atomic)
        check(FileSignature.at(source.path) != file.signature)
        for missing in [false, true] {
            if missing { try FileManager.default.removeItem(at: source) }
            let cancelled = try file.saveCopy(of: source.path, to: target, arrangement: state) { false }
            let accepted = try file.saveCopy(of: source.path, to: target, arrangement: state) { true }
            let bytes = try Data(contentsOf: target)
            check(!cancelled && accepted && bytes == original)
        }
        scene.window.close()
        print("Offscreen shape, drag, selection, arrangement, export and Save As checks passed.")
    }

    private static func benchmark(work: URL) throws {
        print("nodes edges   first ms   reload ms   drag p50 ms   drag p95 ms")
        for count in [50, 200, 500] {
            for degree in [1, 6] {
                let nodes = (0..<count).map { ["id": "n" + String($0), "label": "Service " + String($0), "summary": "Handles a request."] }
                let edges = (0..<count).flatMap { i in
                    (0..<degree).map { k in ["from": nodes[i]["id"]!, "to": nodes[(i + 1 + k * 7) % count]["id"]!, "label": "calls"] }
                }
                let url = work.appendingPathComponent("map.json")
                func rewrite(title: String) throws {
                    let data = try JSONSerialization.data(withJSONObject: ["title": title, "nodes": nodes, "edges": edges, "focus": "n0"])
                    try data.write(to: url, options: .atomic)
                }
                try rewrite(title: "Map")
                let start = CACurrentMediaTime()
                let scene = Scene()
                scene.load(try GraphFile(url.path).result.graph!)
                let first = CACurrentMediaTime() - start
                try rewrite(title: "Revised map")
                let reloadStart = CACurrentMediaTime()
                scene.load(try GraphFile(url.path).result.graph!)
                let reload = CACurrentMediaTime() - reloadStart
                let p = scene.location(of: "n0")
                scene.mouse(.leftMouseDown, at: p)
                var frames = [Double]()
                for i in 1...20 {
                    let t = CACurrentMediaTime()
                    scene.mouse(.leftMouseDragged, at: CGPoint(x: p.x + CGFloat(i * 4), y: p.y))
                    scene.canvas.advanceFrame(at: reloadStart + Double(i) / 60)
                    scene.draw()
                    frames.append((CACurrentMediaTime() - t) * 1000)
                }
                scene.mouse(.leftMouseUp, at: CGPoint(x: p.x + 80, y: p.y))
                scene.window.close()
                frames.sort()
                print(String(format: "%5d %5d %10.1f %11.1f %13.1f %13.1f", count, edges.count,
                             first * 1000, reload * 1000, frames[9], frames[18]))
            }
        }
    }
}
