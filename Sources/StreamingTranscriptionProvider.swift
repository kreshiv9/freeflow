import Foundation

/// Which service, if any, hears audio while the shortcut is held. `.off` uploads the
/// file after release. Replaces the realtime toggle; `save` keeps writing that legacy
/// key so an older build behaves the same.
enum StreamingTranscriptionProvider: String, CaseIterable, Identifiable {
    case off
    case openAIRealtime
    case deepgram

    var id: String { rawValue }

    static let defaultProvider: StreamingTranscriptionProvider = .off
    static let storageKey = "streaming_transcription_provider"
    /// The pre-feature toggle: read only when no provider is stored, always written by `save`.
    static let legacyRealtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"

    var displayName: String {
        switch self {
        case .off: "Off"
        case .openAIRealtime: "OpenAI Realtime"
        case .deepgram: "Deepgram"
        }
    }

    /// Shown under the Settings picker.
    var caption: String {
        switch self {
        case .off:
            "Audio is uploaded for transcription after you release the shortcut."
        case .openAIRealtime:
            "Streams audio through the provider's OpenAI-compatible /v1/realtime WebSocket so transcription runs while you speak."
        case .deepgram:
            "Deepgram Nova-3 transcribes while you talk, so the text is ready when you release the key. Your custom vocabulary, corrections and, in Cursor, Windsurf and VS Code, visible code names are sent as key terms."
        }
    }

    /// The Realtime Transcription Model field only applies to the OpenAI-compatible socket.
    var usesRealtimeStreamingModel: Bool { self == .openAIRealtime }

    /// Inline warning while Deepgram is selected without a key; pinned by tests.
    static let deepgramMissingKeyWarning = "Add a Deepgram API key to stream audio. Until then, audio is uploaded after you release the shortcut."

    /// A stored provider wins. Otherwise the legacy toggle migrates: true -> `.openAIRealtime`,
    /// anything else -> `.off`. An invalid or non-string value counts as unset. Never persists.
    static func load(from defaults: UserDefaults) -> StreamingTranscriptionProvider {
        if let raw = defaults.object(forKey: storageKey) as? String,
           let provider = StreamingTranscriptionProvider(rawValue: raw) {
            return provider
        }
        let legacyEnabled = defaults.object(forKey: legacyRealtimeStreamingEnabledStorageKey) as? Bool
        return legacyEnabled == true ? .openAIRealtime : defaultProvider
    }

    /// Writes the provider and mirrors `self == .openAIRealtime` into the legacy toggle for older builds.
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
        defaults.set(self == .openAIRealtime, forKey: Self.legacyRealtimeStreamingEnabledStorageKey)
    }
}

/// One recording's streaming session as AppState drives it: started before the
/// recorder, fed `onPCM16Samples` chunks, committed on stop. Any thrown error
/// from the commit makes resolveRawTranscript fall back to the file upload.
/// Class-bound so AppState's `[weak service]` capture keeps working.
protocol StreamingTranscriptionSession: AnyObject {
    /// PipelineStageTimings source label recorded by resolveRawTranscript.
    var transcriptionSource: String { get }
    func start() throws
    func appendPCM16(_ data: Data)
    func commitAndAwaitFinal() async throws -> String
    func cancel()
}
