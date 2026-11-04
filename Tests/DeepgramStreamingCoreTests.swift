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
        testListenURLSendsEnglishOnAutoDetect()
        testKeytermEncoding()
        testKeytermNormalization()
        testKeytermsFromVocabularyText()
        testConfigureMessage()
        testKeytermPlanConnectTerms()
        testKeytermPlanConfigureTerms()
        testAudioMilliseconds()
        testConfigureRepliesAreIgnored()
        testPendingAudioLimit()
        testFrameBytes()
        testFrameAggregatorCarriesRemainderAcrossAppends()
        testFrameAggregatorFlushAndEmptyInput()
        testFrameAggregatorSplitsLargeAppendInOrder()
        testFrameAggregatorConservesBytes()
        testParsesFinalAndInterimResults()
        testParsesMetadataUtteranceEndSpeechStartedAndError()
        testParsingToleratesMissingFieldsAndMalformedInput()
        testFinalWordsParsing()
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
            "model=nova-3&language=en&encoding=linear16&sample_rate=24000&channels=1&smart_format=true&punctuate=true&interim_results=true&endpointing=500&mip_opt_out=true&keyterm=Claude%20Code&keyterm=FreeFlow"
        )
        TestSupport.expect(!url.absoluteString.contains(syntheticKey), "The listen URL must never carry the key")
        TestSupport.expectEqual(Core.authorizationHeaderValue(apiKey: " \(syntheticKey) "), "Token \(syntheticKey)")
        TestSupport.expectEqual(Core.model, "nova-3")
        TestSupport.expectEqual(Core.endpointingMilliseconds, 500)
        TestSupport.expectEqual(Core.defaultLanguage, "en")
    }

    private static func languageValues(for configuration: Core.Configuration) -> [String] {
        let url = Core.listenURL(for: configuration)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "language" }
            .compactMap(\.value) ?? []
    }

    /// Auto-detect sends Deepgram's own default explicitly, exactly once.
    private static func testListenURLSendsEnglishOnAutoDetect() {
        for autoDetect: String? in [nil, "  ", "\n\t"] {
            TestSupport.expectEqual(languageValues(for: configuration(language: autoDetect)), ["en"])
        }
        TestSupport.expectEqual(query(for: configuration(language: nil)), query(for: configuration(language: "en")))
        TestSupport.expectEqual(languageValues(for: configuration(language: "es")), ["es"])
        TestSupport.expectEqual(languageValues(for: configuration(language: " es ")), ["es"])
        for language: String? in [nil, "  ", "es"] {
            TestSupport.expect(
                !Core.listenURL(for: configuration(language: language)).absoluteString.contains(syntheticKey),
                "The listen URL must never carry the key"
            )
        }
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

        // A term that would pass the character cap is skipped; later, shorter terms still fit.
        let fiftyNines = (0..<20).map { index in
            String(repeating: Character(UnicodeScalar(97 + index)!), count: 59)
        }
        let thirty = String(repeating: "z", count: 30)
        let skipped = Core.normalizedKeyterms(fiftyNines + [thirty, "Abc"])
        TestSupport.expectEqual(skipped.count, 21)
        TestSupport.expectEqual(skipped.last, "Abc")
        TestSupport.expect(!skipped.contains(thirty), "The term that would pass 1,200 characters is skipped")

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

    /// The mid-stream keyterm update: fixed field names, normalized terms, never the key.
    private static func testConfigureMessage() {
        let configure = Core.configureMessage(keyterms: ["  Synthetic   Term ", "fooBar", "FOOBAR", "", "a/b", "say \"hi\""])
        TestSupport.expectEqual(
            configure,
            #"{"keyterms":["Synthetic Term","fooBar","a/b","say \"hi\""],"type":"Configure"}"#
        )
        let decoded = (try? JSONSerialization.jsonObject(with: Data((configure ?? "").utf8))) as? [String: Any]
        TestSupport.expectEqual(decoded?["type"] as? String, "Configure")
        TestSupport.expectEqual(decoded?["keyterms"] as? [String], ["Synthetic Term", "fooBar", "a/b", "say \"hi\""])
        TestSupport.expectEqual(Core.configureMessage(keyterms: []), nil)
        TestSupport.expect(configure?.contains(syntheticKey) == false, "The Configure message must never carry the key")
    }

    /// The connect URL: correction targets, then vocabulary, then at most two own-name terms,
    /// then the learned slice clamped to 10...25 by the manual terms kept.
    private static func testKeytermPlanConnectTerms() {
        typealias Plan = Core.KeytermPlan
        TestSupport.expectEqual(Plan.targetTotal, 50)
        TestSupport.expectEqual(Plan.minimumScreenSlots, 15)
        TestSupport.expectEqual(Plan.maxOwnNameTerms, 2)
        TestSupport.expectEqual(Plan.learnedSlots, 10...25)

        TestSupport.expectEqual(
            Plan.connectTerms(.init(
                correctionTargets: ["Claude Code"],
                vocabulary: ["Wispr Flow", "claude code", "Deepgram"],
                ownName: ["Kai", "Kai Example", "Extra"]
            )),
            ["Claude Code", "Wispr Flow", "Deepgram", "Kai", "Kai Example"]
        )

        let vocabulary100 = (0..<100).map { "Term\($0)x" }
        let full = Plan.connectTerms(.init(correctionTargets: ["Claude Code"], vocabulary: vocabulary100))
        TestSupport.expectEqual(full.count, 100)
        TestSupport.expectEqual(full.first, "Claude Code")

        let learned = (0..<40).map { "Learned\($0)y" }
        let small = Plan.connectTerms(.init(vocabulary: ["Alpha1x", "Beta2x"], learned: learned))
        TestSupport.expectEqual(small.count, 27)
        TestSupport.expectEqual(Array(small.dropFirst(2)), Array(learned.prefix(25)))
        let thirty = (0..<30).map { "Vocab\($0)x" }
        TestSupport.expectEqual(Plan.connectTerms(.init(vocabulary: thirty, learned: learned)).count, 50)
        let fortyFive = (0..<45).map { "Vocab\($0)x" }
        TestSupport.expectEqual(Plan.connectTerms(.init(vocabulary: fortyFive, learned: learned)).count, 55)
        TestSupport.expectEqual(Plan.connectTerms(.init()), [])

        // A term that would pass 1,200 characters is skipped; later, shorter terms of the same
        // tier and of the next tiers still fit.
        let thirtyCharacters = String(repeating: "z", count: 30)
        let nearCap = Plan.connectTerms(.init(
            correctionTargets: fiftyNineCharacterTerms, vocabulary: [thirtyCharacters, "Abc"], ownName: ["Kai"]
        ))
        TestSupport.expectEqual(nearCap.count, 22)
        TestSupport.expectEqual(Array(nearCap.suffix(2)), ["Abc", "Kai"])
        TestSupport.expect(!nearCap.contains(thirtyCharacters), "The term that would pass 1,200 characters is skipped")
    }

    /// Twenty distinct terms of 59 characters: 1,180 of the 1,200-character cap.
    private static let fiftyNineCharacterTerms = (0..<20).map { index in
        String(repeating: Character(UnicodeScalar(97 + index)!), count: 59)
    }

    /// The one Configure: the connect list unchanged, then screen names, then identifiers,
    /// about targetTotal in all with at least minimumScreenSlots for the screen; nil when
    /// nothing new fits.
    private static func testKeytermPlanConfigureTerms() {
        typealias Plan = Core.KeytermPlan
        let full = (0..<100).map { "term\($0)" }
        TestSupport.expect(
            Plan.configureTerms(connect: full, screenTerms: ["Supabase"], identifiers: ["useAuth"]) == nil,
            "No Configure when the connect list is at the hard cap"
        )
        TestSupport.expect(
            Plan.configureTerms(connect: ["Synthetic Term"], screenTerms: ["synthetic term"], identifiers: ["a.b"]) == nil,
            "No Configure when nothing new fits"
        )

        let connect = ["Claude Code", "Wispr Flow", "Deepgram", "Kai", "Kai Example"]
        let screen = (0..<60).map { "Screen\($0)y" }
        let planned = Plan.configureTerms(connect: connect, screenTerms: screen, identifiers: ["fooBar"])
        TestSupport.expectEqual(planned?.terms.count, 50)
        TestSupport.expectEqual(planned.map { Array($0.terms.prefix(5)) }, connect)
        TestSupport.expectEqual(planned?.screenCount, 45)
        TestSupport.expectEqual(planned?.identifierCount, 0)

        let vocabulary80 = (0..<80).map { "V\($0)" }
        TestSupport.expectEqual(
            Plan.configureTerms(connect: vocabulary80, screenTerms: screen, identifiers: [])?.screenCount, 15
        )

        let ordered = Plan.configureTerms(connect: [], screenTerms: ["Vercel"], identifiers: ["useAuth"])
        TestSupport.expectEqual(ordered?.terms, ["Vercel", "useAuth"])
        TestSupport.expectEqual(ordered?.screenCount, 1)
        TestSupport.expectEqual(ordered?.identifierCount, 1)

        // Identifiers alone send a Configure, counted apart from on-screen names.
        let codeOnly = Plan.configureTerms(connect: ["Synthetic Term"], screenTerms: [], identifiers: ["useAuth"])
        TestSupport.expectEqual(codeOnly?.screenCount, 0)
        TestSupport.expectEqual(codeOnly?.identifierCount, 1)

        let filtered = Plan.configureTerms(
            connect: ["Synthetic Term"],
            screenTerms: ["1234567890", "gh" + "p_" + String(repeating: "FAKEfake", count: 4), "Supabase"],
            identifiers: [
                "appState.isRecording", "1234567890", "gh" + "p_" + String(repeating: "FAKEfake", count: 4), "fooBar"
            ]
        )
        TestSupport.expectEqual(filtered?.terms, ["Synthetic Term", "Supabase", "fooBar"])

        // Near the character cap a long screen term is skipped, and shorter terms still fit.
        let nearCap = Plan.configureTerms(
            connect: fiftyNineCharacterTerms,
            screenTerms: [String(repeating: "z", count: 30), "Vercel"],
            identifiers: ["fooBar"]
        )
        TestSupport.expectEqual(nearCap?.terms, fiftyNineCharacterTerms + ["Vercel", "fooBar"])
        // The identifier tier skips the same way: a long identifier is passed over, not the end.
        let nearCapIdentifiers = Plan.configureTerms(
            connect: fiftyNineCharacterTerms,
            screenTerms: [],
            identifiers: ["syntheticLongIdentifier" + String(repeating: "x", count: 20), "useAuth"]
        )
        TestSupport.expectEqual(nearCapIdentifiers?.terms, fiftyNineCharacterTerms + ["useAuth"])
        TestSupport.expectEqual(nearCapIdentifiers?.identifierCount, 1)

        // Secret-like identifiers never reach the Configure, whatever their shape.
        let secretIdentifiers = Plan.configureTerms(
            connect: [],
            screenTerms: [],
            identifiers: [
                "AbCdEf" + "123456" + "GhIjKlMn", "sk-" + "proj-" + "FAKEfake0000FAKEfake0000",
                String(repeating: "3f9a1c0b7e", count: 4), "acct12345678", "useAuth",
            ]
        )
        TestSupport.expectEqual(secretIdentifiers?.terms, ["useAuth"])
        TestSupport.expectEqual(secretIdentifiers?.identifierCount, 1)
        TestSupport.expect(
            Plan.configureTerms(connect: ["Synthetic Term"], screenTerms: [], identifiers: ["AbCdEf" + "123456" + "GhIjKlMn"]) == nil,
            "Only secret-like identifiers send no Configure"
        )

        // The Run Log's screen count is on-screen names only; IDE identifiers show as "code".
        let editorPlan = Plan.configureTerms(
            connect: ["Synthetic Term"], screenTerms: ["Supabase"], identifiers: ["useAuth", "fooBar"]
        )
        TestSupport.expectEqual(
            PipelineStageTimings(
                keytermsAtConnect: 1, screenKeyterms: editorPlan?.screenCount, codeKeyterms: editorPlan?.identifierCount,
                screenKeytermsAudioMilliseconds: 0
            ).keytermLine,
            "keyterms 1 · screen 1 · code 2 (from start)"
        )
        let identifiersOnly = Plan.configureTerms(connect: ["Synthetic Term"], screenTerms: [], identifiers: ["useAuth", "fooBar"])
        TestSupport.expectEqual(
            PipelineStageTimings(
                keytermsAtConnect: 1, screenKeyterms: identifiersOnly?.screenCount,
                codeKeyterms: identifiersOnly?.identifierCount, screenKeytermsAudioMilliseconds: 0
            ).keytermLine,
            "keyterms 1 · code 2 (from start)"
        )

        // A dot outside a version number marks a host or domain, which is never sent.
        let dotted = Plan.configureTerms(
            connect: [],
            screenTerms: ["zorblax-lab [SSH: devbox-07.corp.example.internal", "Next.js", "GPT-4.5", "Llama-3.1-8B"],
            identifiers: []
        )
        TestSupport.expectEqual(dotted?.terms, ["GPT-4.5", "Llama-3.1-8B"])

        let names = (0..<10).map { "Name\($0)z" }
        let identifiers = (0..<20).map { "identifier\($0)Value" }
        let filled = Plan.configureTerms(connect: vocabulary80, screenTerms: names, identifiers: identifiers)
        TestSupport.expectEqual(filled?.screenCount, 10)
        TestSupport.expectEqual(filled?.identifierCount, 5)
        TestSupport.expectEqual(filled.map { Array($0.terms.suffix(15)) }, names + Array(identifiers.prefix(5)))
    }

    private static func testAudioMilliseconds() {
        TestSupport.expectEqual(Core.audioMilliseconds(bytes: 32_000, sampleRate: 16_000), 1000)
        TestSupport.expectEqual(Core.audioMilliseconds(bytes: 0, sampleRate: 16_000), 0)
        TestSupport.expectEqual(Core.audioMilliseconds(bytes: 32_000, sampleRate: 0), 0)
    }

    /// Deepgram answers a Configure with ConfigureSuccess or ConfigureFailure; neither may
    /// change the transcript or the commit decision, so a refused update keeps the stream.
    private static func testConfigureRepliesAreIgnored() {
        let success = message(#"{"type":"ConfigureSuccess","request_id":"synthetic","keyterms":["fooBar"]}"#)
        let failure = message(
            #"{"type":"ConfigureFailure","request_id":"synthetic","code":"CONFIGURE_KEYTERM_LIMIT_EXCEEDED","description":"synthetic"}"#
        )
        TestSupport.expectEqual(success, .unknown)
        TestSupport.expectEqual(failure, .unknown)

        var assembler = Core.TranscriptAssembler()
        assembler.apply(success)
        assembler.apply(failure)
        TestSupport.expectEqual(assembler, Core.TranscriptAssembler())
        TestSupport.expectEqual(decision(assembler), decision(Core.TranscriptAssembler()))
        TestSupport.expectEqual(decision(assembler, elapsed: 5), .fallBack(.commitTimedOut))
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

    /// Synthetic bytes 0, 1, 2, ... wrapping at 256, so a dropped or shifted byte changes the content.
    private static func ramp(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
    }

    private static func testFrameBytes() {
        TestSupport.expectEqual(Core.frameMilliseconds, 50)
        TestSupport.expectEqual(Core.frameBytes(sampleRate: 16_000), 1_600)
        TestSupport.expectEqual(Core.frameBytes(sampleRate: 24_000), 2_400)
        TestSupport.expectEqual(Core.frameBytes(sampleRate: 48_000), 4_800)
        // 2205 bytes rounds down to whole Int16 samples.
        TestSupport.expectEqual(Core.frameBytes(sampleRate: 22_050), 2_204)
        TestSupport.expectEqual(Core.frameBytes(sampleRate: 11_025), 1_102)
        for sampleRate in [0, 1, 8_000, 11_025, 16_000, 22_050, 24_000, 44_100, 48_000] {
            let bytes = Core.frameBytes(sampleRate: sampleRate)
            TestSupport.expect(bytes % 2 == 0, "\(sampleRate) Hz frames must hold whole Int16 samples, got \(bytes)")
            TestSupport.expect(bytes >= 2, "\(sampleRate) Hz frames must hold at least one sample, got \(bytes)")
        }
    }

    /// 341-sample capture chunks become 1600-byte frames at 16 kHz.
    private static func testFrameAggregatorCarriesRemainderAcrossAppends() {
        let input = ramp(6_820)
        var aggregator = Core.FrameAggregator(frameBytes: Core.frameBytes(sampleRate: 16_000))
        var output = Data()
        var framesPerAppend: [Int] = []
        for start in stride(from: 0, to: input.count, by: 682) {
            let frames = aggregator.append(input.subdata(in: start..<start + 682))
            framesPerAppend.append(frames.count)
            for frame in frames {
                TestSupport.expectEqual(frame.count, 1_600)
                output.append(frame)
            }
        }
        TestSupport.expectEqual(framesPerAppend, [0, 0, 1, 0, 1, 0, 0, 1, 0, 1])

        let remainder = aggregator.flush()
        TestSupport.expectEqual(remainder?.count, 420)
        TestSupport.expectEqual(aggregator.flush(), nil)
        output.append(remainder ?? Data())
        TestSupport.expectEqual(output, input)
        TestSupport.expectEqual(aggregator, Core.FrameAggregator(frameBytes: 1_600))
    }

    private static func testFrameAggregatorFlushAndEmptyInput() {
        var aggregator = Core.FrameAggregator(frameBytes: 1_600)
        TestSupport.expectEqual(aggregator.flush(), nil)
        TestSupport.expectEqual(aggregator.append(Data()), [])
        TestSupport.expectEqual(aggregator.flush(), nil)

        let exact = ramp(1_600)
        TestSupport.expectEqual(aggregator.append(exact), [exact])
        TestSupport.expectEqual(aggregator.flush(), nil)

        let short = ramp(3)
        TestSupport.expectEqual(aggregator.append(short), [])
        TestSupport.expectEqual(aggregator.flush(), short)
        TestSupport.expectEqual(aggregator.flush(), nil)

        // A zero frame size is raised to one Int16 sample, so no frame is ever empty.
        var minimal = Core.FrameAggregator(frameBytes: 0)
        TestSupport.expectEqual(minimal.frameBytes, 2)
        TestSupport.expectEqual(minimal.append(ramp(5)).map(\.count), [2, 2])
        TestSupport.expectEqual(minimal.flush()?.count, 1)
        TestSupport.expectEqual(minimal.flush(), nil)
    }

    private static func testFrameAggregatorSplitsLargeAppendInOrder() {
        let input = ramp(7_300)
        var aggregator = Core.FrameAggregator(frameBytes: 2_400)
        TestSupport.expectEqual(
            aggregator.append(input),
            [Data(input[0..<2_400]), Data(input[2_400..<4_800]), Data(input[4_800..<7_200])]
        )
        TestSupport.expectEqual(aggregator.flush(), Data(input[7_200..<7_300]))
        TestSupport.expectEqual(aggregator.flush(), nil)
    }

    private static func testFrameAggregatorConservesBytes() {
        let chunkSizes = [0, 1, 682, 1_599, 1_600, 1_601, 3_200, 4_799, 2, 341]
        let input = ramp(13_825)
        TestSupport.expectEqual(chunkSizes.reduce(0, +), input.count)

        var aggregator = Core.FrameAggregator(frameBytes: Core.frameBytes(sampleRate: 16_000))
        var output = Data()
        var start = 0
        for size in chunkSizes {
            for frame in aggregator.append(input.subdata(in: start..<start + size)) {
                TestSupport.expectEqual(frame.count, 1_600)
                output.append(frame)
            }
            start += size
        }
        let remainder = aggregator.flush()
        TestSupport.expect(remainder.map { !$0.isEmpty } ?? true, "flush must return nil, never an empty frame")
        output.append(remainder ?? Data())
        TestSupport.expectEqual(output, input)
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

    /// words[] of final Results only, for the learning loop's confidence evidence.
    private static func testFinalWordsParsing() {
        func words(_ json: String) -> [Core.RecognizedWord] { Core.finalWords(in: Data(json.utf8)) }
        let final = #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"ask kwen today.","words":[{"word":"ask","punctuated_word":"Ask","confidence":0.99,"start":0.1,"end":0.3},{"word":"kwen","punctuated_word":"kwen","confidence":0.41},{"word":"today","punctuated_word":"today.","confidence":0.93}]}]}}"#
        TestSupport.expectEqual(words(final), [
            Core.RecognizedWord(word: "ask", punctuatedWord: "Ask", confidence: 0.99),
            Core.RecognizedWord(word: "kwen", punctuatedWord: "kwen", confidence: 0.41),
            Core.RecognizedWord(word: "today", punctuatedWord: "today.", confidence: 0.93),
        ])
        let interim = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"words":[{"word":"ask","confidence":0.9}]}]}}"#
        TestSupport.expectEqual(words(interim), [])
        TestSupport.expectEqual(words(#"{"type":"Metadata","request_id":"synthetic"}"#), [])
        TestSupport.expectEqual(words("not json"), [])
        TestSupport.expectEqual(words(#"[1,2,3]"#), [])
        TestSupport.expectEqual(words(#"{"type":"Results","is_final":true,"channel":{"alternatives":[]}}"#), [])
        let odd = #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"words":[{"word":"plain","confidence":0.5},{"word":"high","confidence":"high"},{"word":"flag","confidence":true},{"confidence":0.7},{"word":"over","confidence":1.4},{"word":"under","confidence":-0.2}]}]}}"#
        TestSupport.expectEqual(words(odd), [
            Core.RecognizedWord(word: "plain", punctuatedWord: "plain", confidence: 0.5),
            Core.RecognizedWord(word: "over", punctuatedWord: "over", confidence: 1),
            Core.RecognizedWord(word: "under", punctuatedWord: "under", confidence: 0),
        ])
        // The transcript path is unchanged by the words.
        TestSupport.expectEqual(
            message(final),
            .results(transcript: "ask kwen today.", isFinal: true, speechFinal: false, fromFinalize: false)
        )
        TestSupport.expectEqual(Core.maxRecognizedWords, 2_000)
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
