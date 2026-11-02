import Foundation

public enum TorControlError: Error, Equatable {
    case invalidArgument
    case malformedReply
    case rejected(Int)
}

/// A minimal client for Tor's control protocol. Replies arrive in the order commands were sent, so
/// the caller must send one at a time. Any stream error means the connection should be thrown away.
public actor TorControlClient {
    static let maxLineBytes = 64 * 1024
    static let maxLines = 256

    private let stream: any ByteStream
    private let timeout: TimeInterval
    private var buffer = Data()

    public init(stream: any ByteStream, timeout: TimeInterval = 15) {
        self.stream = stream
        self.timeout = timeout
    }

    public nonisolated func close() { stream.close() }

    public func authenticate(cookie: Data) async throws {
        try await send("AUTHENTICATE", [cookie.hexString], accepting: [250])
    }

    public func setNetworkEnabled(_ enabled: Bool) async throws {
        try await send("SETCONF", ["DisableNetwork=\(enabled ? 0 : 1)"], accepting: [250])
    }

    public func bootstrapPercent() async throws -> Int {
        let lines = try await send("GETINFO", ["status/bootstrap-phase"], accepting: [250])
        for line in lines {
            if let range = line.range(of: "PROGRESS="), let percent = Int(line[range.upperBound...].prefix(while: \.isNumber)) {
                return percent
            }
        }
        throw TorControlError.malformedReply
    }

    /// Bootstrap progress stays at 100 once reached, so this is what shows if the network info has since gone out of date.
    public func hasEnoughDirectoryInfo() async throws -> Bool {
        let lines = try await send("GETINFO", ["status/enough-dir-info"], accepting: [250])
        for line in lines where line.hasPrefix("status/enough-dir-info=") {
            return line.hasSuffix("=1")
        }
        throw TorControlError.malformedReply
    }

    /// Stores the key in Tor's memory only, since there's no "Permanent" flag.
    /// Success: 250 new, 251 replaced an existing key, 252 also decrypted a cached descriptor.
    public func addClientAuth(onion: OnionAddress, key: ClientAuthKey) async throws {
        do {
            try await send("ONION_CLIENT_AUTH_ADD", [onion.serviceID, key.controlPortBlob], accepting: [250, 251, 252])
        } catch TorControlError.rejected(512) {
            // Tor checks the address checksum here.
            throw TorConnectError.badAddress
        }
    }

    /// Success: 250 removed, 251 there was nothing to remove.
    public func removeClientAuth(onion: OnionAddress) async throws {
        try await send("ONION_CLIENT_AUTH_REMOVE", [onion.serviceID], accepting: [250, 251])
    }

    /// Makes Tor drop cached onion service descriptors.
    public func forgetCachedServices() async throws {
        try await send("SIGNAL", ["NEWNYM"], accepting: [250])
    }

    @discardableResult
    func send(_ command: String, _ arguments: [String], accepting: Set<Int>) async throws -> [String] {
        let parts = [command] + arguments
        guard parts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isNewline) && !$0.contains(" ") }) else {
            throw TorControlError.invalidArgument
        }
        let deadline = Date().addingTimeInterval(timeout)
        try await stream.write(Data((parts.joined(separator: " ") + "\r\n").utf8), timeout: timeout)
        var lines: [String] = []
        while true {
            let line = try await readLine(deadline: deadline)
            guard line.utf8.count >= 4, let code = Int(line.prefix(3)), lines.count < Self.maxLines else {
                throw TorControlError.malformedReply
            }
            let body = String(line.dropFirst(4))
            // Asynchronous events aren't replies. This client never subscribes, so this is only a safeguard.
            if (600..<700).contains(code) { continue }
            lines.append(body)
            switch line[line.index(line.startIndex, offsetBy: 3)] {
            case "-":
                continue
            case "+":
                while try await readLine(deadline: deadline) != "." {}
            case " ":
                guard accepting.contains(code) else { throw TorControlError.rejected(code) }
                return lines
            default:
                throw TorControlError.malformedReply
            }
        }
    }

    private func readLine(deadline: Date) async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            guard buffer.count <= Self.maxLineBytes else { throw TorControlError.malformedReply }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StreamError.timedOut }
            buffer += try await stream.read(maxBytes: 16 * 1024, timeout: remaining)
        }
    }
}
