import Foundation
import Testing
@testable import WatchCore

private func hex(_ data: Data) -> String { data.hexString }

@Suite struct AddressTests {
    // Scripts from BIP-173 and BIP-350, script hashes computed separately in Python.
    // The P2PKH hash is also the worked example in the Electrum protocol docs.
    @Test(arguments: [
        ("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", AddressKind.p2pkh,
         "76a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac",
         "8b01df4e368ea28f8dc0423bcf7a4923e3a12d307c875e47a0cfbf90b5c39161"),
        ("3P14159f73E4gFr7JterCCQh9QjiTjiZrG", .p2sh,
         "a914e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a87",
         "a893f75a9f1c7c7449e6a00041fd357fa578e8976144c761f704a98f7babf9da"),
        ("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", .p2wpkh,
         "0014751e76e8199196d454941c45d1b3a323f1433bd6",
         "9623df75239b5daa7f5f03042d325b51498c4bb7059c7748b17049bf96f73888"),
        ("bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3", .p2wsh,
         "00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262",
         "94ef09765c3092cd7a1d9f7a6e1ff861e446fd795d1e8a93f427c42df7ffe123"),
        ("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", .p2tr,
         "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
         "a12cf1aa7c74a6e9f54984646526173abed2a9f4a4862dc83eb94e8e8ef5220a"),
    ])
    func validAddresses(text: String, kind: AddressKind, script: String, hash: String) throws {
        let address = try BitcoinAddress(text)
        #expect(address.kind == kind)
        #expect(hex(address.scriptPubKey) == script)
        #expect(address.scriptHash.hex == hash)
    }

    @Test(arguments: [
        "",
        "not an address",
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",                     // bad bech32 checksum
        "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd", // v1 with bech32, not bech32m
        "Bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",                     // mixed case
        "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb",                             // bad base58 checksum
        "1A1zP1eP5QGefi2DMPTfTL5SLmv7Divf0a",                             // 0 isn't in base58
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7k\u{0}v8f3t4",
        "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8",
    ])
    func invalidAddresses(text: String) {
        #expect(throws: (any Error).self) { try BitcoinAddress(text) }
    }

    @Test(arguments: [
        "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
        "mipcBbFg9gMiCh81Kj8tqqdgoZub1ZJRfn",
    ])
    func testnetIsRejected(text: String) {
        #expect(throws: AddressError.notMainnet) { try BitcoinAddress(text) }
    }

    @Test func whitespaceFromPastingIsIgnored() throws {
        #expect(try BitcoinAddress("  1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa\n").text == "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    }
}

@Suite struct TorIdentifierTests {
    // duckduckgo's public v3 address.
    static let real = "duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad"

    @Test func parsesOnion() throws {
        #expect(try OnionAddress(Self.real + ".onion").serviceID == Self.real)
        #expect(try OnionAddress(" " + Self.real.uppercased() + ".ONION\n").hostname == Self.real + ".onion")
    }

    @Test(arguments: ["", "example.com", "1.1.1.1", "abc.onion", "duckduckgo.onion",
                      String(repeating: "a", count: 56), String(repeating: "1", count: 56)])
    func rejectsNonOnion(text: String) {
        #expect(throws: OnionAddressError.invalid) { try OnionAddress(text) }
    }

    /// RFC 7748 section 6.1 test vector.
    @Test func publicKeyLineMatchesKnownX25519Vector() throws {
        let scalar = Data(hexString: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let key = try ClientAuthKey(privateKey: scalar)
        let expected = Base32.encode(Data(hexString: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
        #expect(key.authorizedClientLine == "descriptor:x25519:" + expected)
        #expect(expected.count == 52)
        #expect(key.controlPortBlob == "x25519:" + scalar.base64EncodedString())
    }

    @Test func generatedKeysDiffer() {
        #expect(ClientAuthKey.generate() != ClientAuthKey.generate())
    }

    @Test func publicLineDoesNotContainPrivateKey() {
        let key = ClientAuthKey.generate()
        #expect(!key.authorizedClientLine.contains(Base32.encode(key.privateKey)))
    }
}

extension Data {
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).map { offset in
            let start = hexString.index(hexString.startIndex, offsetBy: offset)
            return UInt8(hexString[start..<hexString.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

@Suite struct AmountTests {
    @Test(arguments: [
        (Int64(0), "0.00000000"), (1, "0.00000001"), (123_456_789, "1.23456789"),
        (-50_000, "-0.00050000"), (2_100_000_000_000_000, "21000000.00000000"),
    ])
    func format(sats: Int64, text: String) {
        #expect(BitcoinAmount.format(sats: sats) == text)
    }

    @Test func signed() {
        #expect(BitcoinAmount.format(sats: 5, signed: true) == "+0.00000005")
        #expect(BitcoinAmount.format(sats: 0, signed: true) == "0.00000000")
    }
}

/// A scripted peer: hands out queued replies and records what was written.
final class FakeStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var written = Data()

    init(_ chunks: [Data]) { self.chunks = chunks }
    convenience init(lines: [String]) { self.init(lines.map { Data(($0 + "\n").utf8) }) }

    var sent: String { lock.withLock { String(decoding: written, as: UTF8.self) } }

    func read(maxBytes: Int, timeout: TimeInterval) async throws -> Data {
        try lock.withLock {
            guard !chunks.isEmpty else { throw StreamError.closed }
            var head = chunks.removeFirst()
            if head.count > maxBytes {
                chunks.insert(head.dropFirst(maxBytes), at: 0)
                head = head.prefix(maxBytes)
            }
            return Data(head)
        }
    }

    func write(_ data: Data, timeout: TimeInterval) async throws { lock.withLock { written += data } }
    func close() {}
}

@Suite struct ElectrumTests {
    let hash = try! BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa").scriptHash

    @Test func requestFormatIsWhatElectrsExpects() async throws {
        let stream = FakeStream(lines: [#"{"id":1,"jsonrpc":"2.0","result":["electrs/0.12.0","1.4"]}"#])
        try await ElectrumClient(stream: stream).negotiateVersion()
        #expect(stream.sent == #"{"id":1,"jsonrpc":"2.0","method":"server.version","params":["electrs-watch","1.4"]}"# + "\n")
    }

    @Test func parsesBalance() async throws {
        let stream = FakeStream(lines: [#"{"id":1,"result":{"confirmed":100,"unconfirmed":-5}}"#])
        let balance = try await ElectrumClient(stream: stream).balance(of: hash)
        #expect(balance == Balance(confirmedSats: 100, unconfirmedSats: -5))
        #expect(stream.sent.contains("blockchain.scripthash.get_balance"))
        #expect(stream.sent.contains(hash.hex))
    }

    @Test func parsesHistory() async throws {
        let tx = String(repeating: "a", count: 64)
        let stream = FakeStream(lines: [#"{"id":1,"result":[{"height":800,"tx_hash":"\#(tx)"},{"height":900,"tx_hash":"\#(tx)"},{"height":0,"tx_hash":"\#(tx)","fee":1},{"height":-1,"tx_hash":"\#(tx)","fee":1}]}"#])
        let history = try await ElectrumClient(stream: stream).history(of: hash)
        #expect(history == HistorySummary(transactionCount: 4, pendingCount: 2, latestConfirmedHeight: 900))
    }

    @Test func skipsNotificationsAndHandlesSplitReads() async throws {
        let notification = #"{"jsonrpc":"2.0","method":"blockchain.headers.subscribe","params":[{"height":5,"hex":"00"}]}"# + "\n"
        let reply = #"{"id":1,"result":{"height":900000,"hex":"00"}}"# + "\n"
        let all = Data((notification + reply).utf8)
        let stream = FakeStream([all.prefix(7), all.dropFirst(7).prefix(100), all.dropFirst(107)].map { Data($0) })
        #expect(try await ElectrumClient(stream: stream).tip() == ChainTip(height: 900000))
    }

    @Test func snapshotTotals() async throws {
        let stream = FakeStream(lines: [
            #"{"id":1,"result":{"height":7,"hex":"00"}}"#,
            #"{"id":2,"result":{"confirmed":3,"unconfirmed":1}}"#, #"{"id":3,"result":[]}"#,
            #"{"id":4,"result":{"confirmed":4,"unconfirmed":0}}"#, #"{"id":5,"result":[]}"#,
        ])
        let watched = try ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "3P14159f73E4gFr7JterCCQh9QjiTjiZrG"].map {
            WatchedAddress(address: try BitcoinAddress($0), label: "x")
        }
        let snapshot = try await ElectrumClient(stream: stream).snapshot(of: watched)
        #expect(snapshot.totalConfirmedSats == 7)
        #expect(snapshot.totalUnconfirmedSats == 1)
    }

    // Hostile replies

    @Test func tooManyCoinsInOneReply() async {
        let stream = FakeStream(lines: [#"{"id":1,"result":{"confirmed":2100000000000001,"unconfirmed":0}}"#])
        await #expect(throws: ElectrumError.implausibleValue) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test func negativeConfirmed() async {
        let stream = FakeStream(lines: [#"{"id":1,"result":{"confirmed":-1,"unconfirmed":0}}"#])
        await #expect(throws: ElectrumError.implausibleValue) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test func totalAboveSupplyAcrossAddresses() async throws {
        let big = 2_000_000_000_000_000
        let stream = FakeStream(lines: [
            #"{"id":1,"result":{"height":7,"hex":"00"}}"#,
            #"{"id":2,"result":{"confirmed":\#(big),"unconfirmed":0}}"#, #"{"id":3,"result":[]}"#,
            #"{"id":4,"result":{"confirmed":\#(big),"unconfirmed":0}}"#, #"{"id":5,"result":[]}"#,
        ])
        let watched = try ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "3P14159f73E4gFr7JterCCQh9QjiTjiZrG"].map {
            WatchedAddress(address: try BitcoinAddress($0), label: "x")
        }
        await #expect(throws: ElectrumError.implausibleValue) { try await ElectrumClient(stream: stream).snapshot(of: watched) }
    }

    @Test func wrongReplyID() async {
        let stream = FakeStream(lines: [#"{"id":99,"result":{"confirmed":1,"unconfirmed":0}}"#])
        await #expect(throws: ElectrumError.unexpectedReplyID) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test(arguments: ["not json", "[]", #"{"id":1}"#, #"{"id":1,"result":"text"}"#, #"{"id":1,"result":{"confirmed":1.5,"unconfirmed":0}}"#,
                      #"{"id":1,"result":{"confirmed":99999999999999999999,"unconfirmed":0}}"#])
    func malformed(line: String) async {
        let stream = FakeStream(lines: [line])
        await #expect(throws: ElectrumError.malformedReply) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test func serverErrorTextIsDropped() async {
        let stream = FakeStream(lines: [#"{"id":1,"error":{"code":1,"message":"<evil>"}}"#])
        await #expect(throws: ElectrumError.serverError) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test func endlessLineIsCut() async {
        let chunk = Data(repeating: 0x41, count: 1024 * 1024)
        let stream = FakeStream(Array(repeating: chunk, count: 10))
        await #expect(throws: ElectrumError.lineTooLong) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test func notificationFloodStops() async {
        let flood = String(repeating: #"{"method":"blockchain.headers.subscribe","params":[]}"# + "\n", count: 2_000)
        let stream = FakeStream([Data(flood.utf8)])
        await #expect(throws: ElectrumError.tooManyNotifications) { try await ElectrumClient(stream: stream).balance(of: hash) }
    }

    @Test(arguments: [#"[{"height":1,"tx_hash":"xyz"}]"#, #"[{"height":-2,"tx_hash":"\#(String(repeating: "a", count: 64))"}]"#])
    func badHistory(result: String) async {
        let stream = FakeStream(lines: [#"{"id":1,"result":\#(result)}"#])
        await #expect(throws: ElectrumError.implausibleValue) { try await ElectrumClient(stream: stream).history(of: hash) }
    }

    @Test func wrongProtocolVersion() async {
        let stream = FakeStream(lines: [#"{"id":1,"result":["x","1.2"]}"#])
        await #expect(throws: ElectrumError.incompatibleServer) { try await ElectrumClient(stream: stream).negotiateVersion() }
    }

    @Test func onlyAllowedMethodsExist() {
        let all: [ElectrumRequest] = [.version, .headersSubscribe, .balance(hash), .history(hash)]
        #expect(Set(all.map(\.method)) == ["server.version", "blockchain.headers.subscribe",
                                           "blockchain.scripthash.get_balance", "blockchain.scripthash.get_history"])
    }
}

@Suite struct SocksTests {
    let onion = try! OnionAddress(TorIdentifierTests.real)

    private func reply(_ code: UInt8) -> [Data] {
        [Data([5, 0]), Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0])]
    }

    @Test func sendsHostnameNotIP() async throws {
        let stream = FakeStream(reply(0))
        try await Socks5.connect(over: stream, to: onion, port: 50001)
        let sent = Data(stream.sent.utf8)
        #expect(sent.starts(with: [5, 1, 0]))
        #expect(stream.sent.contains(onion.hostname))
    }

    @Test(arguments: [
        (UInt8(0xF0), TorConnectError.serviceNotFound), (0xF2, .serviceUnreachable), (0xF7, .serviceUnreachable),
        (0xF4, .notAuthorized), (0xF5, .notAuthorized), (0xF6, .badAddress), (0x01, .refused(1)),
    ])
    func errorCodes(code: UInt8, expected: TorConnectError) async {
        await #expect(throws: expected) {
            try await Socks5.connect(over: FakeStream(reply(code)), to: onion, port: 50001)
        }
    }

    @Test func rejectsAuthRequirement() async {
        await #expect(throws: TorConnectError.malformedReply) {
            try await Socks5.connect(over: FakeStream([Data([5, 2])]), to: onion, port: 50001)
        }
    }

    @Test func rejectsUnknownAddressType() async {
        await #expect(throws: TorConnectError.malformedReply) {
            try await Socks5.connect(over: FakeStream([Data([5, 0]), Data([5, 0, 0, 9])]), to: onion, port: 50001)
        }
    }
}

/// Exercises the real POSIX socket code against a local Unix socket.
@Suite struct UnixSocketTests {
    private func makeListener() throws -> (fd: Int32, path: String) {
        let path = "/tmp/ew-test-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        return (fd, path)
    }

    @Test func roundTrip() async throws {
        let (listener, path) = try makeListener()
        defer { Darwin.close(listener); unlink(path) }
        let stream = try UnixSocketStream(path: path)
        let peer = accept(listener, nil, nil)
        defer { Darwin.close(peer) }

        try await stream.write(Data("hi".utf8), timeout: 2)
        var buffer = [UInt8](repeating: 0, count: 2)
        #expect(recv(peer, &buffer, 2, 0) == 2)
        #expect(buffer == Array("hi".utf8))

        _ = send(peer, "yo", 2, 0)
        #expect(try await stream.read(maxBytes: 16, timeout: 2) == Data("yo".utf8))
    }

    @Test func readTimesOut() async throws {
        let (listener, path) = try makeListener()
        defer { Darwin.close(listener); unlink(path) }
        let stream = try UnixSocketStream(path: path)
        let peer = accept(listener, nil, nil)
        defer { Darwin.close(peer) }
        await #expect(throws: StreamError.timedOut) { try await stream.read(maxBytes: 1, timeout: 0.1) }
    }

    @Test func closeWakesReader() async throws {
        let (listener, path) = try makeListener()
        defer { Darwin.close(listener); unlink(path) }
        let stream = try UnixSocketStream(path: path)
        let peer = accept(listener, nil, nil)
        defer { Darwin.close(peer) }
        let read = Task { try await stream.read(maxBytes: 1, timeout: 30) }
        try await Task.sleep(for: .milliseconds(50))
        stream.close()
        await #expect(throws: StreamError.closed) { try await read.value }
    }

    @Test func peerHangupDoesNotKillProcess() async throws {
        let (listener, path) = try makeListener()
        defer { Darwin.close(listener); unlink(path) }
        let stream = try UnixSocketStream(path: path)
        let peer = accept(listener, nil, nil)
        Darwin.close(peer)
        await #expect(throws: StreamError.closed) {
            for _ in 0..<5 { try await stream.write(Data(repeating: 0, count: 65536), timeout: 1) }
        }
    }

    @Test func missingSocketFails() {
        #expect(throws: StreamError.socketFailed) { try UnixSocketStream(path: "/tmp/does-not-exist-ew.sock") }
    }

    @Test func longPathFails() {
        #expect(throws: StreamError.pathTooLong) { try UnixSocketStream(path: "/tmp/" + String(repeating: "a", count: 200)) }
    }
}

/// Replies are the exact bytes captured from Tor 0.4.9.15.
@Suite struct TorControlTests {
    let onion = try! OnionAddress(TorIdentifierTests.real)
    let key = ClientAuthKey.generate()

    private func client(_ reply: String) -> (TorControlClient, FakeStream) {
        let stream = FakeStream([Data(reply.utf8)])
        return (TorControlClient(stream: stream), stream)
    }

    @Test(arguments: ["250 OK\r\n", "251 Client for onion existed and replaced\r\n", "252 Registered client and decrypted desc\r\n"])
    func addSucceeds(reply: String) async throws {
        let (control, stream) = client(reply)
        try await control.addClientAuth(onion: onion, key: key)
        #expect(stream.sent == "ONION_CLIENT_AUTH_ADD \(onion.serviceID) \(key.controlPortBlob)\r\n")
        #expect(!stream.sent.contains("Permanent"))
    }

    @Test func addWithBadChecksumIsBadAddress() async {
        let (control, _) = client("512 Invalid v3 address \"aaa\"\r\n")
        await #expect(throws: TorConnectError.badAddress) { try await control.addClientAuth(onion: onion, key: key) }
    }

    @Test(arguments: ["250 OK\r\n", "251 No credentials for \"x\"\r\n"])
    func removeSucceeds(reply: String) async throws {
        try await client(reply).0.removeClientAuth(onion: onion)
    }

    @Test func bootstrapParsesMultilineReply() async throws {
        let (control, _) = client("250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=75 TAG=x SUMMARY=\"y\"\r\n250 OK\r\n")
        #expect(try await control.bootstrapPercent() == 75)
    }

    @Test func authFailureIsAnError() async {
        let (control, _) = client("515 Authentication failed: Wrong length\r\n")
        await #expect(throws: TorControlError.rejected(515)) { try await control.authenticate(cookie: Data(count: 32)) }
    }

    @Test func dataBlocksAreSkipped() async throws {
        let (control, _) = client("250+x=\r\nsome\r\ndata\r\n.\r\n250 OK\r\n")
        #expect(try await control.send("GETINFO", ["x"], accepting: [250]) == ["x=", "OK"])
    }

    @Test func eventsAreNotTakenAsReplies() async throws {
        let (control, _) = client("650 STATUS_CLIENT NOTICE X\r\n250 OK\r\n")
        try await control.setNetworkEnabled(true)
    }

    @Test func closedConnectionThrows() async {
        let (control, _) = client("")
        await #expect(throws: StreamError.closed) { try await control.setNetworkEnabled(false) }
    }

    @Test(arguments: ["garbage\r\n", "25\r\n", "250?OK\r\n"])
    func malformedReplies(reply: String) async {
        let (control, _) = client(reply)
        await #expect(throws: TorControlError.malformedReply) { try await control.setNetworkEnabled(false) }
    }

    @Test(arguments: ["a\r\nSIGNAL SHUTDOWN", "a b", ""])
    func injectionIsRefused(argument: String) async {
        let (control, stream) = client("250 OK\r\n")
        await #expect(throws: TorControlError.invalidArgument) { try await control.send("GETINFO", [argument], accepting: [250]) }
        #expect(stream.sent.isEmpty)
    }
}

final class SlowStream: ByteStream, @unchecked Sendable {
    func read(maxBytes: Int, timeout: TimeInterval) async throws -> Data {
        try await Task.sleep(for: .milliseconds(20))
        return Data([0x41])
    }
    func write(_ data: Data, timeout: TimeInterval) async throws {}
    func close() {}
}

@Suite struct DeadlineTests {
    @Test func slowServerCantStallPastTheDeadline() async throws {
        let client = ElectrumClient(stream: SlowStream(), requestTimeout: 0.1)
        await #expect(throws: StreamError.timedOut) { try await client.negotiateVersion() }
    }

    @Test func snapshotKeepingDropsRemovedRows() throws {
        let a = WatchedAddress(address: try BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"), label: "a")
        let b = WatchedAddress(address: try BitcoinAddress("3P14159f73E4gFr7JterCCQh9QjiTjiZrG"), label: "b")
        let history = HistorySummary(transactionCount: 0, pendingCount: 0, latestConfirmedHeight: nil)
        let rows = [a, b].map { AddressStatus(watched: $0, balance: Balance(confirmedSats: 5, unconfirmedSats: 0), history: history) }
        let snapshot = WalletSnapshot(tip: ChainTip(height: 1), rows: rows, fetchedAt: Date())
        #expect(snapshot.keeping([a]).totalConfirmedSats == 5)
    }
}
