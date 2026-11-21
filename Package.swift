// swift-tools-version:5.9
// For editors and `swift build`. The supported build is scripts/build.sh, which uses
// plain swiftc so that only the Xcode Command Line Tools are needed.
import PackageDescription

let package = Package(
    name: "ConceptGraph",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "concept-graph", path: "Sources/ConceptGraph"),
    ]
)
