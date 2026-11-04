import Foundation

/// Every failure of the AssemblyAI socket path. resolveRawTranscript treats any
/// non-cancellation error as "use the file upload". Each description is a fixed,
/// text-free reason the Run Log shows after "file-fallback: "; the server's error text
/// is only matched to pick a case, never stored, logged or shown.
enum AssemblyAIStreamingError: LocalizedError, Equatable {
    /// The handshake failed, Begin never arrived within the pending-audio limit, the
    /// commit came twice or cancel() ran.
    case notConnected
    /// The shortcut was released before Begin (a short dictation while the handshake ran,
    /// or a stream never started); nothing failed.
    case releasedBeforeSessionBegan
    /// Close or error code 1008 for a missing, invalid, expired or disabled key (or with no
    /// text naming an account refusal), or an HTTP 401/403 on the handshake.
    case unauthorized
    /// Code 1008 for the session-start rate limit or a low account balance, or HTTP 429.
    case accountLimit
    /// Any other Error frame or error close code (3005, 3006, 3007, 3008, 1011).
    case serverError(code: Int?)
    /// The socket closed before commitAndAwaitFinal.
    case socketClosedBeforeCommit
    /// The socket closed abnormally after the commit, before the transcript arrived.
    case socketClosedBeforeFinal
    /// The commit deadline passed with no text although the recorder counted speech, or
    /// before the server could have reached the end of the audio.
    case commitTimedOut
    /// AssemblyAI returned no words although the recorder counted speech.
    case emptyTranscriptForSpeech

    var errorDescription: String? {
        switch self {
        case .notConnected: "AssemblyAI could not connect"
        case .releasedBeforeSessionBegan: "AssemblyAI session had not started yet"
        case .unauthorized: "AssemblyAI rejected the API key"
        case .accountLimit: "AssemblyAI refused the session (rate limit or account balance)"
        case .serverError: "AssemblyAI reported an error"
        case .socketClosedBeforeCommit: "AssemblyAI closed the connection early"
        case .socketClosedBeforeFinal: "AssemblyAI closed the connection before the transcript arrived"
        case .commitTimedOut: "AssemblyAI did not finish the transcript in time"
        case .emptyTranscriptForSpeech: "AssemblyAI returned no words for recorded speech"
        }
    }
}

/// Pure rules for the AssemblyAI Universal-3.6 Pro streaming path: URL building, keyterm
/// caps, the fixed scenario prompts, server-message parsing, turn assembly and the commit
/// and key-validation decisions. Never logs, and never embeds the key, screen text or
/// transcript text in anything it produces. Protocol per
/// assemblyai.com/docs/api-reference/streaming-api/streaming-api and
/// assemblyai.com/docs/streaming/message-sequence.
enum AssemblyAIStreamingCore {
    static let listenEndpoint = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
    static let tokenEndpoint = URL(string: "https://token.assemblyai.com/v1/token")!
    /// Sent explicitly so a change of the server default cannot swap the model.
    static let speechModel = "universal-3-6-pro"
    static let encoding = "pcm_s16le"
    /// Auto-detect and English both pin `language_codes=["en"]`, so automatic language
    /// detection never runs.
    static let defaultLanguage = "en"
    /// The `language_codes` values the API reference lists for Universal-3.6 Pro.
    static let supportedLanguageCodes: Set<String> = [
        "af", "ar", "yue", "ca", "da", "nl", "en", "et", "fi", "fr", "gl", "de", "he", "hi", "it", "ja",
        "ko", "zh", "mr", "no", "nn", "fa", "pt", "ro", "ru", "es", "sv", "tr", "ur", "vi", "xh", "zu",
    ]
    /// Silence before the model checks whether the turn reads as complete, and the
    /// silence that ends a turn regardless (both ms; the first is clamped to 50-10000).
    /// Far above ordinary 1-3 s thinking pauses, so a dictation is normally one turn and
    /// ForceEndpoint ends it on release; a long hands-free dictation still splits at
    /// long pauses, and its turns are joined in order.
    static let minTurnSilenceMilliseconds = 5_000
    static let maxTurnSilenceMilliseconds = 10_000
    /// The server ends a session that receives nothing for this long (5-3600 s). Audio
    /// flows for the whole dictation, so this only bounds a stalled or leaked session,
    /// which is billed by socket-open time.
    static let inactivityTimeoutSeconds = 30
    /// Audio goes out in frames this long; AssemblyAI accepts 50-1000 ms per chunk and
    /// closes the session with 3007 outside that range.
    static let frameMilliseconds = 50
    /// Audio sent faster than real time is processed at about this rate (message-sequence
    /// docs), so the audio held until Begin drains behind the live audio.
    static let throttleRealTimeFactor = 1.25
    /// teardown sends Terminate, then closes once that send completes or after this long.
    static let terminateFlushSeconds: TimeInterval = 0.5
    static let maxKeytermLength = 50
    static let maxKeyterms = 100
    static let maxPromptCharacters = 1_750
    /// The single gate for `prompt`, at connect and mid-stream. The API reference labels
    /// it "Universal-3.5 Pro Streaming only" while the mid-stream and message-sequence
    /// pages describe it on U3 Pro models; unrecognized parameters are documented as
    /// ignored, not rejected, so sending it cannot fail the connection.
    static let sendsPrompt = true
    /// Keychain account for the key, through AppSettingsStore like deepgram_api_key.
    static let apiKeyAccount = "assemblyai_api_key"
    static let keyValidationTimeoutSeconds: TimeInterval = 10
    /// The redemption window of the token Validate mints and discards (documented 1-600).
    static let validationTokenExpirySeconds = 60

    /// The fixed scenario prompt, chosen only from the destination category. The prompt
    /// carries context, never instructions, at the docs' recommended "Scenario" level of
    /// 5-15 words, and never contains screen text, field text, titles, URLs, brand names
    /// or user names.
    enum PromptScenario: String, CaseIterable, Equatable {
        /// AI coding assistants and IDEs, the Claude Code panel in VS Code included.
        case codingAssistant = "coding"
        /// AI chat apps and sites: the ChatGPT app (com.openai.codex), chatgpt.com, claude.ai.
        case aiChat = "ai-chat"
        /// The Google search box.
        case googleSearch = "search"
        case email
        case terminal
        /// Everything else.
        case dictation

        var prompt: String {
            switch self {
            case .codingAssistant: "A software developer dictating a prompt to an AI coding assistant or code editor."
            case .aiChat: "A person dictating a message to an AI chat assistant."
            case .googleSearch: "A person dictating a short web search query."
            case .email: "A person dictating an email message."
            case .terminal: "A software developer dictating in a terminal, often to an AI coding agent."
            case .dictation: "A person dictating text on a computer."
            }
        }
    }

    /// Latency and accuracy presets. Not sent unless the hidden override is set, so the
    /// server applies its own default (balanced); the API reference also labels `mode`
    /// "Universal-3.5 Pro Streaming only".
    enum Mode: String, CaseIterable, Equatable {
        case minLatency = "min_latency"
        case balanced
        case maxAccuracy = "max_accuracy"
    }

    /// Hidden UserDefaults switches for A/B tests; no UI. Read at each connect.
    struct Overrides: Equatable {
        static let promptEnabledStorageKey = "assemblyai_prompt_enabled"
        static let keytermsEnabledStorageKey = "assemblyai_keyterms_enabled"
        static let modeStorageKey = "assemblyai_mode"

        var promptEnabled = true
        var keytermsEnabled = true
        var mode: Mode? = nil

        /// A missing or non-Bool switch loads its default (true); an unknown or
        /// non-string mode loads nil. Never persists anything.
        static func load(from defaults: UserDefaults) -> Overrides {
            Overrides(
                promptEnabled: defaults.object(forKey: promptEnabledStorageKey) as? Bool ?? true,
                keytermsEnabled: defaults.object(forKey: keytermsEnabledStorageKey) as? Bool ?? true,
                mode: (defaults.object(forKey: modeStorageKey) as? String).flatMap(Mode.init(rawValue:))
            )
        }
    }

    struct Configuration: Equatable {
        let apiKey: String
        /// One of supportedLanguageCodes; see languageCode(for:).
        let languageCode: String
        /// The recorder's PCM16 stream rate, passed through unchanged.
        let sampleRate: Int
        let keyterms: [String]
        /// False sends no keyterms at connect and ignores mid-stream keyterm updates.
        let keytermsEnabled: Bool
        /// nil sends no prompt at connect and ignores mid-stream prompt updates.
        let promptScenario: PromptScenario?
        /// nil leaves the server's preset.
        let mode: Mode?
    }

    /// defaultLanguage for Auto-detect (nil or blank); the trimmed, lowercased code when
    /// AssemblyAI lists it; nil otherwise, so no AssemblyAI stream starts and the file
    /// upload honors the chosen language.
    static func languageCode(for language: String?) -> String? {
        let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if code.isEmpty { return defaultLanguage }
        return supportedLanguageCodes.contains(code) ? code : nil
    }

    /// wss://streaming.assemblyai.com/v3/ws?speech_model=universal-3-6-pro
    /// &language_codes=["xx"]&encoding=pcm_s16le&sample_rate=N&min_turn_silence=5000
    /// &max_turn_silence=10000&inactivity_timeout=30[&mode=..][&prompt=..][&keyterms_prompt=[..]]
    /// Fixed item order. List values are JSON array strings. format_turns is not sent:
    /// Universal-3.6 Pro always formats turns. Never contains the key. Values are
    /// percent-encoded against the RFC 3986 unreserved set and assembled with
    /// percentEncodedQuery, as in DeepgramStreamingCore, so "&", "#", "+", quotes,
    /// spaces and non-ASCII survive.
    static func listenURL(for configuration: Configuration) -> URL {
        var items: [(name: String, value: String)] = [
            ("speech_model", speechModel),
            ("language_codes", jsonArray([configuration.languageCode])),
            ("encoding", encoding),
            ("sample_rate", String(configuration.sampleRate)),
            ("min_turn_silence", String(minTurnSilenceMilliseconds)),
            ("max_turn_silence", String(maxTurnSilenceMilliseconds)),
            ("inactivity_timeout", String(inactivityTimeoutSeconds)),
        ]
        if let mode = configuration.mode {
            items.append(("mode", mode.rawValue))
        }
        if sendsPrompt, let scenario = configuration.promptScenario {
            items.append(("prompt", scenario.prompt))
        }
        let keyterms = configuration.keytermsEnabled ? normalizedKeyterms(configuration.keyterms) : []
        if !keyterms.isEmpty {
            items.append(("keyterms_prompt", jsonArray(keyterms)))
        }

        var components = URLComponents(url: listenEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items
            .map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
        // The query holds only unreserved characters, "=" and "&", so it always forms a URL.
        return components.url!
    }

    /// The trimmed key; AssemblyAI takes no "Bearer" or "Token" prefix.
    static func authorizationHeaderValue(apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASCII letters, digits and "-._~": everything else is percent-encoded.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// Trims; collapses internal whitespace runs to one space; drops empties and terms
    /// longer than maxKeytermLength (dropped, not cut: AssemblyAI ignores longer terms
    /// and a truncated phrase boosts a wrong spelling); dedupes case-insensitively
    /// keeping the first spelling; stops at maxKeyterms. Order (priority) is preserved.
    static func normalizedKeyterms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let collapsed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty, collapsed.count <= maxKeytermLength else { continue }
            let key = collapsed.lowercased()
            guard !seen.contains(key) else { continue }
            guard result.count < maxKeyterms else { break }
            seen.insert(key)
            result.append(collapsed)
        }
        return result
    }

    /// The one mid-stream keyterm list, planned by DeepgramStreamingCore.KeytermPlan
    /// (connect terms first and unchanged, since keyterms_prompt replaces the whole list;
    /// then on-screen names, then identifiers, with its dotted-name and secret filters).
    /// Screen names and identifiers over maxKeytermLength are dropped first, so the counts
    /// match what is sent. Nil when nothing new fits.
    static func updateTerms(
        connect: [String],
        screenTerms: [String],
        identifiers: [String]
    ) -> (terms: [String], screenCount: Int, identifierCount: Int)? {
        func fits(_ term: String) -> Bool {
            term.split(whereSeparator: \.isWhitespace).joined(separator: " ").count <= maxKeytermLength
        }
        guard let plan = DeepgramStreamingCore.KeytermPlan.configureTerms(
            connect: normalizedKeyterms(connect),
            screenTerms: screenTerms.filter(fits),
            identifiers: identifiers.filter(fits)
        ) else { return nil }
        return (normalizedKeyterms(plan.terms), plan.screenCount, plan.identifierCount)
    }

    /// `{"keyterms_prompt":[..],"prompt":"..","type":"UpdateConfiguration"}` with sorted keys.
    /// The message is a delta: an omitted field keeps its value. An empty keyterm list
    /// is omitted rather than sent as [], which would clear every keyterm; the prompt
    /// is omitted when sendsPrompt is off, and is typed so no free text can reach it.
    /// Nil when nothing remains.
    static func updateConfigurationMessage(keyterms: [String]?, prompt: PromptScenario?) -> String? {
        var object: [String: Any] = ["type": "UpdateConfiguration"]
        if let keyterms {
            let normalized = normalizedKeyterms(keyterms)
            if !normalized.isEmpty { object["keyterms_prompt"] = normalized }
        }
        if sendsPrompt, let prompt {
            object["prompt"] = prompt.prompt
        }
        guard object.count > 1,
              let data = try? JSONSerialization.data(
                  withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// sampleRate * 2 bytes * frameMilliseconds / 1000, rounded down to whole Int16
    /// samples: 1600 at 16 kHz.
    static func frameBytes(sampleRate: Int) -> Int {
        let sampleBytes = MemoryLayout<Int16>.size
        let bytes = sampleRate * sampleBytes * frameMilliseconds / 1000
        return max(sampleBytes, bytes - bytes % sampleBytes)
    }

    /// The final partial frame zero-padded (silence) to `frameBytes`, so no chunk is
    /// shorter than 50 ms; a full frame is unchanged and empty input stays empty.
    static func paddedFinalChunk(_ partial: Data, frameBytes: Int) -> Data {
        guard !partial.isEmpty, partial.count < frameBytes else { return partial }
        var padded = partial
        padded.append(Data(count: frameBytes - partial.count))
        return padded
    }

    /// Audio the server cannot have processed yet: everything sent, minus what the
    /// throttle let through since Begin. Zero once the burst held until Begin has drained.
    static func estimatedBacklogMilliseconds(audioMillisecondsSent: Int, secondsSinceBegin: TimeInterval) -> Int {
        let processable = Int((max(0, secondsSinceBegin) * 1000 * throttleRealTimeFactor).rounded(.down))
        return max(0, audioMillisecondsSent - processable)
    }

    /// Error frame text is matched against fixed markers only and then dropped. Code 1008
    /// covers a bad key and account refusals alike (assemblyai.com/docs/streaming/
    /// common-session-errors-and-closures), so its text picks the case.
    static func failure(errorCode: Int?, message: String?) -> AssemblyAIStreamingError {
        guard errorCode == 1008 else { return .serverError(code: errorCode) }
        let text = message?.lowercased() ?? ""
        let accountMarkers = ["too many concurrent sessions", "insufficient funds", "no metronome account"]
        return accountMarkers.contains(where: text.contains) ? .accountLimit : .unauthorized
    }

    /// The failure a close reports when no Error frame did: a refused handshake (HTTP
    /// 401/403 or 429) or a documented error close code. A 1008 close reason carries the
    /// Error frame's text when the frame could not be sent (common-session-errors), so it
    /// is matched like that text and dropped. A normal close (1000), no code and
    /// transport-level codes are nil; the socket state then decides.
    static func failure(closeCode: Int?, closeReason: String?, httpStatus: Int?) -> AssemblyAIStreamingError? {
        switch httpStatus {
        case 401, 403: return .unauthorized
        case 429: return .accountLimit
        default: break
        }
        switch closeCode {
        case 1008: return failure(errorCode: 1008, message: closeReason)
        case 1011, 3005, 3006, 3007, 3008: return .serverError(code: closeCode)
        default: return nil
        }
    }

    enum ServerMessage: Equatable {
        /// About 24.8 days of stream audio; sessions end after 3 hours.
        static let maxWordEndMilliseconds = Int(Int32.max)

        case begin
        /// One Turn: its text replaces the previous text of the same turn_order.
        /// speechEndMilliseconds is the latest words[].end (ms of stream audio), nil
        /// without words.
        case turn(order: Int, transcript: String, endOfTurn: Bool, speechEndMilliseconds: Int?)
        case termination
        /// Classified at parse; the server's text is not kept.
        case error(AssemblyAIStreamingError)
        case unknown

        /// Malformed JSON, a non-object root, a missing or unknown `type` and a Turn
        /// without an integral turn_order -> .unknown (SpeechStarted, Heartbeat and
        /// SpeakerRevision included). Turn text is `transcript`, or `utterance` when the
        /// transcript is empty; end_of_turn defaults false and tolerates wrong types, and
        /// words without a numeric `end` in 0...maxWordEndMilliseconds are skipped, so no
        /// provider value can trap the conversion or overflow the commit arithmetic.
        init(data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                self = .unknown
                return
            }
            switch type {
            case "Begin":
                self = .begin
            case "Turn":
                guard let order = object["turn_order"] as? Int else {
                    self = .unknown
                    return
                }
                let transcript = object["transcript"] as? String ?? ""
                let utterance = object["utterance"] as? String ?? ""
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? utterance : transcript
                let wordEnds = (object["words"] as? [Any] ?? []).compactMap { word -> Int? in
                    guard let end = (word as? [String: Any])?["end"] as? Double,
                          (0...Double(Self.maxWordEndMilliseconds)).contains(end) else { return nil }
                    return Int(end.rounded())
                }
                self = .turn(
                    order: order,
                    transcript: text,
                    endOfTurn: object["end_of_turn"] as? Bool ?? false,
                    speechEndMilliseconds: wordEnds.max()
                )
            case "Termination":
                self = .termination
            case "Error":
                self = .error(AssemblyAIStreamingCore.failure(
                    errorCode: object["error_code"] as? Int, message: object["error"] as? String
                ))
            default:
                self = .unknown
            }
        }
    }

    /// Each Turn replaces the text for its turn_order until end_of_turn fixes it; later
    /// messages for an ended turn are ignored. AssemblyAI delivers every message of a turn
    /// before the next turn's first message, so the unfinished turn is the latest one.
    struct TurnAssembler: Equatable {
        private var texts: [Int: String] = [:]
        private var ended = Set<Int>()
        private var committed = false
        /// Every Turn message, including ignored ones.
        private(set) var turnMessageCount = 0
        private(set) var hasReceivedTermination = false
        /// True once a turn ended after markCommitted: ForceEndpoint's answer, or a
        /// natural end of turn that arrived late; CommitPolicy tells them apart.
        private(set) var hasEndOfTurnAfterCommit = false
        /// The latest words[].end over the ended turns (ms of stream audio); nil without words.
        private(set) var finalSpeechEndMilliseconds: Int?

        /// Ended turns in turn_order, trimmed, empties skipped, single-space joined.
        var finalTranscript: String { joined(ended.sorted()) }
        /// The unfinished turns' latest text, in turn_order.
        var partialTail: String { joined(texts.keys.filter { !ended.contains($0) }.sorted()) }
        var hasPartialTail: Bool { !partialTail.isEmpty }
        var transcriptWithTail: String {
            [finalTranscript, partialTail].filter { !$0.isEmpty }.joined(separator: " ")
        }
        /// A turn has started and not ended, with or without text yet.
        var hasUnfinishedTurn: Bool { !texts.keys.allSatisfy(ended.contains) }

        mutating func markCommitted() {
            committed = true
        }

        /// begin, error and unknown are no-ops.
        mutating func apply(_ message: ServerMessage) {
            switch message {
            case .turn(let order, let transcript, let endOfTurn, let speechEnd):
                turnMessageCount += 1
                guard !ended.contains(order) else { return }
                texts[order] = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if endOfTurn {
                    ended.insert(order)
                    if committed { hasEndOfTurnAfterCommit = true }
                    if let speechEnd {
                        finalSpeechEndMilliseconds = max(finalSpeechEndMilliseconds ?? speechEnd, speechEnd)
                    }
                }
            case .termination:
                hasReceivedTermination = true
            case .begin, .error, .unknown:
                break
            }
        }

        private func joined(_ orders: [Int]) -> String {
            orders.compactMap { texts[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    enum CommitPolicy {
        /// Same budget as Deepgram's (#21); ForceEndpoint answers in about 0.1-0.3 s.
        static let timeout: TimeInterval = 3
        /// The most the deadline grows for audio still queued behind the throttle at the
        /// commit, so a commit never waits longer than timeout + this.
        static let maxBacklogWait: TimeInterval = 3
        /// Margin under min_turn_silence for the fast path's coverage check.
        static let coverageSlackMilliseconds = 300
        static let forceEndpointMessage = #"{"type":"ForceEndpoint"}"#
        static let terminateMessage = #"{"type":"Terminate"}"#
        /// Text frames sent back to back, in this order, on shortcut release. ForceEndpoint
        /// ends the current turn at once; Terminate right behind it makes the server flush
        /// every in-flight message, send Termination and close with 1000.
        static let commitMessages = [forceEndpointMessage, terminateMessage]

        /// Which stream text resolved the commit. The raw value is the Run Log source label.
        enum TranscriptPath: String, Equatable {
            /// Every word came from an ended turn.
            case finals = "assemblyai-final"
            /// An unfinished turn's latest text follows the ended turns.
            case finalsWithPartialTail = "assemblyai-final+partial-tail"
        }

        typealias SocketState = DeepgramStreamingCore.CommitPolicy.SocketState

        /// Seconds the server needs, at the throttle rate, to reach the end of the audio
        /// still queued when the commit started.
        static func backlogDrainSeconds(backlogMillisecondsAtCommit: Int) -> TimeInterval {
            Double(max(0, backlogMillisecondsAtCommit)) / (1000 * AssemblyAIStreamingCore.throttleRealTimeFactor)
        }

        /// timeout after the server can have reached the end of the audio, so ForceEndpoint
        /// gets the same budget with or without a backlog; at most timeout + maxBacklogWait.
        static func deadline(backlogMillisecondsAtCommit: Int) -> TimeInterval {
            timeout + min(maxBacklogWait, backlogDrainSeconds(backlogMillisecondsAtCommit: backlogMillisecondsAtCommit))
        }

        enum Decision: Equatable {
            case wait
            case resolve(String, TranscriptPath)
            case fallBack(AssemblyAIStreamingError)
        }

        /// Pure decision over a state snapshot, evaluated after every event and on the
        /// timeout, in this order:
        /// 1. A failure always falls back, even after text arrived.
        /// 2. Termination (Terminate flushed every frame) or a normal close resolves the
        ///    stream text; an abnormal close without them falls back.
        /// 3. Fast path: the end_of_turn after the commit resolves the ended turns once it
        ///    must be ForceEndpoint's answer over all the audio: no turn is unfinished, no
        ///    throttle backlog was left at the commit (ForceEndpoint answers "right away",
        ///    not after queued audio), and the last final word ends closer to the end of the
        ///    audio than a natural end of turn allows (min_turn_silence minus a slack).
        ///    Anything else waits for Termination.
        /// 4. At the deadline the ended turns plus the latest unfinished turn resolve, unless
        ///    the recorder counted speech and the throttle estimate says the server has not
        ///    reached the end of the audio yet: its text would miss the trailing words, so
        ///    the file upload runs instead.
        /// Empty text falls back when the recorder counted speech; otherwise "" resolves.
        static func decision(
            assembler: TurnAssembler,
            socketState: SocketState,
            failure: AssemblyAIStreamingError?,
            elapsedSinceCommit: TimeInterval,
            recorderHeardSpeech: Bool,
            audioMillisecondsSent: Int,
            backlogMillisecondsAtCommit: Int
        ) -> Decision {
            if let failure {
                return .fallBack(failure)
            }
            if assembler.hasReceivedTermination || socketState == .closedNormally {
                return streamText(
                    assembler, emptyFailure: .emptyTranscriptForSpeech, recorderHeardSpeech: recorderHeardSpeech
                )
            }
            if socketState == .closedAbnormally {
                return .fallBack(.socketClosedBeforeFinal)
            }
            if assembler.hasEndOfTurnAfterCommit,
               !assembler.hasUnfinishedTurn,
               backlogMillisecondsAtCommit <= 0,
               let speechEnd = assembler.finalSpeechEndMilliseconds,
               audioMillisecondsSent - speechEnd
                   < AssemblyAIStreamingCore.minTurnSilenceMilliseconds - coverageSlackMilliseconds {
                return streamText(
                    assembler, emptyFailure: .emptyTranscriptForSpeech, recorderHeardSpeech: recorderHeardSpeech
                )
            }
            if elapsedSinceCommit >= deadline(backlogMillisecondsAtCommit: backlogMillisecondsAtCommit) {
                if recorderHeardSpeech,
                   backlogDrainSeconds(backlogMillisecondsAtCommit: backlogMillisecondsAtCommit) > elapsedSinceCommit {
                    return .fallBack(.commitTimedOut)
                }
                return streamText(assembler, emptyFailure: .commitTimedOut, recorderHeardSpeech: recorderHeardSpeech)
            }
            return .wait
        }

        private static func streamText(
            _ assembler: TurnAssembler,
            emptyFailure: AssemblyAIStreamingError,
            recorderHeardSpeech: Bool
        ) -> Decision {
            let text = assembler.transcriptWithTail
            if !text.isEmpty {
                return .resolve(text, assembler.hasPartialTail ? .finalsWithPartialTail : .finals)
            }
            return recorderHeardSpeech ? .fallBack(emptyFailure) : .resolve("", .finals)
        }
    }

    enum KeyValidation: Equatable {
        case valid
        case invalid
        case unreachable

        /// 200 valid, 401/403 invalid, anything else unreachable.
        init(statusCode: Int) {
            switch statusCode {
            case 200: self = .valid
            case 401, 403: self = .invalid
            default: self = .unreachable
            }
        }

        var statusText: String {
            switch self {
            case .valid: "Valid"
            case .invalid: "Invalid"
            case .unreachable: "Could not reach AssemblyAI"
            }
        }
    }

    /// POST tokenEndpoint minting a short-lived streaming token: documented
    /// (assemblyai.com/docs/streaming/api-spec/generate-streaming-token), answers 401 for
    /// a bad key, and opens no billed session. Nil when the trimmed key is empty.
    static func validationRequest(apiKey: String) -> URLRequest? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let body = try? JSONSerialization.data(
                  withJSONObject: ["expires_in_seconds": validationTokenExpirySeconds, "product": "streaming"],
                  options: [.sortedKeys]
              ) else { return nil }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = keyValidationTimeoutSeconds
        request.setValue(authorizationHeaderValue(apiKey: trimmed), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// An empty key is .invalid without calling the transport; a thrown transport error
    /// is .unreachable. The response body (the minted token) is discarded unread.
    static func validateAPIKey(
        _ key: String,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await LLMAPITransport.data(for: request)
        }
    ) async -> KeyValidation {
        guard let request = validationRequest(apiKey: key) else { return .invalid }
        do {
            let (_, response) = try await transport(request)
            return KeyValidation(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unreachable
        }
    }
}
