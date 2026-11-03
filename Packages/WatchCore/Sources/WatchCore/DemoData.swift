import CryptoKit
import Foundation

/// Sample data for demo mode, so people (and App Review) can see the app without a node.
/// Built here, never fetched: demo mode has no server and never starts Tor. The addresses are
/// public test vectors, and the amounts and transactions are made up.
public enum DemoData {
    public struct Contents: Sendable {
        public let watched: [WatchedAddress]
        public let snapshot: WalletSnapshot
        public let histories: [AddressHistory]
    }

    /// One made-up transaction: days ago (nil for pending) and the amount for the address.
    private typealias Event = (daysAgo: Int?, sats: Int64)

    private static let samples: [(label: String, address: String, events: [Event])] = [
        ("Cold storage", "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3",
         [(410, 50_000_000), (205, 25_000_000), (31, 10_000_000)]),
        ("Savings", "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
         [(92, 12_000_000), (12, -2_150_000), (nil, 500_000)]),
        ("Spending", "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
         [(60, 3_000_000), (44, -750_000), (20, 1_200_000), (6, -480_000), (2, -310_000)]),
    ]

    public static func make(now: Date = Date()) -> Contents {
        let tip = 920_000
        var watched: [WatchedAddress] = []
        var rows: [AddressStatus] = []
        var histories: [AddressHistory] = []

        for (sampleIndex, sample) in samples.enumerated() {
            let address = try! BitcoinAddress(sample.address)
            let item = WatchedAddress(address: address, label: sample.label)
            watched.append(item)

            var running: Int64 = 0
            var transactions: [AddressTransaction] = []
            for (index, event) in sample.events.enumerated() {
                running += event.sats
                let height = event.daysAgo.map { tip - $0 * 144 } ?? 0
                transactions.append(AddressTransaction(
                    txid: fakeID(sampleIndex, index),
                    height: height,
                    netSats: event.sats,
                    balanceAfterSats: running,
                    time: event.daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) }
                ))
            }
            let pending = sample.events.filter { $0.daysAgo == nil }.reduce(0) { $0 + $1.sats }
            let confirmedHeights = transactions.filter { !$0.isPending }.map(\.height)
            rows.append(AddressStatus(
                watched: item,
                balance: Balance(confirmedSats: running - pending, unconfirmedSats: pending),
                history: HistorySummary(
                    transactionCount: transactions.count,
                    pendingCount: transactions.filter(\.isPending).count,
                    latestConfirmedHeight: confirmedHeights.max()
                )
            ))
            histories.append(AddressHistory(
                address: item.address,
                tipHeight: tip,
                balanceSats: running,
                totalCount: transactions.count,
                transactions: transactions.reversed(),
                fetchedAt: now
            ))
        }
        return Contents(
            watched: watched,
            snapshot: WalletSnapshot(tip: ChainTip(height: tip), rows: rows, fetchedAt: now),
            histories: histories
        )
    }

    /// A well-formed ID that no real transaction has: a hash of a label, not of a transaction.
    private static func fakeID(_ sample: Int, _ index: Int) -> TxID {
        TxID(internalBytes: Data(SHA256.hash(data: Data("electrs-watch demo \(sample) \(index)".utf8))))
    }
}
