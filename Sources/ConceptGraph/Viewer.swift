import AppKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let agent = NSToolbarItem.Identifier("agent")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let search = NSToolbarItem.Identifier("search")
}

private final class InspectorSplitController: NSSplitViewController {
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let native = super.splitView(splitView, effectiveRect: proposedEffectiveRect,
                                     forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard drawnRect.height > 0,
              !splitViewItems[dividerIndex + 1].isCollapsed else { return native }
        return native.union(drawnRect.insetBy(dx: -12, dy: 0)).intersection(splitView.bounds)
    }
}

/// The app: one window showing one graph file, for as long as the user keeps it open.
final class ViewerController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private static var shared: ViewerController?

    private let path: String
    private var graph: ConceptGraph
    private let canvas = CanvasView()
    private let inspector = InspectorViewController()
    private let split = InspectorSplitController()
    private var window: NSWindow!
    private var searchItem: NSSearchToolbarItem?
    private let lock: InstanceLock
    private let channel = ViewerChannel()

    private var lastValid: GraphFile
    private var loadedSignature: FileSignature?
    private var candidateSignature: FileSignature?
    private var loading = false
    private var pendingSave: DispatchWorkItem?
    private let recent = NSMenu(title: "Open Recent")
    private let settingsChanged = Notification.Name("local.concept-graph.settingsChanged")
    private let layoutUndo = UndoManager()

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { layoutUndo }

    static func run(path: String, graph: ConceptGraph, file: GraphFile, lock: InstanceLock) -> Never {
        let app = NSApplication.shared
        let controller = ViewerController(path: path, graph: graph, file: file, lock: lock)
        shared = controller
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }

    private init(path: String, graph: ConceptGraph, file: GraphFile, lock: InstanceLock) {
        self.path = path
        self.lock = lock
        self.graph = graph
        lastValid = file
        loadedSignature = file.signature
        super.init()
    }

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        recent.delegate = self
        NSApp.mainMenu = makeMenu()
        makeWindow()

        canvas.onPrompt = { [weak self] in self?.composePrompt(nil) }
        canvas.onSelectionChanged = { [weak self] _ in self?.refreshInspector() }
        inspector.onNavigate = { [weak self] id in self?.canvas.select(id: id, reveal: true) }
        window.representedURL = URL(fileURLWithPath: path)
        NSDocumentController.shared.noteNewRecentDocumentURL(window.representedURL!)
        canvas.setGraph(graph)
        if let state = Arrangement.load(for: path) { canvas.restore(state) }
        canvas.onStateChanged = { [weak self] in self?.scheduleSave() }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(applyPreferences),
            name: settingsChanged, object: nil)
        refreshInspector()
        refreshTitle()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        bringToFront()

        // Live reload: the agent rewrites the file, the window follows.
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)

        do {
            try channel.start(file: path, focus: { [weak self] in
                self?.reload()
                self?.bringToFront()
            }, closeWindow: { NSApp.terminate(nil) })
        } catch { fail("Could not start the document control channel: \(error)") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

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
        inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        split.splitView.dividerStyle = .thick
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

    private func poll() {
        guard !loading else { return }
        guard let current = FileSignature.at(path) else {
            canvas.banner = "Showing the last valid graph.\nThe source file is unavailable."
            candidateSignature = nil
            loadedSignature = nil
            return
        }
        if current == loadedSignature {
            candidateSignature = nil
        } else if current == candidateSignature {
            reload()
        } else {
            candidateSignature = current
        }
    }

    private func reload() {
        guard !loading else { return }
        loading = true
        let path = self.path
        DispatchQueue.global(qos: .userInitiated).async {
            let revision = Result { try GraphFile(path) }
            DispatchQueue.main.async {
                self.loading = false
                self.candidateSignature = nil
                do {
                    let file = try revision.get()
                    // Discard a read overtaken by an in-place write or atomic rename.
                    guard let signature = file.signature, signature == FileSignature.at(path) else { return }
                    self.loadedSignature = signature
                    guard let updated = file.result.graph else {
                        throw Launcher.LaunchError(description: file.result.errors.first?.line ?? "Invalid graph")
                    }
                    self.lastValid = file
                    self.canvas.banner = nil
                    guard updated != self.graph else { return }
                    self.graph = updated
                    self.canvas.setGraph(updated)
                    self.refreshInspector()
                    self.refreshTitle()
                    self.scheduleSave()
                } catch {
                    self.canvas.banner = "Showing the last valid graph.\n\(error)"
                }
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveState() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func saveState() {
        do { try canvas.arrangement.save(for: path) }
        catch { complain("Could not save arrangement: \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveState()
        unlink(Launcher.socketPath(for: path))
    }
    func windowWillClose(_ notification: Notification) { saveState() }

    private func openDocument(_ url: URL) {
        if Launcher.canonicalPath(url.path) == path { reload(); bringToFront() }
        else { DocumentOpener.open(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Finder can deliver these before the window is constructed.
        DispatchQueue.main.async { urls.forEach(self.openDocument) }
    }

    @objc private func openPanel() {
        if let url = DocumentOpener.choose() { openDocument(url) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recent else { return }
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.path, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No Recent Graphs", action: nil, keyEquivalent: "") }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openDocument(url) }
    }

    @objc private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [DocumentOpener.graphType, .json]
        panel.nameFieldStringValue = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".conceptgraph"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let saved = try lastValid.saveCopy(of: path, to: destination, arrangement: canvas.arrangement) {
                let confirm = NSAlert()
                confirm.messageText = "The source graph is missing or invalid."
                confirm.informativeText = "Save the last valid revision shown in this window?"
                confirm.addButton(withTitle: "Save Last Valid Revision")
                confirm.addButton(withTitle: "Cancel")
                return confirm.runModal() == .alertFirstButtonReturn
            }
            guard saved else { return }
            openDocument(destination)
        } catch { showError(error) }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "The operation could not be completed"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    @objc private func exportPNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = graph.title + ".png"
        let scope = NSPopUpButton()
        let dimensions = "\(Int(canvas.bounds.width * 2)) × \(Int(canvas.bounds.height * 2)) pixels"
        scope.addItems(withTitles: ["Current View · " + dimensions, "Whole Graph · " + dimensions])
        scope.sizeToFit()
        panel.accessoryView = scope
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try canvas.export(to: url, source: path, wholeGraph: scope.indexOfSelectedItem == 1) }
        catch { showError(error) }
    }

    @objc private func settings() {
        let sheet = NSAlert()
        sheet.messageText = "Settings"
        let shape = NSPopUpButton()
        shape.addItems(withTitles: ["Circles", "Rounded Rectangles"])
        shape.selectItem(at: canvas.shape.rawValue)
        let preview = ShapePreview(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        preview.update(shape)
        shape.target = preview
        shape.action = #selector(ShapePreview.update(_:))
        let motion = NSPopUpButton()
        motion.addItems(withTitles: ["Follow System", "Reduce Motion"])
        motion.selectItem(at: ViewerPreferences.defaults.bool(forKey: "reduceMotion") ? 1 : 0)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Node shape"), shape, preview,
                                        NSTextField(labelWithString: "Motion"), motion])
        stack.orientation = .vertical
        stack.alignment = .leading
        preview.heightAnchor.constraint(equalToConstant: 80).isActive = true
        preview.widthAnchor.constraint(equalToConstant: 260).isActive = true
        stack.frame.size = stack.fittingSize
        sheet.accessoryView = stack
        sheet.addButton(withTitle: "Apply")
        sheet.addButton(withTitle: "Cancel")
        guard sheet.runModal() == .alertFirstButtonReturn else { return }
        ViewerPreferences.defaults.set(shape.indexOfSelectedItem, forKey: "nodeShape")
        ViewerPreferences.defaults.set(motion.indexOfSelectedItem == 1, forKey: "reduceMotion")
        ViewerPreferences.defaults.synchronize()
        applyPreferences()
        DistributedNotificationCenter.default().postNotificationName(settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
    }

    @objc private func applyPreferences() {
        ViewerPreferences.defaults.synchronize()
        let shape = NodeShape(rawValue: ViewerPreferences.defaults.integer(forKey: "nodeShape")) ?? .circle
        if canvas.shape != shape {
            canvas.shape = shape
            canvas.setGraph(graph)
            canvas.refreshLayout()
        }
        canvas.needsDisplay = true
    }

    @objc private func labelMode(_ sender: NSMenuItem) {
        canvas.labels = CanvasView.LabelMode(rawValue: sender.tag) ?? .automatic
        for item in sender.menu?.items ?? [] { item.state = item === sender ? .on : .off }
    }

    @objc private func toggleGroups(_ sender: NSMenuItem) {
        canvas.showsGroups.toggle()
        sender.state = canvas.showsGroups ? .on : .off
    }

    @objc private func resetLayout() { canvas.resetLayout() }
    @objc private func focusNeighborhood() { canvas.enterNeighborhood(); window.makeFirstResponder(canvas) }
    @objc private func leaveNeighborhood() { canvas.leaveNeighborhood() }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.agent, .flexibleSpace, .zoom, .search, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .agent:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Agent Prompt"
            item.toolTip = "Compose a prompt for your agent"
            item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(composePrompt(_:))
            return item
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

    @objc private func composePrompt(_ sender: Any?) {
        let composer = PromptComposer(graph: graph, selection: canvas.selectionIDs, path: path)
        composer.present(on: window)
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
            add(menu, "Settings…", #selector(settings), ",", target: self)
            menu.addItem(.separator())
            add(menu, "Hide \(name)", #selector(NSApplication.hide(_:)), "h")
            add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            menu.addItem(.separator())
            add(menu, "Quit \(name)", #selector(NSApplication.terminate(_:)), "q")
        }
        submenu("File") { menu in
            add(menu, "Open…", #selector(openPanel), "o", target: self)
            add(menu, "Open Recent", nil).submenu = recent
            add(menu, "Save As…", #selector(saveAs), "s", [.command, .shift], target: self)
            add(menu, "Export PNG…", #selector(exportPNG), target: self)
            menu.addItem(.separator())
            add(menu, "Compose Agent Prompt…", #selector(composePrompt(_:)), "p", [.command, .shift], target: self)
            add(menu, "Show Graph File in Finder", #selector(revealFile(_:)), "r", [.command, .shift], target: self)
            menu.addItem(.separator())
            add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        }
        submenu("Edit") { menu in
            add(menu, "Undo", Selector(("undo:")), "z")
            menu.addItem(.separator())
            add(menu, "Cut", #selector(NSText.cut(_:)), "x")
            add(menu, "Paste", #selector(NSText.paste(_:)), "v")
            add(menu, "Copy", #selector(NSText.copy(_:)), "c")
            add(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
            menu.addItem(.separator())
            add(menu, "Find…", #selector(find(_:)), "f", target: self)
        }
        submenu("View") { menu in
            let labels = NSMenu(title: "Relationship Labels")
            for (index, name) in ["Automatic", "Selected Neighborhood", "Always"].enumerated() {
                let option = add(labels, name, #selector(labelMode(_:)), target: self)
                option.tag = index
                option.state = index == canvas.labels.rawValue ? .on : .off
            }
            add(menu, "Relationship Labels", nil).submenu = labels
            add(menu, "Show Group Regions", #selector(toggleGroups(_:)), target: self).state = .on
            add(menu, "Focus Neighborhood", #selector(focusNeighborhood), target: self)
            add(menu, "Leave Neighborhood", #selector(leaveNeighborhood), target: self)
            add(menu, "Reset Layout", #selector(resetLayout), target: self)
            menu.addItem(.separator())
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

private final class ShapePreview: NSView {
    private var shape = NodeShape.circle

    @objc func update(_ sender: NSPopUpButton) {
        shape = NodeShape(rawValue: sender.indexOfSelectedItem) ?? .circle
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = shape.geometry(39).path(at: center)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        NSGraphicsContext.current?.cgContext.addPath(path)
        NSGraphicsContext.current?.cgContext.fillPath()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: "Scheduled report delivery", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ])
        let width = shape.geometry(39).labelWidth
        text.draw(in: CGRect(x: center.x - width / 2, y: center.y - 22, width: width, height: 42))
    }
}
