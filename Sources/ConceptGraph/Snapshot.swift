import AppKit

/// Renders a graph to a PNG without showing a window, using the same views the
/// window uses. This is how an agent can look at what the user is going to see.
enum Snapshot {
    private final class Backdrop: NSView {
        var dividerX: CGFloat = 0
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: dividerX, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    static func render(graph: ConceptGraph, source: String, to path: String, size: CGSize, dark: Bool?) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let appearance = dark.flatMap { NSAppearance(named: $0 ? .darkAqua : .aqua) }
        if let appearance { app.appearance = appearance }

        let inspectorWidth = min(340, size.width * 0.3)
        let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
        backdrop.dividerX = size.width - inspectorWidth
        let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: size.width - inspectorWidth, height: size.height))
        canvas.showsHint = false
        let inspector = InspectorViewController()
        inspector.view.frame = NSRect(x: size.width - inspectorWidth + 1, y: 0, width: inspectorWidth - 1, height: size.height)
        backdrop.addSubview(canvas)
        backdrop.addSubview(inspector.view)

        // An offscreen window gives the views an appearance and a backing store; it is never shown.
        let window = NSWindow(contentRect: backdrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = backdrop

        canvas.setGraph(graph, fullySettle: true)
        inspector.show(graph: graph, selected: canvas.selectedID, style: canvas.style)
        backdrop.layoutSubtreeIfNeeded()

        try write(view: backdrop, source: source, to: URL(fileURLWithPath: path))
    }

    static func write(view: NSView, source: String, to url: URL) throws {
        try GraphFile.requireDistinct(source: source, destination: url)
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Launcher.LaunchError(description: "could not allocate a \(Int(size.width))×\(Int(size.height)) image")
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw Launcher.LaunchError(description: "could not encode the image as PNG")
        }
        try png.write(to: url, options: .atomic)
    }
}
