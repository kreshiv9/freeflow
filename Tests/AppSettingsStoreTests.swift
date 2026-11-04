import Foundation
import Security

/// In-memory stand-in for the login Keychain. Never touches the real Keychain.
private final class FakeKeychain: SecretKeychain {
    var items: [String: String] = [:]
    /// Accounts whose writes fail outright.
    var failingWrites: Set<String> = []
    /// Accounts whose writes report success but store nothing, so only the
    /// read-back can catch them.
    var droppedWrites: Set<String> = []
    /// Accounts whose reads fail, as after a denied access prompt.
    var failingReads: Set<String> = []
    /// Accounts whose deletes fail and leave the item in place.
    var failingDeletes: Set<String> = []
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0

    /// Every call that would reach securityd in the real Keychain.
    var callCount: Int { readCount + writeCount + deleteCount }

    func read(account: String) -> KeychainReadResult {
        readCount += 1
        if failingReads.contains(account) { return .failed(errSecAuthFailed) }
        guard let value = items[account] else { return .notFound }
        return .found(value)
    }

    func write(_ value: String, account: String) -> OSStatus {
        writeCount += 1
        if failingWrites.contains(account) { return errSecIO }
        if droppedWrites.contains(account) { return errSecSuccess }
        items[account] = value
        return errSecSuccess
    }

    func delete(account: String) -> OSStatus {
        deleteCount += 1
        if failingDeletes.contains(account) { return errSecAuthFailed }
        return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
    }
}

/// Synthetic keys and URLs in a temporary directory only; never the user's
/// `.settings` file or Keychain.
enum AppSettingsStoreTests {
    private static let groq = "groq_api_key"
    private static let transcription = "transcription_api_key"
    private static let deepgram = "deepgram_api_key"
    /// The account AppState uses, so the test covers the app's real key path.
    private static let assemblyAI = AssemblyAIStreamingCore.apiKeyAccount
    private static let baseURL = "api_base_url"
    private static let transcriptionURL = "transcription_api_url"

    static func run() {
        testSecretClassification()
        testMigrationMovesSecretsAndDeletesEmptyFile()
        testMigrationKeepsNonSecretEntries()
        testFailedKeychainWriteKeepsFileValue()
        testFailedVerificationKeepsFileValue()
        testMigrationIsNoOpWhenAlreadyMigrated()
        testUnreadableFileIsLeftUntouched()
        testFileValueWinsOverStaleKeychainItem()
        testSaveAndDeleteRouteByAccount()
        testSaveFallsBackToFileWhenKeychainFails()
        testSaveSupersedesFileFallback()
        testDeleteRemovesBothCopies()
        testFailedDeleteMasksSurvivingItem()
        testDeleteKeepsItemThatFailedToLoad()
        testSaveLiftsUnreadableDeleteProtection()
        testUnchangedSaveSkipsKeychain()
        testSaveWithFileCopyStillWritesKeychain()
        testFailedReadForgetsKnownKeychainValue()
        testAssemblyAIKeyGoesToKeychain()
    }

    private static func testSecretClassification() {
        TestSupport.expectEqual(assemblyAI, "assemblyai_api_key")
        for account in [groq, transcription, deepgram, assemblyAI] {
            TestSupport.expect(AppSettingsStore.isSecret(account), "\(account) must be stored as a secret")
        }
        for account in [baseURL, transcriptionURL] {
            TestSupport.expect(!AppSettingsStore.isSecret(account), "\(account) must stay in the settings file")
        }
    }

    private static func testMigrationMovesSecretsAndDeletesEmptyFile() {
        withStore { store, keychain in
            writeSettingsFile([
                groq: "synthetic-groq-key",
                transcription: "synthetic-transcription-key",
                deepgram: "synthetic-deepgram-key",
                AppSettingsStore.legacyMigrationMarker: "true"
            ], for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [
                groq: "synthetic-groq-key",
                transcription: "synthetic-transcription-key",
                deepgram: "synthetic-deepgram-key"
            ])
            TestSupport.expect(!settingsFileExists(store), "An emptied settings file must be deleted")
        }
    }

    private static func testMigrationKeepsNonSecretEntries() {
        withStore { store, keychain in
            writeSettingsFile([
                groq: "synthetic-groq-key",
                baseURL: "https://provider.invalid/v1",
                transcriptionURL: "https://provider.invalid/v1/audio/transcriptions",
                AppSettingsStore.legacyMigrationMarker: "true"
            ], for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expectEqual(readSettingsFile(store), [
                baseURL: "https://provider.invalid/v1",
                transcriptionURL: "https://provider.invalid/v1/audio/transcriptions"
            ])
            let attributes = try? FileManager.default.attributesOfItem(atPath: store.settingsFileURL.path)
            TestSupport.expectEqual(attributes?[.posixPermissions] as? Int, 0o600)
        }
    }

    private static func testFailedKeychainWriteKeepsFileValue() {
        withStore { store, keychain in
            keychain.failingWrites = [deepgram]
            writeSettingsFile([
                groq: "synthetic-groq-key",
                deepgram: "synthetic-deepgram-key"
            ], for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expectEqual(readSettingsFile(store), [deepgram: "synthetic-deepgram-key"])
            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-deepgram-key")
            TestSupport.expectEqual(store.load(account: groq), "synthetic-groq-key")
        }
    }

    private static func testFailedVerificationKeepsFileValue() {
        withStore { store, keychain in
            keychain.droppedWrites = [groq]
            writeSettingsFile([groq: "synthetic-groq-key"], for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.writeCount, 1)
            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expectEqual(readSettingsFile(store), [groq: "synthetic-groq-key"])
            TestSupport.expectEqual(store.load(account: groq), "synthetic-groq-key")
        }
    }

    private static func testMigrationIsNoOpWhenAlreadyMigrated() {
        withStore { store, keychain in
            keychain.items = [groq: "synthetic-groq-key"]

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.writeCount, 0)
            TestSupport.expect(!settingsFileExists(store), "Migration must not create a settings file")
            TestSupport.expectEqual(store.load(account: groq), "synthetic-groq-key")
        }

        withStore { store, keychain in
            writeSettingsFile([
                baseURL: "https://provider.invalid/v1",
                transcriptionURL: "https://provider.invalid/v1/audio/transcriptions"
            ], for: store)
            let before = try? Data(contentsOf: store.settingsFileURL)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.writeCount, 0)
            TestSupport.expect(before != nil, "Synthetic settings file must be readable")
            TestSupport.expectEqual(try? Data(contentsOf: store.settingsFileURL), before)
        }
    }

    private static func testUnreadableFileIsLeftUntouched() {
        withStore { store, keychain in
            let malformed = Data("synthetic-not-json {".utf8)
            writeRawSettingsFile(malformed, for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.writeCount, 0)
            TestSupport.expectEqual(try? Data(contentsOf: store.settingsFileURL), malformed)
        }
    }

    private static func testFileValueWinsOverStaleKeychainItem() {
        withStore { store, keychain in
            keychain.items = [groq: "synthetic-stale"]
            writeSettingsFile([groq: "synthetic-fresh"], for: store)

            TestSupport.expectEqual(store.load(account: groq), "synthetic-fresh")

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [groq: "synthetic-fresh"])
            TestSupport.expect(!settingsFileExists(store), "An emptied settings file must be deleted")
            TestSupport.expectEqual(store.load(account: groq), "synthetic-fresh")
        }
    }

    private static func testSaveAndDeleteRouteByAccount() {
        withStore { store, keychain in
            store.save("synthetic-groq-key", account: groq)
            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expect(!settingsFileExists(store), "A saved secret must not be written to the file")
            TestSupport.expectEqual(store.load(account: groq), "synthetic-groq-key")

            store.save("https://provider.invalid/v1", account: baseURL)
            TestSupport.expectEqual(readSettingsFile(store), [baseURL: "https://provider.invalid/v1"])
            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expectEqual(store.load(account: baseURL), "https://provider.invalid/v1")

            store.delete(account: groq)
            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expectEqual(store.load(account: groq), nil)

            store.delete(account: baseURL)
            TestSupport.expect(!settingsFileExists(store), "Deleting the last file entry must delete the file")
            TestSupport.expectEqual(store.load(account: baseURL), nil)
        }
    }

    private static func testSaveFallsBackToFileWhenKeychainFails() {
        withStore { store, keychain in
            keychain.failingWrites = [deepgram]

            store.save("synthetic-deepgram-key", account: deepgram)

            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expectEqual(readSettingsFile(store), [deepgram: "synthetic-deepgram-key"])
            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-deepgram-key")

            keychain.failingWrites = []
            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [deepgram: "synthetic-deepgram-key"])
            TestSupport.expect(!settingsFileExists(store), "A migrated fallback file must be deleted")
            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-deepgram-key")
        }
    }

    private static func testSaveSupersedesFileFallback() {
        withStore { store, keychain in
            keychain.failingWrites = [deepgram]
            store.save("synthetic-old", account: deepgram)
            TestSupport.expectEqual(readSettingsFile(store), [deepgram: "synthetic-old"])

            keychain.failingWrites = []
            store.save("synthetic-new", account: deepgram)

            TestSupport.expectEqual(keychain.items, [deepgram: "synthetic-new"])
            TestSupport.expect(!settingsFileExists(store), "A Keychain save must remove the fallback file copy")
            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-new")

            store.migrateFileSecretsToKeychain()
            TestSupport.expectEqual(keychain.items, [deepgram: "synthetic-new"])
        }
    }

    private static func testDeleteRemovesBothCopies() {
        withStore { store, keychain in
            keychain.items = [groq: "synthetic-stale"]
            writeSettingsFile([groq: "synthetic-fresh"], for: store)

            store.delete(account: groq)

            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expect(!settingsFileExists(store), "Deleting the only entry must delete the file")
            TestSupport.expectEqual(store.load(account: groq), nil)
        }
    }

    private static func testFailedDeleteMasksSurvivingItem() {
        withStore { store, keychain in
            keychain.items = [deepgram: "synthetic-deepgram-key"]
            keychain.failingDeletes = [deepgram]

            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-deepgram-key")
            store.delete(account: deepgram)

            TestSupport.expectEqual(keychain.items, [deepgram: "synthetic-deepgram-key"])
            TestSupport.expectEqual(readSettingsFile(store), [deepgram: ""])
            TestSupport.expectEqual(store.load(account: deepgram), "")

            // The next launch retries the delete; a repeat failure keeps the mask.
            store.migrateFileSecretsToKeychain()
            TestSupport.expectEqual(readSettingsFile(store), [deepgram: ""])
            TestSupport.expectEqual(store.load(account: deepgram), "")

            keychain.failingDeletes = []
            store.migrateFileSecretsToKeychain()
            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expect(!settingsFileExists(store), "A retried delete must drop the mask and the empty file")
            TestSupport.expectEqual(store.load(account: deepgram), nil)
        }
    }

    private static func testDeleteKeepsItemThatFailedToLoad() {
        withStore { store, keychain in
            keychain.items = [transcription: "synthetic-transcription-key"]
            keychain.failingReads = [transcription]

            TestSupport.expectEqual(store.load(account: transcription), nil)
            store.delete(account: transcription)

            TestSupport.expectEqual(keychain.items, [transcription: "synthetic-transcription-key"])
            TestSupport.expect(!settingsFileExists(store), "A skipped delete must not write the file")

            keychain.failingReads = []
            TestSupport.expectEqual(store.load(account: transcription), "synthetic-transcription-key")
            store.delete(account: transcription)
            TestSupport.expectEqual(keychain.items, [:])
        }
    }

    private static func testSaveLiftsUnreadableDeleteProtection() {
        withStore { store, keychain in
            keychain.items = [groq: "synthetic-old"]
            keychain.failingReads = [groq]

            TestSupport.expectEqual(store.load(account: groq), nil)
            keychain.failingWrites = [groq]
            store.save("synthetic-new", account: groq)
            TestSupport.expectEqual(readSettingsFile(store), [groq: "synthetic-new"])

            store.delete(account: groq)

            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expect(!settingsFileExists(store), "Deleting a saved key must remove its file copy")
        }
    }

    /// Settings saves every API value at once. Values the store already knows
    /// the Keychain holds, or knows it lacks, must not call the Keychain, since
    /// a Keychain prompt on the main thread stalls the shortcut event tap.
    private static func testUnchangedSaveSkipsKeychain() {
        withStore { store, keychain in
            keychain.items = [groq: "synthetic-groq-key"]
            TestSupport.expectEqual(store.load(account: groq), "synthetic-groq-key")
            TestSupport.expectEqual(store.load(account: transcription), nil)
            let afterLoad = keychain.callCount

            store.save("synthetic-groq-key", account: groq)
            store.delete(account: transcription)
            store.save("https://provider.invalid/v1", account: baseURL)

            TestSupport.expectEqual(keychain.callCount, afterLoad)
            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expectEqual(readSettingsFile(store), [baseURL: "https://provider.invalid/v1"])

            store.save("synthetic-groq-key-2", account: groq)
            TestSupport.expectEqual(keychain.writeCount, 1)
            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key-2"])

            let afterChange = keychain.callCount
            store.save("synthetic-groq-key-2", account: groq)
            TestSupport.expectEqual(keychain.callCount, afterChange)

            store.delete(account: groq)
            TestSupport.expectEqual(keychain.deleteCount, 1)
            TestSupport.expectEqual(keychain.items, [:])

            let afterDelete = keychain.callCount
            store.delete(account: groq)
            TestSupport.expectEqual(keychain.callCount, afterDelete)
            TestSupport.expectEqual(store.load(account: groq), nil)
        }
    }

    private static func testSaveWithFileCopyStillWritesKeychain() {
        withStore { store, keychain in
            store.save("synthetic-groq-key", account: groq)
            TestSupport.expectEqual(keychain.writeCount, 1)
            writeSettingsFile([groq: "synthetic-groq-key"], for: store)

            store.save("synthetic-groq-key", account: groq)

            TestSupport.expectEqual(keychain.writeCount, 2)
            TestSupport.expectEqual(keychain.items, [groq: "synthetic-groq-key"])
            TestSupport.expect(!settingsFileExists(store), "A Keychain save must remove a leftover file copy")
        }
    }

    private static func testFailedReadForgetsKnownKeychainValue() {
        withStore { store, keychain in
            keychain.items = [deepgram: "synthetic-deepgram-key"]
            TestSupport.expectEqual(store.load(account: deepgram), "synthetic-deepgram-key")
            keychain.failingReads = [deepgram]
            TestSupport.expectEqual(store.load(account: deepgram), nil)
            keychain.failingReads = []
            keychain.items = [:]

            store.save("synthetic-deepgram-key", account: deepgram)

            TestSupport.expectEqual(keychain.writeCount, 1)
            TestSupport.expectEqual(keychain.items, [deepgram: "synthetic-deepgram-key"])
        }
    }

    // MARK: - Helpers

    /// The AssemblyAI key takes the secret path: the Keychain, never the plain settings file.
    private static func testAssemblyAIKeyGoesToKeychain() {
        withStore { store, keychain in
            store.save("synthetic-assemblyai-key", account: assemblyAI)
            TestSupport.expectEqual(keychain.items, [assemblyAI: "synthetic-assemblyai-key"])
            TestSupport.expect(!settingsFileExists(store), "The AssemblyAI key must not be written to the settings file")
            TestSupport.expectEqual(store.load(account: assemblyAI), "synthetic-assemblyai-key")

            store.delete(account: assemblyAI)
            TestSupport.expectEqual(keychain.items, [:])
            TestSupport.expectEqual(store.load(account: assemblyAI), nil)
        }
        withStore { store, keychain in
            writeSettingsFile([assemblyAI: "synthetic-assemblyai-key"], for: store)

            store.migrateFileSecretsToKeychain()

            TestSupport.expectEqual(keychain.items, [assemblyAI: "synthetic-assemblyai-key"])
            TestSupport.expect(!settingsFileExists(store), "A migrated AssemblyAI key must leave no settings file")
        }
    }

    private static func withStore(_ body: (AppSettingsStore, FakeKeychain) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("freeflow-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = FakeKeychain()
        let store = AppSettingsStore(
            settingsFileURL: directory.appendingPathComponent(".settings"),
            keychain: keychain
        )
        body(store, keychain)
    }

    private static func writeSettingsFile(_ dict: [String: String], for store: AppSettingsStore) {
        guard let data = try? JSONEncoder().encode(dict) else {
            fatalError("Could not encode synthetic settings")
        }
        writeRawSettingsFile(data, for: store)
    }

    private static func writeRawSettingsFile(_ data: Data, for store: AppSettingsStore) {
        do {
            try FileManager.default.createDirectory(
                at: store.settingsFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: store.settingsFileURL)
        } catch {
            fatalError("Could not write synthetic settings file")
        }
    }

    private static func readSettingsFile(_ store: AppSettingsStore) -> [String: String]? {
        guard let data = try? Data(contentsOf: store.settingsFileURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private static func settingsFileExists(_ store: AppSettingsStore) -> Bool {
        FileManager.default.fileExists(atPath: store.settingsFileURL.path)
    }
}
