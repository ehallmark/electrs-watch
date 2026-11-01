import Foundation

/// Everything the Keychain item holds.
public struct VaultContents: Codable, Sendable, Equatable {
    public static let maxAddresses = 200
    public var clientKey: ClientAuthKey
    public var onion: OnionAddress?
    public var watched: [WatchedAddress]

    public init(clientKey: ClientAuthKey, onion: OnionAddress? = nil, watched: [WatchedAddress] = []) {
        self.clientKey = clientKey
        self.onion = onion
        self.watched = watched
    }
}

public struct WatchedAddress: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let address: String
    public var label: String
    public var id: String { address }

    public init(address: BitcoinAddress, label: String) {
        self.address = address.text
        self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}

public struct AddressStatus: Sendable, Equatable, Identifiable {
    public let watched: WatchedAddress
    public let balance: Balance
    public let history: HistorySummary
    public var id: String { watched.address }
}

public struct WalletSnapshot: Sendable, Equatable {
    public let tip: ChainTip
    public let rows: [AddressStatus]
    public let fetchedAt: Date

    public init(tip: ChainTip, rows: [AddressStatus], fetchedAt: Date) {
        self.tip = tip
        self.rows = rows
        self.fetchedAt = fetchedAt
    }

    /// Drops rows for addresses removed while a refresh was running, so totals match what's listed.
    public func keeping(_ watched: [WatchedAddress]) -> WalletSnapshot {
        WalletSnapshot(tip: tip, rows: rows.filter { watched.contains($0.watched) }, fetchedAt: fetchedAt)
    }

    public var totalConfirmedSats: Int64 { rows.reduce(0) { $0 + $1.balance.confirmedSats } }
    public var totalUnconfirmedSats: Int64 { rows.reduce(0) { $0 + $1.balance.unconfirmedSats } }
}

extension ElectrumClient {
    /// Fetches everything for one refresh. Rejects a total over the 21M supply, which also rules out overflow.
    public func snapshot(of watched: [WatchedAddress], now: Date = Date()) async throws -> WalletSnapshot {
        let currentTip = try await tip()
        var rows: [AddressStatus] = []
        var total: Int64 = 0
        for item in watched.prefix(VaultContents.maxAddresses) {
            let hash = try BitcoinAddress(item.address).scriptHash
            let itemBalance = try await balance(of: hash)
            let itemHistory = try await history(of: hash)
            total += itemBalance.confirmedSats
            guard total <= maxSupplySats else { throw ElectrumError.implausibleValue }
            rows.append(AddressStatus(watched: item, balance: itemBalance, history: itemHistory))
        }
        return WalletSnapshot(tip: currentTip, rows: rows, fetchedAt: now)
    }
}

public enum BitcoinAmount {
    /// Integer arithmetic only, so no floating-point rounding: 123456789 -> "1.23456789".
    public static func format(sats: Int64, signed: Bool = false) -> String {
        let magnitude = sats.magnitude
        let whole = magnitude / 100_000_000
        let fraction = String(magnitude % 100_000_000)
        let padded = String(repeating: "0", count: 8 - fraction.count) + fraction
        let sign = sats < 0 ? "-" : (signed && sats > 0 ? "+" : "")
        return "\(sign)\(whole).\(padded)"
    }
}
