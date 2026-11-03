import CryptoKit
import Foundation

/// A transaction ID in the usual display order: 64 lowercase hex characters.
public struct TxID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let hex: String

    public init(_ hex: String) throws {
        let digits = Set("0123456789abcdef".utf8)
        guard hex.utf8.count == 64, hex.utf8.allSatisfy(digits.contains) else { throw ElectrumError.implausibleValue }
        self.hex = hex
    }

    /// Bytes as they appear inside a transaction, which is the reverse of display order.
    init(internalBytes: Data) {
        hex = Data(internalBytes.reversed()).hexString
    }

    public var description: String { hex }
}

public struct OutPoint: Hashable, Sendable {
    public let txid: TxID
    public let index: UInt32
}

public struct TxOutput: Sendable, Equatable {
    public let sats: Int64
    public let script: Data
}

/// Only what's needed to work out how a transaction changed one address's balance. Scripts and
/// witnesses are skipped over, not checked: this app never validates or relays transactions.
public struct RawTransaction: Sendable {
    /// Hashed locally from the bytes, so a server can't hand over a different transaction under this ID.
    public let txid: TxID
    public let inputs: [OutPoint]
    public let outputs: [TxOutput]

    static let maxBytes = 4_000_000

    public init(hex: String) throws {
        guard let bytes = Data(hexEncoded: hex), bytes.count <= Self.maxBytes else { throw ElectrumError.implausibleValue }
        try self.init(bytes: bytes)
    }

    init(bytes: Data) throws {
        var reader = ByteReader(bytes)
        let version = try reader.take(4)
        var segwit = false
        if reader.peek(2) == Data([0x00, 0x01]) {
            segwit = true
            _ = try reader.take(2)
        }
        let bodyStart = reader.offset

        // Each input is at least 41 bytes and each output at least 9, which bounds the counts
        // before anything is allocated.
        let inputCount = try reader.count(minimumItemBytes: 41)
        guard inputCount > 0 else { throw ElectrumError.implausibleValue }
        var inputs: [OutPoint] = []
        inputs.reserveCapacity(inputCount)
        for _ in 0..<inputCount {
            let previous = try reader.take(32)
            let index = try reader.uint32()
            _ = try reader.take(try reader.count(minimumItemBytes: 1))
            _ = try reader.take(4)
            inputs.append(OutPoint(txid: TxID(internalBytes: previous), index: index))
        }

        let outputCount = try reader.count(minimumItemBytes: 9)
        var outputs: [TxOutput] = []
        outputs.reserveCapacity(outputCount)
        var total: Int64 = 0
        for _ in 0..<outputCount {
            let sats = try reader.int64()
            guard (0...maxSupplySats).contains(sats) else { throw ElectrumError.implausibleValue }
            total += sats
            guard total <= maxSupplySats else { throw ElectrumError.implausibleValue }
            let script = try reader.take(try reader.count(minimumItemBytes: 1))
            outputs.append(TxOutput(sats: sats, script: script))
        }
        let bodyEnd = reader.offset

        if segwit {
            for _ in 0..<inputCount {
                let items = try reader.count(minimumItemBytes: 1)
                for _ in 0..<items {
                    _ = try reader.take(try reader.count(minimumItemBytes: 1))
                }
            }
        }
        let lockTime = try reader.take(4)
        guard reader.isAtEnd else { throw ElectrumError.implausibleValue }

        // The ID covers the transaction without its witness data.
        var stripped = version
        stripped += bytes[(bytes.startIndex + bodyStart)..<(bytes.startIndex + bodyEnd)]
        stripped += lockTime
        let hash = Data(SHA256.hash(data: Data(SHA256.hash(data: stripped))))
        txid = TxID(internalBytes: hash)
        self.inputs = inputs
        self.outputs = outputs
    }
}

/// Reads a block header's timestamp. The header is 80 bytes and the time is bytes 68 to 71.
enum BlockHeader {
    static func time(hex: String) throws -> Date {
        guard let bytes = Data(hexEncoded: hex), bytes.count == 80 else { throw ElectrumError.implausibleValue }
        var reader = ByteReader(bytes.suffix(12))
        let seconds = try reader.uint32()
        // Not before the genesis block, and not absurdly far ahead.
        guard seconds >= 1_231_006_505, seconds < 4_000_000_000 else { throw ElectrumError.implausibleValue }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

struct ByteReader {
    private let bytes: Data
    private(set) var offset = 0

    init(_ bytes: Data) { self.bytes = Data(bytes) }

    var isAtEnd: Bool { offset == bytes.count }
    private var remaining: Int { bytes.count - offset }

    func peek(_ length: Int) -> Data? {
        guard length <= remaining else { return nil }
        return bytes.subdata(in: offset..<(offset + length))
    }

    mutating func take(_ length: Int) throws -> Data {
        guard length >= 0, length <= remaining else { throw ElectrumError.implausibleValue }
        defer { offset += length }
        return bytes.subdata(in: offset..<(offset + length))
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func int64() throws -> Int64 {
        Int64(bitPattern: try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) })
    }

    /// A Bitcoin compact size, refused if that many items couldn't fit in what's left.
    mutating func count(minimumItemBytes: Int) throws -> Int {
        let first = try take(1)[0]
        let value: UInt64
        switch first {
        case 0xFD: value = try take(2).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        case 0xFE: value = try take(4).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        case 0xFF: value = try take(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        default: value = UInt64(first)
        }
        guard value <= UInt64(remaining / max(1, minimumItemBytes)) else { throw ElectrumError.implausibleValue }
        return Int(value)
    }
}

extension Data {
    init?(hexEncoded text: String) {
        let utf8 = Array(text.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            case 0x41...0x46: c - 0x41 + 10
            default: nil
            }
        }
        var data = Data(capacity: utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        self = data
    }
}
