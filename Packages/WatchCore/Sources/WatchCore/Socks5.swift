import Foundation

/// Why Tor could not connect, from SOCKS5 replies with `ExtendedErrors`.
public enum TorConnectError: Error, Equatable {
    case serviceNotFound          // 0xF0: no descriptor: the service is offline or still publishing
    case serviceUnreachable       // 0xF1, 0xF2, 0xF3, 0xF7
    case notAuthorized            // 0xF4, 0xF5: no key, or a key the service does not accept
    case badAddress               // 0xF6
    case refused(UInt8)           // anything else
    case malformedReply
}

enum Socks5 {
    /// Long enough for Tor to reach an onion service on a slow network. Past this, Tor is more
    /// likely stuck than slow, and the app retries after resetting it.
    static let connectTimeout: TimeInterval = 60

    /// Connects through Tor. Always sends the hostname, so nothing is resolved outside Tor,
    /// and only accepts an `OnionAddress`, so this can't be pointed at the open internet.
    static func connect(over stream: any ByteStream, to onion: OnionAddress, port: UInt16) async throws {
        try await stream.write(Data([0x05, 0x01, 0x00]), timeout: 10)
        let method = try await readExactly(stream, count: 2, timeout: 10)
        guard method == Data([0x05, 0x00]) else { throw TorConnectError.malformedReply }

        let host = Array(onion.hostname.utf8)
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(host.count)])
        request += host
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        try await stream.write(request, timeout: 10)

        let head = try await readExactly(stream, count: 4, timeout: connectTimeout)
        guard head[0] == 0x05, head[2] == 0x00 else { throw TorConnectError.malformedReply }
        let boundLength: Int
        switch head[3] {
        case 0x01: boundLength = 4 + 2
        case 0x04: boundLength = 16 + 2
        case 0x03:
            let length = try await readExactly(stream, count: 1, timeout: 10)
            boundLength = Int(length[0]) + 2
        default: throw TorConnectError.malformedReply
        }
        _ = try await readExactly(stream, count: boundLength, timeout: 10)

        switch head[1] {
        case 0x00: return
        case 0xF0: throw TorConnectError.serviceNotFound
        case 0xF1, 0xF2, 0xF3, 0xF7: throw TorConnectError.serviceUnreachable
        case 0xF4, 0xF5: throw TorConnectError.notAuthorized
        case 0xF6: throw TorConnectError.badAddress
        default: throw TorConnectError.refused(head[1])
        }
    }
}
