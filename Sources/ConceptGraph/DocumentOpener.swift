import AppKit
import UniformTypeIdentifiers

/// Launch Services can start an app before it delivers its first document event.
/// Route Finder and menu opens through the CLI's per-path viewer ownership.
final class DocumentOpener: NSObject, NSApplicationDelegate {
    static let graphType = UTType(exportedAs: "local.concept-graph.document", conformingTo: .json)
    private var receivedFiles = false

    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [graphType, .json]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    static func open(_ url: URL) -> Bool {
        do {
            guard let path = Launcher.canonicalPath(url.path) else { throw CocoaError(.fileNoSuchFile) }
            let file = try GraphFile(path)
            guard file.result.graph != nil else {
                throw Launcher.LaunchError(description: file.result.errors.map(\.line).joined(separator: "\n"))
            }
            _ = try Launcher.openViewer(file: path)
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open \(url.lastPathComponent)"
            alert.informativeText = String(describing: error)
            alert.runModal()
            return false
        }
    }

    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = DocumentOpener()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        urls.forEach { Self.open($0) }
        DispatchQueue.main.async { application.terminate(nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard !self.receivedFiles else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let url = Self.choose() { Self.open(url) }
            NSApp.terminate(nil)
        }
    }
}
