import Foundation
import CryptoKit

struct Arrangement: Codable {
    struct Place: Codable {
        var point: CGPoint
        var pinned: Bool
    }
    var places: [String: Place]
    var center: CGPoint
    var scale: CGFloat
    var automaticCamera: Bool
    var selection: [String]

    static func url(for path: String) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("Concept Graph/Arrangements", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The canonical path survives an agent's atomic replacement of the JSON inode.
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    static func load(for path: String) -> Arrangement? {
        try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url(for: path)))
    }

    func save(for path: String) throws {
        try JSONEncoder().encode(self).write(to: Self.url(for: path), options: .atomic)
    }
}
