import Foundation

/// Every failure of the Deepgram socket path. resolveRawTranscript treats any
/// non-cancellation error as "use the file upload", so these only need to be
/// distinct for tests and logs; descriptions are fixed strings that never
/// embed a server message.
enum DeepgramStreamingError: LocalizedError, Equatable {
    /// start() never ran, the socket never opened, or cancel() ran.
    case notConnected
    /// The receive loop ended before commitAndAwaitFinal.
    case socketClosedBeforeCommit
    /// Deepgram sent `{"type":"Error"}`; the message is kept for tests, not described.
    case serverError(String)
    /// The socket closed abnormally after the commit, before the from_finalize
    /// final or Metadata arrived.
    case socketClosedBeforeFinal
    /// CommitPolicy.timeout elapsed without the from_finalize final, Metadata or a close.
    case commitTimedOut
    /// The stream ended without a single Results frame: no audio was processed.
    case noResults
    /// Deepgram returned no words although the recorder counted speech.
    case emptyTranscriptForSpeech

    var errorDescription: String? {
        switch self {
        case .notConnected: "Deepgram streaming socket is not connected"
        case .socketClosedBeforeCommit: "Deepgram socket closed before the transcript was committed"
        case .serverError: "Deepgram reported an error"
        case .socketClosedBeforeFinal: "Deepgram socket closed before the final transcript arrived"
        case .commitTimedOut: "Deepgram did not finish the transcript in time"
        case .noResults: "Deepgram processed no audio"
        case .emptyTranscriptForSpeech: "Deepgram returned no words for recorded speech"
        }
    }
}

/// Pure rules for the Deepgram Nova-3 streaming path: URL building, keyterm
/// normalization, audio framing, server-message parsing, transcript assembly and
/// the commit, keep-alive and key-validation decisions. Never logs, and never
/// embeds the key or transcript text in anything it produces.
enum DeepgramStreamingCore {
    static let listenEndpoint = URL(string: "wss://api.deepgram.com/v1/listen")!
    static let projectsEndpoint = URL(string: "https://api.deepgram.com/v1/projects")!
    static let model = "nova-3"
    /// Sent for Auto-detect (nil or blank language). Deepgram already uses en when
    /// the item is omitted, so this only makes the request explicit.
    static let defaultLanguage = "en"
    /// Silence before Deepgram finalizes a segment (its default is 10 ms). Inside its
    /// 300-500 ms range for speakers who pause mid-thought. FreeFlow ignores
    /// speech_final and always sends Finalize on release, so release latency is unchanged.
    static let endpointingMilliseconds = 500
    /// Audio goes out in frames this long; Deepgram recommends 20-100 ms buffers and
    /// closes the socket on an empty frame.
    static let frameMilliseconds = 50
    /// Same cap as DictionaryCorrection.maxFieldLength, declared locally.
    static let maxKeytermLength = 60
    static let maxKeyterms = 100
    /// About 300 tokens, well under Deepgram's 500-token keyterm budget.
    static let maxKeytermTotalCharacters = 1200
    /// Audio buffered while the handshake is pending before the stream is abandoned.
    static let maxPendingAudioSeconds = 10
    /// Above HandsFreeAutoStop.maximumMilliseconds (20 min) so URLSession's
    /// request timeout, which also bounds an idle WebSocket receive, never
    /// fires mid-dictation.
    static let socketIdleTimeoutSeconds: TimeInterval = 25 * 60
    static let keyValidationTimeoutSeconds: TimeInterval = 10

    struct Configuration: Equatable {
        let apiKey: String
        /// nil or blank = Auto-detect, sent as defaultLanguage.
        let language: String?
        /// The recorder's PCM16 stream rate, passed through unchanged.
        let sampleRate: Int
        let keyterms: [String]
    }

    /// wss://api.deepgram.com/v1/listen?model=nova-3&language=xx&encoding=linear16&sample_rate=N
    /// &channels=1&smart_format=true&punctuate=true&interim_results=true&endpointing=500
    /// &mip_opt_out=true[&keyterm=..]*
    /// Fixed item order; language is defaultLanguage when the configured one is nil
    /// or blank. Never contains the key. Keyterms pass through
    /// normalizedKeyterms (idempotent). Values are percent-encoded against the
    /// RFC 3986 unreserved set and assembled with percentEncodedQuery, so a
    /// space is %20, "+" is %2B, "&" is %26 and "=" is %3D
    /// (URLComponents.queryItems leaves "+" bare, which a server may decode as a space).
    static func listenURL(for configuration: Configuration) -> URL {
        var items: [(name: String, value: String)] = [("model", model)]
        let language = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        items.append(("language", language.isEmpty ? defaultLanguage : language))
        items += [
            ("encoding", "linear16"),
            ("sample_rate", String(configuration.sampleRate)),
            ("channels", "1"),
            ("smart_format", "true"),
            ("punctuate", "true"),
            ("interim_results", "true"),
            ("endpointing", String(endpointingMilliseconds)),
            // Deepgram keeps opted-out audio only while it processes the request.
            ("mip_opt_out", "true"),
        ]
        for keyterm in normalizedKeyterms(configuration.keyterms) {
            items.append(("keyterm", keyterm))
        }

        var components = URLComponents(url: listenEndpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = items
            .map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }
            .joined(separator: "&")
        // The query holds only unreserved characters, "=" and "&", so it always forms a URL.
        return components.url!
    }

    /// "Token " + the trimmed key.
    static func authorizationHeaderValue(apiKey: String) -> String {
        "Token " + apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASCII letters, digits and "-._~": everything else is percent-encoded.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    /// Trims; collapses internal whitespace runs (spaces, tabs, CR/LF) to one
    /// space; drops empties and terms longer than maxKeytermLength (dropped, not
    /// cut: a truncated phrase boosts a wrong spelling); dedupes
    /// case-insensitively keeping the first spelling; stops at maxKeyterms or
    /// when the running character total would exceed maxKeytermTotalCharacters.
    /// Order is preserved, so vocabulary entries come before correction targets.
    static func normalizedKeyterms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var totalCharacters = 0
        for term in terms {
            let collapsed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty, collapsed.count <= maxKeytermLength else { continue }
            let key = collapsed.lowercased()
            guard !seen.contains(key) else { continue }
            guard result.count < maxKeyterms,
                  totalCharacters + collapsed.count <= maxKeytermTotalCharacters else {
                break
            }
            seen.insert(key)
            result.append(collapsed)
            totalCharacters += collapsed.count
        }
        return result
    }

    /// Splits on newline, CR, comma and semicolon (the Custom Vocabulary
    /// separators), then normalizes. The input is
    /// DictionaryCorrection.vocabularyText(_:merging:).
    static func keyterms(fromVocabularyText text: String) -> [String] {
        normalizedKeyterms(text.components(separatedBy: CharacterSet(charactersIn: "\n\r,;")))
    }

    /// Code identifiers added to one stream's keyterms, at most.
    static let maxContextKeyterms = 50

    /// The stream's own keyterms followed by up to maxContextKeyterms identifiers, normalized,
    /// so the vocabulary terms always survive maxKeyterms and maxKeytermTotalCharacters.
    /// Dotted member paths are never spoken, so they are left out. nil when nothing new
    /// would be added: then no update is sent.
    static func mergedKeyterms(base: [String], adding identifiers: [String]) -> [String]? {
        let current = normalizedKeyterms(base)
        let merged = normalizedKeyterms(current + identifiers.filter { !$0.contains(".") }.prefix(maxContextKeyterms))
        return merged == current ? nil : merged
    }

    /// `{"keyterms":[...],"type":"Configure"}`, or nil when no keyterm survives
    /// normalization. Per developers.deepgram.com/docs/configure (Nova-3 only), the list
    /// replaces the stream's whole keyterm list, URL keyterms included. Deepgram answers
    /// ConfigureSuccess or ConfigureFailure (CONFIGURE_ALREADY_PENDING,
    /// CONFIGURE_KEYTERM_LIMIT_EXCEEDED, …) and keeps its previous settings on failure;
    /// both replies parse as .unknown and are ignored. Only an unknown field produces an
    /// Error frame, and this message carries only `type` and `keyterms`.
    static func configureMessage(keyterms: [String]) -> String? {
        let normalized = normalizedKeyterms(keyterms)
        guard !normalized.isEmpty,
              let data = try? JSONSerialization.data(
                  withJSONObject: ["type": "Configure", "keyterms": normalized],
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// sampleRate * 2 bytes * maxPendingAudioSeconds.
    static func maxPendingAudioBytes(sampleRate: Int) -> Int {
        sampleRate * MemoryLayout<Int16>.size * maxPendingAudioSeconds
    }

    /// sampleRate * 2 bytes * frameMilliseconds / 1000, rounded down to whole Int16
    /// samples and at least one sample: 1600 at 16 kHz, 2400 at 24 kHz.
    static func frameBytes(sampleRate: Int) -> Int {
        let sampleBytes = MemoryLayout<Int16>.size
        let bytes = sampleRate * sampleBytes * frameMilliseconds / 1000
        return max(sampleBytes, bytes - bytes % sampleBytes)
    }

    /// Regroups PCM16 chunks of any size into frameBytes-sized frames, in order.
    /// Never yields an empty frame; the partial frame waits for the next append
    /// or for flush.
    struct FrameAggregator: Equatable {
        let frameBytes: Int
        private var pending = Data()

        /// At least one Int16 sample, so append always makes progress.
        init(frameBytes: Int) { self.frameBytes = max(MemoryLayout<Int16>.size, frameBytes) }

        /// Every complete frame now available; an empty append yields none.
        mutating func append(_ data: Data) -> [Data] {
            pending.append(data)
            var frames: [Data] = []
            var offset = 0
            while pending.count - offset >= frameBytes {
                frames.append(pending.subdata(in: offset..<offset + frameBytes))
                offset += frameBytes
            }
            if offset > 0 { pending = pending.subdata(in: offset..<pending.count) }
            return frames
        }

        /// The partial frame, once; nil when nothing is pending.
        mutating func flush() -> Data? {
            guard !pending.isEmpty else { return nil }
            defer { pending = Data() }
            return pending
        }
    }

    enum ServerMessage: Equatable {
        case results(
            transcript: String, isFinal: Bool, speechFinal: Bool, fromFinalize: Bool,
            start: Double? = nil, duration: Double? = nil
        )
        case metadata
        case utteranceEnd
        case speechStarted
        case error(message: String)
        case unknown

        /// Malformed JSON, a non-object root, a missing or unknown `type` ->
        /// .unknown. Results: channel.alternatives[0].transcript ?? "";
        /// is_final / speech_final / from_finalize default false and tolerate
        /// wrong types; start and duration are seconds into the stream, nil when
        /// missing or not a number. Error: description ?? message ?? a fixed fallback.
        init(data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                self = .unknown
                return
            }
            switch type {
            case "Results":
                let channel = object["channel"] as? [String: Any]
                let alternatives = channel?["alternatives"] as? [[String: Any]]
                self = .results(
                    transcript: alternatives?.first?["transcript"] as? String ?? "",
                    isFinal: object["is_final"] as? Bool ?? false,
                    speechFinal: object["speech_final"] as? Bool ?? false,
                    fromFinalize: object["from_finalize"] as? Bool ?? false,
                    start: object["start"] as? Double,
                    duration: object["duration"] as? Double
                )
            case "Metadata":
                self = .metadata
            case "UtteranceEnd":
                self = .utteranceEnd
            case "SpeechStarted":
                self = .speechStarted
            case "Error":
                let message = object["description"] as? String
                    ?? object["message"] as? String
                    ?? "unknown Deepgram error"
                self = .error(message: message)
            default:
                self = .unknown
            }
        }
    }

    /// Appends is_final transcripts in arrival order (trimmed, single-space
    /// joins, empties skipped), dropping finals Deepgram re-sends for audio it
    /// already finalized; interim results only count toward resultCount and
    /// set the interim tail. Metadata marks completion.
    struct TranscriptAssembler: Equatable {
        /// Slack, in seconds, when comparing Results start and end times.
        static let timingToleranceSeconds = 0.01

        /// One kept final; start and end are nil when its frame carried no usable timing.
        private struct FinalSegment: Equatable {
            let text: String
            let start: Double?
            let end: Double?
        }

        private var finals: [FinalSegment] = []
        /// Every .results, interim or final.
        private(set) var resultCount = 0
        private(set) var hasReceivedMetadata = false
        /// The latest interim transcript with no final for its audio after it:
        /// words Deepgram heard but has not yet finalized, so finalTranscript
        /// is missing them. Deepgram's interims cover the audio from the last
        /// final to the current tip, so the latest one is the whole tail, and a
        /// blank one (the server revised the guess away) empties it. A final
        /// that adds or replaces text clears it, and so does an empty one; a
        /// final dropped as a re-send of finalized audio leaves it.
        private(set) var interimTail = ""
        /// True once a Results frame with is_final and from_finalize arrived:
        /// Deepgram's answer to Finalize, sent once it processed every audio
        /// frame received before it.
        private(set) var hasReceivedFinalizeResponse = false

        var finalTranscript: String { finals.map(\.text).joined(separator: " ") }
        var hasReceivedResults: Bool { resultCount > 0 }
        var isComplete: Bool { hasReceivedMetadata }
        /// Deepgram heard words it has not finalized.
        var hasUnfinalizedSpeech: Bool { !interimTail.isEmpty }
        /// The finals followed by the interim tail, single-space joined, empties skipped.
        var transcriptWithInterimTail: String {
            [finalTranscript, interimTail].filter { !$0.isEmpty }.joined(separator: " ")
        }

        /// utteranceEnd, speechStarted, error and unknown are no-ops.
        mutating func apply(_ message: ServerMessage) {
            switch message {
            case .results(let transcript, let isFinal, _, let fromFinalize, let start, let duration):
                resultCount += 1
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isFinal else {
                    interimTail = trimmed
                    return
                }
                if fromFinalize { hasReceivedFinalizeResponse = true }
                guard !trimmed.isEmpty else {
                    interimTail = ""
                    return
                }
                if appendFinal(trimmed, start: start, duration: duration) {
                    interimTail = ""
                }
            case .metadata:
                hasReceivedMetadata = true
            case .utteranceEnd, .speechStarted, .error, .unknown:
                break
            }
        }

        /// A final without usable timing (missing, non-finite or negative) is
        /// appended as before. A timed final ending within audio an earlier
        /// timed final already covered is a re-send and is dropped. Any other
        /// timed final first removes every trailing timed final starting where
        /// it starts or later, whose audio it covers again (a cumulative
        /// re-emit, which can span several finals), and is then appended with
        /// the earliest of those starts. Known limitation: a final starting
        /// inside a kept one and ending after it repeats the overlapping words,
        /// since splitting text needs word timings. Returns false only for a
        /// dropped re-send, which carries no new audio.
        private mutating func appendFinal(_ text: String, start: Double?, duration: Double?) -> Bool {
            guard let start, let duration, start.isFinite, duration.isFinite, start >= 0, duration >= 0 else {
                finals.append(FinalSegment(text: text, start: nil, end: nil))
                return true
            }
            let end = start + duration
            let tolerance = Self.timingToleranceSeconds
            if let finalizedEnd = finals.compactMap(\.end).max(), end <= finalizedEnd + tolerance {
                return false
            }
            var keptStart = start
            while let last = finals.last, let lastStart = last.start, lastStart >= start - tolerance {
                keptStart = min(keptStart, lastStart)
                finals.removeLast()
            }
            finals.append(FinalSegment(text: text, start: keptStart, end: end))
            return true
        }
    }

    enum CommitPolicy {
        /// Deepgram documents 200-500 ms of transcript latency, and CloseStream
        /// right behind Finalize always ends in Metadata, so 3 s is at least six
        /// times the documented worst case while still leaving room for a
        /// late-opened socket draining its buffered audio. A stalled stream
        /// reaches the file upload 2 s sooner than with the former 5 s.
        static let timeout: TimeInterval = 3
        static let finalizeMessage = #"{"type":"Finalize"}"#
        static let closeStreamMessage = #"{"type":"CloseStream"}"#
        /// Text frames sent back to back, in this order, on shortcut release.
        /// Finalize asks for the from_finalize final; CloseStream right behind
        /// it guarantees Metadata as the safety net when that final never comes.
        static let commitMessages = [finalizeMessage, closeStreamMessage]

        /// Which stream text resolved the commit. The raw value is the Run Log
        /// source label.
        enum TranscriptPath: String, Equatable {
            /// Every word came from a final.
            case finals = "deepgram-final"
            /// The stream ended with interim words Deepgram never finalized; they follow the finals.
            case finalsWithInterimTail = "deepgram-final+interim-tail"
        }

        enum Decision: Equatable {
            case wait
            case resolve(String, TranscriptPath)
            case fallBack(DeepgramStreamingError)
        }

        /// The receive loop's view of the socket, reported only after every
        /// delivered frame has been applied. A close is normal when the server
        /// sent close code 1000; anything else (another code, no close frame,
        /// a transport error) is abnormal.
        enum SocketState: Equatable {
            case open
            case closedNormally
            case closedAbnormally
        }

        /// Pure decision over a state snapshot, evaluated after every event and
        /// on the timeout, in this order. A server error always falls back, even
        /// after text arrived. The from_finalize final means Deepgram flushed all
        /// the audio sent before Finalize, and frames are applied in socket order,
        /// so the stream text resolves at once, whatever the close or the clock
        /// says afterwards. Metadata or a normal close means Deepgram processed
        /// all the audio. Either way the finals resolve, followed by the latest
        /// interim words it never finalized (none after the from_finalize final,
        /// unless that final was dropped as a re-send). An abnormal close without
        /// either falls back whatever arrived, since the tail may be missing.
        /// Only then does the clock matter. Stream text that is empty falls back
        /// with .noResults when no Results frame arrived at all, and with
        /// .emptyTranscriptForSpeech when the recorder counted speech; otherwise
        /// "" resolves (Deepgram heard no words, which the stop path handles
        /// like an empty Realtime result).
        static func decision(
            assembler: TranscriptAssembler,
            socketState: SocketState,
            serverErrorMessage: String?,
            elapsedSinceCommit: TimeInterval,
            recorderHeardSpeech: Bool
        ) -> Decision {
            if let serverErrorMessage {
                return .fallBack(.serverError(serverErrorMessage))
            }
            if assembler.hasReceivedFinalizeResponse || assembler.hasReceivedMetadata
                || socketState == .closedNormally {
                return streamText(
                    assembler.transcriptWithInterimTail,
                    path: assembler.hasUnfinalizedSpeech ? .finalsWithInterimTail : .finals,
                    assembler: assembler, recorderHeardSpeech: recorderHeardSpeech
                )
            }
            if socketState == .closedAbnormally {
                return .fallBack(.socketClosedBeforeFinal)
            }
            if elapsedSinceCommit >= timeout {
                return .fallBack(.commitTimedOut)
            }
            return .wait
        }

        private static func streamText(
            _ text: String,
            path: TranscriptPath,
            assembler: TranscriptAssembler,
            recorderHeardSpeech: Bool
        ) -> Decision {
            if !text.isEmpty {
                return .resolve(text, path)
            }
            guard assembler.hasReceivedResults else { return .fallBack(.noResults) }
            return recorderHeardSpeech ? .fallBack(.emptyTranscriptForSpeech) : .resolve("", .finals)
        }
    }

    enum KeepAlivePolicy {
        static let message = #"{"type":"KeepAlive"}"#
        static let interval: TimeInterval = 5

        /// True when no audio has been sent yet or the last chunk is at least `interval` old.
        static func shouldSendKeepAlive(lastAudioSentAt: TimeInterval?, now: TimeInterval) -> Bool {
            guard let lastAudioSentAt else { return true }
            return now - lastAudioSentAt >= interval
        }
    }

    enum KeyValidation: Equatable {
        case valid
        case invalid
        case limitedScope
        case unreachable

        /// 200 valid, 401 invalid, 403 a valid key that cannot list projects, anything else unreachable.
        init(statusCode: Int) {
            switch statusCode {
            case 200: self = .valid
            case 401: self = .invalid
            case 403: self = .limitedScope
            default: self = .unreachable
            }
        }

        var statusText: String {
            switch self {
            case .valid: "Valid"
            case .invalid: "Invalid"
            case .limitedScope: "Limited scope"
            case .unreachable: "Could not reach Deepgram"
            }
        }
    }

    /// GET projectsEndpoint with the Token header; nil when the trimmed key is
    /// empty. Mirrors TranscriptionService.validateAPIKey's request.
    static func validationRequest(apiKey: String) -> URLRequest? {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var request = URLRequest(url: projectsEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = keyValidationTimeoutSeconds
        request.setValue(authorizationHeaderValue(apiKey: trimmed), forHTTPHeaderField: "Authorization")
        return request
    }

    /// An empty key is .invalid without calling the transport; a thrown
    /// transport error is .unreachable.
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
