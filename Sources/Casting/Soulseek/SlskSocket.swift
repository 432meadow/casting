import Darwin
import Foundation

/// What the client needs from a TCP stream, whichever backend provides it.
/// Outbound connections use Network.framework (`TCPConnection`); the listener and its
/// accepted connections use BSD sockets, because `NWListener` fails outright on Macs
/// with certain network filters installed (observed: EINVAL on every bind).
protocol SlskStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// One chunk of whatever is available; `nil` on a clean close.
    func receive() async throws -> Data?
    func cancel()
}

// MARK: Listener

/// IPv4 TCP listener (the Soulseek network is IPv4-only).
final class SlskListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "casting.slsk.listener")

    /// Binds the preferred port, falling back to an ephemeral one.
    init?(preferredPort: UInt16) {
        func bind(to port: UInt16, fd: Int32) -> Bool {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard bind(to: preferredPort, fd: fd) || bind(to: 0, fd: fd), listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        guard port != 0 else {
            close(fd)
            return nil
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    }

    func start(onAccept: @escaping @Sendable (SocketConnection) -> Void) {
        let fd = fd
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                onAccept(SocketConnection(fd: client))
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

// MARK: Accepted connections

/// Async reads/writes over a connected BSD socket. Incoming bytes are buffered on a private
/// queue; `receive()` hands over whatever has arrived.
final class SocketConnection: SlskStream, @unchecked Sendable {
    private static let maxBufferedBytes = 8 << 20

    private let fd: Int32
    private let queue = DispatchQueue(label: "casting.slsk.peer")
    private let source: DispatchSourceRead
    private var buffered = Data()
    private var sawEOF = false
    private var failure: Error?
    private var pendingRead: CheckedContinuation<Data?, Error>?

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Writing to a peer that hung up must fail with an error, not SIGPIPE the app.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count > 0 {
                buffered.append(contentsOf: chunk[0 ..< count])
                if buffered.count > Self.maxBufferedBytes {
                    finish(with: SlskError(message: "peer flooded the connection"))
                    return
                }
            } else if count == 0 {
                sawEOF = true
                break
            } else if errno == EWOULDBLOCK || errno == EAGAIN {
                break
            } else if errno == EINTR {
                continue
            } else {
                finish(with: SlskError(message: "socket read failed (\(errno))"))
                return
            }
        }
        deliverIfPossible()
    }

    private func finish(with error: Error) {
        guard failure == nil else { return }
        failure = error
        source.cancel()
        deliverIfPossible()
    }

    private func deliverIfPossible() {
        guard let continuation = pendingRead else { return }
        if !buffered.isEmpty {
            pendingRead = nil
            let data = buffered
            buffered = Data()
            continuation.resume(returning: data)
        } else if let failure {
            pendingRead = nil
            continuation.resume(throwing: failure)
        } else if sawEOF {
            pendingRead = nil
            continuation.resume(returning: nil)
        }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.pendingRead == nil else {
                    continuation.resume(throwing: SlskError(message: "overlapping reads"))
                    return
                }
                self.pendingRead = continuation
                self.deliverIfPossible()
            }
        }
    }

    /// Writes are rare and small on accepted connections; a bounded retry loop is enough.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                var remaining = data
                var attempts = 0
                while !remaining.isEmpty {
                    let sent = remaining.withUnsafeBytes { Darwin.send(self.fd, $0.baseAddress, remaining.count, 0) }
                    if sent > 0 {
                        remaining = remaining.dropFirst(sent)
                    } else if errno == EWOULDBLOCK || errno == EAGAIN {
                        attempts += 1
                        guard attempts < 500 else {
                            return continuation.resume(throwing: SlskError(message: "socket send stalled"))
                        }
                        usleep(10_000)
                    } else if errno == EINTR {
                        continue
                    } else {
                        return continuation.resume(throwing: SlskError(message: "socket send failed (\(errno))"))
                    }
                }
                continuation.resume()
            }
        }
    }

    func cancel() {
        queue.async {
            self.finish(with: SlskError(message: "connection cancelled"))
        }
    }
}
