import Foundation

private actor DeepgramRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        requests.append(request)
    }
}

/// Synthetic keys, invented vocabulary and hand-written JSON fixtures only.
/// No URLSession, no sockets, no network.
enum DeepgramStreamingCoreTests {
    private typealias Core = DeepgramStreamingCore
    private static let syntheticKey = "synthetic-deepgram-key"

    static func run() async {
        testListenURLIncludesRequiredParameters()
        testListenURLOmitsLanguageOnAutoDetect()
        testKeytermEncoding()
        testKeytermNormalization()
        testKeytermsFromVocabularyText()
        testPendingAudioLimit()
        testParsesFinalAndInterimResults()
        testParsesMetadataUtteranceEndSpeechStartedAndError()
        testParsingToleratesMissingFieldsAndMalformedInput()
        testAssemblerAppendsFinalsInOrderAndIgnoresInterim()
        testCommitPolicyConstantsAndMessages()
        testCommitDecision()
        testKeepAliveDecision()
        testKeyValidationRequestAndStatusMapping()
        await testValidateAPIKeyWithStubTransport()
    }

    private static func configuration(
        language: String? = "en",
        sampleRate: Int = 24000,
        keyterms: [String] = []
    ) -> Core.Configuration {
        Core.Configuration(apiKey: syntheticKey, language: language, sampleRate: sampleRate, keyterms: keyterms)
    }

    private static func query(for configuration: Core.Configuration) -> String {
        let url = Core.listenURL(for: configuration)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
    }

    private static func testListenURLIncludesRequiredParameters() {
        let url = Core.listenURL(for: configuration(keyterms: ["Claude Code", "FreeFlow"]))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        TestSupport.expectEqual(components?.scheme, "wss")
        TestSupport.expectEqual(components?.host, "api.deepgram.com")
        TestSupport.expectEqual(components?.path, "/v1/listen")
        TestSupport.expectEqual(
            components?.percentEncodedQuery,
            "model=nova-3&language=en&encoding=linear16&sample_rate=24000&channels=1&smart_format=true&punctuate=true&interim_results=true&keyterm=Claude%20Code&keyterm=FreeFlow"
        )
        TestSupport.expect(!url.absoluteString.contains(syntheticKey), "The listen URL must never carry the key")
        TestSupport.expectEqual(Core.authorizationHeaderValue(apiKey: " \(syntheticKey) "), "Token \(syntheticKey)")
        TestSupport.expectEqual(Core.model, "nova-3")
    }

    private static func testListenURLOmitsLanguageOnAutoDetect() {
        TestSupport.expect(!query(for: configuration(language: nil)).contains("language="), "nil language must be omitted")
        TestSupport.expect(!query(for: configuration(language: "  ")).contains("language="), "Blank language must be omitted")
        TestSupport.expect(query(for: configuration(language: "es")).contains("language=es"), "A language code must be sent")
        TestSupport.expect(
            query(for: configuration(sampleRate: 16000)).contains("sample_rate=16000"),
            "The sample rate is passed through, never resampled"
        )
        TestSupport.expect(!query(for: configuration()).contains("keyterm="), "No keyterms means no keyterm items")
    }

    private static func testKeytermEncoding() {
        let keyterms = ["C++", "R&D", "a=b", "Zürich"]
        let url = Core.listenURL(for: configuration(keyterms: keyterms))
        let encodedQuery = query(for: configuration(keyterms: keyterms))
        for expected in ["keyterm=C%2B%2B", "keyterm=R%26D", "keyterm=a%3Db", "keyterm=Z%C3%BCrich"] {
            TestSupport.expect(encodedQuery.contains(expected), "Expected \(expected) in \(encodedQuery)")
        }

        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "keyterm" }
            .compactMap(\.value)
        TestSupport.expectEqual(decoded, keyterms)

        let encodedValues = encodedQuery
            .split(separator: "&")
            .filter { $0.hasPrefix("keyterm=") }
            .map { $0.dropFirst("keyterm=".count) }
        TestSupport.expectEqual(encodedValues.count, keyterms.count)
        for value in encodedValues {
            TestSupport.expect(
                !value.contains(" ") && !value.contains("+") && !value.contains("&") && !value.contains("="),
                "Encoded keyterm \(value) must not contain a raw space, '+', '&' or '='"
            )
        }
    }

    private static func testKeytermNormalization() {
        TestSupport.expectEqual(Core.maxKeytermLength, 60)
        TestSupport.expectEqual(Core.maxKeyterms, 100)
        TestSupport.expectEqual(Core.maxKeytermTotalCharacters, 1200)

        TestSupport.expectEqual(Core.normalizedKeyterms(["  Claude\tCode  "]), ["Claude Code"])
        TestSupport.expectEqual(Core.normalizedKeyterms(["Claude \r\n Code", "Free  \n Flow"]), ["Claude Code", "Free Flow"])
        TestSupport.expectEqual(Core.normalizedKeyterms(["", "   ", "\t\n", "FreeFlow"]), ["FreeFlow"])

        let sixty = String(repeating: "a", count: 60)
        let sixtyOne = String(repeating: "b", count: 61)
        TestSupport.expectEqual(Core.normalizedKeyterms([sixtyOne, sixty]), [sixty])

        TestSupport.expectEqual(Core.normalizedKeyterms(["FreeFlow", "freeflow", "FREEFLOW"]), ["FreeFlow"])

        let manyShort = (0..<150).map { "term\($0)" }
        let cappedByCount = Core.normalizedKeyterms(manyShort)
        TestSupport.expectEqual(cappedByCount, Array(manyShort.prefix(100)))

        let manyLong = (0..<30).map { index in
            String(repeating: Character(UnicodeScalar(97 + index % 26)!), count: 59) + String(index % 10)
        }
        TestSupport.expectEqual(Set(manyLong).count, 30)
        let cappedByCharacters = Core.normalizedKeyterms(manyLong)
        TestSupport.expectEqual(cappedByCharacters.count, 20)
        TestSupport.expectEqual(cappedByCharacters, Array(manyLong.prefix(20)))

        let mixed = ["  Claude\tCode  ", "freeflow", "FreeFlow", sixtyOne, "", "Deepgram"]
        TestSupport.expectEqual(Core.normalizedKeyterms(Core.normalizedKeyterms(mixed)), Core.normalizedKeyterms(mixed))

        let capped = query(for: configuration(keyterms: manyShort))
        TestSupport.expectEqual(capped.components(separatedBy: "keyterm=").count - 1, 100)
    }

    private static func testKeytermsFromVocabularyText() {
        TestSupport.expectEqual(
            Core.keyterms(fromVocabularyText: "Claude Code\nFreeFlow, Deepgram;  Nova-3 \r\n , ;"),
            ["Claude Code", "FreeFlow", "Deepgram", "Nova-3"]
        )
        TestSupport.expectEqual(Core.keyterms(fromVocabularyText: ""), [])
        TestSupport.expectEqual(Core.keyterms(fromVocabularyText: ",;\n"), [])

        let merged = DictionaryCorrection.vocabularyText(
            "Foo, Bar",
            merging: [DictionaryCorrection(from: "klaud", to: "Claude Code")]
        )
        TestSupport.expectEqual(Core.keyterms(fromVocabularyText: merged), ["Foo", "Bar", "Claude Code"])
    }

    private static func testPendingAudioLimit() {
        TestSupport.expectEqual(Core.maxPendingAudioSeconds, 10)
        TestSupport.expectEqual(Core.maxPendingAudioBytes(sampleRate: 24000), 480_000)
        TestSupport.expectEqual(Core.maxPendingAudioBytes(sampleRate: 16000), 320_000)
        TestSupport.expect(
            Core.socketIdleTimeoutSeconds > HandsFreeAutoStop.maximumMilliseconds / 1000,
            "The socket idle timeout must outlast the longest possible dictation"
        )
    }

    private static func message(_ json: String) -> Core.ServerMessage {
        Core.ServerMessage(data: Data(json.utf8))
    }

    private static func testParsesFinalAndInterimResults() {
        let final = #"{"type":"Results","is_final":true,"speech_final":true,"channel":{"alternatives":[{"transcript":"synthetic final text","confidence":0.9}]}}"#
        TestSupport.expectEqual(
            message(final),
            .results(transcript: "synthetic final text", isFinal: true, speechFinal: true, fromFinalize: false)
        )

        let interim = #"{"type":"Results","is_final":false,"speech_final":false,"channel":{"alternatives":[{"transcript":"synthetic partial"}]}}"#
        TestSupport.expectEqual(
            message(interim),
            .results(transcript: "synthetic partial", isFinal: false, speechFinal: false, fromFinalize: false)
        )

        let finalized = #"{"type":"Results","is_final":true,"from_finalize":true,"channel":{"alternatives":[{"transcript":"flushed"}]}}"#
        TestSupport.expectEqual(
            message(finalized),
            .results(transcript: "flushed", isFinal: true, speechFinal: false, fromFinalize: true)
        )
    }

    private static func testParsesMetadataUtteranceEndSpeechStartedAndError() {
        TestSupport.expectEqual(message(#"{"type":"Metadata","request_id":"synthetic"}"#), .metadata)
        TestSupport.expectEqual(message(#"{"type":"UtteranceEnd","last_word_end":1.2}"#), .utteranceEnd)
        TestSupport.expectEqual(message(#"{"type":"SpeechStarted","timestamp":0.1}"#), .speechStarted)
        TestSupport.expectEqual(
            message(#"{"type":"Error","description":"synthetic failure"}"#),
            .error(message: "synthetic failure")
        )
        TestSupport.expectEqual(message(#"{"type":"Error","message":"other"}"#), .error(message: "other"))
        TestSupport.expectEqual(message(#"{"type":"Error"}"#), .error(message: "unknown Deepgram error"))
    }

    private static func testParsingToleratesMissingFieldsAndMalformedInput() {
        let empty = Core.ServerMessage.results(transcript: "", isFinal: false, speechFinal: false, fromFinalize: false)
        TestSupport.expectEqual(message(#"{"type":"Results"}"#), empty)
        TestSupport.expectEqual(message(#"{"type":"Results","channel":{"alternatives":[]}}"#), empty)
        TestSupport.expectEqual(message(#"{"type":"Results","is_final":"yes"}"#), empty)
        for malformed in ["{not json", "[]", #"{"foo":1}"#, #"{"type":"Warning"}"#] {
            TestSupport.expectEqual(message(malformed), .unknown)
        }
        TestSupport.expectEqual(Core.ServerMessage(data: Data()), .unknown)
    }

    private static func results(_ transcript: String, isFinal: Bool) -> Core.ServerMessage {
        .results(transcript: transcript, isFinal: isFinal, speechFinal: false, fromFinalize: false)
    }

    private static func testAssemblerAppendsFinalsInOrderAndIgnoresInterim() {
        var assembler = Core.TranscriptAssembler()
        TestSupport.expectEqual(assembler.finalTranscript, "")
        TestSupport.expectEqual(assembler.resultCount, 0)
        TestSupport.expect(!assembler.hasReceivedResults, "A fresh assembler has seen no results")
        TestSupport.expect(!assembler.hasReceivedMetadata, "A fresh assembler has no metadata")
        TestSupport.expect(!assembler.isComplete, "A fresh assembler is not complete")

        assembler.apply(results("hel", isFinal: false))
        TestSupport.expect(assembler.hasUnfinalizedSpeech, "A non-empty interim is speech awaiting its final")
        assembler.apply(results("  Hello ", isFinal: true))
        TestSupport.expect(!assembler.hasUnfinalizedSpeech, "A final frame finalizes the pending interim")
        assembler.apply(results("wor", isFinal: false))
        assembler.apply(results("world.", isFinal: true))
        assembler.apply(results("", isFinal: true))
        assembler.apply(results("   ", isFinal: true))
        assembler.apply(.utteranceEnd)
        assembler.apply(.speechStarted)
        assembler.apply(.unknown)
        TestSupport.expectEqual(assembler.finalTranscript, "Hello world.")
        TestSupport.expectEqual(assembler.resultCount, 6)
        TestSupport.expect(assembler.hasReceivedResults, "Results frames must be counted")
        TestSupport.expect(!assembler.hasUnfinalizedSpeech, "Every interim was finalized")
        TestSupport.expect(!assembler.isComplete && !assembler.hasReceivedMetadata, "No metadata yet")

        assembler.apply(.metadata)
        TestSupport.expect(assembler.isComplete && assembler.hasReceivedMetadata, "Metadata completes the stream")
        TestSupport.expectEqual(assembler.finalTranscript, "Hello world.")

        var interimOnly = Core.TranscriptAssembler()
        interimOnly.apply(results("partial", isFinal: false))
        TestSupport.expectEqual(interimOnly.finalTranscript, "")
        TestSupport.expect(interimOnly.hasReceivedResults, "An interim result still counts as processed audio")
        TestSupport.expect(interimOnly.hasUnfinalizedSpeech, "Interim words without a final are unfinalized speech")

        var revisedAway = interimOnly
        revisedAway.apply(results("", isFinal: true))
        TestSupport.expect(!revisedAway.hasUnfinalizedSpeech, "An empty final clears the interim guess")
        TestSupport.expectEqual(revisedAway.finalTranscript, "")

        var blankInterim = Core.TranscriptAssembler()
        blankInterim.apply(results("   ", isFinal: false))
        TestSupport.expect(blankInterim.hasReceivedResults, "A blank interim is still a Results frame")
        TestSupport.expect(!blankInterim.hasUnfinalizedSpeech, "A blank interim carries no speech")

        var truncatedTail = Core.TranscriptAssembler()
        truncatedTail.apply(results("Hello", isFinal: true))
        truncatedTail.apply(results("wor", isFinal: false))
        TestSupport.expectEqual(truncatedTail.finalTranscript, "Hello")
        TestSupport.expect(truncatedTail.hasUnfinalizedSpeech, "An interim after the last final is a missing tail")
    }

    private static func testCommitPolicyConstantsAndMessages() {
        TestSupport.expectEqual(Core.CommitPolicy.timeout, 5)
        TestSupport.expectEqual(
            Core.CommitPolicy.commitMessages,
            [Core.CommitPolicy.finalizeMessage, Core.CommitPolicy.closeStreamMessage]
        )
        let expected = [
            (Core.KeepAlivePolicy.message, "KeepAlive"),
            (Core.CommitPolicy.finalizeMessage, "Finalize"),
            (Core.CommitPolicy.closeStreamMessage, "CloseStream"),
        ]
        for (text, type) in expected {
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            TestSupport.expectEqual(object?.keys.sorted(), ["type"])
            TestSupport.expectEqual(object?["type"] as? String, type)
        }
    }

    private static func decision(
        _ assembler: Core.TranscriptAssembler,
        socket: Core.CommitPolicy.SocketState = .open,
        serverErrorMessage: String? = nil,
        elapsed: TimeInterval = 0
    ) -> Core.CommitPolicy.Decision {
        Core.CommitPolicy.decision(
            assembler: assembler,
            socketState: socket,
            serverErrorMessage: serverErrorMessage,
            elapsedSinceCommit: elapsed
        )
    }

    private static func testCommitDecision() {
        let empty = Core.TranscriptAssembler()
        TestSupport.expectEqual(decision(empty, elapsed: 4.99), .wait)
        TestSupport.expectEqual(decision(empty, elapsed: 5.0), .fallBack(.commitTimedOut))

        var ready = Core.TranscriptAssembler()
        ready.apply(results("ready", isFinal: true))
        var readyWithMetadata = ready
        readyWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(readyWithMetadata), .resolve("ready"))
        TestSupport.expectEqual(decision(ready, socket: .closedNormally), .resolve("ready"))
        TestSupport.expectEqual(decision(ready), .wait)

        // An abnormal close before Metadata may have cut off the tail, so the
        // file upload wins even when some finals arrived; Metadata first means
        // the stream completed and the close code no longer matters.
        TestSupport.expectEqual(decision(ready, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))
        TestSupport.expectEqual(decision(readyWithMetadata, socket: .closedAbnormally), .resolve("ready"))
        TestSupport.expectEqual(decision(empty, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))

        // Interim words without a final are speech the finals do not carry:
        // never resolve "" or a truncated transcript over them.
        var interimOnly = Core.TranscriptAssembler()
        interimOnly.apply(results("partial", isFinal: false))
        var interimWithMetadata = interimOnly
        interimWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(interimWithMetadata), .fallBack(.incompleteTranscript))
        TestSupport.expectEqual(decision(interimOnly, socket: .closedNormally), .fallBack(.incompleteTranscript))
        TestSupport.expectEqual(decision(interimOnly, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))
        TestSupport.expectEqual(decision(interimOnly), .wait)

        var truncatedTail = ready
        truncatedTail.apply(results("tail", isFinal: false))
        TestSupport.expectEqual(decision(truncatedTail, socket: .closedNormally), .fallBack(.incompleteTranscript))
        var finalizedTail = truncatedTail
        finalizedTail.apply(results("tail.", isFinal: true))
        TestSupport.expectEqual(decision(finalizedTail, socket: .closedNormally), .resolve("ready tail."))

        // Deepgram processed audio and heard nothing: an empty result, like Realtime.
        var blankInterimOnly = Core.TranscriptAssembler()
        blankInterimOnly.apply(results("", isFinal: false))
        TestSupport.expectEqual(decision(blankInterimOnly, socket: .closedNormally), .resolve(""))
        var revisedAway = interimOnly
        revisedAway.apply(results("", isFinal: true))
        revisedAway.apply(.metadata)
        TestSupport.expectEqual(decision(revisedAway), .resolve(""))

        var emptyWithMetadata = Core.TranscriptAssembler()
        emptyWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(emptyWithMetadata), .fallBack(.noResults))
        TestSupport.expectEqual(decision(empty, socket: .closedNormally), .fallBack(.noResults))

        TestSupport.expectEqual(
            decision(readyWithMetadata, serverErrorMessage: "synthetic"),
            .fallBack(.serverError("synthetic"))
        )
        TestSupport.expectEqual(
            decision(ready, socket: .closedAbnormally, serverErrorMessage: "synthetic"),
            .fallBack(.serverError("synthetic"))
        )
        TestSupport.expectEqual(decision(readyWithMetadata, elapsed: 10), .resolve("ready"))

        let errors: [DeepgramStreamingError] = [
            .notConnected, .socketClosedBeforeCommit, .serverError("synthetic secret"), .socketClosedBeforeFinal,
            .commitTimedOut, .noResults, .incompleteTranscript,
        ]
        for error in errors {
            TestSupport.expect(error.errorDescription != nil, "\(error) must describe itself")
        }
        TestSupport.expect(
            DeepgramStreamingError.serverError("synthetic secret").errorDescription?.contains("synthetic secret") == false,
            "The server message is untrusted and must never reach the description"
        )
    }

    private static func testKeepAliveDecision() {
        TestSupport.expectEqual(Core.KeepAlivePolicy.interval, 5)
        TestSupport.expect(Core.KeepAlivePolicy.shouldSendKeepAlive(lastAudioSentAt: nil, now: 100), "No audio yet")
        TestSupport.expect(!Core.KeepAlivePolicy.shouldSendKeepAlive(lastAudioSentAt: 98, now: 100), "Audio is recent")
        TestSupport.expect(Core.KeepAlivePolicy.shouldSendKeepAlive(lastAudioSentAt: 95, now: 100), "Exactly one interval")
        TestSupport.expect(Core.KeepAlivePolicy.shouldSendKeepAlive(lastAudioSentAt: 70, now: 100), "Long idle")
    }

    private static func testKeyValidationRequestAndStatusMapping() {
        let request = Core.validationRequest(apiKey: " synthetic-key ")
        TestSupport.expectEqual(request?.url?.absoluteString, "https://api.deepgram.com/v1/projects")
        TestSupport.expectEqual(request?.httpMethod, "GET")
        TestSupport.expectEqual(request?.value(forHTTPHeaderField: "Authorization"), "Token synthetic-key")
        TestSupport.expectEqual(request?.timeoutInterval, 10)
        TestSupport.expectEqual(request?.httpBody, nil)
        TestSupport.expectEqual(Core.validationRequest(apiKey: "   "), nil)

        TestSupport.expectEqual(Core.KeyValidation(statusCode: 200), .valid)
        TestSupport.expectEqual(Core.KeyValidation(statusCode: 401), .invalid)
        TestSupport.expectEqual(Core.KeyValidation(statusCode: 403), .limitedScope)
        for status in [0, 404, 500] {
            TestSupport.expectEqual(Core.KeyValidation(statusCode: status), .unreachable)
        }
        TestSupport.expectEqual(Core.KeyValidation.valid.statusText, "Valid")
        TestSupport.expectEqual(Core.KeyValidation.invalid.statusText, "Invalid")
        TestSupport.expectEqual(Core.KeyValidation.limitedScope.statusText, "Limited scope")
        TestSupport.expectEqual(Core.KeyValidation.unreachable.statusText, "Could not reach Deepgram")
    }

    private static func testValidateAPIKeyWithStubTransport() async {
        let recorder = DeepgramRequestRecorder()
        func stub(status: Int) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { request in
                await recorder.append(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(), response)
            }
        }

        let outcomes: [(Int, Core.KeyValidation)] = [
            (200, .valid), (401, .invalid), (403, .limitedScope), (500, .unreachable),
        ]
        for (status, expected) in outcomes {
            let result = await Core.validateAPIKey(syntheticKey, transport: stub(status: status))
            TestSupport.expectEqual(result, expected)
        }

        struct SyntheticTransportFailure: Error {}
        let unreachable = await Core.validateAPIKey(syntheticKey) { _ in throw SyntheticTransportFailure() }
        TestSupport.expectEqual(unreachable, .unreachable)

        let requestsBeforeEmptyKeys = await recorder.requests.count
        let emptyKey = await Core.validateAPIKey("", transport: stub(status: 200))
        TestSupport.expectEqual(emptyKey, .invalid)
        let whitespaceKey = await Core.validateAPIKey("   \n", transport: stub(status: 200))
        TestSupport.expectEqual(whitespaceKey, .invalid)
        let requests = await recorder.requests
        TestSupport.expectEqual(requests.count, requestsBeforeEmptyKeys)
        TestSupport.expectEqual(requests.count, outcomes.count)
        for request in requests {
            TestSupport.expectEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/projects")
            TestSupport.expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Token \(syntheticKey)")
        }
    }
}
