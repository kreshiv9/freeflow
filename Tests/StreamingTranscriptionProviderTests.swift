import Foundation

enum StreamingTranscriptionProviderTests {
    static func run() {
        testDefaultAndStorage()
        testMigrationFromRealtimeToggle()
        testSaveWritesBothKeysAndRoundTrips()
    }

    private static func testDefaultAndStorage() {
        let suite = "FreeFlowTests.StreamingTranscriptionProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(StreamingTranscriptionProvider.defaultProvider, .off)
        TestSupport.expectEqual(StreamingTranscriptionProvider.storageKey, "streaming_transcription_provider")
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.legacyRealtimeStreamingEnabledStorageKey,
            "realtime_streaming_enabled"
        )
        TestSupport.expectEqual(StreamingTranscriptionProvider.allCases, [.off, .openAIRealtime, .deepgram])
        TestSupport.expectEqual(StreamingTranscriptionProvider.allCases.map(\.rawValue), ["off", "openAIRealtime", "deepgram"])
        for provider in StreamingTranscriptionProvider.allCases {
            TestSupport.expectEqual(provider.id, provider.rawValue)
        }
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.displayName),
            ["Off", "OpenAI Realtime", "Deepgram"]
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.off.caption,
            "Audio is uploaded for transcription after you release the shortcut."
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.openAIRealtime.caption,
            "Streams audio through the provider's OpenAI-compatible /v1/realtime WebSocket so transcription runs while you speak."
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.deepgram.caption,
            "Deepgram Nova-3 transcribes while you talk, so the text is ready when you release the key. Your custom vocabulary and corrections are sent as key terms."
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.usesRealtimeStreamingModel),
            [false, true, false]
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.deepgramMissingKeyWarning,
            "Add a Deepgram API key to stream audio. Until then, audio is uploaded after you release the shortcut."
        )

        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .off)
        TestSupport.expect(
            defaults.object(forKey: StreamingTranscriptionProvider.storageKey) == nil,
            "Loading the default must not persist a provider"
        )
        TestSupport.expect(
            defaults.object(forKey: StreamingTranscriptionProvider.legacyRealtimeStreamingEnabledStorageKey) == nil,
            "Loading the default must not persist the legacy toggle"
        )
    }

    /// The pre-feature toggle only matters while no provider is stored.
    private static func testMigrationFromRealtimeToggle() {
        let suite = "FreeFlowTests.StreamingTranscriptionProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyKey = StreamingTranscriptionProvider.legacyRealtimeStreamingEnabledStorageKey

        defaults.set(true, forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .openAIRealtime)
        defaults.set(false, forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .off)
        defaults.set("invalid", forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .off)
        defaults.removeObject(forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .off)

        // A stored provider wins over the legacy toggle.
        defaults.set("deepgram", forKey: StreamingTranscriptionProvider.storageKey)
        defaults.set(true, forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .deepgram)

        // An unknown provider counts as unset and falls through to the migration rule.
        defaults.set("turbo", forKey: StreamingTranscriptionProvider.storageKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .openAIRealtime)

        // A non-string provider counts as unset too.
        defaults.set(2, forKey: StreamingTranscriptionProvider.storageKey)
        defaults.set(false, forKey: legacyKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .off)
        TestSupport.expectEqual(defaults.object(forKey: StreamingTranscriptionProvider.storageKey) as? Int, 2)
    }

    private static func testSaveWritesBothKeysAndRoundTrips() {
        let suite = "FreeFlowTests.StreamingTranscriptionProvider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyKey = StreamingTranscriptionProvider.legacyRealtimeStreamingEnabledStorageKey

        for provider in StreamingTranscriptionProvider.allCases {
            provider.save(to: defaults)
            let reloaded = UserDefaults(suiteName: suite)!
            TestSupport.expectEqual(
                reloaded.object(forKey: StreamingTranscriptionProvider.storageKey) as? String,
                provider.rawValue
            )
            TestSupport.expectEqual(reloaded.object(forKey: legacyKey) as? Bool, provider == .openAIRealtime)
            TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: reloaded), provider)
        }

        StreamingTranscriptionProvider.openAIRealtime.save(to: defaults)
        TestSupport.expectEqual(defaults.object(forKey: legacyKey) as? Bool, true)
        StreamingTranscriptionProvider.deepgram.save(to: defaults)
        TestSupport.expectEqual(defaults.object(forKey: legacyKey) as? Bool, false)
    }
}
