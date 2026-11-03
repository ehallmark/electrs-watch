import Foundation
import LocalAuthentication
import Security
import WatchCore

enum VaultError: Error, Equatable {
    case biometryUnavailable
    case canceled
    case authFailed
    case unreadable
    case keychain(OSStatus)
}

/// The app's only persistent store of anything sensitive: Keychain items that Face ID protects.
/// The vault item holds the key, addresses and balances. A second item holds saved address pages,
/// so the vault stays small, with the same protection.
struct KeychainVault: Sendable {
    private static let service = "electrs-watch.vault"
    private static let account = "vault.v1"
    private static let historyAccount = "history.v1"

    private var baseQuery: [String: Any] { query(account: Self.account) }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Not in backups or iCloud, removed if the passcode is, and invalidated if Face ID enrollment changes.
    private static func accessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
        ) else {
            throw VaultError.biometryUnavailable
        }
        return access
    }

    /// Checks for the item without prompting and without reading its contents.
    func exists() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func create(_ contents: VaultContents) throws {
        var query = baseQuery
        query[kSecAttrAccessControl as String] = try Self.accessControl()
        query[kSecValueData as String] = try JSONEncoder().encode(contents)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    /// Blocks while the Face ID prompt is up, so call off the main thread.
    func load(context: LAContext) throws -> VaultContents {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseOperationPrompt as String] = "Unlock your watched addresses"
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let contents = try? JSONDecoder().decode(VaultContents.self, from: data) else {
                throw VaultError.unreadable
            }
            return contents
        case errSecUserCanceled:
            throw VaultError.canceled
        case errSecAuthFailed:
            throw VaultError.authFailed
        case errSecItemNotFound:
            // Face ID enrollment changed, so the item can no longer be read.
            throw VaultError.unreadable
        default:
            throw VaultError.keychain(status)
        }
    }

    func save(_ contents: VaultContents, context: LAContext) throws {
        var query = baseQuery
        query[kSecUseAuthenticationContext as String] = context
        let update = [kSecValueData as String: try JSONEncoder().encode(contents)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    func erase() {
        SecItemDelete(baseQuery as CFDictionary)
        eraseHistory()
    }

    // MARK: Saved address pages

    /// Read with the context that just unlocked the vault, so there's no second Face ID prompt.
    /// Anything unreadable counts as empty: these pages can always be fetched again.
    func loadHistory(context: LAContext) -> HistoryCache {
        var query = query(account: Self.historyAccount)
        query[kSecReturnData as String] = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let compressed = result as? Data,
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data,
              let cache = try? JSONDecoder().decode(HistoryCache.self, from: data) else {
            return HistoryCache()
        }
        return cache
    }

    func saveHistory(_ cache: HistoryCache, context: LAContext) throws {
        guard !cache.histories.isEmpty else {
            eraseHistory()
            return
        }
        let data = try (JSONEncoder().encode(cache) as NSData).compressed(using: .lzfse) as Data
        var query = query(account: Self.historyAccount)
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = self.query(account: Self.historyAccount)
            add[kSecAttrAccessControl as String] = try Self.accessControl()
            add[kSecValueData as String] = data
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw VaultError.keychain(added) }
        default:
            // For example after a Face ID change made the old item unreadable: start it over.
            eraseHistory()
            throw VaultError.keychain(status)
        }
    }

    func eraseHistory() {
        SecItemDelete(query(account: Self.historyAccount) as CFDictionary)
    }
}
