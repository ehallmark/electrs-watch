import CryptoKit
import Foundation

public enum OnionAddressError: Error, Equatable { case invalid }

/// A v3 onion address. The checksum is left to Tor, which reports a bad one as `.badAddress`.
public struct OnionAddress: Sendable, Equatable, Codable {
    /// 56 lowercase base32 characters, without ".onion".
    public let serviceID: String

    public init(_ input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".onion") { text.removeLast(6) }
        guard text.utf8.count == 56, let decoded = Base32.decode(text), decoded.count == 35, decoded.last == 3 else {
            throw OnionAddressError.invalid
        }
        serviceID = text
    }

    public var hostname: String { serviceID + ".onion" }
}

/// The Tor client authorization key. Generated on the phone, and only the public half is ever shown.
public struct ClientAuthKey: Sendable, Equatable, Codable {
    public let privateKey: Data

    public static func generate() -> ClientAuthKey {
        ClientAuthKey(uncheckedPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
    }

    public init(privateKey: Data) throws {
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.privateKey = privateKey
    }

    private init(uncheckedPrivateKey: Data) { privateKey = uncheckedPrivateKey }

    /// The line to put in the node's `authorized_clients/<name>.auth` file.
    public var authorizedClientLine: String {
        // The key was validated on creation, so this can't fail for a stored value.
        let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let publicKey = key?.publicKey.rawRepresentation ?? Data()
        return "descriptor:x25519:" + Base32.encode(publicKey)
    }

    /// The key blob for Tor's ONION_CLIENT_AUTH_ADD control command.
    public var controlPortBlob: String { "x25519:" + privateKey.base64EncodedString() }
}

enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    static func decode(_ text: String) -> Data? {
        var result = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.utf8 {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        return result
    }

    /// Unpadded and uppercase, as Tor's `.auth` files use.
    static func encode(_ data: Data) -> String {
        var result: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: result, as: UTF8.self).uppercased()
    }
}
