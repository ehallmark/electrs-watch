import Foundation

/// When a failed connection is worth retrying, and when Tor itself needs a reset first.
public enum ConnectionRetry {
    /// An attempt this slow is treated as stuck. A faster failure is usually brief, and a reset
    /// would only bring back the moment just after Tor resumes, when failures like that happen.
    public static let stallSeconds: TimeInterval = 20
    /// No new attempt starts after this long, so a failure gets shown within a few minutes.
    public static let budgetSeconds: TimeInterval = 180

    public static func isStall(attemptSeconds: TimeInterval) -> Bool {
        attemptSeconds >= stallSeconds
    }

    public static func shouldRetry(retriesLeft: Int, elapsedSeconds: TimeInterval) -> Bool {
        retriesLeft > 0 && elapsedSeconds < budgetSeconds
    }
}

/// How connections have gone on this phone, to help explain slow ones.
/// Holds only a count per outcome: no addresses, times, or server replies.
public struct ConnectionLog: Codable, Sendable, Equatable {
    public enum Outcome: String, CaseIterable, Sendable {
        case connected
        case connectedAfterReset
        case connectedAfterHardRefresh
        case hardRefreshUsed
        case timedOut
        case timedOutWithoutNetworkInfo
        case unreachable
        case serviceNotFound
        case notAuthorized
        case dropped
        case localSocketFailed
        case torNotStarted
        case badServerReply
        case other
        case leftWhileWaiting

        public var label: String {
            switch self {
            case .connected: "Connected"
            case .connectedAfterReset: "Connected after resetting Tor"
            case .connectedAfterHardRefresh: "Connected after a hard refresh"
            case .hardRefreshUsed: "Hard refreshes"
            case .timedOut: "Timed out"
            case .timedOutWithoutNetworkInfo: "Timed out, Tor's network info out of date"
            case .unreachable: "Server unreachable"
            case .serviceNotFound: "Server not found on Tor"
            case .notAuthorized: "Phone not authorized"
            case .dropped: "Connection dropped"
            case .localSocketFailed: "Couldn't reach Tor inside the app"
            case .torNotStarted: "Tor didn't start"
            case .badServerReply: "Unexpected server reply"
            case .other: "Other failure"
            case .leftWhileWaiting: "Left the app while waiting"
            }
        }
    }

    private static let maxCount = 1_000_000
    /// Keyed by raw value, so an outcome removed in a later version can't make this unreadable.
    private var counts: [String: Int] = [:]

    public init() {}

    public func count(of outcome: Outcome) -> Int {
        counts[outcome.rawValue] ?? 0
    }

    public mutating func record(_ outcome: Outcome) {
        counts[outcome.rawValue] = min(count(of: outcome) + 1, Self.maxCount)
    }
}
