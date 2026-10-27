import Foundation

enum CleanupLevelTests {
    static func run() {
        testDefaultAndStorage()
        testMigrationFromPreserveExactWording()
        testSaveWritesBothKeysAndRoundTrips()
        testPromptDirectivesAndSkip()
        testUndoAIEditAvailability()
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.CleanupLevel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(CleanupLevel.defaultLevel, .light)
        TestSupport.expectEqual(CleanupLevel.storageKey, "cleanup_level")
        TestSupport.expectEqual(CleanupLevel.legacyPreserveExactWordingStorageKey, "preserve_exact_wording")
        TestSupport.expectEqual(CleanupLevel.allCases, [CleanupLevel.none, .light, .medium])
        for level in CleanupLevel.allCases {
            TestSupport.expectEqual(level.id, level.rawValue)
        }
        TestSupport.expectEqual(CleanupLevel.allCases.map(\.displayName), ["None", "Light", "Medium"])
        TestSupport.expectEqual(
            CleanupLevel.none.caption,
            "Pastes the raw transcript, including filler words, false starts, and spoken errors."
        )
        TestSupport.expectEqual(CleanupLevel.light.caption, "Removes filler words and fixes grammar.")
        TestSupport.expectEqual(
            CleanupLevel.medium.caption,
            "May reword phrases for clarity and conciseness while preserving meaning."
        )

        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)
        TestSupport.expect(
            defaults.object(forKey: CleanupLevel.storageKey) == nil,
            "Loading the default must not persist a level"
        )
        TestSupport.expect(
            defaults.object(forKey: CleanupLevel.legacyPreserveExactWordingStorageKey) == nil,
            "Loading the default must not persist the legacy toggle"
        )

        TestSupport.expectEqual(CleanupLevel.rawTranscriptCopiedStatusText, "Raw transcript copied")
        TestSupport.expect(
            !CleanupLevel.rawTranscriptCopiedStatusText.hasPrefix("Error:"),
            "Copying the raw transcript must not read as an error"
        )
    }

    /// The pre-feature toggle only matters while no level is stored.
    private static func testMigrationFromPreserveExactWording() {
        let suite = "FreeFlowTests.CleanupLevel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyKey = CleanupLevel.legacyPreserveExactWordingStorageKey

        defaults.set(true, forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), CleanupLevel.none)
        defaults.set(false, forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)
        defaults.set("invalid", forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)
        defaults.removeObject(forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)

        // A stored level wins over the legacy toggle.
        defaults.set("medium", forKey: CleanupLevel.storageKey)
        defaults.set(true, forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .medium)

        // An unknown level counts as unset and falls through to the migration rule.
        defaults.set("turbo", forKey: CleanupLevel.storageKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), CleanupLevel.none)

        // A non-string level counts as unset too.
        defaults.set(2, forKey: CleanupLevel.storageKey)
        defaults.set(false, forKey: legacyKey)
        TestSupport.expectEqual(CleanupLevel.load(from: defaults), .light)
        TestSupport.expectEqual(defaults.object(forKey: CleanupLevel.storageKey) as? Int, 2)
    }

    private static func testSaveWritesBothKeysAndRoundTrips() {
        let suite = "FreeFlowTests.CleanupLevel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        for level in CleanupLevel.allCases {
            level.save(to: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(reloaded.object(forKey: CleanupLevel.storageKey) as? String, level.rawValue)
            TestSupport.expectEqual(
                reloaded.object(forKey: CleanupLevel.legacyPreserveExactWordingStorageKey) as? Bool,
                level.skipsCleanup
            )
            TestSupport.expectEqual(CleanupLevel.load(from: reloaded), level)
        }

        CleanupLevel.none.save(to: defaults)
        TestSupport.expectEqual(defaults.object(forKey: CleanupLevel.legacyPreserveExactWordingStorageKey) as? Bool, true)
        CleanupLevel.light.save(to: defaults)
        TestSupport.expectEqual(
            defaults.object(forKey: CleanupLevel.legacyPreserveExactWordingStorageKey) as? Bool,
            false
        )
    }

    private static func testPromptDirectivesAndSkip() {
        TestSupport.expect(CleanupLevel.none.skipsCleanup, "None must skip the cleanup model")
        TestSupport.expect(!CleanupLevel.light.skipsCleanup, "Light must run the cleanup model")
        TestSupport.expect(!CleanupLevel.medium.skipsCleanup, "Medium must run the cleanup model")

        TestSupport.expect(CleanupLevel.none.promptDirective == nil, "None never reaches the model")

        guard let light = CleanupLevel.light.promptDirective,
              let medium = CleanupLevel.medium.promptDirective else {
            TestSupport.expect(false, "Light and Medium must each have a directive")
            return
        }
        TestSupport.expect(light.hasPrefix("Cleanup level: Light"), "Light directive must name its level")
        TestSupport.expect(light.contains("do not reword"), "Light must forbid rewording")
        TestSupport.expect(!light.contains("\n"), "Light directive must be a single line")
        TestSupport.expect(medium.hasPrefix("Cleanup level: Medium"), "Medium directive must name its level")
        TestSupport.expect(
            medium.contains("reword phrases for clarity and conciseness while preserving meaning"),
            "Medium must allow rewording"
        )
        TestSupport.expect(!medium.contains("\n"), "Medium directive must be a single line")
        TestSupport.expect(light != medium, "Light and Medium must differ")
    }

    /// Synthetic rows only. The predicate is shared by the Run Log row and
    /// `AppState.undoAIEdit`, so it is pinned here.
    private static func testUndoAIEditAvailability() {
        func item(
            intent: PipelineHistoryItemIntent = .dictation,
            raw: String,
            cleaned: String
        ) -> PipelineHistoryItem {
            PipelineHistoryItem(
                intent: intent,
                timestamp: Date(),
                rawTranscript: raw,
                postProcessedTranscript: cleaned,
                postProcessingPrompt: nil,
                contextSummary: "synthetic context",
                contextScreenshotDataURL: nil,
                contextScreenshotStatus: "No screenshot",
                postProcessingStatus: "synthetic status",
                debugStatus: "Done",
                customVocabulary: ""
            )
        }

        TestSupport.expect(
            item(raw: "synthetic raw um transcript", cleaned: "Synthetic raw transcript.").canUndoAIEdit,
            "A cleaned dictation can be undone"
        )
        TestSupport.expect(
            !item(raw: "synthetic transcript", cleaned: "synthetic transcript").canUndoAIEdit,
            "An unchanged dictation has nothing to undo"
        )
        TestSupport.expect(
            !item(raw: "  synthetic  ", cleaned: "synthetic").canUndoAIEdit,
            "Whitespace-only differences have nothing to undo"
        )
        TestSupport.expect(
            !item(raw: "", cleaned: "Synthetic.").canUndoAIEdit,
            "An empty raw transcript cannot be restored"
        )
        TestSupport.expect(
            !item(intent: .commandAutomatic, raw: "make it shorter", cleaned: "Synthetic shorter text.").canUndoAIEdit,
            "An Edit Mode row stores the spoken command, not a dictation"
        )
    }
}
