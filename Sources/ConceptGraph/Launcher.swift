import CryptoKit
import Darwin
import Foundation

/// Process plumbing: starting the window as its own process so the agent's
/// command returns immediately, and making sure one graph file gets one window.
///
/// Each viewer holds an exclusive `flock` on a small lock file for as long as it
/// runs. The control socket acknowledges requests only after window setup.
enum Launcher {
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func documentPath(_ path: String) -> String {
        if let existing = canonicalPath(path) { return existing }
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }

    /// Per-user temporary directory (independent of `$TMPDIR`, so every caller agrees on it).
    private static let stateDirectory: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let base = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        let directory = (base as NSString).appendingPathComponent("concept-graph")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func stateFile(for file: String, extension ext: String) -> String {
        if ext != "lock" {
            let digest = SHA256.hash(data: Data(file.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return (stateDirectory as NSString).appendingPathComponent(digest + "." + ext)
        }
        // Preserve the original filename when checking for pre-socket viewers.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in file.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return (stateDirectory as NSString).appendingPathComponent(String(hash, radix: 16) + "." + ext)
    }

    static func lockPath(for file: String) -> String { stateFile(for: file, extension: "viewer-lock") }
    static func logPath(for file: String) -> String { stateFile(for: file, extension: "log") }

    static func socketPath(for file: String) -> String { stateFile(for: file, extension: "sock") }

    static func closeViewer(file: String) throws -> Bool {
        try checkLegacyWindow(file: file)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            if let viewer = try ViewerConnection.request(.close, file: file) {
                try viewer.waitUntilClosed()
                return true
            }
            // A window may own the file before its controls are ready.
            guard try isLocked(lockPath(for: file)) else { return false }
            usleep(40_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw LaunchError(description: "The document is busy and did not acknowledge close.")
    }

    static func openViewer(file: String, wait: Bool = false) throws -> (connection: ViewerConnection, existing: Bool) {
        let request: ViewerConnection.Request = wait ? .focusAndWait : .focus
        if let connection = try ViewerConnection.request(request, file: file) { return (connection, true) }
        try checkLegacyWindow(file: file)
        return (try spawnViewer(file: file, request: request), false)
    }

    // Older installations use a different protocol. Never interpret a legacy lock as a PID.
    static func checkLegacyWindow(file: String) throws {
        if try isLocked(stateFile(for: file, extension: "lock")) {
            throw LaunchError(description: "Close the older Concept Graph window for \(file) from its File menu first.")
        }
    }

    private static func isLocked(_ path: String) throws -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var record = Darwin.flock()
        record.l_type = Int16(F_WRLCK)
        record.l_whence = Int16(SEEK_SET)
        guard fcntl(fd, F_GETLK, &record) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return record.l_type != F_UNLCK
    }

    /// The binary that hosts the window: the copy inside ConceptGraph.app when it
    /// exists (so the Dock and menu bar show a proper app), otherwise this binary.
    private static func viewerExecutable() -> String {
        let own = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let directory = ((canonicalPath(own) ?? own) as NSString).deletingLastPathComponent
        let bundled = (directory as NSString).appendingPathComponent("ConceptGraph.app/Contents/MacOS/concept-graph")
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : own
    }

    struct LaunchError: Error, CustomStringConvertible {
        var description: String
    }

    /// Starts a viewer for `file` in its own session, detached from this process
    /// and from the caller's terminal, and waits until its window is up.
    private static func spawnViewer(file: String, request: ViewerConnection.Request) throws -> ViewerConnection {
        let executable = viewerExecutable()
        let log = logPath(for: file)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New session: the viewer outlives the shell that launched it. Close-on-exec by
        // default: it inherits none of our pipes, so the caller is never left waiting on it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var argv: [UnsafeMutablePointer<CChar>?] = [executable, "__viewer", file].map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw LaunchError(description: "could not start the viewer (\(String(cString: strerror(result)))): \(executable)")
        }

        // Only a viewer with a configured window can acknowledge a request.
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        let child = pid
        var reaped = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let winner = try ViewerConnection.request(request, file: file) {
                if !reaped {
                    // File → Open can leave the parent viewer running after the child closes.
                    let monitor = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
                    monitor.setEventHandler {
                        var status: Int32 = 0
                        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
                        monitor.cancel()
                    }
                    monitor.resume()
                }
                return winner
            }
            var status: Int32 = 0
            if !reaped && waitpid(child, &status, WNOHANG) == child {
                reaped = true
                if status == 0 { continue }
                let output = (try? String(contentsOfFile: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw LaunchError(description: "the viewer exited before showing a window"
                    + (output.isEmpty ? "" : ":\n\(output)") + "\n(log: \(log))")
            }
            usleep(40_000)
        }
        throw LaunchError(description: "the viewer started (pid \(pid)) but did not report a window within 10 seconds (log: \(log))")
    }
}

/// Held by a viewer for its whole life. See `Launcher`.
final class InstanceLock {
    private let fd: Int32

    init?(file: String) throws {
        let descriptor = open(Launcher.lockPath(for: file), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK { return nil }
            throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        fd = descriptor
    }

    deinit { close(fd) }
}
