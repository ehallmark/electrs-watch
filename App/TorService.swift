import CTorNoLzma
import Foundation
import WatchCore

enum TorServiceError: Error, Equatable {
    case startFailed
    case stopped
    case bootstrapTimedOut
}

/// Owns the single Tor thread this process is allowed to run.
///
/// Locking must beat any work already in progress. So commands go through a queue whose order is
/// fixed synchronously on this actor, and every command that exposes something (turning the network
/// on, loading the key) first checks that its session hasn't been locked. Whatever passes that
/// check is queued ahead of the lock's own cleanup commands.
actor TorService {
    private let socketDirectory: URL
    private let dataDirectory: URL
    private var thread: TorThread?
    private var control: TorControlClient?
    private var tail: Task<Void, Never>?
    private var lockedThrough = -1
    private var latestStartedSession = -1
    /// Which onion's key Tor currently holds, so a lock can always remove it.
    private var loadedOnion: OnionAddress?
    private var lastNewnym: Date?

    nonisolated var socksPath: String { socketDirectory.appendingPathComponent("s").path }
    private nonisolated var controlPath: String { socketDirectory.appendingPathComponent("c").path }
    private nonisolated var cookieURL: URL { dataDirectory.appendingPathComponent("control_auth_cookie") }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dataDirectory = support.appendingPathComponent("tor", isDirectory: true)
#if targetEnvironment(simulator)
        // Unix socket paths are limited to 103 bytes, and simulator containers are longer than that.
        // Real device paths fit. The simulator has no app sandbox here to protect anyway.
        socketDirectory = URL(fileURLWithPath: "/tmp/ew-\(getuid())", isDirectory: true)
#else
        socketDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("t", isDirectory: true)
#endif
    }

    /// Starts Tor if needed, turns its network on, and waits until it's ready. Safe to call repeatedly.
    func start(session: Int, progress: @Sendable @escaping (Int) -> Void) async throws {
        try checkNotLocked(session)
        latestStartedSession = max(latestStartedSession, session)
        if thread == nil {
            try prepareDirectories()
            let tor = TorThread(arguments: arguments())
            tor.start()
            thread = tor
        }
        let client = try await connectControl()
        try checkNotLocked(session)
        try await run(client) { try await $0.setNetworkEnabled(true) }

        for _ in 0..<300 {
            try checkNotLocked(session)
            let percent = try await run(client) { try await $0.bootstrapPercent() }
            progress(percent)
            if percent == 100 { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw TorServiceError.bootstrapTimedOut
    }

    /// Hands the key to Tor. It's held in Tor's memory only and never written to disk.
    func addClientAuth(session: Int, onion: OnionAddress, key: ClientAuthKey) async throws {
        try checkNotLocked(session)
        guard let client = control else { throw TorServiceError.startFailed }
        if let previous = loadedOnion, previous != onion {
            _ = try? await run(client) { try await $0.removeClientAuth(onion: previous) }
            try checkNotLocked(session)
        }
        loadedOnion = onion
        try await run(client) { try await $0.addClientAuth(onion: onion, key: key) }
    }

    /// Makes Tor fetch the service's info again. Call before `addClientAuth`, never after: Tor clears
    /// keys added without the Permanent flag along with the cache (`hs_client_purge_state` in Tor's source).
    /// Tor delays a NEWNYM sent within 10 seconds of the last one, and a delayed one could clear a key
    /// added in the meantime. So this waits out that window, and Tor then acts on it before the next command.
    func forgetCachedServices() async {
        guard let client = control else { return }
        if let lastNewnym {
            let wait = 11 - Date().timeIntervalSince(lastNewnym)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        lastNewnym = Date()
        _ = try? await run(client) { try await $0.forgetCachedServices() }
    }

    /// Whether Tor has current enough network info to build circuits. Nil if it couldn't be asked.
    func hasEnoughDirectoryInfo() async -> Bool? {
        guard let client = control else { return nil }
        return try? await run(client) { try await $0.hasEnoughDirectoryInfo() }
    }

    /// Clears a stuck Tor the way a lock and unlock does: its relay connections close and the key
    /// is removed. `start` and `addClientAuth` then bring it back.
    func resetNetwork(session: Int) async throws {
        try checkNotLocked(session)
        guard thread != nil else { return }
        let client = try await connectControl()
        try checkNotLocked(session)
        await takeOffline(client)
    }

    /// Called on lock. Tor can't be restarted in the same process, so it idles with its network off.
    func suspend(session: Int) async {
        lockedThrough = max(lockedThrough, session)
        guard thread != nil else { return }
        guard let client = try? await connectControl(), latestStartedSession <= session else { return }
        await takeOffline(client)
    }

    private func takeOffline(_ client: TorControlClient) async {
        // Queued with no suspension point between them, so nothing can land in between.
        let onion = loadedOnion
        let remove = onion.map { onion in enqueue(client) { try await $0.removeClientAuth(onion: onion) } }
        let networkOff = enqueue(client) { try await $0.setNetworkEnabled(false) }
        if (try? await remove?.value) != nil, onion == loadedOnion {
            loadedOnion = nil
        }
        _ = await networkOff.result
    }

    /// Deletes Tor's cached network data and guard choices. Only call before Tor has started.
    nonisolated func eraseFiles() {
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func checkNotLocked(_ session: Int) throws {
        guard session > lockedThrough else { throw CancellationError() }
    }

    private func enqueue<Value: Sendable>(
        _ client: TorControlClient,
        _ operation: @Sendable @escaping (TorControlClient) async throws -> Value
    ) -> Task<Value, Error> {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation(client)
        }
        tail = Task { _ = await task.result }
        return task
    }

    /// Runs a command in order. A broken connection is dropped, so the next call opens a new one.
    private func run<Value: Sendable>(
        _ client: TorControlClient,
        _ operation: @Sendable @escaping (TorControlClient) async throws -> Value
    ) async throws -> Value {
        do {
            return try await enqueue(client, operation).value
        } catch let error as StreamError {
            client.close()
            if control === client { control = nil }
            if thread?.isFinished == true { throw TorServiceError.stopped }
            throw error
        }
    }

    private nonisolated func arguments() -> [String] {
        var arguments = [
            "--ignore-missing-torrc", "--allow-missing-torrc",
            "--DataDirectory", dataDirectory.path,
            "--ClientOnly", "1",
            "--AvoidDiskWrites", "1",
            // Stays off until an unlocked session turns it on.
            "--DisableNetwork", "1",
            "--CookieAuthentication", "1",
            // No TCP listeners, since other apps on the phone can reach loopback ports.
            "--ControlSocket", controlPath,
            // Tor itself refuses any destination other than an onion service.
            "--SocksPort", "unix:\(socksPath) OnionTrafficOnly ExtendedErrors",
            "--SafeLogging", "1",
            "--Log", "err stderr",
            "--MaxMemInQueues", "64 MB",
            "--GeoIPFile", "",
            "--GeoIPv6File", "",
        ]
#if targetEnvironment(simulator)
        // For the E2E test only, so a slow connection can be explained. SafeLogging keeps addresses out.
        // Phone builds never log to a file.
        arguments += ["--Log", "notice file \(socketDirectory.appendingPathComponent("tor.log").path)"]
#endif
        return arguments
    }

    private nonisolated func prepareDirectories() throws {
        let manager = FileManager.default
        // Stale sockets from an earlier run would block binding, and an old cookie would fail to authenticate.
        try? manager.removeItem(at: socketDirectory)
        try? manager.removeItem(at: cookieURL)
        try manager.createDirectory(at: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: nil)
        try manager.setAttributes(
            [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete],
            ofItemAtPath: dataDirectory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dataDirectory
        try url.setResourceValues(values)
    }

    private func connectControl() async throws -> TorControlClient {
        if let control { return control }
        for _ in 0..<100 {
            if thread?.isFinished == true { throw TorServiceError.stopped }
            if let cookie = try? Data(contentsOf: cookieURL), cookie.count == 32,
               let stream = try? UnixSocketStream(path: controlPath) {
                let client = TorControlClient(stream: stream)
                do {
                    try await run(client) { try await $0.authenticate(cookie: cookie) }
                    control = client
                    return client
                } catch {
                    client.close()
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw TorServiceError.startFailed
    }
}
