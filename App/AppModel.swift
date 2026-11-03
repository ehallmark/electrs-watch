import Foundation
import LocalAuthentication
import Observation
import UIKit
import WatchCore

@MainActor @Observable
final class AppModel {
    enum Activity: Equatable {
        case idle
        case startingTor(Int)
        case resetting
        case connecting
        case waitingToRetry
        case refreshing
    }

    /// Only our own messages are ever shown. Nothing from the server reaches the screen.
    struct Failure: Equatable {
        let message: String
    }

    private(set) var vault: VaultContents?
    /// Demo mode: sample data held in memory only. It has no server address, so nothing can start
    /// Tor or connect, and it never reads or writes the Keychain. Locking ends it.
    private(set) var isDemo = false
    private(set) var vaultExists = false
    private(set) var snapshot: WalletSnapshot?
    /// False while `snapshot` is an older saved copy, or while a newer one is being fetched or failed to arrive.
    /// A copy saved in the last 10 minutes counts as current, so opening the app doesn't fetch again.
    private(set) var balanceIsCurrent = false
    private(set) var activity: Activity = .idle
    private(set) var failure: Failure?
    private(set) var unlockFailure: String?
    private(set) var offerErase = false
    var hideAmounts = false

    var unit: AmountUnit { vault?.unit ?? .btc }

    private let store = KeychainVault()
    private let tor = TorService()
    private var context: LAContext?
    private var client: ElectrumClient?
    private var refreshTask: Task<Void, Never>?
    private var suspendTask: Task<Void, Never>?
    private var unlocking = false
    private var needsDescriptorRefresh = false
    /// Set after a stalled attempt, because a new connection through a stuck Tor tends to stall too.
    private var needsNetworkReset = false
    private enum Reset { case none, automatic, hard }
    private var resetBeforeThisConnection = Reset.none
    /// For the screen: when this update started, which attempt is running, and whether it's a hard refresh.
    private(set) var refreshStartedAt: Date?
    private(set) var attempt = 1
    private(set) var isHardRefresh = false
    /// Goes up on each Hard Refresh tap, so the screen can confirm it with a tap of feedback.
    private(set) var hardRefreshTaps = 0
    /// Goes up on every lock, so work that finishes afterward can tell it's stale and drop its results.
    private var session = 0

    /// Address pages. Saved in their own Face ID protected Keychain item, loaded on unlock, and
    /// dropped from memory on lock.
    private var historyCache = HistoryCache()
    var histories: [String: AddressHistory] { historyCache.histories }
    private(set) var historyLoading: Set<String> = []
    private var historyTasks: [String: Task<Void, Never>] = [:]
    private(set) var historyFailures: [String: Failure] = [:]
    /// Whether a server connection is open, so an address page can load as soon as one is.
    var isConnected: Bool { client != nil }

    init() {
        vaultExists = store.exists()
        // After an erase, Tor's cached data goes too. It can't be removed while Tor runs, so it's done here.
        if !vaultExists { tor.eraseFiles() }
    }

    // MARK: Setup and unlock

    func beginSetup() async {
        unlockFailure = nil
        guard Self.biometryAvailable() else {
            unlockFailure = "This app needs Face ID and a device passcode."
            return
        }
        do {
            try store.create(VaultContents(clientKey: .generate()))
            vaultExists = true
            await unlock()
        } catch {
            unlockFailure = "Couldn't create secure storage. Check that Face ID and a passcode are set up."
        }
    }

    func unlock() async {
        guard !unlocking, vault == nil else { return }
        unlocking = true
        defer { unlocking = false }
        unlockFailure = nil
        offerErase = false
        let session = session
        let context = LAContext()
        // Stored first, so a lock during the prompt can cancel it.
        self.context = context
        let store = store
        do {
            // Blocks during the Face ID prompt, so it can't run on the main thread.
            let box = ContextBox(context)
            let (contents, cache) = try await Task.detached {
                let contents = try store.load(context: box.context)
                return (contents, store.loadHistory(context: box.context))
            }.value
            guard self.session == session else {
                context.invalidate()
                return
            }
            vault = contents
            historyCache = cache
            historyCache.keep(contents.watched)
            snapshot = contents.lastSnapshot?.keeping(contents.watched)
            // Going back and forth between apps shouldn't reconnect each time. Refresh still works on request.
            let fresh = contents.lastSnapshot?.isFresh(for: contents.watched, within: Self.freshSeconds) ?? false
            balanceIsCurrent = fresh
            // Right after Tor resumes, the first connection to the service can fail briefly.
            if !contents.watched.isEmpty, !fresh { refresh(retries: 6) }
        } catch {
            guard self.session == session else { return }
            context.invalidate()
            self.context = nil
            switch error {
            case VaultError.canceled:
                break
            case VaultError.authFailed:
                unlockFailure = "Face ID didn't match. Try again."
            case VaultError.unreadable:
                unlockFailure = "This data can't be read, which is expected after a Face ID change. Erase it and set up again."
                offerErase = true
            default:
                unlockFailure = "Couldn't unlock."
            }
        }
    }

    func setOnion(_ text: String) -> Bool {
        guard !isDemo, var contents = vault, let onion = try? OnionAddress(text) else { return false }
        contents.onion = onion
        // Balances saved from the old server shouldn't appear as if they came from the new one.
        contents.lastSnapshot = nil
        guard persist(contents) else { return false }
        historyCache = HistoryCache()
        store.eraseHistory()
        client?.close()
        client = nil
        snapshot = nil
        balanceIsCurrent = false
        failure = nil
        return true
    }

    func setUnit(_ unit: AmountUnit) {
        guard var contents = vault, contents.unit != unit else { return }
        contents.unit = unit
        _ = persist(contents)
    }

    func add(address: BitcoinAddress, label: String) -> Bool {
        guard var contents = vault, contents.watched.count < VaultContents.maxAddresses else { return false }
        guard !contents.watched.contains(where: { $0.address == address.text }) else { return true }
        contents.watched.append(WatchedAddress(address: address, label: label))
        return persist(contents)
    }

    func rename(_ item: WatchedAddress, to label: String) -> Bool {
        guard var contents = vault, let index = contents.watched.firstIndex(where: { $0.id == item.id }) else { return false }
        contents.watched[index].rename(to: label)
        return persist(contents)
    }

    func remove(_ item: WatchedAddress) {
        guard var contents = vault else { return }
        contents.watched.removeAll { $0.id == item.id }
        contents.lastSnapshot = contents.lastSnapshot?.keeping(contents.watched)
        if persist(contents) {
            snapshot = snapshot?.keeping(contents.watched)
        }
        historyCache.keep(contents.watched)
        saveHistories()
    }

    private func persist(_ contents: VaultContents) -> Bool {
        // Demo changes, like a rename, last until the demo ends.
        if isDemo {
            vault = contents
            return true
        }
        guard let context, (try? store.save(contents, context: context)) != nil else {
            failure = Failure(message: "Couldn't save. Try locking and unlocking the app.")
            return false
        }
        vault = contents
        return true
    }

    /// A failed save only costs this count, so it's never reported as a problem.
    private func record(_ outcome: ConnectionLog.Outcome) {
        guard var contents = vault else { return }
        contents.connectionLog.record(outcome)
        vault = contents
        if !isDemo, let context { try? store.save(contents, context: context) }
    }

    /// Runs on leaving the foreground and on request. Everything sensitive leaves app state here.
    func lock() {
        // Has to come first: saving needs the unlocked context. A stall is often ended by leaving,
        // so without this the log would miss the case it's there to explain.
        if client == nil, activity != .idle, let refreshStartedAt,
           ConnectionRetry.isStall(attemptSeconds: Date().timeIntervalSince(refreshStartedAt)) {
            record(.leftWhileWaiting)
        }
        refreshStartedAt = nil
        isHardRefresh = false
        // A lock resets Tor anyway.
        needsNetworkReset = false
        resetBeforeThisConnection = .none
        let lockedSession = session
        session += 1
        refreshTask?.cancel()
        refreshTask = nil
        client?.close()
        client = nil
        let tor = tor
        // iOS could otherwise freeze the app before Tor has dropped the key.
        let background = BackgroundWork()
        suspendTask = Task {
            await tor.suspend(session: lockedSession)
            background.end()
        }
        context?.invalidate()
        context = nil
        vault = nil
        snapshot = nil
        balanceIsCurrent = false
        failure = nil
        unlockFailure = nil
        offerErase = false
        activity = .idle
        hideAmounts = false
        isDemo = false
        historyCache = HistoryCache()
        historyTasks.values.forEach { $0.cancel() }
        historyTasks = [:]
        historyLoading = []
        historyFailures = [:]
        vaultExists = store.exists()
    }

    /// Only from the welcome screen, so it can't run alongside a real setup.
    func startDemo() {
        guard !vaultExists, vault == nil else { return }
        let demo = DemoData.make()
        var contents = VaultContents(clientKey: .generate(), onion: nil, watched: demo.watched)
        contents.lastSnapshot = nil
        isDemo = true
        vault = contents
        snapshot = demo.snapshot
        balanceIsCurrent = true
        historyCache = HistoryCache()
        demo.histories.forEach { historyCache.store($0) }
    }

    func exitDemo() {
        lock()
    }

    func eraseEverything() {
        lock()
        store.erase()
        needsDescriptorRefresh = false
        vaultExists = false
    }

    // MARK: Refresh

    /// Drops whatever is in progress and reconnects from scratch: Tor's relay connections close, its
    /// key is reloaded, and it builds new circuits and fetches the server's info again. Tor itself can't
    /// be restarted in the same process. Its guard and circuit timing data are kept on purpose,
    /// since Tor warns that discarding them makes tracking easier.
    func hardRefresh() {
        guard vault?.onion != nil else { return }
        record(.hardRefreshUsed)
        // Work still running from before sees a different session and drops its results.
        session += 1
        refreshTask?.cancel()
        refreshTask = nil
        client?.close()
        client = nil
        needsNetworkReset = true
        needsDescriptorRefresh = true
        resetBeforeThisConnection = .hard
        hardRefreshTaps += 1
        refresh(retries: 6)
        isHardRefresh = true
        activity = .resetting
    }

    /// `retries` are silent: the screen keeps saying it's updating, and only the last failure is shown.
    /// `ConnectionRetry` also limits them by time, so a run of slow failures can't hide for long.
    func refresh(retries: Int = 0) {
        guard refreshTask == nil, vault?.onion != nil else { return }
        let session = session
        failure = nil
        balanceIsCurrent = false
        // Set now so the screen shows progress from the first frame, with no flash of the Refresh button.
        activity = client == nil ? .startingTor(0) : .refreshing
        let startedAt = Date()
        refreshStartedAt = startedAt
        isHardRefresh = false
        attempt = 1
        refreshTask = Task { [weak self] in
            var retriesLeft = retries
            var attempt = 1
            while true {
                // Read each time, so a retry uses any address or server changed in the meantime.
                guard let self, self.session == session, let vault = self.vault, let onion = vault.onion else { return }
                self.attempt = attempt
                let attemptStartedAt = Date()
                await self.runRefresh(session: session, onion: onion, key: vault.clientKey, watched: vault.watched)
                guard self.session == session else { return }
                guard self.failure != nil else { break }
                if ConnectionRetry.isStall(attemptSeconds: Date().timeIntervalSince(attemptStartedAt)) {
                    self.needsNetworkReset = true
                    // Also what Hard Refresh does. After a server goes quiet, Tor can keep using stale
                    // details about how to reach it, and only a fresh copy of the service's info clears them.
                    self.needsDescriptorRefresh = true
                }
                guard ConnectionRetry.shouldRetry(retriesLeft: retriesLeft, elapsedSeconds: Date().timeIntervalSince(startedAt)) else { break }
                retriesLeft -= 1
                attempt += 1
                self.failure = nil
                self.activity = .waitingToRetry
                try? await Task.sleep(for: .seconds(8))
            }
            guard let self, self.session == session else { return }
            self.refreshTask = nil
            self.activity = .idle
            self.isHardRefresh = false
        }
    }

    /// Fetches one address's transactions over the open connection. It shares the connection with
    /// refreshes, which the client keeps in order. Doesn't connect by itself: the page asks for a
    /// refresh when there's no connection, and calls this again once there is.
    ///
    /// The load belongs to the model, not the page, so the page redrawing can't cancel it halfway.
    /// Only a lock does. Returns the load in progress, so pull to refresh can wait for it.
    @discardableResult
    func loadHistory(for item: WatchedAddress) -> Task<Void, Never>? {
        if let running = historyTasks[item.address] { return running }
        guard let client, let onion = vault?.onion, let address = try? BitcoinAddress(item.address) else { return nil }
        let session = session
        historyLoading.insert(item.address)
        historyFailures[item.address] = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchHistory(item: item, address: address, client: client, onion: onion, session: session)
        }
        historyTasks[item.address] = task
        return task
    }

    private func fetchHistory(item: WatchedAddress, address: BitcoinAddress, client: ElectrumClient, onion: OnionAddress, session: Int) async {
        defer {
            // After a lock, `lock()` has already cleared these, and a newer load may own them.
            if self.session == session {
                historyLoading.remove(item.address)
                historyTasks[item.address] = nil
            }
        }
        do {
            let history = try await client.addressHistory(of: address)
            guard self.session == session, vault?.onion == onion,
                  vault?.watched.contains(where: { $0.address == item.address }) == true else { return }
            historyCache.store(history)
            saveHistories()
        } catch {
            guard self.session == session, !(error is CancellationError) else { return }
            switch error {
            case ElectrumError.serverError:
                historyFailures[item.address] = Failure(message: "Your server reported an error. It may still be syncing.")
            case is ElectrumError:
                historyFailures[item.address] = Failure(message: "Your server sent transaction data that didn't add up, so it was ignored. Check the node if this continues.")
            default:
                historyFailures[item.address] = Failure(message: "The connection dropped while loading. Pull down to try again.")
            }
            // A failed call leaves the connection unusable, so the next refresh opens a new one.
            if self.client === client {
                client.close()
                self.client = nil
            }
        }
    }

    /// A failed save only means the page is fetched again next time, so it isn't reported.
    private func saveHistories() {
        guard !isDemo, let context else { return }
        try? store.saveHistory(historyCache, context: context)
    }

    private func runRefresh(session: Int, onion: OnionAddress, key: ClientAuthKey, watched: [WatchedAddress]) async {
        let tor = tor
        do {
            // A quick relaunch must not race the previous lock's cleanup.
            await suspendTask?.value
            if client == nil {
                activity = .startingTor(0)
                if needsNetworkReset {
                    activity = .resetting
                    try await tor.resetNetwork(session: session)
                    needsNetworkReset = false
                    if resetBeforeThisConnection == .none { resetBeforeThisConnection = .automatic }
                }
                try await tor.start(session: session) { percent in
                    Task { @MainActor [weak self] in
                        guard let self, self.session == session, case .startingTor = self.activity else { return }
                        self.activity = .startingTor(percent)
                    }
                }
                // Before adding the key, because Tor's cache reset also clears keys added from memory.
                if needsDescriptorRefresh {
                    await tor.forgetCachedServices()
                    needsDescriptorRefresh = false
                }
                try await tor.addClientAuth(session: session, onion: onion, key: key)
                guard self.session == session else { return }
                activity = .connecting
                let connected = try await ElectrumClient.connect(socksPath: tor.socksPath, onion: onion)
                guard self.session == session else {
                    connected.close()
                    return
                }
                client = connected
                switch resetBeforeThisConnection {
                case .none: record(.connected)
                case .automatic: record(.connectedAfterReset)
                case .hard: record(.connectedAfterHardRefresh)
                }
                resetBeforeThisConnection = .none
            }
            activity = .refreshing
            guard let client else { return }
            let result = try await client.snapshot(of: watched)
            // The onion check drops a reply from a server that was replaced during this refresh.
            guard self.session == session, var contents = vault, contents.onion == onion else { return }
            let current = result.keeping(contents.watched)
            snapshot = current
            balanceIsCurrent = true
            contents.lastSnapshot = current
            // A failed save only costs the saved copy, so the refresh still counts as a success.
            if let context, (try? store.save(contents, context: context)) != nil {
                vault = contents
            }
        } catch {
            guard self.session == session, !(error is CancellationError) else { return }
            client?.close()
            client = nil
            switch error {
            // A key added on the node only shows up in a newly fetched descriptor.
            case TorConnectError.notAuthorized, TorConnectError.serviceNotFound:
                needsDescriptorRefresh = true
            default:
                break
            }
            var outcome = Self.outcome(of: error)
            // Asked now, since a later retry may have refreshed the info.
            if outcome == .timedOut, await tor.hasEnoughDirectoryInfo() == false {
                outcome = .timedOutWithoutNetworkInfo
            }
            guard self.session == session else { return }
            record(outcome)
            failure = Failure(message: Self.describe(error))
        }
    }

    private static func outcome(of error: Error) -> ConnectionLog.Outcome {
        switch error {
        case StreamError.timedOut: .timedOut
        case StreamError.closed: .dropped
        case StreamError.socketFailed, StreamError.pathTooLong: .localSocketFailed
        case TorConnectError.serviceUnreachable: .unreachable
        case TorConnectError.serviceNotFound: .serviceNotFound
        case TorConnectError.notAuthorized: .notAuthorized
        case TorServiceError.startFailed, TorServiceError.stopped, TorServiceError.bootstrapTimedOut: .torNotStarted
        case is ElectrumError: .badServerReply
        default: .other
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case TorConnectError.notAuthorized:
            "This phone isn't authorized yet. Add its public key to the node, then retry."
        case TorConnectError.serviceNotFound:
            "Your server isn't reachable on Tor yet. It may be offline or still publishing. Try again in a minute."
        case TorConnectError.serviceUnreachable, StreamError.timedOut, StreamError.closed:
            "The connection to your server failed or dropped. Try again."
        case TorConnectError.badAddress:
            "That onion address isn't valid. Check it, and change it in Settings."
        case ElectrumError.lineTooLong, ElectrumError.malformedReply, ElectrumError.unexpectedReplyID,
             ElectrumError.implausibleValue, ElectrumError.tooManyNotifications, ElectrumError.incompatibleServer:
            "Your server sent an unexpected response, so it was ignored. Check the node if this continues."
        case ElectrumError.serverError:
            "Your server reported an error. It may still be syncing."
        case TorServiceError.bootstrapTimedOut:
            "Tor couldn't connect to its network. Check your internet connection."
        case TorServiceError.stopped:
            "Tor stopped unexpectedly. Close and reopen the app."
        default:
            "Couldn't connect. Try again."
        }
    }

    /// The E2E test sets this to 0 in the simulator, so it can test a stalled open soon after a refresh.
    /// Phone builds always use 10 minutes.
    private static let freshSeconds: TimeInterval = {
#if targetEnvironment(simulator)
        if let text = ProcessInfo.processInfo.environment["EW_FRESH_SECONDS"], let seconds = TimeInterval(text) { return seconds }
#endif
        return WalletSnapshot.freshSeconds
    }()

    private static func biometryAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

/// LAContext isn't marked Sendable. This hands it to one background read while the caller waits.
private struct ContextBox: @unchecked Sendable {
    let context: LAContext
    init(_ context: LAContext) { self.context = context }
}

/// Asks iOS for time to finish, and releases it exactly once, whichever comes first.
@MainActor
private final class BackgroundWork: Sendable {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
