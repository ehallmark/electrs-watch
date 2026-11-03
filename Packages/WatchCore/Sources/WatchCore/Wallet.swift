import Foundation

/// Everything the Keychain item holds.
public struct VaultContents: Codable, Sendable, Equatable {
    public static let maxAddresses = 200
    public var clientKey: ClientAuthKey
    public var onion: OnionAddress?
    public var watched: [WatchedAddress]
    /// Nil means the default, BTC. Optional so vaults saved before this field still open.
    public var unit: AmountUnit?
    /// The last balances fetched, shown while a new refresh runs.
    public var lastSnapshot: WalletSnapshot?
    public var connectionLog = ConnectionLog()

    public init(clientKey: ClientAuthKey, onion: OnionAddress? = nil, watched: [WatchedAddress] = []) {
        self.clientKey = clientKey
        self.onion = onion
        self.watched = watched
    }

    /// The display extras are decoded leniently. An unreadable vault offers to erase the client key,
    /// and a damaged saved balance or setting must never lead there.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientKey = try container.decode(ClientAuthKey.self, forKey: .clientKey)
        onion = try container.decodeIfPresent(OnionAddress.self, forKey: .onion)
        watched = try container.decode([WatchedAddress].self, forKey: .watched)
        unit = try? container.decodeIfPresent(AmountUnit.self, forKey: .unit)
        lastSnapshot = try? container.decodeIfPresent(WalletSnapshot.self, forKey: .lastSnapshot)
        connectionLog = (try? container.decodeIfPresent(ConnectionLog.self, forKey: .connectionLog)) ?? ConnectionLog()
    }
}

public enum AmountUnit: String, Codable, Sendable, CaseIterable {
    case btc
    case sats

    public var label: String {
        switch self {
        case .btc: "BTC"
        case .sats: "sats"
        }
    }
}

public struct WatchedAddress: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let address: String
    public private(set) var label: String
    public var id: String { address }

    public init(address: BitcoinAddress, label: String) {
        self.address = address.text
        self.label = Self.normalized(label)
    }

    public mutating func rename(to label: String) {
        self.label = Self.normalized(label)
    }

    private static func normalized(_ label: String) -> String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}

public struct AddressStatus: Codable, Sendable, Equatable, Identifiable {
    public let watched: WatchedAddress
    public let balance: Balance
    public let history: HistorySummary
    public var id: String { watched.address }
}

public struct WalletSnapshot: Codable, Sendable, Equatable {
    public let tip: ChainTip
    public let rows: [AddressStatus]
    public let fetchedAt: Date

    public init(tip: ChainTip, rows: [AddressStatus], fetchedAt: Date) {
        self.tip = tip
        self.rows = rows
        self.fetchedAt = fetchedAt
    }

    /// Drops rows for addresses removed while a refresh was running, so totals match what's listed.
    /// Matches on the address alone, so a renamed address keeps its balance.
    public func keeping(_ watched: [WatchedAddress]) -> WalletSnapshot {
        let addresses = Set(watched.map(\.address))
        return WalletSnapshot(tip: tip, rows: rows.filter { addresses.contains($0.watched.address) }, fetchedAt: fetchedAt)
    }

    /// Whether this is recent enough to show on opening without fetching again. Every watched address
    /// has to be in it, and a time in the future (a changed clock) doesn't count as recent.
    public func isFresh(for watched: [WatchedAddress], now: Date = Date(), within seconds: TimeInterval = WalletSnapshot.freshSeconds) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 0, age < seconds else { return false }
        return Set(watched.map(\.address)).isSubset(of: rows.map(\.watched.address))
    }

    public static let freshSeconds: TimeInterval = 10 * 60

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
            try await subscribe(to: hash)
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

    /// An amount with its unit, for display: "1.23456789 BTC" or "123,456,789 sats".
    /// Doesn't use the device's locale, so a balance reads the same everywhere.
    public static func display(sats: Int64, unit: AmountUnit, signed: Bool = false) -> String {
        switch unit {
        case .btc:
            return "\(format(sats: sats, signed: signed)) BTC"
        case .sats:
            var grouped = ""
            for (index, digit) in String(sats.magnitude).reversed().enumerated() {
                if index > 0, index % 3 == 0 { grouped.insert(",", at: grouped.startIndex) }
                grouped.insert(digit, at: grouped.startIndex)
            }
            let sign = sats < 0 ? "-" : (signed && sats > 0 ? "+" : "")
            return "\(sign)\(grouped) \(sats.magnitude == 1 ? "sat" : "sats")"
        }
    }
}
