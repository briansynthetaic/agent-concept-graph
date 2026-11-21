// swift-tools-version:5.9
// For editors and `swift build`. scripts/build.sh installs the CLI in the skill
// and builds the app bundle on macOS.
import PackageDescription

#if os(macOS)
let excludedSources: [String] = []
#else
// The document parser and CLI have no window-system dependency.
let excludedSources = [
    "AgentPrompt.swift", "Arrangement.swift", "CanvasView.swift", "DocumentOpener.swift",
    "GraphFile.swift", "InspectorViewController.swift", "Launcher.swift", "Layout.swift",
    "NodeGeometry.swift", "PromptComposer.swift", "Snapshot.swift", "Theme.swift",
    "Viewer.swift", "ViewerChannel.swift",
]
#endif

let package = Package(
    name: "ConceptGraph",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "concept-graph", path: "Sources/ConceptGraph", exclude: excludedSources),
    ]
)
