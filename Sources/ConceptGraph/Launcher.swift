import Darwin
import Foundation

/// Process plumbing: starting the window as its own process so the agent's
/// command returns immediately, and making sure one graph file gets one window.
///
/// Each viewer holds an exclusive `flock` on a small lock file for as long as it
/// runs. That lock is the single source of truth for "is this file open?" — it
/// vanishes with the process however the process ends, so it can never go stale.
enum Launcher {
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
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
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in file.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return (stateDirectory as NSString).appendingPathComponent(String(hash, radix: 16) + "." + ext)
    }

    static func lockPath(for file: String) -> String { stateFile(for: file, extension: "lock") }
    static func logPath(for file: String) -> String { stateFile(for: file, extension: "log") }

    /// The process currently showing `file`, if any.
    static func viewerPID(for file: String) -> pid_t? {
        let fd = open(lockPath(for: file), O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // The viewer writes its pid just after taking the lock, so allow it a moment.
        for _ in 0..<25 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                flock(fd, LOCK_UN)
                return nil
            }
            var buffer = [UInt8](repeating: 0, count: 32)
            let count = pread(fd, &buffer, buffer.count - 1, 0)
            if count > 0, let pid = pid_t(String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                return pid
            }
            usleep(20_000)
        }
        return nil
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
    static func spawnViewer(file: String) throws -> pid_t {
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
        posix_spawn_file_actions_addopen(&actions, 2, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

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

        // Ready means the viewer holds the lock. Dying first means something is wrong.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if viewerPID(for: file) != nil { return pid }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                let output = (try? String(contentsOfFile: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw LaunchError(description: "the viewer exited before showing a window"
                    + (output.isEmpty ? "" : ":\n\(output)") + "\n(log: \(log))")
            }
            usleep(40_000)
        }
        throw LaunchError(description: "the viewer started (pid \(pid)) but did not report a window within 10 seconds (log: \(log))")
    }

    /// Blocks until no viewer holds `file` any more, i.e. until the user closes the window.
    static func waitUntilClosed(file: String) {
        let fd = open(lockPath(for: file), O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        flock(fd, LOCK_UN)
    }
}

/// Held by a viewer for its whole life. See `Launcher`.
final class InstanceLock {
    private let fd: Int32

    init?(file: String) {
        let descriptor = open(Launcher.lockPath(for: file), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        // Another process may be holding the lock for an instant just to test it.
        var locked = false
        for _ in 0..<15 {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                locked = true
                break
            }
            usleep(20_000)
        }
        guard locked else {
            close(descriptor)
            return nil
        }
        ftruncate(descriptor, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        fd = descriptor
    }

    deinit {
        close(fd)
    }
}
