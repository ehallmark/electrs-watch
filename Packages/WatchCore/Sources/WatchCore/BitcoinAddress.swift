import CryptoKit
import Foundation

public enum AddressError: Error, Equatable {
    case invalid
    case notMainnet
    case unsupportedWitnessVersion
}

public enum AddressKind: String, Sendable, Codable {
    case p2pkh = "P2PKH"
    case p2sh = "P2SH"
    case p2wpkh = "P2WPKH"
    case p2wsh = "P2WSH"
    case p2tr = "P2TR"
}

/// A validated mainnet Bitcoin address. Only this type can produce a `ScriptHash`.
public struct BitcoinAddress: Sendable, Equatable {
    public let text: String
    public let kind: AddressKind
    public let scriptPubKey: Data

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100, trimmed.allSatisfy(\.isASCII) else {
            throw AddressError.invalid
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bc1") {
            (kind, scriptPubKey) = try Self.decodeSegwit(trimmed)
            text = lower
        } else if lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1") {
            throw AddressError.notMainnet
        } else {
            (kind, scriptPubKey) = try Self.decodeBase58(trimmed)
            text = trimmed
        }
    }

    public var scriptHash: ScriptHash { ScriptHash(scriptPubKey: scriptPubKey) }

    private static func decodeSegwit(_ text: String) throws -> (AddressKind, Data) {
        guard let decoded = Bech32.decode(text), decoded.hrp == "bc", let version = decoded.data.first, version <= 16 else {
            throw AddressError.invalid
        }
        // BIP-350: version 0 uses bech32, every later version uses bech32m.
        guard decoded.encoding == (version == 0 ? .bech32 : .bech32m) else { throw AddressError.invalid }
        guard let program = Bech32.convert5to8(decoded.data.dropFirst()), (2...40).contains(program.count) else {
            throw AddressError.invalid
        }
        switch (version, program.count) {
        case (0, 20): return (.p2wpkh, Data([0x00, 0x14]) + program)
        case (0, 32): return (.p2wsh, Data([0x00, 0x20]) + program)
        case (0, _): throw AddressError.invalid
        case (1, 32): return (.p2tr, Data([0x51, 0x20]) + program)
        default: throw AddressError.unsupportedWitnessVersion
        }
    }

    private static func decodeBase58(_ text: String) throws -> (AddressKind, Data) {
        guard let payload = Base58.decodeCheck(text), payload.count == 21 else { throw AddressError.invalid }
        let hash = payload.dropFirst()
        switch payload.first {
        case 0x00: return (.p2pkh, Data([0x76, 0xA9, 0x14]) + hash + Data([0x88, 0xAC]))
        case 0x05: return (.p2sh, Data([0xA9, 0x14]) + hash + Data([0x87]))
        case 0x6F, 0xC4: throw AddressError.notMainnet
        default: throw AddressError.invalid
        }
    }
}

/// The Electrum index key: SHA-256 of the scriptPubKey, bytes reversed, as hex.
public struct ScriptHash: Sendable, Equatable, Hashable {
    public let hex: String

    init(scriptPubKey: Data) {
        hex = Data(SHA256.hash(data: scriptPubKey).reversed()).hexString
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

enum Bech32 {
    enum Encoding: Equatable { case bech32, bech32m }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    private static let reverse: [UInt8: UInt8] = Dictionary(
        uniqueKeysWithValues: charset.enumerated().map { ($1, UInt8($0)) }
    )

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var check: UInt32 = 1
        for value in values {
            let top = check >> 25
            check = (check & 0x1FF_FFFF) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { check ^= generator[i] }
        }
        return check
    }

    static func decode(_ text: String) -> (hrp: String, data: [UInt8], encoding: Encoding)? {
        guard text.count <= 90, text == text.lowercased() || text == text.uppercased() else { return nil }
        let bytes = Array(text.lowercased().utf8)
        guard let separator = bytes.lastIndex(of: UInt8(ascii: "1")), separator >= 1, bytes.count - separator - 1 >= 6 else {
            return nil
        }
        let hrp = Array(bytes[..<separator])
        guard hrp.allSatisfy({ (33...126).contains($0) }) else { return nil }
        var values: [UInt8] = []
        for byte in bytes[(separator + 1)...] {
            guard let value = reverse[byte] else { return nil }
            values.append(value)
        }
        let expanded = hrp.map { $0 >> 5 } + [0] + hrp.map { $0 & 31 } + values
        let encoding: Encoding
        switch polymod(expanded) {
        case 1: encoding = .bech32
        case 0x2BC8_30A3: encoding = .bech32m
        default: return nil
        }
        return (String(decoding: hrp, as: UTF8.self), Array(values.dropLast(6)), encoding)
    }

    static func convert5to8(_ values: ArraySlice<UInt8>) -> Data? {
        var result = Data()
        var accumulator: UInt32 = 0
        var bits = 0
        for value in values {
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
            accumulator &= (1 << UInt32(bits)) - 1
        }
        // BIP-173: at most 4 padding bits, all zero.
        guard bits < 5, accumulator == 0 else { return nil }
        return result
    }
}

enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    private static let reverse: [UInt8: UInt32] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt32($0)) }
    )

    static func decodeCheck(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        for character in text.utf8 {
            guard var carry = reverse[character] else { return nil }
            for index in bytes.indices.reversed() {
                carry += UInt32(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        let zeros = text.utf8.prefix { $0 == UInt8(ascii: "1") }.count
        let full = Data(repeating: 0, count: zeros) + bytes
        guard full.count > 4 else { return nil }
        let payload = full.dropLast(4)
        let first = Data(SHA256.hash(data: payload))
        let check = Data(SHA256.hash(data: first)).prefix(4)
        guard check == full.suffix(4) else { return nil }
        return Data(payload)
    }
}
