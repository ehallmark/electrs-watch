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
        case connecting
        case refreshing
    }

    /// Only our own messages are ever shown. Nothing from the server reaches the screen.
    struct Failure: Equatable {
        let message: String
    }

    private(set) var vault: VaultContents?
    private(set) var vaultExists = false
    private(set) var snapshot: WalletSnapshot?
    /// False while `snapshot` is a saved copy, or while a newer one is being fetched or failed to arrive.
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
    /// Goes up on every lock, so work that finishes afterward can tell it's stale and drop its results.
    private var session = 0

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
            let contents = try await Task.detached { try store.load(context: box.context) }.value
            guard self.session == session else {
                context.invalidate()
                return
            }
            vault = contents
            snapshot = contents.lastSnapshot?.keeping(contents.watched)
            balanceIsCurrent = false
            // Right after Tor resumes, the first connection to the service can fail briefly.
            if !contents.watched.isEmpty { refresh(retries: 6) }
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
        guard var contents = vault, let onion = try? OnionAddress(text) else { return false }
        contents.onion = onion
        // Balances saved from the old server shouldn't appear as if they came from the new one.
        contents.lastSnapshot = nil
        guard persist(contents) else { return false }
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

    func remove(_ item: WatchedAddress) {
        guard var contents = vault else { return }
        contents.watched.removeAll { $0 == item }
        contents.lastSnapshot = contents.lastSnapshot?.keeping(contents.watched)
        if persist(contents) {
            snapshot = snapshot?.keeping(contents.watched)
        }
    }

    private func persist(_ contents: VaultContents) -> Bool {
        guard let context, (try? store.save(contents, context: context)) != nil else {
            failure = Failure(message: "Couldn't save. Try locking and unlocking the app.")
            return false
        }
        vault = contents
        return true
    }

    /// Runs on leaving the foreground and on request. Everything sensitive leaves app state here.
    func lock() {
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
        vaultExists = store.exists()
    }

    func eraseEverything() {
        lock()
        store.erase()
        needsDescriptorRefresh = false
        vaultExists = false
    }

    // MARK: Refresh

    /// `retries` are silent: the screen keeps saying it's updating, and only the last failure is shown.
    func refresh(retries: Int = 0) {
        guard refreshTask == nil, vault?.onion != nil else { return }
        let session = session
        failure = nil
        balanceIsCurrent = false
        // Set now so the screen shows progress from the first frame, with no flash of the Refresh button.
        activity = client == nil ? .startingTor(0) : .refreshing
        refreshTask = Task { [weak self] in
            var retriesLeft = retries
            while true {
                // Read each time, so a retry uses any address or server changed in the meantime.
                guard let self, self.session == session, let vault = self.vault, let onion = vault.onion else { return }
                await self.runRefresh(session: session, onion: onion, key: vault.clientKey, watched: vault.watched)
                guard self.session == session else { return }
                guard self.failure != nil, retriesLeft > 0 else { break }
                retriesLeft -= 1
                self.failure = nil
                self.activity = .connecting
                try? await Task.sleep(for: .seconds(8))
            }
            guard let self, self.session == session else { return }
            self.refreshTask = nil
            self.activity = .idle
        }
    }

    private func runRefresh(session: Int, onion: OnionAddress, key: ClientAuthKey, watched: [WatchedAddress]) async {
        let tor = tor
        do {
            // A quick relaunch must not race the previous lock's cleanup.
            await suspendTask?.value
            if client == nil {
                activity = .startingTor(0)
                try await tor.start(session: session) { percent in
                    Task { @MainActor [weak self] in
                        guard let self, self.session == session, case .startingTor = self.activity else { return }
                        self.activity = .startingTor(percent)
                    }
                }
                try await tor.addClientAuth(session: session, onion: onion, key: key)
                if needsDescriptorRefresh {
                    await tor.forgetCachedServices()
                    needsDescriptorRefresh = false
                }
                guard self.session == session else { return }
                activity = .connecting
                let connected = try await ElectrumClient.connect(socksPath: tor.socksPath, onion: onion)
                guard self.session == session else {
                    connected.close()
                    return
                }
                client = connected
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
            failure = Failure(message: Self.describe(error))
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
