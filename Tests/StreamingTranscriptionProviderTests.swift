import Foundation

enum StreamingTranscriptionProviderTests {
    static func run() {
        testDefaultAndStorage()
        testMigrationFromRealtimeToggle()
        testSaveWritesBothKeysAndRoundTrips()
        testStreamSampleRates()
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
        TestSupport.expectEqual(StreamingTranscriptionProvider.allCases, [.off, .openAIRealtime, .deepgram, .assemblyAI])
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.rawValue), ["off", "openAIRealtime", "deepgram", "assemblyAI"]
        )
        for provider in StreamingTranscriptionProvider.allCases {
            TestSupport.expectEqual(provider.id, provider.rawValue)
        }
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.displayName),
            ["Off", "OpenAI Realtime", "Deepgram", "AssemblyAI Universal-3 Pro"]
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
            "Deepgram Nova-3 transcribes while you talk, so the text is ready when you release the key. Your custom vocabulary and corrections are sent as key terms. With Context Awareness on, so are your Mac account name, visible code names in Cursor, Windsurf and VS Code, and names on screen in the Claude Code panel, ChatGPT in Chrome or the ChatGPT app, and Google search in Chrome."
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.assemblyAI.caption,
            "AssemblyAI Universal-3 Pro transcribes while you talk, so the text is ready when you release the key. It receives your audio only while you dictate, your custom vocabulary and correction targets as key terms, and for English a short fixed description of the dictation (with Context Awareness on, of the kind of app you are dictating into, such as email or an AI chat). With Context Awareness on, it also gets the names Deepgram gets as key terms (your Mac account name, visible code names in Cursor, Windsurf and VS Code, and names on screen in the Claude Code panel, ChatGPT in Chrome or the ChatGPT app, and Google search in Chrome); never field text, window titles or URLs. For zero data retention, turn off model training in AssemblyAI's dashboard (paid plans only)."
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.usesRealtimeStreamingModel),
            [false, true, false, false]
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.usesContextKeyterms),
            [false, false, true, true]
        )
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.assemblyAIMissingKeyWarning,
            "Add an AssemblyAI API key to stream audio. Until then, audio is uploaded after you release the shortcut."
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

        defaults.set("assemblyAI", forKey: StreamingTranscriptionProvider.storageKey)
        TestSupport.expectEqual(StreamingTranscriptionProvider.load(from: defaults), .assemblyAI)

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
        StreamingTranscriptionProvider.openAIRealtime.save(to: defaults)
        StreamingTranscriptionProvider.assemblyAI.save(to: defaults)
        TestSupport.expectEqual(defaults.object(forKey: StreamingTranscriptionProvider.storageKey) as? String, "assemblyAI")
        TestSupport.expectEqual(defaults.object(forKey: legacyKey) as? Bool, false)
    }

    /// OpenAI accepts 24 kHz PCM only; Deepgram and AssemblyAI get the same 16 kHz samples as the WAV.
    private static func testStreamSampleRates() {
        TestSupport.expectEqual(StreamingTranscriptionProvider.openAIRealtimeSampleRate, 24_000)
        TestSupport.expectEqual(StreamingTranscriptionProvider.deepgramSampleRate, 16_000)
        TestSupport.expectEqual(StreamingTranscriptionProvider.assemblyAISampleRate, 16_000)
        TestSupport.expectEqual(
            StreamingTranscriptionProvider.allCases.map(\.streamSampleRate), [nil, 24_000, 16_000, 16_000]
        )
        TestSupport.expectEqual(
            DeepgramStreamingCore.maxPendingAudioBytes(sampleRate: StreamingTranscriptionProvider.deepgramSampleRate),
            320_000
        )
    }
}
