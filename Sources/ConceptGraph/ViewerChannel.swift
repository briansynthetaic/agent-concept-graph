import Darwin
import Foundation

/// A connection belongs to one document window, including while a caller waits for it to close.
/// The PID in the reply is for display only. All actions travel over this connection.
final class ViewerConnection {
    enum Request: UInt8 { case focus = 1, focusAndWait, close }
    private let fd: Int32
    private(set) var pid: pid_t = 0

    init(fd: Int32) {
        self.fd = fd
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    deinit { Darwin.close(fd) }

    static func request(_ request: Request, file: String) throws -> ViewerConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let connection = ViewerConnection(fd: fd)
        let result = try withSocketAddress(file) { connect(fd, $0, $1) }
        guard result == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var byte = request.rawValue
        guard write(fd, &byte, 1) == 1,
              recv(fd, &connection.pid, MemoryLayout<pid_t>.size, MSG_WAITALL) == MemoryLayout<pid_t>.size,
              connection.pid > 1 else {
            throw Launcher.LaunchError(description: "The document window did not acknowledge the request.")
        }
        return connection
    }

    func waitUntilClosed() throws {
        var timeout = timeval()
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var byte: UInt8 = 0
        while true {
            let count = read(fd, &byte, 1)
            if count == 0 { return }
            if count < 0 && errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }
}

private func withSocketAddress(_ file: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
    var address = sockaddr_un()
    let bytes = Launcher.socketPath(for: file).utf8CString
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { throw POSIXError(.ENAMETOOLONG) }
    withUnsafeMutableBytes(of: &address.sun_path) { target in
        bytes.withUnsafeBytes { target.copyMemory(from: $0) }
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let length = socklen_t(address.sun_len)
    return withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
    }
}

/// Only the exclusive document owner may bind or remove this socket. An orphaned
/// socket from an interrupted viewer can therefore be replaced safely.
final class ViewerChannel {
    private let queue = DispatchQueue(label: "ConceptGraph.document-control")
    private var listener: DispatchSourceRead?
    private var waiters: [Int32: DispatchSourceRead] = [:]

    func start(file: String, focus: @escaping () -> Void, closeWindow: @escaping () -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let path = Launcher.socketPath(for: file)
        unlink(path)
        do {
            guard try withSocketAddress(file, { bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            let connection = ViewerConnection(fd: client)
            defer { withExtendedLifetime(connection) {} }
            guard fcntl(client, F_SETFL, 0) == 0 else { return }
            var byte: UInt8 = 0
            guard read(client, &byte, 1) == 1, let request = ViewerConnection.Request(rawValue: byte) else { return }
            var pid = getpid()
            guard write(client, &pid, MemoryLayout.size(ofValue: pid)) == MemoryLayout.size(ofValue: pid) else { return }
            if request == .focusAndWait || request == .close {
                // Retain the connection until the window exits or the caller disconnects.
                let waiter = DispatchSource.makeReadSource(fileDescriptor: client, queue: self.queue)
                waiter.setEventHandler { [weak self] in self?.waiters.removeValue(forKey: client)?.cancel() }
                waiter.setCancelHandler { withExtendedLifetime(connection) {} }
                self.waiters[client] = waiter
                waiter.resume()
            }
            switch request {
            case .focus, .focusAndWait: DispatchQueue.main.async(execute: focus)
            case .close: DispatchQueue.main.async(execute: closeWindow)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    deinit { listener?.cancel() }
}
