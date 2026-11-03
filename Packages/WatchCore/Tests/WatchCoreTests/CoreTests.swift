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

    @Test(arguments: [
        (Int64(0), false, "0 sats"), (1, false, "1 sat"), (-1, true, "-1 sat"), (999, false, "999 sats"),
        (1_000, false, "1,000 sats"), (-1_000, true, "-1,000 sats"), (5, true, "+5 sats"),
        (123_506_789, false, "123,506,789 sats"), (2_100_000_000_000_000, false, "2,100,000,000,000,000 sats"),
    ])
    func displaysSats(sats: Int64, signed: Bool, text: String) {
        #expect(BitcoinAmount.display(sats: sats, unit: .sats, signed: signed) == text)
    }

    @Test func displaysBTC() {
        #expect(BitcoinAmount.display(sats: 123_456_789, unit: .btc) == "1.23456789 BTC")
        #expect(BitcoinAmount.display(sats: -1_000, unit: .btc, signed: true) == "-0.00001000 BTC")
    }

    @Test func smallestPossibleValueDoesntCrash() {
        #expect(BitcoinAmount.display(sats: .min, unit: .sats) == "-9,223,372,036,854,775,808 sats")
    }
}

@Suite struct VaultCompatibilityTests {
    private func sample() throws -> VaultContents {
        var vault = VaultContents(clientKey: .generate())
        let watched = WatchedAddress(address: try BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"), label: "a")
        vault.watched = [watched]
        vault.unit = .sats
        vault.lastSnapshot = WalletSnapshot(
            tip: ChainTip(height: 7),
            rows: [AddressStatus(
                watched: watched,
                balance: Balance(confirmedSats: 5, unconfirmedSats: -1),
                history: HistorySummary(transactionCount: 2, pendingCount: 1, latestConfirmedHeight: 6))],
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return vault
    }

    /// Re-encodes a vault after changing its JSON, to imitate older or damaged saved data.
    private func decode(_ vault: VaultContents, editing edit: (inout [String: Any]) -> Void) throws -> VaultContents {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(vault)) as? [String: Any])
        edit(&json)
        return try JSONDecoder().decode(VaultContents.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func savedBalanceAndUnitSurviveARoundTrip() throws {
        let vault = try sample()
        #expect(try JSONDecoder().decode(VaultContents.self, from: JSONEncoder().encode(vault)) == vault)
    }

    @Test func vaultSavedBeforeTheseFieldsStillOpens() throws {
        let vault = try sample()
        let old = try decode(vault) {
            $0.removeValue(forKey: "unit")
            $0.removeValue(forKey: "lastSnapshot")
        }
        #expect(old.clientKey == vault.clientKey)
        #expect(old.watched == vault.watched)
        #expect(old.unit == nil)
        #expect(old.lastSnapshot == nil)
    }

    @Test func damagedDisplayExtrasDontLoseTheKey() throws {
        let vault = try sample()
        let damaged = try decode(vault) {
            $0["unit"] = "dogecoin"
            $0["lastSnapshot"] = ["tip": "nonsense"]
        }
        #expect(damaged.clientKey == vault.clientKey)
        #expect(damaged.watched == vault.watched)
        #expect(damaged.unit == nil)
        #expect(damaged.lastSnapshot == nil)
    }

    @Test func renamingKeepsTheAddressAndNormalizesTheLabel() throws {
        var item = WatchedAddress(address: try BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"), label: "old")
        let address = item.address
        item.rename(to: "  " + String(repeating: "x", count: 50) + "\n")
        #expect(item.label == String(repeating: "x", count: 40))
        #expect(item.address == address)
        item.rename(to: "   ")
        #expect(item.label.isEmpty)
    }

    @Test func aRenamedAddressKeepsItsSavedBalance() throws {
        let original = WatchedAddress(address: try BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"), label: "old")
        let snapshot = WalletSnapshot(
            tip: ChainTip(height: 1),
            rows: [AddressStatus(
                watched: original,
                balance: Balance(confirmedSats: 5, unconfirmedSats: 0),
                history: HistorySummary(transactionCount: 1, pendingCount: 0, latestConfirmedHeight: 1)
            )],
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
        var renamed = original
        renamed.rename(to: "new")
        #expect(snapshot.keeping([renamed]).totalConfirmedSats == 5)
        #expect(snapshot.keeping([]).rows.isEmpty)
    }

    @Test func connectionLogSurvivesARoundTrip() throws {
        var vault = try sample()
        vault.connectionLog.record(.timedOut)
        vault.connectionLog.record(.timedOut)
        vault.connectionLog.record(.connectedAfterReset)
        let decoded = try JSONDecoder().decode(VaultContents.self, from: JSONEncoder().encode(vault))
        #expect(decoded.connectionLog.count(of: .timedOut) == 2)
        #expect(decoded.connectionLog.count(of: .connectedAfterReset) == 1)
        #expect(decoded.connectionLog.count(of: .connected) == 0)
    }

    @Test func missingOrDamagedConnectionLogDoesntLoseTheKey() throws {
        let vault = try sample()
        let missing = try decode(vault) { $0.removeValue(forKey: "connectionLog") }
        let damaged = try decode(vault) { $0["connectionLog"] = "nonsense" }
        for result in [missing, damaged] {
            #expect(result.clientKey == vault.clientKey)
            #expect(result.connectionLog == ConnectionLog())
        }
    }

    @Test func aDamagedKeyIsStillAnError() throws {
        let vault = try sample()
        #expect(throws: (any Error).self) {
            _ = try decode(vault) { $0.removeValue(forKey: "clientKey") }
        }
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
            #"{"id":2,"result":null}"#,
            #"{"id":3,"result":{"confirmed":3,"unconfirmed":1}}"#, #"{"id":4,"result":[]}"#,
            #"{"id":5,"result":"\#(String(repeating: "c", count: 64))"}"#,
            #"{"id":6,"result":{"confirmed":4,"unconfirmed":0}}"#, #"{"id":7,"result":[]}"#,
        ])
        let watched = try ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa", "3P14159f73E4gFr7JterCCQh9QjiTjiZrG"].map {
            WatchedAddress(address: try BitcoinAddress($0), label: "x")
        }
        let snapshot = try await ElectrumClient(stream: stream).snapshot(of: watched)
        #expect(snapshot.totalConfirmedSats == 7)
        #expect(snapshot.totalUnconfirmedSats == 1)
        // electrs repeats its work for any query made before subscribing.
        let methods = stream.sent.split(separator: "\n").map { line in
            ["subscribe", "get_balance", "get_history"].first { line.contains("scripthash.\($0)") } ?? "other"
        }
        #expect(methods == ["other", "subscribe", "get_balance", "get_history", "subscribe", "get_balance", "get_history"])
    }

    @Test func subscribeSendsTheScriptHash() async throws {
        let stream = FakeStream(lines: [#"{"id":1,"result":null}"#])
        try await ElectrumClient(stream: stream).subscribe(to: hash)
        #expect(stream.sent.contains(#""method":"blockchain.scripthash.subscribe","params":["\#(hash.hex)"]"#))
    }

    // Hostile replies

    @Test func subscribeRejectsABadStatus() async {
        for status in ["\"short\"", "\"\(String(repeating: "Z", count: 64))\""] {
            let stream = FakeStream(lines: [#"{"id":1,"result":\#(status)}"#])
            await #expect(throws: ElectrumError.implausibleValue) { try await ElectrumClient(stream: stream).subscribe(to: hash) }
        }
    }

    @Test func subscribeRejectsAMissingResult() async {
        let stream = FakeStream(lines: [#"{"id":1}"#])
        await #expect(throws: ElectrumError.malformedReply) { try await ElectrumClient(stream: stream).subscribe(to: hash) }
    }

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
            #"{"id":2,"result":null}"#,
            #"{"id":3,"result":{"confirmed":\#(big),"unconfirmed":0}}"#, #"{"id":4,"result":[]}"#,
            #"{"id":5,"result":null}"#,
            #"{"id":6,"result":{"confirmed":\#(big),"unconfirmed":0}}"#, #"{"id":7,"result":[]}"#,
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
        let all: [ElectrumRequest] = [.version, .headersSubscribe, .subscribe(hash), .balance(hash), .history(hash),
                                      .transaction(try! TxID(String(repeating: "a", count: 64))), .blockHeader(1)]
        #expect(Set(all.map(\.method)) == ["server.version", "blockchain.headers.subscribe", "blockchain.scripthash.subscribe",
                                           "blockchain.scripthash.get_balance", "blockchain.scripthash.get_history",
                                           "blockchain.transaction.get", "blockchain.block.header"])
    }
}

/// Vectors from scripts/e2e/txfixtures.py, which builds and hashes them separately in Python.
enum Fixtures {
    static let legacy = try! BitcoinAddress("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    static let segwit = try! BitcoinAddress("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    static let a = ("3d9ece8f1cb762dbfa6c15af6610c79e745aa6b32adf0dd1cd7450cfbb5ac6da",
                    "02000000011111111111111111111111111111111111111111111111111111111111111111000000000151ffffffff0200c2eb0b000000001976a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac881300000000000017a914e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a8700000000")
    static let b = ("c2f22e3a91faa4e3a488289d3d9a6ea9d7032e571d4ba724c8a9959d8a46e6c1",
                    "0200000001dac65abbcf5074cdd10ddf2ab3a65a749ec71066af156cfadb62b71c8fce9e3d000000000151ffffffff02ebf48f040000000017a914e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a8715cd5b07000000001976a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac00000000")
    static let c = ("5f687d4a0b03c7ec9b2733df3d61e0d4bc3a7d1a0f77b06a0969a384379eed98",
                    "02000000012222222222222222222222222222222222222222222222222222222222222222010000000151ffffffff0150c3000000000000160014751e76e8199196d454941c45d1b3a323f1433bd600000000")
    /// SegWit serialization, so its ID has to leave out the witness.
    static let d = ("907d70b0d7eaa44554d248d26589210088d403f21463c3135098635fabcd12bd",
                    "0200000000010198ed9e3784a369096ab0770f1a7d3abcd4e0613ddf33279becc7030b4a7d685f000000000151ffffffff02e80300000000000017a914e9c3dd0c07aac76179ebc76a6c78d4d67c6c160a8768bf000000000000160014751e76e8199196d454941c45d1b3a323f1433bd602030102030000000000")
    static let header700k = "0000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000282d3c61ffff001d00000000"

    static func raw(_ pair: (String, String)) -> RawTransaction { try! RawTransaction(hex: pair.1) }
    static func id(_ pair: (String, String)) -> TxID { try! TxID(pair.0) }
}

@Suite struct DemoDataTests {
    @Test func sampleDataAddsUpLikeRealData() {
        let demo = DemoData.make()
        #expect(demo.watched.count == 3)
        for (row, history) in zip(demo.snapshot.rows, demo.histories) {
            #expect(row.watched.address == history.address)
            #expect(history.balanceSats == row.balance.confirmedSats + row.balance.unconfirmedSats)
            #expect(history.transactions.first?.balanceAfterSats == history.balanceSats)
            #expect(history.receivedSats! - history.sentSats! == history.balanceSats)
            #expect(HistoryCache.matches(history, row: row, tip: demo.snapshot.tip))
            #expect(Set(history.transactions.map(\.txid)).count == history.transactions.count)
        }
        #expect(demo.snapshot.totalConfirmedSats == 85_000_000 + 9_850_000 + 2_660_000)
        #expect(demo.snapshot.totalUnconfirmedSats == 500_000)
    }
}

@Suite struct FreshnessTests {
    let legacy = WatchedAddress(address: Fixtures.legacy, label: "a")
    let segwit = WatchedAddress(address: Fixtures.segwit, label: "b")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(ageSeconds: TimeInterval, rows: [WatchedAddress]) -> WalletSnapshot {
        WalletSnapshot(
            tip: ChainTip(height: 1),
            rows: rows.map { AddressStatus(watched: $0, balance: Balance(confirmedSats: 1, unconfirmedSats: 0),
                                           history: HistorySummary(transactionCount: 1, pendingCount: 0, latestConfirmedHeight: 1)) },
            fetchedAt: now.addingTimeInterval(-ageSeconds))
    }

    @Test func recentSnapshotIsFresh() {
        #expect(snapshot(ageSeconds: 0, rows: [legacy]).isFresh(for: [legacy], now: now))
        #expect(snapshot(ageSeconds: 599, rows: [legacy]).isFresh(for: [legacy], now: now))
        // A renamed address still counts as covered.
        var renamed = legacy
        renamed.rename(to: "new")
        #expect(snapshot(ageSeconds: 60, rows: [legacy]).isFresh(for: [renamed], now: now))
    }

    @Test func oldFutureOrIncompleteSnapshotIsNot() {
        #expect(!snapshot(ageSeconds: 600, rows: [legacy]).isFresh(for: [legacy], now: now))
        #expect(!snapshot(ageSeconds: -5, rows: [legacy]).isFresh(for: [legacy], now: now))
        // An address added since has no balance yet.
        #expect(!snapshot(ageSeconds: 60, rows: [legacy]).isFresh(for: [legacy, segwit], now: now))
    }
}

@Suite struct TransactionTests {
    @Test(arguments: [Fixtures.a, Fixtures.b, Fixtures.c, Fixtures.d])
    func idsMatchIndependentHashes(pair: (String, String)) throws {
        #expect(try RawTransaction(hex: pair.1).txid.hex == pair.0)
    }

    @Test func readsInputsAndOutputs() throws {
        let d = Fixtures.raw(Fixtures.d)
        #expect(d.inputs == [OutPoint(txid: Fixtures.id(Fixtures.c), index: 0)])
        #expect(d.outputs.map(\.sats) == [1_000, 49_000])
        #expect(d.outputs[1].script == Fixtures.segwit.scriptPubKey)
    }

    @Test func readsBlockTime() throws {
        #expect(try BlockHeader.time(hex: Fixtures.header700k) == Date(timeIntervalSince1970: 1_631_333_672))
    }

    @Test(arguments: [
        "", "0", "zz", "02000000",
        // Trailing byte, missing lock time, no inputs
        Fixtures.a.1 + "00", String(Fixtures.a.1.dropLast(8)), "020000000000000000000000",
        // An input count far beyond what the bytes could hold
        "02000000fe00ffffff",
        // An output worth more than all bitcoin, and a negative one
        "0200000001" + String(repeating: "11", count: 32) + "000000000151ffffffff01" + "ffffffffffffff7f" + "015100000000",
        "0200000001" + String(repeating: "11", count: 32) + "000000000151ffffffff01" + "ffffffffffffffff" + "015100000000",
    ])
    func rejectsBadTransactions(hex: String) {
        #expect(throws: ElectrumError.self) { try RawTransaction(hex: hex) }
    }

    @Test(arguments: ["00", String(repeating: "00", count: 80), String(repeating: "00", count: 81)])
    func rejectsBadHeaders(hex: String) {
        #expect(throws: ElectrumError.self) { try BlockHeader.time(hex: hex) }
    }

    @Test func rejectsBadIDs() {
        for text in ["", String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            #expect(throws: ElectrumError.self) { try TxID(text) }
        }
    }
}

@Suite struct AddressHistoryTests {
    let entries = [HistoryEntry(txid: Fixtures.id(Fixtures.a), height: 700000), HistoryEntry(txid: Fixtures.id(Fixtures.b), height: 800000)]
    var all: [TxID: RawTransaction] { [Fixtures.id(Fixtures.a): Fixtures.raw(Fixtures.a), Fixtures.id(Fixtures.b): Fixtures.raw(Fixtures.b)] }

    private func build(balance: Int64 = 123_456_789, entries: [HistoryEntry]? = nil, transactions: [TxID: RawTransaction]? = nil) throws -> AddressHistory {
        try AddressHistory.build(address: Fixtures.legacy, tipHeight: 900000, balanceSats: balance, entries: entries ?? self.entries,
                                 transactions: transactions ?? all, times: [700000: Date(timeIntervalSince1970: 1)], fetchedAt: Date())
    }

    @Test func netsAndRunningBalance() throws {
        let history = try build()
        #expect(history.transactions.map(\.txid) == [Fixtures.id(Fixtures.b), Fixtures.id(Fixtures.a)])
        #expect(history.transactions.map(\.netSats) == [-76_543_211, 200_000_000])
        #expect(history.transactions.map(\.balanceAfterSats) == [123_456_789, 200_000_000])
        #expect(history.receivedSats == 200_000_000)
        #expect(history.sentSats == 76_543_211)
        #expect(history.transactions[1].time == Date(timeIntervalSince1970: 1))
        #expect(history.transactions[0].confirmations(tip: 900000) == 100001)
    }

    @Test func pendingSpendWithWitness() throws {
        let entries = [HistoryEntry(txid: Fixtures.id(Fixtures.d), height: 0), HistoryEntry(txid: Fixtures.id(Fixtures.c), height: 850000)]
        let history = try AddressHistory.build(
            address: Fixtures.segwit, tipHeight: 900000, balanceSats: 49_000, entries: entries,
            transactions: [Fixtures.id(Fixtures.c): Fixtures.raw(Fixtures.c), Fixtures.id(Fixtures.d): Fixtures.raw(Fixtures.d)],
            times: [:], fetchedAt: Date())
        // Pending goes newest, whatever order the server listed it in.
        #expect(history.transactions.map(\.netSats) == [-1_000, 50_000])
        #expect(history.transactions[0].isPending)
        #expect(history.transactions[0].confirmations(tip: 900000) == 0)
    }

    @Test func balanceThatDisagreesWithTransactionsIsRefused() {
        #expect(throws: ElectrumError.implausibleValue) { try build(balance: 123_456_788) }
        #expect(throws: ElectrumError.implausibleValue) { try build(balance: 5, entries: [], transactions: [:]) }
    }

    @Test func missingParentLeavesAmountUnknown() throws {
        let history = try build(transactions: [Fixtures.id(Fixtures.b): Fixtures.raw(Fixtures.b)])
        #expect(history.transactions.map(\.netSats) == [nil, nil])
        #expect(history.transactions[0].balanceAfterSats == 123_456_789)
        #expect(history.transactions[1].balanceAfterSats == nil)
        #expect(history.receivedSats == nil)
    }

    @Test func cacheRoundTripsAndStaysSmall() throws {
        var cache = HistoryCache()
        cache.store(try build())
        let decoded = try JSONDecoder().decode(HistoryCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded == cache)
        // Oldest pages go first once over the limit.
        for index in 0..<HistoryCache.maxAddresses {
            let other = AddressHistory(address: "a\(index)", tipHeight: 1, balanceSats: 0, totalCount: 0, transactions: [],
                                       fetchedAt: Date(timeIntervalSinceNow: Double(index + 1)))
            cache.store(other)
        }
        #expect(cache.histories.count == HistoryCache.maxAddresses)
        #expect(cache.histories[Fixtures.legacy.text] == nil)
        cache.keep([WatchedAddress(address: Fixtures.legacy, label: "")])
        #expect(cache.histories.isEmpty)
    }

    @Test func clientChecksEachTransactionAgainstItsID() async {
        // The server answers with A when asked for B.
        let stream = FakeStream(lines: [#"{"id":1,"result":"\#(Fixtures.a.1)"}"#])
        await #expect(throws: ElectrumError.implausibleValue) {
            _ = try await ElectrumClient(stream: stream).transactions([Fixtures.id(Fixtures.b)])
        }
    }

    @Test func batchedRepliesMayArriveInAnyOrder() async throws {
        let stream = FakeStream(lines: [#"{"id":2,"result":"\#(Fixtures.b.1)"}"#, #"{"id":1,"result":"\#(Fixtures.a.1)"}"#])
        let fetched = try await ElectrumClient(stream: stream).transactions([Fixtures.id(Fixtures.a), Fixtures.id(Fixtures.b)])
        #expect(fetched.count == 2)
        // Both requests go out before any reply is read.
        #expect(stream.sent.split(separator: "\n").count == 2)
        #expect(stream.sent.contains(#""method":"blockchain.transaction.get","params":["\#(Fixtures.a.0)"]"#))
    }

    @Test func duplicateReplyIsRefused() async {
        let stream = FakeStream(lines: [#"{"id":1,"result":"\#(Fixtures.a.1)"}"#, #"{"id":1,"result":"\#(Fixtures.a.1)"}"#])
        await #expect(throws: ElectrumError.unexpectedReplyID) {
            _ = try await ElectrumClient(stream: stream).transactions([Fixtures.id(Fixtures.a), Fixtures.id(Fixtures.b)])
        }
    }

    @Test func aFailedCallEndsTheConnection() async {
        let stream = FakeStream(lines: [#"{"id":5,"result":null}"#, #"{"id":2,"result":null}"#])
        let client = ElectrumClient(stream: stream)
        await #expect(throws: ElectrumError.unexpectedReplyID) { try await client.subscribe(to: Fixtures.legacy.scriptHash) }
        await #expect(throws: StreamError.closed) { try await client.subscribe(to: Fixtures.legacy.scriptHash) }
    }

    @Test func headerRequestSendsTheHeightAsANumber() async throws {
        let stream = FakeStream(lines: [#"{"id":1,"result":"\#(Fixtures.header700k)"}"#])
        let times = try await ElectrumClient(stream: stream).blockTimes([700000])
        #expect(times[700000] == Date(timeIntervalSince1970: 1_631_333_672))
        #expect(stream.sent.contains(#""method":"blockchain.block.header","params":[700000]"#))
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

    @Test(arguments: [("1", true), ("0", false)])
    func directoryInfoParsesReply(value: String, expected: Bool) async throws {
        let (control, stream) = client("250-status/enough-dir-info=\(value)\r\n250 OK\r\n")
        #expect(try await control.hasEnoughDirectoryInfo() == expected)
        #expect(stream.sent == "GETINFO status/enough-dir-info\r\n")
    }

    @Test func directoryInfoMissingFromReplyIsAnError() async {
        let (control, _) = client("250 OK\r\n")
        await #expect(throws: TorControlError.malformedReply) { try await control.hasEnoughDirectoryInfo() }
    }

    @Test func retriesStopOnCountOrTime() {
        #expect(ConnectionRetry.shouldRetry(retriesLeft: 1, elapsedSeconds: 0))
        #expect(ConnectionRetry.shouldRetry(retriesLeft: 1, elapsedSeconds: 179))
        #expect(!ConnectionRetry.shouldRetry(retriesLeft: 0, elapsedSeconds: 0))
        #expect(!ConnectionRetry.shouldRetry(retriesLeft: 6, elapsedSeconds: 180))
    }

    @Test func onlySlowFailuresCountAsStalls() {
        #expect(!ConnectionRetry.isStall(attemptSeconds: 1))
        #expect(ConnectionRetry.isStall(attemptSeconds: 20))
        #expect(ConnectionRetry.isStall(attemptSeconds: 60))
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
