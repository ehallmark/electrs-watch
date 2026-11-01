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

/// The app's only persistent store of anything sensitive: one Keychain item that Face ID protects.
struct KeychainVault: Sendable {
    private static let service = "electrs-watch.vault"
    private static let account = "vault.v1"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
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
        var error: Unmanaged<CFError>?
        // Not in backups or iCloud, removed if the passcode is, and invalidated if Face ID enrollment changes.
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
        ) else {
            throw VaultError.biometryUnavailable
        }
        var query = baseQuery
        query[kSecAttrAccessControl as String] = access
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
    }
}
