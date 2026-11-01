import Foundation

public enum StreamError: Error, Equatable {
    case socketFailed
    case pathTooLong
    case timedOut
    case closed
}

public protocol ByteStream: Sendable {
    /// Returns between 1 and `maxBytes` bytes. Throws `.closed` at end of stream.
    func read(maxBytes: Int, timeout: TimeInterval) async throws -> Data
    func write(_ data: Data, timeout: TimeInterval) async throws
    func close()
}

/// A connection to a Unix domain socket. There's deliberately no IP equivalent in this app.
public final class UnixSocketStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "electrs-watch.socket.read")
    private let writeQueue = DispatchQueue(label: "electrs-watch.socket.write")

    public init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw StreamError.pathTooLong }

        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw StreamError.socketFailed }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
        }
        guard result == 0 else {
            Darwin.close(socket)
            throw StreamError.socketFailed
        }
        fd = socket
    }

    deinit { Darwin.close(fd) }

    /// Wakes any blocked read or write. The descriptor itself closes in `deinit`, so an
    /// in-flight call can never touch a reused descriptor number.
    public func close() { shutdown(fd, SHUT_RDWR) }

    public func read(maxBytes: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [self] in
                continuation.resume(with: Result { try blockingRead(maxBytes: maxBytes, timeout: timeout) })
            }
        }
    }

    public func write(_ data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                continuation.resume(with: Result { try blockingWrite(data, timeout: timeout) })
            }
        }
    }

    private func wait(for events: Int32, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StreamError.timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw StreamError.socketFailed }
        }
    }

    private func blockingRead(maxBytes: Int, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        while true {
            try wait(for: POLLIN, deadline: deadline)
            let count = recv(fd, &buffer, maxBytes, MSG_DONTWAIT)
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { throw StreamError.closed }
            if errno == EAGAIN || errno == EINTR { continue }
            throw StreamError.closed
        }
    }

    private func blockingWrite(_ data: Data, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            try wait(for: POLLOUT, deadline: deadline)
            let count = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if count > 0 {
                offset += count
            } else if !(errno == EAGAIN || errno == EINTR) {
                throw StreamError.closed
            }
        }
    }
}

/// Reads exactly `count` bytes.
func readExactly(_ stream: any ByteStream, count: Int, timeout: TimeInterval) async throws -> Data {
    var result = Data()
    while result.count < count {
        result += try await stream.read(maxBytes: count - result.count, timeout: timeout)
    }
    return result
}
