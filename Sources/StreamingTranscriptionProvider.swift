import Foundation

/// Which service, if any, hears audio while the shortcut is held. `.off` uploads the
/// file after release. Replaces the realtime toggle; `save` keeps writing that legacy
/// key so an older build behaves the same.
enum StreamingTranscriptionProvider: String, CaseIterable, Identifiable {
    case off
    case openAIRealtime
    case deepgram
    case assemblyAI

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
        case .assemblyAI: "AssemblyAI Universal-3 Pro"
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
            "Deepgram Nova-3 transcribes while you talk, so the text is ready when you release the key. Your custom vocabulary and corrections are sent as key terms. With Context Awareness on, so are your Mac account name, visible code names in Cursor, Windsurf and VS Code, and names on screen in the Claude Code panel, ChatGPT in Chrome or the ChatGPT app, and Google search in Chrome."
        case .assemblyAI:
            "AssemblyAI Universal-3 Pro transcribes while you talk, so the text is ready when you release the key. It receives your audio only while you dictate, your custom vocabulary and correction targets as key terms, and for English a short fixed description of the dictation (with Context Awareness on, of the kind of app you are dictating into, such as email or an AI chat). With Context Awareness on, it also gets the names Deepgram gets as key terms (your Mac account name, visible code names in Cursor, Windsurf and VS Code, and names on screen in the Claude Code panel, ChatGPT in Chrome or the ChatGPT app, and Google search in Chrome); never field text, window titles or URLs. For zero data retention, turn off model training in AssemblyAI's dashboard (paid plans only)."
        }
    }

    /// The Realtime Transcription Model field only applies to the OpenAI-compatible socket.
    var usesRealtimeStreamingModel: Bool { self == .openAIRealtime }

    /// OpenAI's `audio/pcm` input accepts 24 kHz only.
    static let openAIRealtimeSampleRate = 24_000
    /// Deepgram's documented sweet spot; the same samples as the saved WAV.
    static let deepgramSampleRate = 16_000
    /// AssemblyAI's documented default rate; the same samples as the saved WAV.
    static let assemblyAISampleRate = 16_000

    /// Rate of the PCM16 chunks this provider's stream takes; nil when nothing streams.
    var streamSampleRate: Int? {
        switch self {
        case .off: nil
        case .openAIRealtime: Self.openAIRealtimeSampleRate
        case .deepgram: Self.deepgramSampleRate
        case .assemblyAI: Self.assemblyAISampleRate
        }
    }

    /// Inline warning while Deepgram is selected without a key; pinned by tests.
    static let deepgramMissingKeyWarning = "Add a Deepgram API key to stream audio. Until then, audio is uploaded after you release the shortcut."
    /// Inline warning while AssemblyAI is selected without a key; pinned by tests.
    static let assemblyAIMissingKeyWarning = "Add an AssemblyAI API key to stream audio. Until then, audio is uploaded after you release the shortcut."

    /// The streams that take vocabulary keyterms at connect and on-screen names and code
    /// identifiers mid-stream (KeytermStreamingSession).
    var usesContextKeyterms: Bool { self == .deepgram || self == .assemblyAI }

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
    /// PipelineStageTimings source label, read by resolveRawTranscript after a
    /// successful commit; a session may refine it to the path that produced the
    /// text (Deepgram does).
    var transcriptionSource: String { get }
    func start() throws
    func appendPCM16(_ data: Data)
    func commitAndAwaitFinal() async throws -> String
    func cancel()
}

/// A stream that also takes keyterms: the Deepgram and AssemblyAI sessions. AppState drives
/// both through these calls, which each provider implements against its own protocol.
protocol KeytermStreamingSession: StreamingTranscriptionSession {
    /// Whether the recorder's speech tracker counted speech; called on stop, before the
    /// commit, so an empty stream transcript for counted speech falls back to the file.
    func setRecorderHeardSpeech(_ heardSpeech: Bool)
    /// False when updateKeyterms discards every call (AssemblyAI with its keyterms switched
    /// off), so text context does not read on-screen names nothing would receive.
    var acceptsKeytermUpdates: Bool { get }
    /// On-screen names and code identifiers from text context, sent at most once.
    func updateKeyterms(screenTerms: [String], identifiers: [String])
    /// Numbers only, for the Run Log.
    var keytermReport: DeepgramStreamingCore.KeytermReport { get }
}
