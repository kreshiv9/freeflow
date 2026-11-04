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
        testAssemblerAppendsFinalsInOrderAndIgnoresInterim()
        testAssemblerKeepsInterimTail()
        testAssemblerDropsResentFinals()
        testCommitMessageSequences()
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

        let timed = #"{"type":"Results","start":1.5,"duration":0.75,"is_final":true,"channel":{"alternatives":[{"transcript":"synthetic timed"}]}}"#
        TestSupport.expectEqual(
            message(timed),
            .results(
                transcript: "synthetic timed", isFinal: true, speechFinal: false, fromFinalize: false,
                start: 1.5, duration: 0.75
            )
        )
        let integerTimed = #"{"type":"Results","start":0,"duration":2,"is_final":false,"channel":{"alternatives":[{"transcript":"whole seconds"}]}}"#
        TestSupport.expectEqual(
            message(integerTimed),
            .results(
                transcript: "whole seconds", isFinal: false, speechFinal: false, fromFinalize: false,
                start: 0.0, duration: 2.0
            )
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
        TestSupport.expectEqual(message(#"{"type":"Results","start":"0.5","duration":null}"#), empty)
        for malformed in ["{not json", "[]", #"{"foo":1}"#, #"{"type":"Warning"}"#] {
            TestSupport.expectEqual(message(malformed), .unknown)
        }
        TestSupport.expectEqual(Core.ServerMessage(data: Data()), .unknown)
    }

    private static func results(_ transcript: String, isFinal: Bool) -> Core.ServerMessage {
        .results(transcript: transcript, isFinal: isFinal, speechFinal: false, fromFinalize: false)
    }

    /// The final Deepgram sends in answer to Finalize.
    private static func finalized(_ transcript: String) -> Core.ServerMessage {
        .results(transcript: transcript, isFinal: true, speechFinal: false, fromFinalize: true)
    }

    private static func timedFinal(_ transcript: String, start: Double, duration: Double) -> Core.ServerMessage {
        .results(
            transcript: transcript, isFinal: true, speechFinal: false, fromFinalize: false,
            start: start, duration: duration
        )
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
        TestSupport.expectEqual(assembler.interimTail, "hel")
        assembler.apply(results("  Hello ", isFinal: true))
        TestSupport.expect(!assembler.hasUnfinalizedSpeech, "A final frame finalizes the pending interim")
        TestSupport.expectEqual(assembler.interimTail, "")
        assembler.apply(results("wor", isFinal: false))
        // A blank interim is Deepgram's latest guess for the same tail: it revised the words away.
        var blankAfterTail = assembler
        blankAfterTail.apply(results("  ", isFinal: false))
        TestSupport.expectEqual(blankAfterTail.interimTail, "")
        TestSupport.expect(!blankAfterTail.hasUnfinalizedSpeech, "A blank interim retracts the earlier guess")
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

    /// Each interim covers the audio from the last final to the current tip, so
    /// the latest one is the whole unfinalized tail; a final for that audio
    /// replaces it rather than adding to it.
    private static func testAssemblerKeepsInterimTail() {
        TestSupport.expectEqual(Core.TranscriptAssembler().transcriptWithInterimTail, "")

        var assembler = Core.TranscriptAssembler()
        assembler.apply(results("Hello", isFinal: true))
        assembler.apply(results("wor", isFinal: false))
        assembler.apply(results(" world and ", isFinal: false))
        TestSupport.expectEqual(assembler.interimTail, "world and")
        TestSupport.expectEqual(assembler.finalTranscript, "Hello")
        TestSupport.expectEqual(assembler.transcriptWithInterimTail, "Hello world and")

        var superseded = Core.TranscriptAssembler()
        superseded.apply(results("Hello wor", isFinal: false))
        superseded.apply(results("Hello world.", isFinal: true))
        TestSupport.expectEqual(superseded.interimTail, "")
        TestSupport.expectEqual(superseded.transcriptWithInterimTail, "Hello world.")

        var interimOnly = Core.TranscriptAssembler()
        interimOnly.apply(results("tail only", isFinal: false))
        TestSupport.expectEqual(interimOnly.transcriptWithInterimTail, "tail only")

        // from_finalize on an interim is undocumented, so it does not answer Finalize.
        var flaggedInterim = Core.TranscriptAssembler()
        flaggedInterim.apply(.results(transcript: "maybe", isFinal: false, speechFinal: false, fromFinalize: true))
        TestSupport.expectEqual(flaggedInterim.interimTail, "maybe")
        TestSupport.expectEqual(flaggedInterim.finalTranscript, "")
        TestSupport.expect(!flaggedInterim.hasReceivedFinalizeResponse, "Only a final answers Finalize")

        TestSupport.expect(!assembler.hasReceivedFinalizeResponse, "No from_finalize final yet")
        var emptyFinalize = assembler
        emptyFinalize.apply(finalized(""))
        TestSupport.expect(emptyFinalize.hasReceivedFinalizeResponse, "An empty from_finalize final still answers Finalize")
        TestSupport.expectEqual(emptyFinalize.interimTail, "")
        TestSupport.expectEqual(emptyFinalize.finalTranscript, "Hello")
    }

    /// Results start and duration tell a re-sent final from a phrase the user
    /// really repeated; finals without timing keep the plain append.
    private static func testAssemblerDropsResentFinals() {
        TestSupport.expectEqual(Core.TranscriptAssembler.timingToleranceSeconds, 0.01)

        var assembler = Core.TranscriptAssembler()
        assembler.apply(timedFinal("Synthetic one.", start: 0, duration: 1.2))
        assembler.apply(timedFinal("Two.", start: 1.2, duration: 0.8))
        TestSupport.expectEqual(assembler.finalTranscript, "Synthetic one. Two.")
        assembler.apply(timedFinal("Two.", start: 1.2, duration: 0.8))
        TestSupport.expectEqual(assembler.finalTranscript, "Synthetic one. Two.")
        // Lies inside audio that is already finalized.
        assembler.apply(timedFinal("one.", start: 0.5, duration: 0.5))
        TestSupport.expectEqual(assembler.finalTranscript, "Synthetic one. Two.")
        // A cumulative re-emit from the last final's start replaces it.
        assembler.apply(timedFinal("Two. Three.", start: 1.2, duration: 1.6))
        TestSupport.expectEqual(assembler.finalTranscript, "Synthetic one. Two. Three.")
        // The same words later in the audio are new speech.
        assembler.apply(timedFinal("Two.", start: 3.5, duration: 0.5))
        TestSupport.expectEqual(assembler.finalTranscript, "Synthetic one. Two. Three. Two.")
        TestSupport.expectEqual(assembler.resultCount, 6)

        var untimed = Core.TranscriptAssembler()
        untimed.apply(results("Yes.", isFinal: true))
        untimed.apply(results("Yes.", isFinal: true))
        TestSupport.expectEqual(untimed.finalTranscript, "Yes. Yes.")
        var unusableTiming = Core.TranscriptAssembler()
        unusableTiming.apply(timedFinal("Yes.", start: -1, duration: 0.5))
        unusableTiming.apply(timedFinal("Yes.", start: -1, duration: 0.5))
        unusableTiming.apply(timedFinal("Yes.", start: .nan, duration: 0.5))
        TestSupport.expectEqual(unusableTiming.finalTranscript, "Yes. Yes. Yes.")

        var tolerant = Core.TranscriptAssembler()
        tolerant.apply(timedFinal("Synthetic one.", start: 0, duration: 1.2))
        tolerant.apply(timedFinal("Two.", start: 1.2, duration: 0.8))
        tolerant.apply(timedFinal("Two. Three.", start: 1.205, duration: 1.6))
        TestSupport.expectEqual(tolerant.finalTranscript, "Synthetic one. Two. Three.")
        tolerant.apply(timedFinal("Three.", start: 2.0, duration: 0.81))
        TestSupport.expectEqual(tolerant.finalTranscript, "Synthetic one. Two. Three.")
        // Known limitation, pinned rather than intended: a final starting inside
        // a kept one and ending after it repeats the overlapping words, so the
        // spec's "overlapping finals not duplicated" holds only for exact
        // re-sends, contained finals and re-emits from a kept final's start.
        // Dropping only those words needs Results words[] timings; once they are
        // parsed, this expectation becomes "Synthetic one. Two. Three. Four.".
        tolerant.apply(timedFinal("Three. Four.", start: 2.0, duration: 1.0))
        TestSupport.expectEqual(tolerant.finalTranscript, "Synthetic one. Two. Three. Three. Four.")

        // A re-emit spanning several kept finals replaces all of them, not only the last.
        var spanning = Core.TranscriptAssembler()
        spanning.apply(timedFinal("Synthetic one.", start: 0, duration: 1.2))
        spanning.apply(timedFinal("Two.", start: 1.2, duration: 0.8))
        spanning.apply(timedFinal("Synthetic one. Two. Three.", start: 0, duration: 2.8))
        TestSupport.expectEqual(spanning.finalTranscript, "Synthetic one. Two. Three.")
        spanning.apply(timedFinal("Four.", start: 2.8, duration: 0.6))
        spanning.apply(timedFinal("Five.", start: 3.4, duration: 0.5))
        // Starting within the tolerance after a kept final's start still re-covers it.
        spanning.apply(timedFinal("Four. Five. Six.", start: 2.805, duration: 1.5))
        TestSupport.expectEqual(spanning.finalTranscript, "Synthetic one. Two. Three. Four. Five. Six.")
        // A re-emit starting before the first final but after the stream start replaces them all.
        var earlierStart = Core.TranscriptAssembler()
        earlierStart.apply(timedFinal("Synthetic one.", start: 0.4, duration: 0.8))
        earlierStart.apply(timedFinal("Two.", start: 1.2, duration: 0.8))
        earlierStart.apply(timedFinal("Synthetic one. Two. Three.", start: 0.2, duration: 2.6))
        TestSupport.expectEqual(earlierStart.finalTranscript, "Synthetic one. Two. Three.")

        // A dropped re-send carries no new audio, so the interim tail for later audio survives it.
        var resentAfterTail = Core.TranscriptAssembler()
        resentAfterTail.apply(timedFinal("Synthetic one.", start: 0, duration: 1.0))
        resentAfterTail.apply(.results(
            transcript: "two three", isFinal: false, speechFinal: false, fromFinalize: false,
            start: 1.0, duration: 0.8
        ))
        resentAfterTail.apply(timedFinal("Synthetic one.", start: 0, duration: 1.0))
        TestSupport.expectEqual(resentAfterTail.finalTranscript, "Synthetic one.")
        TestSupport.expectEqual(resentAfterTail.interimTail, "two three")
        TestSupport.expectEqual(resentAfterTail.transcriptWithInterimTail, "Synthetic one. two three")
        // A kept final for that audio, or an empty final, still clears it.
        var tailFinalized = resentAfterTail
        tailFinalized.apply(timedFinal("Two three.", start: 1.0, duration: 0.8))
        TestSupport.expectEqual(tailFinalized.interimTail, "")
        TestSupport.expectEqual(tailFinalized.finalTranscript, "Synthetic one. Two three.")
        var tailRevisedAway = resentAfterTail
        tailRevisedAway.apply(timedFinal("", start: 1.0, duration: 0.8))
        TestSupport.expectEqual(tailRevisedAway.interimTail, "")
        TestSupport.expectEqual(tailRevisedAway.finalTranscript, "Synthetic one.")
    }

    private static func testCommitPolicyConstantsAndMessages() {
        TestSupport.expectEqual(Core.CommitPolicy.timeout, 3)
        TestSupport.expectEqual(Core.CommitPolicy.TranscriptPath.finals.rawValue, "deepgram-final")
        TestSupport.expectEqual(
            Core.CommitPolicy.TranscriptPath.finalsWithInterimTail.rawValue,
            "deepgram-final+interim-tail"
        )
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

    /// heardSpeech defaults to true, like the service before the recorder reports.
    private static func decision(
        _ assembler: Core.TranscriptAssembler,
        socket: Core.CommitPolicy.SocketState = .open,
        serverErrorMessage: String? = nil,
        elapsed: TimeInterval = 0,
        heardSpeech: Bool = true
    ) -> Core.CommitPolicy.Decision {
        Core.CommitPolicy.decision(
            assembler: assembler,
            socketState: socket,
            serverErrorMessage: serverErrorMessage,
            elapsedSinceCommit: elapsed,
            recorderHeardSpeech: heardSpeech
        )
    }

    private static func testCommitDecision() {
        let empty = Core.TranscriptAssembler()
        TestSupport.expectEqual(decision(empty, elapsed: 2.99), .wait)
        TestSupport.expectEqual(decision(empty, elapsed: 3.0), .fallBack(.commitTimedOut))

        var ready = Core.TranscriptAssembler()
        ready.apply(results("ready", isFinal: true))
        var readyWithMetadata = ready
        readyWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(readyWithMetadata), .resolve("ready", .finals))
        TestSupport.expectEqual(decision(ready, socket: .closedNormally), .resolve("ready", .finals))
        TestSupport.expectEqual(decision(ready), .wait)

        // An abnormal close before Metadata may have cut off the tail, so the
        // file upload wins even when some finals arrived; Metadata first means
        // the stream completed and the close code no longer matters.
        TestSupport.expectEqual(decision(ready, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))
        TestSupport.expectEqual(decision(readyWithMetadata, socket: .closedAbnormally), .resolve("ready", .finals))
        TestSupport.expectEqual(decision(empty, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))

        // The from_finalize final means every earlier final is assembled: it
        // resolves without waiting for Metadata or the close, whatever the
        // close or the clock says afterwards. Only a server error beats it.
        var flushed = ready
        flushed.apply(finalized("flushed."))
        TestSupport.expectEqual(decision(flushed), .resolve("ready flushed.", .finals))
        TestSupport.expectEqual(
            decision(flushed, socket: .closedAbnormally, elapsed: 10),
            .resolve("ready flushed.", .finals)
        )
        TestSupport.expectEqual(
            decision(flushed, serverErrorMessage: "synthetic"),
            .fallBack(.serverError("synthetic"))
        )
        var emptyFlush = Core.TranscriptAssembler()
        emptyFlush.apply(finalized(""))
        TestSupport.expectEqual(decision(emptyFlush), .fallBack(.emptyTranscriptForSpeech))
        TestSupport.expectEqual(decision(emptyFlush, heardSpeech: false), .resolve("", .finals))
        var flaggedInterim = ready
        flaggedInterim.apply(.results(transcript: "tail", isFinal: false, speechFinal: false, fromFinalize: true))
        TestSupport.expectEqual(decision(flaggedInterim), .wait)

        // Once the stream has ended, interim words Deepgram never finalized
        // follow the finals instead of sending the recording to the file
        // upload. An abnormal close or the timeout still falls back: without
        // an end of stream nothing shows the last audio was processed.
        var interimOnly = Core.TranscriptAssembler()
        interimOnly.apply(results("partial", isFinal: false))
        var interimWithMetadata = interimOnly
        interimWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(interimWithMetadata), .resolve("partial", .finalsWithInterimTail))
        TestSupport.expectEqual(
            decision(interimOnly, socket: .closedNormally),
            .resolve("partial", .finalsWithInterimTail)
        )
        TestSupport.expectEqual(decision(interimOnly, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))
        TestSupport.expectEqual(decision(interimOnly), .wait)

        var truncatedTail = ready
        truncatedTail.apply(results("tail", isFinal: false))
        TestSupport.expectEqual(
            decision(truncatedTail, socket: .closedNormally),
            .resolve("ready tail", .finalsWithInterimTail)
        )
        var truncatedWithMetadata = truncatedTail
        truncatedWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(truncatedWithMetadata), .resolve("ready tail", .finalsWithInterimTail))
        TestSupport.expectEqual(decision(truncatedTail, socket: .closedAbnormally), .fallBack(.socketClosedBeforeFinal))
        TestSupport.expectEqual(decision(truncatedTail, elapsed: 2.99), .wait)
        TestSupport.expectEqual(decision(truncatedTail, elapsed: 3), .fallBack(.commitTimedOut))
        var finalizedTail = truncatedTail
        finalizedTail.apply(results("tail.", isFinal: true))
        TestSupport.expectEqual(decision(finalizedTail, socket: .closedNormally), .resolve("ready tail.", .finals))

        // Deepgram processed audio and heard no words: an empty result, like
        // Realtime, unless the recorder counted speech, which the file upload
        // then transcribes.
        var blankInterimOnly = Core.TranscriptAssembler()
        blankInterimOnly.apply(results("", isFinal: false))
        TestSupport.expectEqual(
            decision(blankInterimOnly, socket: .closedNormally, heardSpeech: false),
            .resolve("", .finals)
        )
        TestSupport.expectEqual(
            decision(blankInterimOnly, socket: .closedNormally),
            .fallBack(.emptyTranscriptForSpeech)
        )
        var revisedAway = interimOnly
        revisedAway.apply(results("", isFinal: true))
        revisedAway.apply(.metadata)
        TestSupport.expectEqual(decision(revisedAway, heardSpeech: false), .resolve("", .finals))
        TestSupport.expectEqual(decision(revisedAway, heardSpeech: true), .fallBack(.emptyTranscriptForSpeech))

        // No Results frame at all: Deepgram processed nothing, whatever the recorder counted.
        var emptyWithMetadata = Core.TranscriptAssembler()
        emptyWithMetadata.apply(.metadata)
        TestSupport.expectEqual(decision(emptyWithMetadata), .fallBack(.noResults))
        TestSupport.expectEqual(decision(emptyWithMetadata, heardSpeech: false), .fallBack(.noResults))
        TestSupport.expectEqual(decision(empty, socket: .closedNormally), .fallBack(.noResults))

        TestSupport.expectEqual(
            decision(readyWithMetadata, serverErrorMessage: "synthetic"),
            .fallBack(.serverError("synthetic"))
        )
        TestSupport.expectEqual(
            decision(ready, socket: .closedAbnormally, serverErrorMessage: "synthetic"),
            .fallBack(.serverError("synthetic"))
        )
        TestSupport.expectEqual(decision(readyWithMetadata, elapsed: 10), .resolve("ready", .finals))

        let errors: [DeepgramStreamingError] = [
            .notConnected, .socketClosedBeforeCommit, .serverError("synthetic secret"), .socketClosedBeforeFinal,
            .commitTimedOut, .noResults, .emptyTranscriptForSpeech,
        ]
        for error in errors {
            TestSupport.expect(error.errorDescription != nil, "\(error) must describe itself")
        }
        TestSupport.expect(
            DeepgramStreamingError.serverError("synthetic secret").errorDescription?.contains("synthetic secret") == false,
            "The server message is untrusted and must never reach the description"
        )
    }

    /// Applies frames one at a time and evaluates after each, as the service's
    /// evaluateLocked does, with no time elapsed; then, when timerElapsed is
    /// set, once more as the commit timer would. Returns the first decision
    /// that is not .wait and the index of the frame that produced it (nil for
    /// the timer or when every evaluation waited).
    private static func firstDecision(
        _ frames: [String],
        heardSpeech: Bool = true,
        timerElapsed: TimeInterval? = nil
    ) -> (decision: Core.CommitPolicy.Decision, frameIndex: Int?) {
        var assembler = Core.TranscriptAssembler()
        var serverErrorMessage: String?
        for (index, frame) in frames.enumerated() {
            let parsed = message(frame)
            assembler.apply(parsed)
            if case .error(let errorMessage) = parsed {
                serverErrorMessage = errorMessage
            }
            let result = decision(assembler, serverErrorMessage: serverErrorMessage, heardSpeech: heardSpeech)
            if result != .wait { return (result, index) }
        }
        guard let timerElapsed else { return (.wait, nil) }
        return (
            decision(assembler, serverErrorMessage: serverErrorMessage, elapsed: timerElapsed, heardSpeech: heardSpeech),
            nil
        )
    }

    /// Hand-written frame sequences in the shape Deepgram sends after Finalize and CloseStream.
    private static func testCommitMessageSequences() {
        let metadata = #"{"type":"Metadata","request_id":"synthetic"}"#

        // (a) The from_finalize final resolves before Metadata, with every final in order.
        let finalizeFirst = firstDecision([
            #"{"type":"Results","is_final":false,"start":0.0,"duration":0.9,"channel":{"alternatives":[{"transcript":"synthetic first"}]}}"#,
            #"{"type":"Results","is_final":true,"speech_final":true,"start":0.0,"duration":1.4,"channel":{"alternatives":[{"transcript":"Synthetic first line."}]}}"#,
            #"{"type":"Results","is_final":false,"start":1.4,"duration":0.6,"channel":{"alternatives":[{"transcript":"second"}]}}"#,
            #"{"type":"Results","is_final":true,"from_finalize":true,"start":1.4,"duration":1.1,"channel":{"alternatives":[{"transcript":"Second line."}]}}"#,
            metadata,
        ])
        TestSupport.expectEqual(finalizeFirst.decision, .resolve("Synthetic first line. Second line.", .finals))
        TestSupport.expectEqual(finalizeFirst.frameIndex, 3)

        // (b) No from_finalize: Metadata resolves the finals plus the interim tail.
        let interimTail = firstDecision([
            #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"finals"}]}}"#,
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"tail"}]}}"#,
            metadata,
        ])
        TestSupport.expectEqual(interimTail.decision, .resolve("finals tail", .finalsWithInterimTail))
        TestSupport.expectEqual(interimTail.frameIndex, 2)

        // (c) Deepgram heard no words: the file upload only when the recorder counted speech.
        let silent = [
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":""}]}}"#,
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":" "}]}}"#,
            #"{"type":"Results","is_final":true,"from_finalize":true,"channel":{"alternatives":[{"transcript":""}]}}"#,
        ]
        let silentWithSpeech = firstDecision(silent, heardSpeech: true)
        TestSupport.expectEqual(silentWithSpeech.decision, .fallBack(.emptyTranscriptForSpeech))
        TestSupport.expectEqual(silentWithSpeech.frameIndex, 2)
        let silentWithoutSpeech = firstDecision(silent, heardSpeech: false)
        TestSupport.expectEqual(silentWithoutSpeech.decision, .resolve("", .finals))
        TestSupport.expectEqual(silentWithoutSpeech.frameIndex, 2)

        // (d) A server error falls back even after finals arrived.
        let serverError = firstDecision([
            #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"Synthetic words."}]}}"#,
            #"{"type":"Error","description":"synthetic failure"}"#,
            metadata,
        ])
        TestSupport.expectEqual(serverError.decision, .fallBack(.serverError("synthetic failure")))
        TestSupport.expectEqual(serverError.frameIndex, 1)

        // (e) A re-sent final and a cumulative re-emit never repeat words.
        let resent = firstDecision([
            #"{"type":"Results","is_final":true,"start":0.0,"duration":1.0,"channel":{"alternatives":[{"transcript":"Synthetic one."}]}}"#,
            #"{"type":"Results","is_final":true,"start":0.0,"duration":1.0,"channel":{"alternatives":[{"transcript":"Synthetic one."}]}}"#,
            #"{"type":"Results","is_final":true,"start":1.0,"duration":0.8,"channel":{"alternatives":[{"transcript":"Two."}]}}"#,
            #"{"type":"Results","is_final":true,"start":1.0,"duration":1.5,"channel":{"alternatives":[{"transcript":"Two. Three."}]}}"#,
            #"{"type":"Results","is_final":true,"from_finalize":true,"start":2.5,"duration":0.5,"channel":{"alternatives":[{"transcript":"Four."}]}}"#,
        ])
        TestSupport.expectEqual(resent.decision, .resolve("Synthetic one. Two. Three. Four.", .finals))
        TestSupport.expectEqual(resent.frameIndex, 4)
        let spanningReEmit = firstDecision([
            #"{"type":"Results","is_final":true,"start":0.0,"duration":1.2,"channel":{"alternatives":[{"transcript":"Synthetic one."}]}}"#,
            #"{"type":"Results","is_final":true,"start":1.2,"duration":0.8,"channel":{"alternatives":[{"transcript":"Two."}]}}"#,
            #"{"type":"Results","is_final":true,"from_finalize":true,"start":0.0,"duration":2.8,"channel":{"alternatives":[{"transcript":"Synthetic one. Two. Three."}]}}"#,
        ])
        TestSupport.expectEqual(spanningReEmit.decision, .resolve("Synthetic one. Two. Three.", .finals))
        TestSupport.expectEqual(spanningReEmit.frameIndex, 2)

        // (f) Metadata without a single Results frame: nothing was processed.
        let metadataOnly = firstDecision([metadata])
        TestSupport.expectEqual(metadataOnly.decision, .fallBack(.noResults))
        TestSupport.expectEqual(metadataOnly.frameIndex, 0)

        // (g) A stream that never ends waits until the timer, then falls back.
        let unended = [
            #"{"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"Synthetic open"}]}}"#,
            #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"tail"}]}}"#,
        ]
        TestSupport.expectEqual(firstDecision(unended).decision, .wait)
        TestSupport.expectEqual(firstDecision(unended, timerElapsed: 2.99).decision, .wait)
        let timedOut = firstDecision(unended, timerElapsed: 3.0)
        TestSupport.expectEqual(timedOut.decision, .fallBack(.commitTimedOut))
        TestSupport.expectEqual(timedOut.frameIndex, nil)

        // (h) A re-sent final after an interim tail does not finalize that tail's audio.
        let syntheticOne = #"{"type":"Results","is_final":true,"start":0.0,"duration":1.0,"channel":{"alternatives":[{"transcript":"Synthetic one."}]}}"#
        let laterTail = #"{"type":"Results","is_final":false,"start":1.0,"duration":0.8,"channel":{"alternatives":[{"transcript":"two three"}]}}"#
        let resentBeforeMetadata = firstDecision([syntheticOne, laterTail, syntheticOne, metadata])
        TestSupport.expectEqual(
            resentBeforeMetadata.decision,
            .resolve("Synthetic one. two three", .finalsWithInterimTail)
        )
        TestSupport.expectEqual(resentBeforeMetadata.frameIndex, 3)
        let resentFromFinalize = firstDecision([
            syntheticOne, laterTail,
            #"{"type":"Results","is_final":true,"from_finalize":true,"start":0.0,"duration":1.0,"channel":{"alternatives":[{"transcript":"Synthetic one."}]}}"#,
        ])
        TestSupport.expectEqual(
            resentFromFinalize.decision,
            .resolve("Synthetic one. two three", .finalsWithInterimTail)
        )
        TestSupport.expectEqual(resentFromFinalize.frameIndex, 2)

        // (i) A blank interim retracts the earlier guess, so it is never pasted.
        let retractedGuess = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":"synthetic guess"}]}}"#
        let blankInterim = #"{"type":"Results","is_final":false,"channel":{"alternatives":[{"transcript":""}]}}"#
        TestSupport.expectEqual(
            firstDecision([retractedGuess, blankInterim, metadata], heardSpeech: false).decision,
            .resolve("", .finals)
        )
        TestSupport.expectEqual(
            firstDecision([retractedGuess, blankInterim, metadata]).decision,
            .fallBack(.emptyTranscriptForSpeech)
        )
        TestSupport.expectEqual(
            firstDecision([syntheticOne, retractedGuess, blankInterim, metadata]).decision,
            .resolve("Synthetic one.", .finals)
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
