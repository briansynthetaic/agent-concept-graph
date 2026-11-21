import Foundation

/// An open descriptor keeps the bytes and their identity together across atomic renames.
struct FileSignature: Equatable {
    let seconds: Int
    let nanoseconds: Int
    let size: Int64
    let inode: UInt64
    let device: Int32

    init(_ info: stat) {
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
        size = info.st_size
        inode = info.st_ino
        device = info.st_dev
    }

    static func at(_ path: String) -> Self? {
        var info = stat()
        return stat(path, &info) == 0 ? Self(info) : nil
    }
}

struct GraphFile {
    let bytes: Data
    let signature: FileSignature?
    let result: ParseResult

    init(_ path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var before = stat(), after = stat()
        let initial = fstat(handle.fileDescriptor, &before) == 0 ? FileSignature(before) : nil
        bytes = try handle.readToEnd() ?? Data()
        signature = fstat(handle.fileDescriptor, &after) == 0 && initial == FileSignature(after) ? initial : nil
        result = GraphParser.parse(data: bytes)
    }

    func saveCopy(of source: String, to destination: URL, arrangement: Arrangement,
                  confirmLastValid: () -> Bool) throws -> Bool {
        try Self.requireDistinct(source: source, destination: destination)
        let target = Launcher.documentPath(destination.path)
        let data: Data
        if let latest = try? GraphFile(source), latest.result.graph != nil,
           let signature = latest.signature, signature == FileSignature.at(source) {
            data = latest.bytes
        } else {
            guard confirmLastValid() else { return false }
            data = bytes
        }
        try Launcher.checkLegacyWindow(file: target)
        guard let lock = try InstanceLock(file: target) else {
            throw Launcher.LaunchError(description: "Choose another name or close the destination graph first.")
        }
        try withExtendedLifetime(lock) {
            try Self.requireDistinct(source: source, destination: URL(fileURLWithPath: target))
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
            try arrangement.save(for: target)
        }
        return true
    }

    static func requireDistinct(source: String, destination: URL) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath().path
        let original = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path
        let a = FileSignature.at(source), b = FileSignature.at(destination.path)
        if original == target || (a != nil && a?.device == b?.device && a?.inode == b?.inode) {
            throw Launcher.LaunchError(description: "Choose a destination different from the source graph.")
        }
    }
}
