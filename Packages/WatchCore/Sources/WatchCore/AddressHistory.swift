import Foundation

/// One entry from `blockchain.scripthash.get_history`.
public struct HistoryEntry: Sendable, Equatable, Codable {
    public let txid: TxID
    /// Above 0: the block it confirmed in. 0 or -1: still pending.
    public let height: Int
}

/// One transaction, as it affected one address.
public struct AddressTransaction: Sendable, Equatable, Identifiable, Codable {
    public let txid: TxID
    public let height: Int
    /// Received minus spent, for this address. Nil when it can't be worked out from what was fetched.
    public let netSats: Int64?
    /// The address's balance once this transaction is included. Nil when an earlier step is unknown.
    public let balanceAfterSats: Int64?
    /// The block's time. Nil while pending.
    public let time: Date?

    public var id: TxID { txid }
    public var isPending: Bool { height <= 0 }

    public func confirmations(tip: Int) -> Int {
        isPending ? 0 : max(1, tip - height + 1)
    }
}

/// An address's activity, newest first. Built on the phone from raw transactions, which are each
/// checked against their ID, so the amounts don't rest on any total the server reports.
public struct AddressHistory: Sendable, Equatable, Codable {
    /// Larger histories show their newest transactions, with a note saying how many there are.
    public static let maxShown = 100
    /// How many older transactions may be fetched to price the coins the shown ones spend.
    public static let maxExtraFetches = 100

    public let address: String
    public let tipHeight: Int
    public let balanceSats: Int64
    public let totalCount: Int
    public let transactions: [AddressTransaction]
    public let fetchedAt: Date

    public var isComplete: Bool { transactions.count == totalCount }

    /// Sums of incoming and outgoing transactions, or nil unless every one is known.
    public var receivedSats: Int64? { complete { $0 > 0 ? $0 : 0 } }
    public var sentSats: Int64? { complete { $0 < 0 ? -$0 : 0 } }

    private func complete(_ part: (Int64) -> Int64) -> Int64? {
        guard isComplete else { return nil }
        var total: Int64 = 0
        for item in transactions {
            guard let net = item.netSats else { return nil }
            total += part(net)
        }
        return total
    }

    public var firstSeen: Date? { isComplete ? transactions.compactMap(\.time).min() : nil }
    public var lastActivity: Date? { transactions.compactMap(\.time).max() }

    /// Works out each shown transaction's effect on the address.
    ///
    /// `balanceSats` is the server's current total (confirmed plus pending). Balances are walked back
    /// from it, so they're right even when older transactions aren't shown. When the whole history is
    /// here, the walk has to end at zero, which catches a server whose answers don't agree.
    public static func build(
        address: BitcoinAddress,
        tipHeight: Int,
        balanceSats: Int64,
        entries: [HistoryEntry],
        transactions: [TxID: RawTransaction],
        times: [Int: Date],
        fetchedAt: Date
    ) throws -> AddressHistory {
        let script = address.scriptPubKey
        let ordered = order(entries)
        let known = Set(ordered.map(\.txid))

        var ours: [OutPoint: Int64] = [:]
        for raw in transactions.values {
            for (index, output) in raw.outputs.enumerated() where output.script == script {
                ours[OutPoint(txid: raw.txid, index: UInt32(index))] = output.sats
            }
        }

        let shown = Array(ordered.suffix(maxShown))
        let nets = shown.map { entry -> Int64? in
            guard let raw = transactions[entry.txid] else { return nil }
            // Each side is capped by the supply when parsed, so neither can overflow.
            let received = raw.outputs.filter { $0.script == script }.reduce(0) { $0 + $1.sats }
            var spent: Int64 = 0
            for input in raw.inputs where known.contains(input.txid) {
                // A coin from one of this address's transactions, which may or may not have paid it.
                guard transactions[input.txid] != nil else { return nil }
                spent += ours[input] ?? 0
                if spent > maxSupplySats { return nil }
            }
            return received - spent
        }

        var balances = [Int64?](repeating: nil, count: shown.count)
        var running: Int64? = balanceSats
        for index in shown.indices.reversed() {
            balances[index] = running
            guard let current = running, let net = nets[index] else {
                running = nil
                continue
            }
            // Not checked for going negative on the way: the order within one block isn't certain.
            running = current - net
        }
        if shown.count == ordered.count, let start = running, start != 0 {
            throw ElectrumError.implausibleValue
        }

        let items = shown.indices.map { index in
            AddressTransaction(
                txid: shown[index].txid,
                height: shown[index].height,
                netSats: nets[index],
                balanceAfterSats: balances[index],
                time: shown[index].height > 0 ? times[shown[index].height] : nil
            )
        }
        return AddressHistory(
            address: address.text,
            tipHeight: tipHeight,
            balanceSats: balanceSats,
            totalCount: ordered.count,
            transactions: items.reversed(),
            fetchedAt: fetchedAt
        )
    }

    /// Oldest first: confirmed by height, then pending. Keeps the server's order within a block.
    static func order(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        entries.enumerated().sorted { a, b in
            let (ka, kb) = (a.element.height > 0 ? a.element.height : Int.max, b.element.height > 0 ? b.element.height : Int.max)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
    }

    /// Which transactions to fetch: the shown ones first, then older ones whose coins they spend.
    static func neededParents(of shown: [HistoryEntry], fetched: [TxID: RawTransaction], history: [HistoryEntry]) -> [TxID] {
        let known = Set(history.map(\.txid))
        var needed: [TxID] = []
        var seen = Set<TxID>()
        for entry in shown {
            for input in fetched[entry.txid]?.inputs ?? [] where known.contains(input.txid) && fetched[input.txid] == nil {
                if seen.insert(input.txid).inserted { needed.append(input.txid) }
            }
        }
        return Array(needed.prefix(maxExtraFetches))
    }
}

/// Address pages saved between unlocks, in their own Face ID protected Keychain item. Holds the most
/// recently loaded few, which keeps that item small however many addresses are watched.
public struct HistoryCache: Codable, Sendable, Equatable {
    public static let maxAddresses = 20
    public private(set) var histories: [String: AddressHistory] = [:]

    public init() {}

    public mutating func store(_ history: AddressHistory) {
        histories[history.address] = history
        while histories.count > Self.maxAddresses,
              let oldest = histories.values.min(by: { $0.fetchedAt < $1.fetchedAt }) {
            histories[oldest.address] = nil
        }
    }

    /// Drops pages for addresses no longer watched.
    public mutating func keep(_ watched: [WatchedAddress]) {
        let addresses = Set(watched.map(\.address))
        histories = histories.filter { addresses.contains($0.key) }
    }

    /// Whether a saved page still matches the latest balances, so it can be shown without fetching.
    public static func matches(_ history: AddressHistory, row: AddressStatus, tip: ChainTip) -> Bool {
        history.tipHeight == tip.height && history.totalCount == row.history.transactionCount
            && history.balanceSats == row.balance.confirmedSats + row.balance.unconfirmedSats
    }
}
