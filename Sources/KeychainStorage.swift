import Foundation
import Security
import os.log

private let keychainLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Keychain")

// MARK: - Keychain seam

/// Outcome of a Keychain read. A failed read is kept apart from a missing item
/// so a key the app could not read is never treated as absent.
enum KeychainReadResult: Equatable {
    case found(String)
    case notFound
    case failed(OSStatus)
}

/// Minimal generic-password store. Tests substitute a fake so they never
/// touch the real Keychain.
protocol SecretKeychain {
    func read(account: String) -> KeychainReadResult
    func write(_ value: String, account: String) -> OSStatus
    func delete(account: String) -> OSStatus
}

/// Generic passwords in the user's login (file-based) Keychain, keyed by
/// service = bundle identifier and account = storage key.
///
/// The data-protection keychain is not used because it needs a Team ID
/// entitlement that self-signed builds lack. kSecAttrAccessible is not set:
/// SecItem.h notes it is unsupported for macOS file-based items unless the
/// item is synchronizable, and these items stay on this Mac.
struct LoginKeychain: SecretKeychain {
    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func read(account: String) -> KeychainReadResult {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else {
            os_log(.error, log: keychainLog, "Keychain read failed: OSStatus %d", status)
            return .failed(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            os_log(.error, log: keychainLog, "Keychain read failed: OSStatus %d", errSecDecode)
            return .failed(errSecDecode)
        }
        return .found(value)
    }

    func write(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        let attributes: [String: Any] = [kSecValueData as String: data]
        return SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
    }

    func delete(account: String) -> OSStatus {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

// MARK: - Settings store

/// Routes credentials to the Keychain and the non-secret provider URLs to the
/// owner-only `.settings` JSON file, and moves secrets left in that file into
/// the Keychain.
///
/// Not thread-safe: the app calls it from the main thread only.
final class AppSettingsStore {
    let settingsFileURL: URL
    let keychain: any SecretKeychain

    /// Secrets whose Keychain read failed in this process. The app then shows
    /// and later persists an empty value it never chose, so deletes for these
    /// accounts keep the Keychain item until a save replaces it.
    private var unreadableAccounts: Set<String> = []

    private enum KnownKeychainItem: Equatable {
        case holds(String)
        case absent
    }

    /// Keychain state this process last read, verified or deleted, per secret.
    /// A save or delete that would not change it skips Keychain I/O, so
    /// pressing Save with unchanged keys does not call the Keychain. An
    /// account with no entry has an unknown state and always goes to the
    /// Keychain. Edits made outside the app while it runs are not seen.
    private var knownKeychainItems: [String: KnownKeychainItem] = [:]

    init(settingsFileURL: URL, keychain: any SecretKeychain) {
        self.settingsFileURL = settingsFileURL
        self.keychain = keychain
    }

    /// Non-secret accounts kept in the file. Every other account is treated as a
    /// credential, so a newly added account defaults to the Keychain.
    static let plainFileAccounts: Set<String> = ["api_base_url", "transcription_api_url"]

    /// Marker written by the old Keychain-to-file migration. Dropped on migration.
    static let legacyMigrationMarker = "keychain_migration_done"

    static func isSecret(_ account: String) -> Bool {
        !plainFileAccounts.contains(account)
    }

    /// A secret is in the file only before it reaches the Keychain, or as an
    /// empty value masking an item a failed delete left behind, so a file copy
    /// is always the newest value.
    func load(account: String) -> String? {
        if let fileValue = readFile()?[account] {
            return fileValue
        }
        guard Self.isSecret(account) else { return nil }
        switch keychain.read(account: account) {
        case .found(let value):
            unreadableAccounts.remove(account)
            knownKeychainItems[account] = .holds(value)
            return value
        case .notFound:
            unreadableAccounts.remove(account)
            knownKeychainItems[account] = .absent
            return nil
        case .failed:
            unreadableAccounts.insert(account)
            knownKeychainItems[account] = nil
            return nil
        }
    }

    func save(_ value: String, account: String) {
        unreadableAccounts.remove(account)
        if Self.isSecret(account),
           knownKeychainItems[account] == .holds(value),
           readFile()?[account] == nil {
            return
        }
        if Self.isSecret(account), storeInKeychain(value, account: account) {
            removeFromFile(account: account)
            return
        }
        // Non-secrets, and secrets the Keychain refused, go to the file so no
        // key is lost. The next launch's migration retries the Keychain.
        setFileValue(value, account: account)
    }

    func delete(account: String) {
        if Self.isSecret(account) {
            if unreadableAccounts.contains(account) {
                os_log(.error, log: keychainLog, "Keychain delete skipped: item was unreadable at load")
            } else if knownKeychainItems[account] != .absent, !deleteFromKeychain(account: account) {
                // Mask the surviving item so the cleared key does not return on
                // the next launch, where migration retries the delete.
                setFileValue("", account: account)
                return
            }
        }
        removeFromFile(account: account)
    }

    /// Moves every secret in the file into the Keychain, verifying each by
    /// reading it back before removing it from the file, and retries deletes
    /// masked by an empty value. A failed account stays in the file and is
    /// retried on the next run. An unreadable file is never rewritten.
    func migrateFileSecretsToKeychain() {
        guard var dict = readFile() else { return }
        var changed = dict.removeValue(forKey: Self.legacyMigrationMarker) != nil
        for account in dict.keys.sorted() where Self.isSecret(account) {
            guard let value = dict[account] else { continue }
            let moved = value.isEmpty
                ? deleteFromKeychain(account: account)
                : storeInKeychain(value, account: account)
            guard moved else { continue }
            dict.removeValue(forKey: account)
            changed = true
        }
        if changed || dict.isEmpty {
            writeFile(dict)
        }
    }

    private func storeInKeychain(_ value: String, account: String) -> Bool {
        knownKeychainItems[account] = nil
        let status = keychain.write(value, account: account)
        guard status == errSecSuccess else {
            os_log(.error, log: keychainLog, "Keychain write failed: OSStatus %d", status)
            return false
        }
        guard keychain.read(account: account) == .found(value) else {
            os_log(.error, log: keychainLog, "Keychain verify failed")
            return false
        }
        knownKeychainItems[account] = .holds(value)
        return true
    }

    /// True when the item is gone, including when it never existed.
    private func deleteFromKeychain(account: String) -> Bool {
        knownKeychainItems[account] = nil
        let status = keychain.delete(account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            os_log(.error, log: keychainLog, "Keychain delete failed: OSStatus %d", status)
            return false
        }
        knownKeychainItems[account] = .absent
        return true
    }

    private func setFileValue(_ value: String, account: String) {
        var dict = readFile() ?? [:]
        dict[account] = value
        writeFile(dict)
    }

    private func removeFromFile(account: String) {
        guard var dict = readFile(), dict.removeValue(forKey: account) != nil else { return }
        writeFile(dict)
    }

    // MARK: - File I/O

    /// Returns [:] when the file is absent and nil when it cannot be read or decoded.
    private func readFile() -> [String: String]? {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: settingsFileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return dict
    }

    private func writeFile(_ dict: [String: String]) {
        let fileManager = FileManager.default
        if dict.isEmpty {
            if fileManager.fileExists(atPath: settingsFileURL.path) {
                try? fileManager.removeItem(at: settingsFileURL)
            }
            return
        }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? fileManager.createDirectory(
            at: settingsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: settingsFileURL, options: [.atomic])
        // Restrict to owner-only read/write (0600)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsFileURL.path
        )
    }
}

// MARK: - App storage

/// Called on the main thread. Loads run in AppState.init, before the global
/// shortcut event tap is installed, but saves and deletes come from Settings
/// while the tap is live: a Keychain access prompt during one blocks the main
/// run loop, and the tap with it, until the prompt closes or the system
/// disables the tap for timing out. The store skips Keychain calls for
/// unchanged keys, so only a real key change can block.
enum AppSettingsStorage {
    private static let store = AppSettingsStore(
        settingsFileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppName.displayName, isDirectory: true)
            .appendingPathComponent(".settings"),
        keychain: LoginKeychain(service: Bundle.main.bundleIdentifier ?? "com.zachlatta.freeflow")
    )

    /// Runs the file-to-Keychain migration once per launch, before the first
    /// load, save or delete. Static initialization is lazy and thread-safe.
    private static let fileSecretsMigration: Void = store.migrateFileSecretsToKeychain()

    // MARK: - Public API

    static func load(account: String) -> String? {
        _ = fileSecretsMigration
        return store.load(account: account)
    }

    static func save(_ value: String, account: String) {
        _ = fileSecretsMigration
        store.save(value, account: account)
    }

    static func delete(account: String) {
        _ = fileSecretsMigration
        store.delete(account: account)
    }
}
