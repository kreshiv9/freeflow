import Foundation

enum AIAppRawTranscriptPreferenceTests {
    static func run() {
        testDefaultAndStorage()
        testDecisionTable()
        testCategoryResolution()
        testRunLogStatuses()
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.AIAppRawTranscript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expect(AIAppRawTranscriptPreference.defaultEnabled, "Raw pasting in AI apps must default to on")
        TestSupport.expectEqual(AIAppRawTranscriptPreference.storageKey, "ai_apps_raw_transcript_enabled")
        TestSupport.expect(AIAppRawTranscriptPreference.load(from: defaults), "A missing preference must keep raw pasting on")
        TestSupport.expect(defaults.object(forKey: AIAppRawTranscriptPreference.storageKey) == nil, "Loading the default must not persist a choice")

        for enabled in [true, false] {
            defaults.set(enabled, forKey: AIAppRawTranscriptPreference.storageKey)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(AIAppRawTranscriptPreference.load(from: reloaded), enabled)
            TestSupport.expectEqual(reloaded.object(forKey: AIAppRawTranscriptPreference.storageKey) as? Bool, enabled)
        }

        defaults.set("invalid", forKey: AIAppRawTranscriptPreference.storageKey)
        TestSupport.expect(AIAppRawTranscriptPreference.load(from: defaults), "An invalid saved value must default to on")

        defaults.removeObject(forKey: AIAppRawTranscriptPreference.storageKey)
        TestSupport.expect(AIAppRawTranscriptPreference.load(from: defaults), "Removing a saved choice must restore on")
    }

    /// Raw pasting applies only to plain dictation into an AI chat with the
    /// setting on; every other combination keeps the regular cleanup.
    private static func testDecisionTable() {
        let categories: [DictationAppCategory?] = [
            .aiChat, .coding, .email, .workMessaging, .personalMessaging, .other, nil
        ]
        for enabled in [true, false] {
            for category in categories {
                for isCommandMode in [true, false] {
                    TestSupport.expectEqual(
                        AIAppRawTranscriptPreference.shouldPasteRawTranscript(
                            enabled: enabled,
                            category: category,
                            isCommandMode: isCommandMode
                        ),
                        enabled && category == .aiChat && !isCommandMode
                    )
                }
            }
        }

        TestSupport.expect(
            AIAppRawTranscriptPreference.shouldPasteRawTranscript(enabled: true, category: .aiChat, isCommandMode: false),
            "A plain dictation into an AI chat is pasted raw when the setting is on"
        )
        TestSupport.expect(
            !AIAppRawTranscriptPreference.shouldPasteRawTranscript(enabled: true, category: .aiChat, isCommandMode: true),
            "Edit Mode is never affected"
        )
        TestSupport.expect(
            !AIAppRawTranscriptPreference.shouldPasteRawTranscript(enabled: false, category: .aiChat, isCommandMode: false),
            "With the setting off, an AI chat still gets cleanup"
        )
        TestSupport.expect(
            !AIAppRawTranscriptPreference.shouldPasteRawTranscript(enabled: true, category: .coding, isCommandMode: false),
            "Claude Code in a terminal keeps cleanup"
        )
    }

    /// Synthetic bundle identifiers and domains only. Text context wins over
    /// the recording-start bundle identifier, which remains the fallback for
    /// desktop AI apps when no text context arrived.
    private static func testCategoryResolution() {
        let browserChat = TextContextSnapshot(
            bundleIdentifier: "com.apple.Safari",
            category: .aiChat,
            websiteDomain: "chatgpt.com"
        )
        TestSupport.expectEqual(
            AIAppRawTranscriptPreference.resolvedCategory(textContext: browserChat, bundleIdentifier: "com.apple.Safari"),
            .aiChat
        )
        TestSupport.expectEqual(
            TextContextCore.category(bundleIdentifier: "com.apple.Safari", websiteDomain: nil),
            .other
        )

        let codingContext = TextContextSnapshot(bundleIdentifier: "com.openai.chat", category: .coding)
        TestSupport.expectEqual(
            AIAppRawTranscriptPreference.resolvedCategory(textContext: codingContext, bundleIdentifier: "com.openai.chat"),
            .coding
        )

        let bundleFallbacks: [(bundleIdentifier: String, category: DictationAppCategory)] = [
            ("com.anthropic.claudefordesktop", .aiChat),
            ("com.openai.chat", .aiChat),
            ("com.apple.Terminal", .coding),
            ("com.googlecode.iterm2", .coding),
            ("com.apple.Safari", .other)
        ]
        for fallback in bundleFallbacks {
            TestSupport.expectEqual(
                AIAppRawTranscriptPreference.resolvedCategory(textContext: nil, bundleIdentifier: fallback.bundleIdentifier),
                fallback.category
            )
        }

        let unknown = AIAppRawTranscriptPreference.resolvedCategory(textContext: nil, bundleIdentifier: nil)
        TestSupport.expectEqual(unknown, .other)
        TestSupport.expect(
            !AIAppRawTranscriptPreference.shouldPasteRawTranscript(enabled: true, category: unknown, isCommandMode: false),
            "An unknown app still gets cleanup"
        )

        let terminalContext = TextContextSnapshot(bundleIdentifier: "com.apple.Terminal", category: .coding)
        TestSupport.expect(
            !AIAppRawTranscriptPreference.shouldPasteRawTranscript(
                enabled: true,
                category: AIAppRawTranscriptPreference.resolvedCategory(textContext: terminalContext, bundleIdentifier: "com.apple.Terminal"),
                isCommandMode: false
            ),
            "A terminal text context keeps cleanup even with the setting on"
        )
    }

    /// The Run Log renders the stored processing status verbatim and keys its
    /// error and silence-gate rows on specific strings, so the wording is
    /// pinned here. The stop path that writes it needs live capture and is
    /// covered by the manual test.
    private static func testRunLogStatuses() {
        TestSupport.expectEqual(AIAppRawTranscriptPreference.rawTranscriptProcessingStatus, "Raw transcript (AI app)")
        TestSupport.expectEqual(
            AIAppRawTranscriptPreference.translatedProcessingStatus,
            "Raw transcript (AI app), translated to output language"
        )
        for status in [
            AIAppRawTranscriptPreference.rawTranscriptProcessingStatus,
            AIAppRawTranscriptPreference.translatedProcessingStatus
        ] {
            TestSupport.expect(!status.hasPrefix("Error:"), "A raw AI-app dictation must not render as an error row")
            TestSupport.expect(
                status != SilenceGatePreference.skippedProcessingStatus,
                "A raw AI-app dictation must not render as a silence-gated row"
            )
        }
    }
}
