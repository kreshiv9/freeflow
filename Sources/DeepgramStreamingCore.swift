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
    /// The socket closed abnormally after the commit, before Metadata arrived.
    case socketClosedBeforeFinal
    /// CommitPolicy.timeout elapsed without Metadata or a close.
    case commitTimedOut
    /// The stream ended without a single Results frame: no audio was processed.
    case noResults
    /// Deepgram reported speech in an interim result that it never finalized.
    case incompleteTranscript

    var errorDescription: String? {
        switch self {
        case .notConnected: "Deepgram streaming socket is not connected"
        case .socketClosedBeforeCommit: "Deepgram socket closed before the transcript was committed"
        case .serverError: "Deepgram reported an error"
        case .socketClosedBeforeFinal: "Deepgram socket closed before the final transcript arrived"
        case .commitTimedOut: "Deepgram did not finish the transcript in time"
        case .noResults: "Deepgram processed no audio"
        case .incompleteTranscript: "Deepgram did not finalize the whole transcript"
        }
    }
}

/// Pure rules for the Deepgram Nova-3 streaming path: URL building, keyterm
/// normalization, server-message parsing, transcript assembly and the commit,
/// keep-alive and key-validation decisions. Never logs, and never embeds the
/// key or transcript text in anything it produces.
enum DeepgramStreamingCore {
    static let listenEndpoint = URL(string: "wss://api.deepgram.com/v1/listen")!
    static let projectsEndpoint = URL(string: "https://api.deepgram.com/v1/projects")!
    static let model = "nova-3"
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
        /// nil or blank = Auto-detect: the query item is omitted.
        let language: String?
        /// The recorder's PCM16 stream rate, passed through unchanged.
        let sampleRate: Int
        let keyterms: [String]
    }

    /// wss://api.deepgram.com/v1/listen?model=nova-3[&language=xx]&encoding=linear16&sample_rate=N
    /// &channels=1&smart_format=true&punctuate=true&interim_results=true[&keyterm=..]*
    /// Fixed item order. Never contains the key. Keyterms pass through
    /// normalizedKeyterms (idempotent). Values are percent-encoded against the
    /// RFC 3986 unreserved set and assembled with percentEncodedQuery, so a
    /// space is %20, "+" is %2B, "&" is %26 and "=" is %3D
    /// (URLComponents.queryItems leaves "+" bare, which a server may decode as a space).
    static func listenURL(for configuration: Configuration) -> URL {
        var items: [(name: String, value: String)] = [("model", model)]
        if let language = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            items.append(("language", language))
        }
        items += [
            ("encoding", "linear16"),
            ("sample_rate", String(configuration.sampleRate)),
            ("channels", "1"),
            ("smart_format", "true"),
            ("punctuate", "true"),
            ("interim_results", "true"),
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

    enum ServerMessage: Equatable {
        case results(transcript: String, isFinal: Bool, speechFinal: Bool, fromFinalize: Bool)
        case metadata
        case utteranceEnd
        case speechStarted
        case error(message: String)
        case unknown

        /// Malformed JSON, a non-object root, a missing or unknown `type` ->
        /// .unknown. Results: channel.alternatives[0].transcript ?? "";
        /// is_final / speech_final / from_finalize default false and tolerate
        /// wrong types. Error: description ?? message ?? a fixed fallback.
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
                    fromFinalize: object["from_finalize"] as? Bool ?? false
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
    /// joins, empties skipped); interim results only count toward resultCount
    /// and hasUnfinalizedSpeech. Metadata marks completion.
    struct TranscriptAssembler: Equatable {
        private(set) var finalTranscript = ""
        /// Every .results, interim or final.
        private(set) var resultCount = 0
        private(set) var hasReceivedMetadata = false
        /// True once a non-empty interim transcript has arrived with no
        /// is_final frame after it: Deepgram heard words it has not yet
        /// finalized, so finalTranscript is missing them. Any final frame,
        /// even an empty one (the server revised the guess away), clears it.
        private(set) var hasUnfinalizedSpeech = false

        var hasReceivedResults: Bool { resultCount > 0 }
        var isComplete: Bool { hasReceivedMetadata }

        /// utteranceEnd, speechStarted, error and unknown are no-ops.
        mutating func apply(_ message: ServerMessage) {
            switch message {
            case .results(let transcript, let isFinal, _, _):
                resultCount += 1
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isFinal else {
                    if !trimmed.isEmpty { hasUnfinalizedSpeech = true }
                    return
                }
                hasUnfinalizedSpeech = false
                guard !trimmed.isEmpty else { return }
                if !finalTranscript.isEmpty { finalTranscript += " " }
                finalTranscript += trimmed
            case .metadata:
                hasReceivedMetadata = true
            case .utteranceEnd, .speechStarted, .error, .unknown:
                break
            }
        }
    }

    enum CommitPolicy {
        static let timeout: TimeInterval = 5
        static let finalizeMessage = #"{"type":"Finalize"}"#
        static let closeStreamMessage = #"{"type":"CloseStream"}"#
        /// Text frames sent back to back, in this order, on shortcut release.
        static let commitMessages = [finalizeMessage, closeStreamMessage]

        enum Decision: Equatable {
            case wait
            case resolve(String)
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
        /// on the timeout. A server error always falls back. Metadata or a
        /// normal close means Deepgram processed all the audio: interim words
        /// it never finalized fall back (the finals would be truncated or
        /// empty), otherwise the assembled finals resolve; when they are empty,
        /// "" if Deepgram sent any Results frame (it heard no words, which the
        /// stop path handles like an empty Realtime result) and .noResults
        /// otherwise. An abnormal close without Metadata falls back whatever
        /// arrived, since the tail may be missing. Only then does the clock matter.
        static func decision(
            assembler: TranscriptAssembler,
            socketState: SocketState,
            serverErrorMessage: String?,
            elapsedSinceCommit: TimeInterval
        ) -> Decision {
            if let serverErrorMessage {
                return .fallBack(.serverError(serverErrorMessage))
            }
            if assembler.hasReceivedMetadata || socketState == .closedNormally {
                if assembler.hasUnfinalizedSpeech {
                    return .fallBack(.incompleteTranscript)
                }
                if !assembler.finalTranscript.isEmpty {
                    return .resolve(assembler.finalTranscript)
                }
                return assembler.hasReceivedResults ? .resolve("") : .fallBack(.noResults)
            }
            if socketState == .closedAbnormally {
                return .fallBack(.socketClosedBeforeFinal)
            }
            if elapsedSinceCommit >= timeout {
                return .fallBack(.commitTimedOut)
            }
            return .wait
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
