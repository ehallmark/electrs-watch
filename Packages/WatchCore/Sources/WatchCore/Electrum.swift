import Foundation

public enum ElectrumError: Error, Equatable {
    case lineTooLong
    case malformedReply
    case unexpectedReplyID
    case serverError
    case incompatibleServer
    case implausibleValue
    case tooManyNotifications
}

/// Every call the app can make. This closed set is what makes the client read-only:
/// there's no case for sending a transaction, and no way to send an arbitrary method name.
enum ElectrumRequest: Equatable {
    case version
    case headersSubscribe
    case subscribe(ScriptHash)
    case balance(ScriptHash)
    case history(ScriptHash)

    var method: String {
        switch self {
        case .version: "server.version"
        case .headersSubscribe: "blockchain.headers.subscribe"
        case .subscribe: "blockchain.scripthash.subscribe"
        case .balance: "blockchain.scripthash.get_balance"
        case .history: "blockchain.scripthash.get_history"
        }
    }

    var params: [String] {
        switch self {
        case .version: ["electrs-watch", ElectrumClient.protocolVersion]
        case .headersSubscribe: []
        case .subscribe(let hash), .balance(let hash), .history(let hash): [hash.hex]
        }
    }
}

public struct ChainTip: Codable, Sendable, Equatable {
    public let height: Int
}

public struct Balance: Codable, Sendable, Equatable {
    public let confirmedSats: Int64
    public let unconfirmedSats: Int64
}

public struct HistorySummary: Codable, Sendable, Equatable {
    public let transactionCount: Int
    public let pendingCount: Int
    public let latestConfirmedHeight: Int?
}

public let maxSupplySats: Int64 = 21_000_000 * 100_000_000

public actor ElectrumClient {
    static let protocolVersion = "1.4"
    static let maxLineBytes = 4 * 1024 * 1024
    static let maxSkippedNotifications = 1_000

    private let stream: any ByteStream
    private let requestTimeout: TimeInterval
    private var buffer = Data()
    private var nextID = 1

    /// `requestTimeout` covers a whole call, so a server can't stall forever by sending slowly.
    public init(stream: any ByteStream, requestTimeout: TimeInterval = 60) {
        self.stream = stream
        self.requestTimeout = requestTimeout
    }

    /// Opens an Electrum session over Tor at `socksPath`. The stream is closed on failure.
    public static func connect(socksPath: String, onion: OnionAddress, port: UInt16 = 50001) async throws -> ElectrumClient {
        let stream = try UnixSocketStream(path: socksPath)
        do {
            try await Socks5.connect(over: stream, to: onion, port: port)
            let client = ElectrumClient(stream: stream)
            try await client.negotiateVersion()
            return client
        } catch {
            stream.close()
            throw error
        }
    }

    public nonisolated func close() { stream.close() }

    public func negotiateVersion() async throws {
        let reply: [String] = try await call(.version)
        guard reply.count == 2, reply[1] == Self.protocolVersion else { throw ElectrumError.incompatibleServer }
    }

    public func tip() async throws -> ChainTip {
        struct Header: Decodable { let height: Int }
        let header: Header = try await call(.headersSubscribe)
        guard (0...100_000_000).contains(header.height) else { throw ElectrumError.implausibleValue }
        return ChainTip(height: header.height)
    }

    /// Lets electrs compute an address's status once for this connection, instead of again for
    /// each query. Its later change notifications are skipped, since the app refreshes on request.
    /// The reply is null for an address with no history.
    public func subscribe(to hash: ScriptHash) async throws {
        let status: String? = try await call(.subscribe(hash))
        if let status, !Self.isLowercaseHash(status) { throw ElectrumError.implausibleValue }
    }

    private static func isLowercaseHash(_ text: String) -> Bool {
        let hex = Set("0123456789abcdef".utf8)
        return text.utf8.count == 64 && text.utf8.allSatisfy(hex.contains)
    }

    public func balance(of hash: ScriptHash) async throws -> Balance {
        struct Reply: Decodable { let confirmed: Int64; let unconfirmed: Int64 }
        let reply: Reply = try await call(.balance(hash))
        // Pending can be negative, when a confirmed coin is being spent.
        guard (0...maxSupplySats).contains(reply.confirmed),
              (-maxSupplySats...maxSupplySats).contains(reply.unconfirmed) else {
            throw ElectrumError.implausibleValue
        }
        return Balance(confirmedSats: reply.confirmed, unconfirmedSats: reply.unconfirmed)
    }

    public func history(of hash: ScriptHash) async throws -> HistorySummary {
        struct Entry: Decodable { let height: Int; let tx_hash: String }
        let entries: [Entry] = try await call(.history(hash))
        var latest: Int?
        var pending = 0
        for entry in entries {
            guard Self.isLowercaseHash(entry.tx_hash), entry.height >= -1 else {
                throw ElectrumError.implausibleValue
            }
            if entry.height > 0 {
                latest = max(latest ?? 0, entry.height)
            } else {
                pending += 1
            }
        }
        return HistorySummary(transactionCount: entries.count, pendingCount: pending, latestConfirmedHeight: latest)
    }

    // One request at a time: the app awaits each call, and a reply with any other ID is an error.
    private func call<Result: Decodable>(_ request: ElectrumRequest) async throws -> Result {
        let id = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: [
            "id": id, "jsonrpc": "2.0", "method": request.method, "params": request.params,
        ] as [String: Any], options: [.sortedKeys])
        line.append(0x0A)
        let deadline = Date().addingTimeInterval(requestTimeout)
        try await stream.write(line, timeout: requestTimeout)

        var skipped = 0
        while true {
            let reply = try await readLine(deadline: deadline)
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: reply) else {
                throw ElectrumError.malformedReply
            }
            if envelope.id == nil, envelope.method != nil {
                skipped += 1
                guard skipped <= Self.maxSkippedNotifications else { throw ElectrumError.tooManyNotifications }
                continue
            }
            guard envelope.id == id else { throw ElectrumError.unexpectedReplyID }
            // Server error text is never shown or kept.
            if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: reply), failure.error != nil {
                throw ElectrumError.serverError
            }
            guard let decoded = try? JSONDecoder().decode(ResultEnvelope<Result>.self, from: reply) else {
                throw ElectrumError.malformedReply
            }
            return decoded.result
        }
    }

    private func readLine(deadline: Date) async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                guard line.count <= Self.maxLineBytes else { throw ElectrumError.lineTooLong }
                let result = Data(line)
                buffer = Data(buffer[(newline + 1)...])
                return result
            }
            guard buffer.count <= Self.maxLineBytes else { throw ElectrumError.lineTooLong }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw StreamError.timedOut }
            buffer += try await stream.read(maxBytes: 64 * 1024, timeout: remaining)
        }
    }
}

private struct Envelope: Decodable {
    let id: Int?
    let method: String?
}

private struct ResultEnvelope<Value: Decodable>: Decodable { let result: Value }

private struct ErrorEnvelope: Decodable { let error: JSONPresence? }

/// Records that a non-null value was present, without reading it. A JSON null decodes as nil.
private struct JSONPresence: Decodable {
    init(from decoder: any Decoder) throws {}
}
