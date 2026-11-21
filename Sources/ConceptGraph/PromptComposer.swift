import AppKit

/// Freeze the graph and selection together so that the preview always matches the clipboard.
final class PromptComposer: NSObject, NSTextFieldDelegate {
    private let graph: ConceptGraph
    private let selection: [String]
    private let path: String
    private let task = NSPopUpButton()
    private let neighbors = NSButton(checkboxWithTitle: "Include immediate neighbors", target: nil, action: nil)
    private let request = NSTextField()
    private let preview = NSTextView()

    init(graph: ConceptGraph, selection: [String], path: String) {
        self.graph = graph
        self.selection = selection
        self.path = path
    }

    func present(on window: NSWindow) {
        let sheet = NSAlert()
        sheet.messageText = "Compose an agent prompt"
        sheet.informativeText = "Review the context, then copy the prompt into your agent conversation."
        task.addItems(withTitles: PromptTask.allCases.map(\.title))
        neighbors.state = .on
        for control: NSControl in [task, neighbors] {
            control.target = self
            control.action = #selector(update)
        }
        request.delegate = self
        request.placeholderString = "Question or additional instructions"
        request.setAccessibilityLabel("Question or additional instructions")
        request.lineBreakMode = .byWordWrapping
        request.usesSingleLineMode = false
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        preview.isEditable = false
        preview.textContainer?.widthTracksTextView = true
        preview.minSize = .zero
        preview.isVerticallyResizable = true
        preview.isHorizontallyResizable = false
        preview.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        preview.autoresizingMask = [.width]
        preview.setAccessibilityLabel("Prompt context preview")
        scroll.documentView = preview
        let stack = NSStackView(views: [task, neighbors, request, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        for view in [request as NSView, scroll] {
            view.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        request.heightAnchor.constraint(equalToConstant: 56).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        stack.frame.size = stack.fittingSize
        sheet.accessoryView = stack
        sheet.addButton(withTitle: "Copy Prompt")
        sheet.addButton(withTitle: "Cancel")
        sheet.window.initialFirstResponder = request
        update()
        sheet.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.prompt(question: self.request.stringValue), forType: .string)
        }
    }

    private func prompt(question: String) -> String {
        let action = PromptTask(rawValue: task.indexOfSelectedItem) ?? .explain
        return action.compose(graph: graph, path: path, selection: selection, neighbors: neighbors.state == .on, question: question)
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    @objc private func update() {
        neighbors.isEnabled = !selection.isEmpty && task.indexOfSelectedItem != PromptTask.build.rawValue
        preview.string = prompt(question: request.stringValue)
        preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
