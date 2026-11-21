import AppKit

private extension NSToolbarItem.Identifier {
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let search = NSToolbarItem.Identifier("search")
}

/// The app: one window showing one graph file, for as long as the user keeps it open.
final class ViewerController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private static var shared: ViewerController?

    private let path: String
    private var graph: ConceptGraph
    private let canvas = CanvasView()
    private let inspector = InspectorViewController()
    private let split = NSSplitViewController()
    private var window: NSWindow!
    private var searchItem: NSSearchToolbarItem?
    private var lock: InstanceLock?
    private var signalSources: [DispatchSourceSignal] = []

    private struct FileSignature: Equatable {
        var seconds: Int
        var nanoseconds: Int
        var size: Int64
        var inode: UInt64
    }
    private var loadedSignature: FileSignature?
    private var candidateSignature: FileSignature?

    static func run(path: String, graph: ConceptGraph) -> Never {
        let app = NSApplication.shared
        let controller = ViewerController(path: path, graph: graph)
        shared = controller
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }

    private init(path: String, graph: ConceptGraph) {
        self.path = path
        self.graph = graph
        super.init()
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One window per graph file. If another viewer already has this file, it will
        // pick up the changes by itself, so there is nothing for this one to do.
        guard let lock = InstanceLock(file: path) else { exit(0) }
        self.lock = lock
        loadedSignature = signature()

        NSApp.applicationIconImage = AppIcon.make()
        NSApp.mainMenu = makeMenu()
        makeWindow()

        canvas.onSelectionChanged = { [weak self] _ in self?.refreshInspector() }
        inspector.onNavigate = { [weak self] id in self?.canvas.select(id: id, reveal: true) }
        canvas.setGraph(graph)
        refreshInspector()
        refreshTitle()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        bringToFront()

        // Live reload: the agent rewrites the file, the window follows.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)

        // SIGUSR1 = "open" was run again on this file; SIGTERM/SIGINT = close.
        observe(SIGUSR1) { [weak self] in
            self?.reload()
            self?.bringToFront()
        }
        observe(SIGTERM) { NSApp.terminate(nil) }
        observe(SIGINT) { NSApp.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func observe(_ number: Int32, _ handler: @escaping () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }

    private func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // macOS will not take focus away from an app the user is busy in. If that is what
        // happened, bounce the Dock icon once so the window does not go unnoticed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    // MARK: - Window

    private func makeWindow() {
        let canvasController = NSViewController()
        canvasController.view = canvas
        let canvasItem = NSSplitViewItem(viewController: canvasController)
        canvasItem.minimumThickness = 380
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 480
        split.addSplitViewItem(canvasItem)
        split.addSplitViewItem(inspectorItem)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1320, height: 840))
        window.minSize = NSSize(width: 760, height: 480)
        window.center()
        window.setFrameAutosaveName("ConceptGraphWindow")
        window.delegate = self

        let toolbar = NSToolbar(identifier: "ConceptGraphToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        split.view.layoutSubtreeIfNeeded()
        split.splitView.setPosition(split.view.bounds.width - 340, ofDividerAt: 0)
        split.splitView.autosaveName = "ConceptGraphSplit"
    }

    private func refreshTitle() {
        window.title = graph.title
        let concepts = "\(graph.nodes.count) concept\(graph.nodes.count == 1 ? "" : "s")"
        let relationships = "\(graph.edges.count) relationship\(graph.edges.count == 1 ? "" : "s")"
        window.subtitle = "\(concepts) · \(relationships)"
    }

    private func refreshInspector() {
        inspector.show(graph: graph, selected: canvas.selectedID, style: canvas.style)
    }

    // MARK: - Live reload

    private func signature() -> FileSignature? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileSignature(seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec,
                             size: info.st_size, inode: info.st_ino)
    }

    private func poll() {
        // If the file is gone (say the agent cleaned up), keep showing what we have.
        guard let current = signature() else { return }
        if current == loadedSignature {
            candidateSignature = nil
        } else if current == candidateSignature {
            reload()
        } else {
            // Changed since the last look: wait one more tick so we never read a half-written file.
            candidateSignature = current
        }
    }

    private func reload() {
        guard let current = signature() else { return }
        loadedSignature = current
        candidateSignature = nil
        let result = GraphParser.load(path: path)
        guard let updated = result.graph else {
            let name = (path as NSString).lastPathComponent
            let problem = result.errors.first?.line ?? "unknown problem"
            canvas.banner = "The latest change to \(name) could not be shown; this is the last version that worked.\n\(problem)"
            return
        }
        canvas.banner = nil
        guard updated != graph else { return }
        graph = updated
        canvas.setGraph(updated)
        refreshInspector()
        refreshTitle()
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .zoom, .search, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .zoom:
            let names = ["minus.magnifyingglass", "plus.magnifyingglass", "arrow.up.left.and.arrow.down.right"]
            let labels = ["Zoom Out", "Zoom In", "Zoom to Fit"]
            let images = zip(names, labels).map { name, label in
                NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
            }
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier, images: images, selectionMode: .momentary,
                                           labels: labels, target: self, action: #selector(zoomFromToolbar(_:)))
            group.label = "Zoom"
            for (item, label) in zip(group.subitems, labels) { item.toolTip = label }
            return group
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "Find a concept"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.delegate = self
            item.preferredWidthForSearchField = 210
            searchItem = item
            return item
        default:
            return nil
        }
    }

    @objc private func zoomFromToolbar(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0: canvas.zoomOut()
        case 1: canvas.zoomIn()
        default: canvas.zoomToFit()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        canvas.setSearch(sender.stringValue)
    }

    /// Return in the search field walks through the matches.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        canvas.selectNextMatch()
        return true
    }

    // MARK: - Menu

    @objc private func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc private func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }
    @objc private func zoomToActualSize(_ sender: Any?) { canvas.zoomToActualSize() }
    @objc private func find(_ sender: Any?) { searchItem?.beginSearchInteraction() }
    @objc private func revealFile(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func makeMenu() -> NSMenu {
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Concept Graph"
        let main = NSMenu()

        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        submenu(name) { menu in
            add(menu, "About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            menu.addItem(.separator())
            add(menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
            add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("File") { menu in
            add(menu, "Show Graph File in Finder", #selector(revealFile(_:)), "r", [.command, .shift], target: self)
            menu.addItem(.separator())
            add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        }
        submenu("Edit") { menu in
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())
            add(menu, "Find…", #selector(find(_:)), "f", target: self)
        }
        submenu("View") { menu in
            add(menu, "Zoom In", #selector(zoomIn(_:)), "+", target: self)
            // ⌘= is the same key without Shift; accept it too, without showing a second menu item.
            let plain = add(menu, "Zoom In", #selector(zoomIn(_:)), "=", target: self)
            plain.isAlternate = false
            plain.isHidden = true
            plain.allowsKeyEquivalentWhenHidden = true
            add(menu, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
            add(menu, "Zoom to Fit", #selector(zoomToFit(_:)), "0", target: self)
            add(menu, "Actual Size", #selector(zoomToActualSize(_:)), "1", target: self)
            menu.addItem(.separator())
            add(menu, "Show or Hide Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option])
            add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }
        submenu("Window") { menu in
            add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
            NSApp.windowsMenu = menu
        }
        return main
    }
}

/// Drawn at launch so the Dock shows something better than a blank executable.
enum AppIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = rect.insetBy(dx: 50, dy: 50)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 92, cornerHeight: 92, transform: nil))
            context.clip()
            let colors = [CGColor(srgbRed: 0.16, green: 0.18, blue: 0.30, alpha: 1),
                          CGColor(srgbRed: 0.08, green: 0.09, blue: 0.15, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
            }
            let bubbles: [(CGPoint, CGFloat, NSColor)] = [
                (CGPoint(x: 205, y: 300), 78, .systemBlue), (CGPoint(x: 352, y: 352), 46, .systemOrange),
                (CGPoint(x: 340, y: 190), 58, .systemGreen), (CGPoint(x: 168, y: 158), 36, .systemPurple),
            ]
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
            context.setLineWidth(7)
            for (a, b) in [(0, 1), (0, 2), (0, 3), (1, 2)] {
                context.move(to: bubbles[a].0)
                context.addLine(to: bubbles[b].0)
            }
            context.strokePath()
            for (center, radius, color) in bubbles {
                let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let rgb = color.usingColorSpace(.sRGB) ?? color
                context.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.18, alpha: 1))
                context.fillEllipse(in: circle)
                context.setFillColor(rgb.withAlphaComponent(0.55).cgColor)
                context.fillEllipse(in: circle)
                context.setStrokeColor(rgb.cgColor)
                context.setLineWidth(7)
                context.strokeEllipse(in: circle)
            }
            return true
        }
    }
}
