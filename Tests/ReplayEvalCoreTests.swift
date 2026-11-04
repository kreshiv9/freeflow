import Foundation

/// Invented sentences, keyterms and keys; synthetic tones generated in memory.
/// No files, no network, no audio devices.
enum ReplayEvalCoreTests {
    private typealias Core = ReplayEvalCore
    private static let syntheticKey = "dg-synthetic-not-a-key"

    static func run() {
        testNormalization()
        testWERCounts()
        testFirstAndLastWordDeletionFlags()
        testKeytermRecallAndFalseInsertions()
        testOverlapDetection()
        testVariantDefaultsAndOverrides()
        testVariantRejections()
        testPresetsParse()
        testAssemblyAIVariants()
        testAssemblyAIRequestFromVariant()
        testQueryOverridesKeepKeytermsAndDropOmitted()
        testPacingSchedule()
        testFrameSlicing()
        testAssemblyAIChunksAndSchedule()
        testAssemblyAIStatusAndBilling()
        testSignTestPValues()
        testPairedComparison()
        testLevelStatsOnSyntheticTones()
        testGainAndLimiter()
        testIsolationAlignment()
        testSecretIsRedacted()
        testGitWorkTreeDetection()
        testManifestParsing()
        testResultsCSVHasMetricsOnly()
    }

    private static func alignment(_ reference: String, _ hypothesis: String) -> Core.Alignment {
        Core.align(reference: Core.normalizedWords(reference), hypothesis: Core.normalizedWords(hypothesis))
    }

    private static func expectRejected(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = try? Core.parseVariants(text)
        TestSupport.expect(parsed == nil, "Expected the variants to be rejected", file: file, line: line)
    }

    private static func parseError(_ text: String) -> Core.ParseError? {
        do {
            _ = try Core.parseVariants(text)
            return nil
        } catch {
            return error as? Core.ParseError
        }
    }

    private static func sine(
        frequency: Double,
        amplitude: Float,
        sampleRate: Double,
        count: Int
    ) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// Deterministic noise in -amplitude...amplitude from a 64-bit LCG.
    private static func seededNoise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (2 * Float(Double(state >> 11) / Double(1 << 53)) - 1)
        }
    }

    private static func testNormalization() {
        TestSupport.expectEqual(
            Core.normalizedWords("Hello, World!  It's  FreeFlow's \"best\" day\u{2014}really."),
            ["hello", "world", "it's", "freeflow's", "best", "day", "really"]
        )
        TestSupport.expectEqual(
            Core.normalizedWords("Don\u{2019}t stop 'quoted' e-mail Invoice #4471, $40.50 rock'n'roll"),
            ["don't", "stop", "quoted", "e", "mail", "invoice", "4471", "40", "50", "rock'n'roll"]
        )
        TestSupport.expectEqual(Core.normalizedWords(" \n\t "), [])
        TestSupport.expectEqual(Core.formattedWords("Hello, World!  Ship it."), ["Hello,", "World!", "Ship", "it."])
    }

    private static func testWERCounts() {
        let identical = alignment("ship it on friday", "Ship it on Friday.")
        TestSupport.expectEqual(identical.errors, 0)
        TestSupport.expectEqual(identical.wordErrorRate, 0)

        let mixed = alignment(
            "please send the quarterly report to priya today",
            "please send quarterly reports to priya today now"
        )
        TestSupport.expectEqual(mixed.substitutions, 1)
        TestSupport.expectEqual(mixed.deletions, 1)
        TestSupport.expectEqual(mixed.insertions, 1)
        TestSupport.expectEqual(mixed.referenceWords, 8)
        TestSupport.expectApproximatelyEqual(mixed.wordErrorRate ?? -1, 0.375)

        let deletion = alignment("one two three four five", "one two four five")
        TestSupport.expectEqual(deletion.deletions, 1)
        TestSupport.expectEqual(deletion.errors, 1)
        TestSupport.expectApproximatelyEqual(deletion.wordErrorRate ?? -1, 0.2)

        let command = alignment(
            "run make check then git diff check then push the branch",
            "run make check then get diff check push the branch"
        )
        TestSupport.expectEqual(command.substitutions, 1)
        TestSupport.expectEqual(command.deletions, 1)
        TestSupport.expectEqual(command.insertions, 0)
        TestSupport.expectEqual(command.referenceWords, 11)
        TestSupport.expectApproximatelyEqual(command.wordErrorRate ?? -1, 2.0 / 11.0)

        let emptyReference = alignment("", "anything here")
        TestSupport.expectEqual(emptyReference.insertions, 2)
        TestSupport.expectEqual(emptyReference.wordErrorRate, nil)

        let formatted = Core.align(reference: Core.formattedWords("Ship it."), hypothesis: Core.formattedWords("ship it"))
        TestSupport.expectEqual(formatted.substitutions, 2)
        TestSupport.expectEqual(alignment("Ship it.", "ship it").errors, 0)
    }

    private static func testFirstAndLastWordDeletionFlags() {
        let first = alignment("yes we can ship it", "we can ship it")
        TestSupport.expect(first.firstWordDeleted, "Dropped first word is flagged")
        TestSupport.expect(!first.lastWordDeleted, "Last word was heard")

        let last = alignment("ship it on friday", "ship it on")
        TestSupport.expect(!last.firstWordDeleted, "First word was heard")
        TestSupport.expect(last.lastWordDeleted, "Dropped last word is flagged")

        let only = alignment("yes", "")
        TestSupport.expectEqual(only.deletions, 1)
        TestSupport.expect(only.firstWordDeleted && only.lastWordDeleted, "A lone deleted word is first and last")
        TestSupport.expectEqual(only.wordErrorRate, 1.0)

        let misheard = alignment("sasha fixed it", "sasa fixed it")
        TestSupport.expectEqual(misheard.substitutions, 1)
        TestSupport.expect(
            !misheard.firstWordDeleted && !misheard.lastWordDeleted,
            "A substitution is not a deletion"
        )

        // Ambiguous alignments flag a clipped end exactly like the mirrored clipped start.
        let clippedEnd = alignment("ship it now", "ship in")
        TestSupport.expectEqual(clippedEnd.substitutions, 1)
        TestSupport.expectEqual(clippedEnd.deletions, 1)
        TestSupport.expect(clippedEnd.lastWordDeleted, "A truncated tail is flagged")
        TestSupport.expect(!clippedEnd.firstWordDeleted, "The first word was heard")
        let clippedStart = alignment("yes ship it", "sip it")
        TestSupport.expectEqual(clippedStart.substitutions, 1)
        TestSupport.expectEqual(clippedStart.deletions, 1)
        TestSupport.expect(clippedStart.firstWordDeleted, "A truncated start is flagged")
        TestSupport.expect(!clippedStart.lastWordDeleted, "The last word was heard")
        TestSupport.expect(alignment("send it to me", "send it two").lastWordDeleted, "A lost last word is flagged")
        TestSupport.expect(alignment("please send it to", "send it two").firstWordDeleted, "A lost first word is flagged")
    }

    private static func testKeytermRecallAndFalseInsertions() {
        let score = Core.keytermScore(
            keyterms: ["FreeFlow", "Kubernetes", "git diff", "Claude Code"],
            reference: "Set the Kubernetes namespace to FreeFlow dev, then run git diff.",
            hypothesis: "set the cooper netties namespace to freeflow dev then run git diff and FreeFlow, Claude Code"
        )
        TestSupport.expectEqual(score, Core.KeytermScore(expected: 3, recalled: 2, falseInsertions: 2))
        TestSupport.expectEqual(
            Core.keytermList(fromText: "FreeFlow\nKubernetes, git  diff;freeflow\n\n"),
            ["FreeFlow", "Kubernetes", "git diff"]
        )
    }

    private static func testOverlapDetection() {
        func final(_ times: [(Double, Double)]) -> [Core.WordTiming] {
            times.map { Core.WordTiming(start: $0.0, end: $0.1) }
        }
        let finals = [
            final([(0.0, 0.4), (0.5, 0.9)]),
            final([(0.85, 1.2), (1.3, 1.6)]),
            [],
            final([(1.6, 2.0)]),
            final([(1.9, 2.4)]),
            final([(2.5, 2.9)]),
        ]
        TestSupport.expectEqual(Core.overlapCount(finals: finals), 2)

        let results = #"""
        {"type":"Results","is_final":true,"channel":{"alternatives":[{"transcript":"ship it","confidence":0.9,
        "words":[{"word":"ship","start":0.5,"end":0.8},{"word":"it","start":0.8,"end":1.0}]}]}}
        """#
        TestSupport.expectEqual(
            Core.wordTimings(fromResultsJSON: Data(results.utf8)),
            final([(0.5, 0.8), (0.8, 1.0)])
        )
        TestSupport.expectEqual(Core.wordTimings(fromResultsJSON: Data("{".utf8)), [])
        TestSupport.expectEqual(
            Core.wordTimings(fromResultsJSON: Data(#"{"type":"Metadata","request_id":"synthetic"}"#.utf8)),
            []
        )
    }

    private static func testVariantDefaultsAndOverrides() {
        let base = try? Core.parseVariant("base")
        TestSupport.expectEqual(base?.name, "base")
        TestSupport.expectEqual(base?.sampleRate, 16000)
        TestSupport.expectEqual(base?.resampler, .minimumPhase)
        TestSupport.expectEqual(base?.query, [
            Core.QueryItem(name: "language", value: "en"),
            Core.QueryItem(name: "endpointing", value: "500"),
            Core.QueryItem(name: "mip_opt_out", value: "true"),
            Core.QueryItem(name: "smart_format", value: "true"),
            Core.QueryItem(name: "punctuate", value: "true"),
            Core.QueryItem(name: "interim_results", value: "true"),
        ])
        TestSupport.expectEqual(base?.keyterms, Core.KeytermSelection.none)
        TestSupport.expectEqual(base?.frameMilliseconds, 50)
        TestSupport.expectEqual(base?.pacing, .realtime)
        TestSupport.expectEqual(base?.isolation, .off)
        TestSupport.expectEqual(base?.gainDecibels, 0)
        TestSupport.expectEqual(base?.provider, .deepgram)
        TestSupport.expectEqual(base?.prompt, nil)
        TestSupport.expectEqual(base?.mode, nil)
        TestSupport.expectEqual(try? Core.parseVariant("base provider=deepgram"), base)

        let legacy = try? Core.parseVariant(
            "legacy24 rate=24000 src=legacy-chain endpointing=default language=omit keyterms=top-20 frame_ms=20 pacing=1.25x isolation=hq70 gain_db=-6"
        )
        TestSupport.expectEqual(legacy?.sampleRate, 24000)
        TestSupport.expectEqual(legacy?.resampler, .legacyChain)
        TestSupport.expectEqual(legacy?.keyterms, .top(20))
        TestSupport.expectEqual(legacy?.frameMilliseconds, 20)
        TestSupport.expectEqual(legacy?.pacing, .faster)
        TestSupport.expectEqual(legacy?.isolation, .highQualityVoice(wetPercent: 70))
        TestSupport.expectEqual(legacy?.gainDecibels, -6)
        TestSupport.expectEqual(legacy?.query, [
            Core.QueryItem(name: "language", value: nil),
            Core.QueryItem(name: "endpointing", value: nil),
            Core.QueryItem(name: "mip_opt_out", value: "true"),
            Core.QueryItem(name: "smart_format", value: "true"),
            Core.QueryItem(name: "punctuate", value: "true"),
            Core.QueryItem(name: "interim_results", value: "true"),
        ])

        let parsed = try? Core.parseVariants("# c\n\nep10 endpointing=10\nep-false endpointing=false\n")
        TestSupport.expectEqual(parsed?.count, 2)
        TestSupport.expectEqual(parsed?.first?.query[1], Core.QueryItem(name: "endpointing", value: "10"))
        TestSupport.expectEqual(parsed?.last?.query[1], Core.QueryItem(name: "endpointing", value: "false"))

        let voice = try? Core.parseVariant("x isolation=voice70 mip_opt_out=default smart_format=false interim_results=omit")
        TestSupport.expectEqual(voice?.isolation, .voice(wetPercent: 70))
        TestSupport.expectEqual(voice?.query, [
            Core.QueryItem(name: "language", value: "en"),
            Core.QueryItem(name: "endpointing", value: "500"),
            Core.QueryItem(name: "mip_opt_out", value: nil),
            Core.QueryItem(name: "smart_format", value: "false"),
            Core.QueryItem(name: "punctuate", value: "true"),
            Core.QueryItem(name: "interim_results", value: nil),
        ])
        TestSupport.expectEqual((try? Core.parseVariant("x isolation=off"))?.isolation, .off)

        // Prepared audio is shared only by variants that send the same samples.
        func audioKey(_ line: String) -> String? { (try? Core.parseVariant(line))?.audioKey }
        let reference = audioKey("a")
        for line in ["b rate=48000", "b src=mastering-high", "b isolation=hq70", "b isolation=voice70", "b gain_db=6"] {
            TestSupport.expect(audioKey(line) != reference, "The audio key changes with every audio setting")
        }
        TestSupport.expect(audioKey("b isolation=hq70") != audioKey("b isolation=hq100"), "The wet percent is part of the key")
        TestSupport.expect(audioKey("b gain_db=6") != audioKey("b gain_db=-6"), "The gain sign is part of the key")
        for line in [
            "b endpointing=10", "b frame_ms=20", "b pacing=burst", "b keyterms=all", "b language=multi",
            "b provider=assemblyai", "b provider=assemblyai prompt=coding mode=max_accuracy",
        ] {
            TestSupport.expectEqual(audioKey(line), reference)
        }

        let terms = ["alpha", "bravo", "charlie"]
        TestSupport.expectEqual(Core.KeytermSelection.none.select(from: terms), [])
        TestSupport.expectEqual(Core.KeytermSelection.all.select(from: terms), terms)
        TestSupport.expectEqual(Core.KeytermSelection.top(2).select(from: terms), ["alpha", "bravo"])
        TestSupport.expectEqual(Core.KeytermSelection.top(5).select(from: ["alpha", "bravo"]), ["alpha", "bravo"])
    }

    private static func testVariantRejections() {
        TestSupport.expectEqual(parseError("foo bogus=1"), .unknownKey(line: 1, key: "bogus"))
        for line in [
            "x rate=96000", "x rate=abc",
            "x frame_ms=0", "x gain_db=41",
            "x endpointing=0",
            "x keyterms=top-0", "x keyterms=top-101",
            "x isolation=hq101", "x isolation=loud",
            "x language=e!n",
            "x pacing=2x", "x src=linear",
            "x rate=16000 rate=24000", "x rate",
            "bad,name",
        ] {
            expectRejected(line)
        }
        TestSupport.expectEqual(parseError("x rate=16000 rate=24000"), .duplicateKey(line: 1, key: "rate"))
        TestSupport.expectEqual(parseError("x rate"), .missingEquals(line: 1))
        // Errors never echo a whole field: the file may be a transcript or a key.
        TestSupport.expect(
            !(parseError("synthetic sentence")?.description.contains("sentence") ?? true),
            "A field without = is not echoed"
        )
        TestSupport.expectEqual(
            parseError("x abcdefghijklmnopqrstuvwxyz=1"),
            .unknownKey(line: 1, key: "abcdefghijklmnopqrst")
        )
        TestSupport.expectEqual(parseError("bad,name"), .invalidName(line: 1))
        TestSupport.expectEqual(
            parseError("legacy rate=16000 src=legacy-chain"),
            .inconsistent(line: 1, reason: "src=legacy-chain requires rate=24000")
        )
        TestSupport.expectEqual(parseError("a\na"), .duplicateName(line: 2))
        TestSupport.expectEqual(parseError(""), .noVariants)
    }

    private static func testPresetsParse() {
        let expected: [(name: String, count: Int, first: String)] = [
            ("rate", 4, "legacy24"),
            ("src", 3, "src-default"),
            ("endpointing", 5, "ep10"),
            ("keyterms", 3, "kt-all"),
            ("language", 8, "lang-omit"),
            ("isolation", 3, "iso-off"),
            ("frames", 6, "f50"),
            ("determinism", 3, "same-1"),
            ("providers", 4, "dg-nova3"),
        ]
        TestSupport.expectEqual(Core.presetNames, expected.map { $0.name })
        for preset in expected {
            let variants = Core.preset(named: preset.name).flatMap { try? Core.parseVariants($0) }
            TestSupport.expectEqual(variants?.count, preset.count)
            TestSupport.expectEqual(variants?.first?.name, preset.first)
        }
        TestSupport.expectEqual(Core.preset(named: "unknown"), nil)

        let determinism = (try? Core.parseVariants(Core.preset(named: "determinism") ?? "")) ?? []
        TestSupport.expectEqual(determinism.count, 3)
        let renamed = determinism.map { variant -> Core.Variant in
            var copy = variant
            copy.name = "same"
            return copy
        }
        TestSupport.expect(renamed.allSatisfy { $0 == renamed[0] }, "Determinism variants differ only in name")

        // Every other preset compares distinct settings, and each variant sets what
        // its preset is about, so no experiment compares a variant with itself.
        func parsed(_ name: String) -> [Core.Variant] {
            (try? Core.parseVariants(Core.preset(named: name) ?? "")) ?? []
        }
        for name in Core.presetNames where name != "determinism" {
            let settings = parsed(name).map { variant -> Core.Variant in
                var copy = variant
                copy.name = "unnamed"
                return copy
            }
            for (index, variant) in settings.enumerated() {
                TestSupport.expect(
                    !settings[(index + 1)...].contains(variant),
                    "Preset \(name) has two variants with the same settings"
                )
            }
        }
        func query(_ variant: Core.Variant, _ name: String) -> String? {
            variant.query.first { $0.name == name }?.value
        }
        let rate = parsed("rate")
        TestSupport.expectEqual(rate.map(\.sampleRate), [24000, 16000, 16000, 48000])
        TestSupport.expectEqual(rate.map(\.resampler), [.legacyChain, .minimumPhase, .masteringHigh, .minimumPhase])
        TestSupport.expectEqual(parsed("src").map(\.resampler), [.normal, .minimumPhase, .masteringHigh])
        TestSupport.expectEqual(
            parsed("endpointing").map { query($0, "endpointing") },
            ["10", "300", "500", "1000", "false"]
        )
        TestSupport.expectEqual(parsed("keyterms").map(\.keyterms), [Core.KeytermSelection.all, .top(20), .none])
        TestSupport.expectEqual(
            parsed("language").map { query($0, "language") },
            [nil, "en", "en-US", "multi", "en-GB", "en-IN", "en-AU", "en-NZ"]
        )
        TestSupport.expect(
            parsed("language").allSatisfy { $0.provider == .deepgram },
            "The language preset compares Deepgram languages"
        )
        // Deepgram as the app sends it today, then AssemblyAI with and without its
        // prompt and its keyterms.
        let providers = parsed("providers")
        TestSupport.expectEqual(providers.map(\.provider), [.deepgram, .assemblyAI, .assemblyAI, .assemblyAI])
        TestSupport.expectEqual(providers.map(\.prompt), [nil, .dictation, nil, .dictation])
        TestSupport.expectEqual(providers.map(\.keyterms), [Core.KeytermSelection.all, .all, .all, .none])
        TestSupport.expect(providers.allSatisfy { $0.mode == nil }, "No provider variant changes the server's mode")
        if let baseline = providers.first, let defaults = try? Core.parseVariant("dg-nova3") {
            TestSupport.expectEqual(baseline.query, defaults.query)
            TestSupport.expectEqual(baseline.sampleRate, 16000)
        }
        TestSupport.expectEqual(
            parsed("isolation").map(\.isolation),
            [.off, .highQualityVoice(wetPercent: 70), .highQualityVoice(wetPercent: 100)]
        )
        let frames = parsed("frames")
        TestSupport.expectEqual(frames.map(\.frameMilliseconds), [50, 20, 100, 250, 50, 50])
        TestSupport.expectEqual(frames.map(\.pacing), [.realtime, .realtime, .realtime, .realtime, .faster, .burst])

        // Each preset varies only its own parameter. With that parameter (and the
        // name) reset, every variant equals its baseline; without the reset, none
        // does. So a variant that collapses into a copy of its baseline, or that
        // changes something else as well, fails here.
        func withoutParameter(_ variant: Core.Variant, of preset: String) -> Core.Variant {
            var copy = variant
            copy.name = "unnamed"
            switch preset {
            case "rate":
                copy.sampleRate = 0
                copy.resampler = .normal
            case "src":
                copy.resampler = .normal
            case "endpointing", "language":
                copy.query = copy.query.map { $0.name == preset ? Core.QueryItem(name: preset, value: nil) : $0 }
            case "keyterms":
                copy.keyterms = .none
            case "isolation":
                copy.isolation = .off
            case "frames":
                copy.frameMilliseconds = 0
                copy.pacing = .realtime
            case "providers":
                copy.provider = .deepgram
                copy.prompt = nil
                copy.mode = nil
                copy.keyterms = .none
            default:
                TestSupport.expect(false, "Preset \(preset) needs its parameter listed in this test")
            }
            return copy
        }
        for name in Core.presetNames where name != "determinism" {
            let variants = parsed(name)
            guard let baseline = variants.first else {
                TestSupport.expect(false, "Preset \(name) has a baseline")
                continue
            }
            TestSupport.expect(variants.count >= 2, "Preset \(name) compares something with its baseline")
            var renamedBaseline = baseline
            renamedBaseline.name = "unnamed"
            for variant in variants.dropFirst() {
                var renamed = variant
                renamed.name = "unnamed"
                TestSupport.expect(
                    renamed != renamedBaseline,
                    "Preset \(name): \(variant.name) is a copy of the baseline \(baseline.name)"
                )
                TestSupport.expect(
                    withoutParameter(variant, of: name) == withoutParameter(baseline, of: name),
                    "Preset \(name): \(variant.name) changes more than the preset's parameter"
                )
            }
        }
    }

    private static func testAssemblyAIVariants() {
        // An AssemblyAI variant without a prompt key gets the app's fallback scenario.
        let plain = try? Core.parseVariant("aai provider=assemblyai")
        TestSupport.expectEqual(plain?.provider, .assemblyAI)
        TestSupport.expectEqual(plain?.prompt, .dictation)
        TestSupport.expectEqual(plain?.mode, nil)
        TestSupport.expectEqual(plain?.keyterms, Core.KeytermSelection.none)
        TestSupport.expectEqual(plain?.frameMilliseconds, 50)
        TestSupport.expectEqual(plain?.pacing, .realtime)
        TestSupport.expectEqual(plain?.sampleRate, 16000)

        TestSupport.expectEqual((try? Core.parseVariant("aai provider=assemblyai prompt=off"))?.prompt, nil)
        let tuned = try? Core.parseVariant(
            "aai mode=max_accuracy prompt=coding provider=assemblyai keyterms=top-20 frame_ms=1000 pacing=1.25x rate=48000"
        )
        TestSupport.expectEqual(tuned?.prompt, .codingAssistant)
        TestSupport.expectEqual(tuned?.mode, .maxAccuracy)
        TestSupport.expectEqual(tuned?.keyterms, .top(20))
        TestSupport.expectEqual(tuned?.frameMilliseconds, 1000)
        TestSupport.expectEqual(tuned?.pacing, .faster)
        TestSupport.expectEqual(tuned?.sampleRate, 48000)
        TestSupport.expectEqual((try? Core.parseVariant("aai provider=assemblyai mode=default"))?.mode, nil)
        for scenario in AssemblyAIStreamingCore.PromptScenario.allCases {
            TestSupport.expectEqual(
                (try? Core.parseVariant("aai provider=assemblyai prompt=\(scenario.rawValue)"))?.prompt,
                scenario
            )
        }
        for mode in AssemblyAIStreamingCore.Mode.allCases {
            TestSupport.expectEqual((try? Core.parseVariant("aai provider=assemblyai mode=\(mode.rawValue)"))?.mode, mode)
        }
        TestSupport.expectEqual((try? Core.parseVariant("aai provider=assemblyai frame_ms=50"))?.frameMilliseconds, 50)

        for line in [
            "x provider=assembly", "x provider=AssemblyAI", "x provider=",
            "x provider=assemblyai prompt=anything", "x provider=assemblyai prompt=Coding",
            "x provider=assemblyai mode=fast",
        ] {
            expectRejected(line)
        }
        TestSupport.expectEqual(parseError("x provider=openai"), .invalidValue(line: 1, key: "provider"))
        TestSupport.expectEqual(
            parseError("x provider=assemblyai prompt=off prompt=coding"),
            .duplicateKey(line: 1, key: "prompt")
        )
        // Prompt and mode only mean something to AssemblyAI; Deepgram's query items only to Deepgram.
        TestSupport.expectEqual(
            parseError("x prompt=coding"),
            .inconsistent(line: 1, reason: "prompt requires provider=assemblyai")
        )
        TestSupport.expectEqual(
            parseError("x provider=deepgram mode=balanced"),
            .inconsistent(line: 1, reason: "mode requires provider=assemblyai")
        )
        for key in ["endpointing=500", "language=en", "mip_opt_out=true", "smart_format=false", "punctuate=true", "interim_results=omit"] {
            let name = String(key.prefix { $0 != "=" })
            TestSupport.expectEqual(
                parseError("x provider=assemblyai \(key)"),
                .inconsistent(line: 1, reason: "\(name) is a Deepgram setting; remove it with provider=assemblyai")
            )
        }
        // AssemblyAI closes the session for chunks outside 50-1000 ms and processes at
        // most about 1.25x real time.
        for line in ["x provider=assemblyai frame_ms=20", "x provider=assemblyai frame_ms=49"] {
            TestSupport.expectEqual(
                parseError(line),
                .inconsistent(line: 1, reason: "provider=assemblyai requires frame_ms 50-1000")
            )
        }
        TestSupport.expectEqual(
            parseError("x provider=assemblyai pacing=burst"),
            .inconsistent(line: 1, reason: "provider=assemblyai requires pacing=realtime or 1.25x")
        )
        TestSupport.expect(
            (try? Core.parseVariant("x frame_ms=20 pacing=burst")) != nil,
            "Deepgram variants keep every frame size and pace"
        )
        TestSupport.expectEqual(parseError("x\ny provider=assemblyai frame_ms=10"), .inconsistent(
            line: 2, reason: "provider=assemblyai requires frame_ms 50-1000"
        ))
        let allowed = Core.ParseError.invalidValue(line: 1, key: "prompt").description
        TestSupport.expect(
            allowed.contains("off, coding, ai-chat, search, email, terminal, dictation"),
            "The prompt error lists the scenarios"
        )
    }

    private static func testAssemblyAIRequestFromVariant() {
        func items(_ line: String, keyterms: [String]) -> [String: String] {
            guard let variant = try? Core.parseVariant(line) else {
                TestSupport.expect(false, "The variant parses")
                return [:]
            }
            let url = AssemblyAIStreamingCore.listenURL(
                for: Core.assemblyAIConfiguration(for: variant, keyterms: variant.keyterms.select(from: keyterms))
            )
            TestSupport.expect(!url.absoluteString.contains(syntheticKey), "The key never enters the URL")
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        }
        let terms = ["Claude Code", "a+b", "FreeFlow"]
        let full = items("aai provider=assemblyai keyterms=all", keyterms: terms)
        TestSupport.expectEqual(full["speech_model"], "universal-3-6-pro")
        TestSupport.expectEqual(full["language_codes"], #"["en"]"#)
        TestSupport.expectEqual(full["sample_rate"], "16000")
        TestSupport.expectEqual(full["encoding"], "pcm_s16le")
        TestSupport.expectEqual(full["prompt"], AssemblyAIStreamingCore.PromptScenario.dictation.prompt)
        TestSupport.expectEqual(full["keyterms_prompt"], #"["Claude Code","a+b","FreeFlow"]"#)
        TestSupport.expectEqual(full["mode"], nil)

        let top = items("aai provider=assemblyai keyterms=top-2 prompt=off mode=min_latency rate=48000", keyterms: terms)
        TestSupport.expectEqual(top["keyterms_prompt"], #"["Claude Code","a+b"]"#)
        TestSupport.expectEqual(top["prompt"], nil)
        TestSupport.expectEqual(top["mode"], "min_latency")
        TestSupport.expectEqual(top["sample_rate"], "48000")

        let bare = items("aai provider=assemblyai keyterms=none prompt=email", keyterms: terms)
        TestSupport.expectEqual(bare["keyterms_prompt"], nil)
        TestSupport.expectEqual(bare["prompt"], AssemblyAIStreamingCore.PromptScenario.email.prompt)

        // AssemblyAI's caps apply: terms over 50 characters are dropped, not cut.
        let long = String(repeating: "x", count: 51)
        TestSupport.expectEqual(
            items("aai provider=assemblyai keyterms=all", keyterms: [long, "Kubernetes"])["keyterms_prompt"],
            #"["Kubernetes"]"#
        )
    }

    private static func testQueryOverridesKeepKeytermsAndDropOmitted() {
        let base = DeepgramStreamingCore.listenURL(for: .init(
            apiKey: syntheticKey,
            language: "es",
            sampleRate: 16000,
            keyterms: ["Claude Code", "a+b"]
        ))
        // Overrides every item the app's request may add beyond main's (endpointing,
        // mip_opt_out), so the expectation holds whichever of them the base URL has.
        let overridden = Core.overridingQuery(of: base, with: [
            Core.QueryItem(name: "language", value: nil),
            Core.QueryItem(name: "endpointing", value: "500"),
            Core.QueryItem(name: "mip_opt_out", value: "true"),
            Core.QueryItem(name: "smart_format", value: "false"),
        ])
        TestSupport.expectEqual(
            overridden.absoluteString,
            "wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&channels=1&punctuate=true&interim_results=true&keyterm=Claude%20Code&keyterm=a%2Bb&endpointing=500&mip_opt_out=true&smart_format=false"
        )
        TestSupport.expect(!overridden.absoluteString.contains("synthetic"), "The key never enters the URL")
    }

    private static func testPacingSchedule() {
        TestSupport.expectEqual(
            Core.sendOffsetsMilliseconds(frameCount: 4, frameMilliseconds: 50, pacing: .realtime),
            [0, 50, 100, 150]
        )
        TestSupport.expectEqual(
            Core.sendOffsetsMilliseconds(frameCount: 4, frameMilliseconds: 50, pacing: .faster),
            [0, 40, 80, 120]
        )
        TestSupport.expectEqual(
            Core.sendOffsetsMilliseconds(frameCount: 4, frameMilliseconds: 50, pacing: .burst),
            [0, 0, 0, 0]
        )
        TestSupport.expectEqual(Core.sendOffsetsMilliseconds(frameCount: 0, frameMilliseconds: 50, pacing: .realtime), [])
        TestSupport.expectApproximatelyEqual(
            Core.estimatedCostUSD(audioSeconds: 120, variants: 3, repeats: 2, pricePerMinute: 0.0077),
            0.0924,
            accuracy: 1e-9
        )
    }

    private static func testFrameSlicing() {
        TestSupport.expectEqual(
            Core.frames(of: Data(count: 4000), sampleRate: 16000, frameMilliseconds: 50).map(\.count),
            [1600, 1600, 800]
        )
        TestSupport.expectEqual(Core.frames(of: Data(), sampleRate: 16000, frameMilliseconds: 50), [])
        TestSupport.expectEqual(
            Core.frames(of: Data(count: 880), sampleRate: 22050, frameMilliseconds: 10).map(\.count),
            [440, 440]
        )
        for (bytes, rate, milliseconds) in [(1, 16000, 50), (3202, 16000, 50), (9601, 48000, 20), (2000, 8000, 10)] {
            let frames = Core.frames(of: Data(count: bytes), sampleRate: rate, frameMilliseconds: milliseconds)
            TestSupport.expect(frames.allSatisfy { !$0.isEmpty }, "No frame is ever empty")
            TestSupport.expectEqual(frames.map(\.count).reduce(0, +), bytes)
        }
        TestSupport.expectEqual(Core.littleEndianData([1, -2]), Data([0x01, 0x00, 0xFE, 0xFF]))
    }

    private static func testAssemblyAIChunksAndSchedule() {
        func counts(_ bytes: Int, _ rate: Int, _ milliseconds: Int) -> [Int] {
            Core.assemblyAIChunks(of: Data(repeating: 1, count: bytes), sampleRate: rate, frameMilliseconds: milliseconds)
                .map(\.count)
        }
        // A last chunk under 50 ms is padded to 50 ms with silence; one of 50 ms or more is kept.
        TestSupport.expectEqual(counts(4000, 16000, 50), [1600, 1600, 1600])
        TestSupport.expectEqual(counts(3500, 16000, 100), [3200, 1600])
        TestSupport.expectEqual(counts(5200, 16000, 100), [3200, 2000])
        TestSupport.expectEqual(counts(2, 16000, 1000), [1600])
        TestSupport.expectEqual(counts(64000, 16000, 1000), [32000, 32000])
        // 22.05 kHz rounds up to 1103 samples, so a 50 ms chunk never shrinks to 49.98 ms.
        TestSupport.expectEqual(counts(5000, 22050, 50), [2206, 2206, 2206])
        TestSupport.expectEqual(Core.assemblyAIChunks(of: Data(), sampleRate: 16000, frameMilliseconds: 50), [])

        let padded = Core.assemblyAIChunks(of: Data(repeating: 7, count: 2000), sampleRate: 16000, frameMilliseconds: 50)
        TestSupport.expectEqual(padded.map(\.count), [1600, 1600])
        TestSupport.expect(padded[1].prefix(400).allSatisfy { $0 == 7 }, "The audio comes first")
        TestSupport.expect(padded[1].dropFirst(400).allSatisfy { $0 == 0 }, "The padding is silence")

        for (bytes, rate, milliseconds) in [
            (2, 16000, 50), (3202, 16000, 50), (9602, 48000, 50), (2000, 8000, 50), (100_002, 44100, 1000),
            (7778, 22050, 50), (12_346, 24000, 333), (88_200, 44100, 55),
        ] {
            let chunks = Core.assemblyAIChunks(of: Data(count: bytes), sampleRate: rate, frameMilliseconds: milliseconds)
            let bytesPerSecond = rate * 2
            for chunk in chunks {
                // 50 ms <= count / bytesPerSecond <= 1000 ms, in integers.
                TestSupport.expect(
                    chunk.count * 1000 >= 50 * bytesPerSecond && chunk.count * 1000 <= 1000 * bytesPerSecond,
                    "Every AssemblyAI chunk is 50-1000 ms"
                )
                TestSupport.expect(chunk.count % 2 == 0, "Chunks hold whole samples")
            }
            TestSupport.expect(chunks.map(\.count).reduce(0, +) >= bytes, "No audio is dropped")
        }

        // The schedule follows the audio before each chunk, so whole-sample frames match
        // the Deepgram schedule and a padded last chunk does not move.
        for pacing in Core.Pacing.allCases {
            TestSupport.expectEqual(
                Core.sendOffsetsMilliseconds(chunkByteCounts: [1600, 1600, 1600, 1600], sampleRate: 16000, pacing: pacing),
                Core.sendOffsetsMilliseconds(frameCount: 4, frameMilliseconds: 50, pacing: pacing)
            )
        }
        let rounded = Core.sendOffsetsMilliseconds(chunkByteCounts: [2206, 2206, 2206], sampleRate: 22050, pacing: .faster)
        TestSupport.expectEqual(rounded.count, 3)
        TestSupport.expectApproximatelyEqual(rounded[1], 1103.0 / 22.05 / 1.25, accuracy: 1e-9)
        TestSupport.expectApproximatelyEqual(rounded[2], 2206.0 / 22.05 / 1.25, accuracy: 1e-9)
        TestSupport.expectEqual(Core.sendOffsetsMilliseconds(chunkByteCounts: [], sampleRate: 16000, pacing: .realtime), [])
    }

    private static func testAssemblyAIStatusAndBilling() {
        func status(
            failure: AssemblyAIStreamingError? = nil,
            closeFailure: AssemblyAIStreamingError? = nil,
            httpStatus: Int? = 101,
            began: Bool = true,
            sendFailed: Bool = false,
            terminated: Bool = false,
            timedOut: Bool = false
        ) -> Core.RunStatus {
            Core.assemblyAIRunStatus(
                failure: failure, closeFailure: closeFailure, httpStatus: httpStatus, began: began,
                sendFailed: sendFailed, terminated: terminated, timedOut: timedOut
            )
        }
        TestSupport.expectEqual(status(terminated: true), .ok)
        TestSupport.expectEqual(status(timedOut: true), .timedOut)
        TestSupport.expectEqual(status(), .closedEarly)
        TestSupport.expectEqual(status(sendFailed: true, terminated: true), .sendFailed)
        TestSupport.expectEqual(status(failure: .unauthorized, began: false), .keyRefused)
        TestSupport.expectEqual(status(failure: .accountLimit, began: false), .accountLimit)
        TestSupport.expectEqual(status(failure: .serverError(code: 3007), terminated: true), .serverError)
        TestSupport.expectEqual(status(closeFailure: .serverError(code: 3005)), .serverError)
        TestSupport.expectEqual(status(closeFailure: .unauthorized, began: false), .keyRefused)
        TestSupport.expectEqual(status(httpStatus: 401, began: false), .httpError(401))
        TestSupport.expectEqual(status(httpStatus: 101, began: false), .connectFailed)
        TestSupport.expectEqual(status(httpStatus: nil, began: false), .connectFailed)
        TestSupport.expectEqual(status(httpStatus: 500, began: true, terminated: true), .ok)

        TestSupport.expectEqual(Core.RunStatus.keyRefused.csvValue, "key_refused")
        TestSupport.expectEqual(Core.RunStatus.accountLimit.csvValue, "account_limit")
        TestSupport.expect(Core.RunStatus.keyRefused.isAuthenticationFailure, "A refused AssemblyAI key stops scheduling")
        TestSupport.expect(!Core.RunStatus.accountLimit.isAuthenticationFailure, "A rate limit does not stop scheduling")
        TestSupport.expectEqual(Core.RunStatus(assemblyAIFailure: .commitTimedOut), .serverError)

        let turn = #"""
        {"type":"Turn","turn_order":0,"end_of_turn":true,"transcript":"Ship it.",
        "words":[{"text":"Ship","start":1216,"end":1635},{"text":"it.","start":1676,"end":"x"},{"text":"now","start":2000,"end":2400}]}
        """#
        TestSupport.expectEqual(
            Core.wordTimings(fromTurnJSON: Data(turn.utf8)),
            [Core.WordTiming(start: 1.216, end: 1.635), Core.WordTiming(start: 2.0, end: 2.4)]
        )
        TestSupport.expectEqual(Core.wordTimings(fromTurnJSON: Data("[".utf8)), [])
        TestSupport.expectEqual(Core.wordTimings(fromTurnJSON: Data(#"{"type":"Termination"}"#.utf8)), [])

        // Deepgram bills the audio; AssemblyAI bills the open socket, about the paced audio
        // plus a second per stream, and never less than the server's 1.25x processing.
        func variant(_ line: String) -> Core.Variant {
            (try? Core.parseVariant(line)) ?? Core.Variant(name: "unparsed")
        }
        let deepgram = Core.billedMinutes(itemAudioSeconds: [30, 90], variants: [variant("a"), variant("b")], repeats: 2)
        TestSupport.expectApproximatelyEqual(deepgram[.deepgram] ?? -1, 8)
        TestSupport.expectEqual(deepgram[.assemblyAI], nil)
        TestSupport.expectApproximatelyEqual(
            (deepgram[.deepgram] ?? 0) * 0.0077,
            Core.estimatedCostUSD(audioSeconds: 120, variants: 2, repeats: 2, pricePerMinute: 0.0077),
            accuracy: 1e-12
        )
        let realtime = Core.billedMinutes(itemAudioSeconds: [30, 90], variants: [variant("a provider=assemblyai")], repeats: 2)
        TestSupport.expectApproximatelyEqual(realtime[.assemblyAI] ?? -1, (120 + 2) / 60 * 2)
        let faster = Core.billedMinutes(
            itemAudioSeconds: [30, 90], variants: [variant("a provider=assemblyai pacing=1.25x")], repeats: 1
        )
        TestSupport.expectApproximatelyEqual(faster[.assemblyAI] ?? -1, (120 / 1.25 + 2) / 60)
        var burst = variant("a provider=assemblyai")
        burst.pacing = .burst
        TestSupport.expectApproximatelyEqual(
            Core.billedMinutes(itemAudioSeconds: [60], variants: [burst], repeats: 1)[.assemblyAI] ?? -1,
            (60 / 1.25 + 1) / 60
        )
        let mixed = Core.billedMinutes(
            itemAudioSeconds: [60],
            variants: (try? Core.parseVariants(Core.preset(named: "providers") ?? "")) ?? [],
            repeats: 1
        )
        TestSupport.expectApproximatelyEqual(mixed[.deepgram] ?? -1, 1)
        TestSupport.expectApproximatelyEqual(mixed[.assemblyAI] ?? -1, 3 * 61 / 60)
    }

    private static func testSignTestPValues() {
        let cases: [(wins: Int, losses: Int, p: Double)] = [
            (8, 0, 0.0078125),
            (0, 8, 0.0078125),
            (9, 1, 0.021484375),
            (10, 2, 0.03857421875),
            (5, 5, 1),
            (3, 0, 0.25),
            (0, 0, 1),
        ]
        for value in cases {
            TestSupport.expectApproximatelyEqual(
                Core.signTestPValue(wins: value.wins, losses: value.losses),
                value.p,
                accuracy: 1e-12
            )
        }
    }

    private static func testPairedComparison() {
        let comparison = Core.pairedComparison(
            baseline: [1: 0.2, 2: 0.1, 3: 0.3, 4: 0.0],
            candidate: [1: 0.1, 2: 0.1, 3: 0.2, 4: 0.05, 5: 0.4]
        )
        TestSupport.expectEqual(comparison.files, 4)
        TestSupport.expectEqual(comparison.wins, 2)
        TestSupport.expectEqual(comparison.losses, 1)
        TestSupport.expectEqual(comparison.ties, 1)
        TestSupport.expectApproximatelyEqual(comparison.meanDelta, -0.0375, accuracy: 1e-12)
        TestSupport.expectApproximatelyEqual(comparison.pValue, 1.0, accuracy: 1e-12)

        TestSupport.expectEqual(Core.percentile([40, 10, 30, 20], 50), 20)
        TestSupport.expectEqual(Core.percentile([40, 10, 30, 20], 95), 40)
        TestSupport.expectEqual(Core.percentile([], 50), nil)

        func scoredRun(_ hypothesis: String, repeatIndex: Int, status: Core.RunStatus = .ok, ms: Double? = nil) -> Core.RunMetrics {
            Core.makeMetrics(
                variant: "same-1", item: 7, repeatIndex: repeatIndex, status: status, audioSeconds: 1,
                reference: "one two three four five", hypothesis: hypothesis, keyterms: [],
                finals: [], resultCount: 1, unfinalizedAtEnd: false,
                millisecondsToFromFinalize: ms, millisecondsToMetadata: ms
            )
        }
        let runs = [
            scoredRun("one two three four", repeatIndex: 1, ms: 100),
            scoredRun("one two three", repeatIndex: 2, ms: 300),
            scoredRun("", repeatIndex: 3, status: .timedOut),
        ]
        let means = Core.perItemMeanWER(runs)
        TestSupport.expectEqual(means.count, 1)
        TestSupport.expectApproximatelyEqual(means[7] ?? -1, 0.3)

        let summary = Core.summarize(runs)
        TestSupport.expectEqual(summary.files, 1)
        TestSupport.expectEqual(summary.runs, 3)
        TestSupport.expectEqual(summary.failed, 1)
        TestSupport.expectEqual(summary.referenceWords, 10)
        TestSupport.expectEqual(summary.deletions, 3)
        TestSupport.expectEqual(summary.lastWordDeletions, 2)
        TestSupport.expectApproximatelyEqual(summary.wordErrorRate ?? -1, 0.3)
        TestSupport.expectEqual(summary.fromFinalizeP50, 100)
        TestSupport.expectEqual(summary.metadataP95, 300)
    }

    private static func testLevelStatsOnSyntheticTones() {
        let rate = 48_000.0
        let minusSix = Float(pow(10, -6.0 / 20))
        let tone = Core.levelStats(sine(frequency: 1000, amplitude: minusSix, sampleRate: rate, count: 48_000), sampleRate: rate)
        TestSupport.expectApproximatelyEqual(tone.peakDBFS, -6.0, accuracy: 0.1)
        TestSupport.expectApproximatelyEqual(tone.activeRMSDBFS ?? 0, -9.03, accuracy: 0.1)
        TestSupport.expectApproximatelyEqual(tone.activeFraction, 1.0)
        TestSupport.expect(tone.energyAbove4kHz <= 0.01, "A 1 kHz tone has no energy above 4 kHz")

        let bright = Core.levelStats(sine(frequency: 10_000, amplitude: 0.5, sampleRate: rate, count: 48_000), sampleRate: rate)
        TestSupport.expect(bright.energyAbove8kHz >= 0.99, "A 10 kHz tone puts its energy above 8 kHz")

        let narrow = Core.levelStats(
            sine(frequency: 7_900, amplitude: 0.5, sampleRate: 16_000, count: 16_000),
            sampleRate: 16_000
        )
        TestSupport.expectEqual(narrow.energyAbove8kHz, 0)

        let silence = Core.levelStats([Float](repeating: 0, count: 48_000), sampleRate: rate)
        TestSupport.expectEqual(silence.activeRMSDBFS, nil)
        TestSupport.expectEqual(silence.activeFraction, 0)
    }

    private static func testGainAndLimiter() {
        TestSupport.expectEqual(Core.scaled([0.99, -0.7], decibels: 0), [0.99, -0.7])

        let cut = Core.scaled([0.25, -0.99], decibels: -6.0206)
        TestSupport.expectApproximatelyEqual(Double(cut[0]), 0.125, accuracy: 1e-4)
        TestSupport.expectApproximatelyEqual(Double(cut[1]), -0.495, accuracy: 1e-3)

        // A boost only scales; the limiter is a separate, later step.
        let boost = Core.scaled([0.1, 0.8], decibels: 6)
        TestSupport.expectApproximatelyEqual(Double(boost[0]), 0.1995, accuracy: 1e-3)
        TestSupport.expectApproximatelyEqual(Double(boost[1]), 1.596, accuracy: 1e-3)

        TestSupport.expectEqual(Core.softLimited([0.1, -0.3, 0.5]), [0.1, -0.3, 0.5])
        let loud = Core.softLimited(Core.scaled(sine(frequency: 1000, amplitude: 0.5, sampleRate: 48_000, count: 4800), decibels: 20))
        let peak = Double(loud.map { abs($0) }.max() ?? 0)
        TestSupport.expect(peak <= pow(10, -1.0 / 20) + 1e-6, "The limiter keeps a +20 dB boost below -1 dBFS")
        TestSupport.expect(Core.dbfs(peak) >= -1.5, "The limited peak stays close to the ceiling")
        TestSupport.expect(loud.contains { $0 < -0.5 }, "The limiter keeps the sign")

        // Before isolation a boost is limited too, so AUSoundIsolation never gets more
        // than -1 dBFS; without isolation, or without a boost, the gain step only scales.
        let master = sine(frequency: 1000, amplitude: Float(pow(10, -3.0 / 20)), sampleRate: 48_000, count: 4800)
        let isolationInput = Core.gained(master, decibels: 12, isolationFollows: true)
        let isolationPeak = Double(isolationInput.map { abs($0) }.max() ?? 0)
        TestSupport.expect(isolationPeak <= pow(10, -1.0 / 20) + 1e-6, "A +12 dB boost reaches isolation below -1 dBFS")
        TestSupport.expect(Core.dbfs(isolationPeak) >= -1.5, "The boost before isolation stays close to the ceiling")
        let fullScale = seededNoise(count: 4800, amplitude: 1, seed: 7)
        let maximumBoost = Core.gained(fullScale, decibels: 40, isolationFollows: true)
        TestSupport.expect(
            maximumBoost.allSatisfy { abs(Double($0)) <= pow(10, -1.0 / 20) + 1e-6 },
            "The largest boost of full-scale input still reaches isolation below -1 dBFS"
        )
        TestSupport.expectEqual(Core.gained(master, decibels: 12, isolationFollows: false), Core.scaled(master, decibels: 12))
        TestSupport.expectEqual(Core.gained(master, decibels: 0, isolationFollows: true), master)
        TestSupport.expectEqual(Core.gained(master, decibels: -6, isolationFollows: true), Core.scaled(master, decibels: -6))
    }

    private static func testIsolationAlignment() {
        let latency = 2705
        let slice = 4096
        let candidates = [latency, latency + slice]
        let input = seededNoise(count: 24_000, amplitude: 0.3, seed: 11)
        let independent = seededNoise(count: 24_000, amplitude: 0.1, seed: 29)
        let tail = latency + slice + 960
        for delay in candidates {
            // A wet mix: 30 % of the dry input plus a second, uncorrelated signal.
            let mixed = zip(input, independent).map { 0.3 * $0 + $1 }
            let output = [Float](repeating: 0, count: delay) + mixed
                + [Float](repeating: 0, count: tail - delay)
            TestSupport.expectEqual(
                Core.bestAlignmentOffset(output: output, input: input, candidates: candidates),
                delay
            )
            // Fully wet: a smoothed copy, as an isolated signal keeps the input's phase.
            var smoothed = input
            for index in 1..<input.count { smoothed[index] = 0.5 * (input[index] + input[index - 1]) }
            let wet = [Float](repeating: 0, count: delay) + smoothed + [Float](repeating: 0, count: tail - delay)
            TestSupport.expectEqual(Core.bestAlignmentOffset(output: wet, input: input, candidates: candidates), delay)
        }

        // Silent output, silent input, and a match at neither candidate are refused.
        let delayed = [Float](repeating: 0, count: latency) + input + [Float](repeating: 0, count: slice + 960)
        TestSupport.expectEqual(
            Core.bestAlignmentOffset(output: [Float](repeating: 0, count: delayed.count), input: input, candidates: candidates),
            nil
        )
        TestSupport.expectEqual(
            Core.bestAlignmentOffset(output: delayed, input: [Float](repeating: 0, count: input.count), candidates: candidates),
            nil
        )
        TestSupport.expectEqual(
            Core.bestAlignmentOffset(output: independent + delayed, input: input, candidates: candidates),
            nil
        )
        // Too short for the later window: only the reported latency is considered.
        TestSupport.expectEqual(
            Core.bestAlignmentOffset(output: Array(delayed.prefix(latency + input.count)), input: input, candidates: candidates),
            latency
        )
        // A signal that repeats every slice matches both windows, so it is refused.
        let periodic = (0..<(input.count + slice)).map { input[$0 % slice] }
        let ambiguous = [Float](repeating: 0, count: latency) + periodic + [Float](repeating: 0, count: 960)
        TestSupport.expectEqual(
            Core.bestAlignmentOffset(output: ambiguous, input: Array(periodic.prefix(input.count)), candidates: candidates),
            nil
        )
    }

    private static func testSecretIsRedacted() {
        guard let secret = Core.Secret("  \(syntheticKey)\n") else {
            TestSupport.expect(false, "A non-empty key is accepted")
            return
        }
        TestSupport.expectEqual(secret.revealed, syntheticKey)
        TestSupport.expectEqual(String(describing: secret), "<redacted>")
        TestSupport.expectEqual(String(reflecting: secret), "<redacted>")
        TestSupport.expect(!"key: \(secret)".contains("synthetic"), "Interpolation hides the key")
        var dumped = ""
        dump(secret, to: &dumped)
        TestSupport.expect(!dumped.contains("synthetic"), "dump hides the key")
        TestSupport.expect(Core.Secret("   ") == nil, "A blank key is rejected")

        // Only one key token is accepted, so nothing else in a key file reaches the
        // Authorization header, and a key always fits on one line for the name check.
        let hexKey = String(repeating: "0123456789abcdef", count: 3).prefix(40)
        TestSupport.expectEqual(Core.Secret("\(hexKey)\n")?.revealed, String(hexKey))
        TestSupport.expect(Core.Secret(String(repeating: "a", count: 20)) != nil, "A 20-character key is accepted")
        TestSupport.expect(Core.Secret(String(repeating: "a", count: 128)) != nil, "A 128-character key is accepted")
        TestSupport.expectEqual(Core.Secret("test-key-0000-0000-0000\r\n")?.revealed, "test-key-0000-0000-0000")
        for raw in [
            "",
            "\n\n",
            "test-key-0000\ntest-key-0000",
            "test-key-0000 0000-0000",
            "test-key-0000\u{200B}-0000-0000",
            "test-key-0000\u{7F}-0000-0000",
            "# synthetic lab key\n\(syntheticKey)",
            "DEEPGRAM_API_KEY=\(syntheticKey)",
            "\(syntheticKey)\nOTHER_SYNTHETIC_KEY=\(syntheticKey)",
            "\(syntheticKey) \(syntheticKey)",
            "dg-synthetic\tkey-with-a-tab",
            "dg-synthetic-not-a-key\u{0}",
            "dg-synthetic-nöt-a-key",
            String(repeating: "a", count: 19),
            String(repeating: "a", count: 129),
        ] {
            TestSupport.expect(Core.Secret(raw) == nil, "Anything but one key token is rejected")
        }
        TestSupport.expect(!Core.Secret.requirement.contains("synthetic"), "The requirement text is fixed")

        // A key file passed as --variants parses as a variant named after the key.
        let misused = (try? Core.parseVariants(syntheticKey + "\n"))?.map(\.name) ?? []
        TestSupport.expectEqual(misused, [syntheticKey])
        TestSupport.expect(Core.variantNamesExposeKey(misused, key: secret), "A name equal to the key is caught")
        TestSupport.expect(
            Core.variantNamesExposeKey(["run-\(syntheticKey)"], key: secret),
            "A name containing the key is caught"
        )
        TestSupport.expect(!Core.variantNamesExposeKey(["ep500", "same-1"], key: secret), "Ordinary names pass")
    }

    private static func testGitWorkTreeDetection() {
        let nested = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/repo/sub/../out/run1", isDirectory: true),
            exists: { $0 == "/lab/repo/.git" }
        )
        TestSupport.expectEqual(nested?.path, "/lab/repo")
        // A ".." that crosses into the repo from outside is found only after standardizing.
        let crossing = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/elsewhere/../repo/out", isDirectory: true),
            exists: { $0 == "/lab/repo/.git" }
        )
        TestSupport.expectEqual(crossing?.path, "/lab/repo")
        // The other way round: the raw path names the repo, but it resolves outside.
        let leaving = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/repo/../other/out", isDirectory: true),
            exists: { $0 == "/lab/repo/.git" }
        )
        TestSupport.expectEqual(leaving, nil)
        // Only standardized paths are probed, from the folder itself up to the root.
        var probed: [String] = []
        let walked = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/other/../repo/./sub", isDirectory: true),
            exists: { path in
                probed.append(path)
                return false
            }
        )
        TestSupport.expectEqual(walked, nil)
        TestSupport.expectEqual(probed, ["/lab/repo/sub/.git", "/lab/repo/.git", "/lab/.git", "/.git"])
        let itself = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/repo", isDirectory: true),
            exists: { $0 == "/lab/repo/.git" }
        )
        TestSupport.expectEqual(itself?.path, "/lab/repo")
        let elsewhere = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/elsewhere", isDirectory: true),
            exists: { $0 == "/lab/repo/.git" }
        )
        TestSupport.expectEqual(elsewhere, nil)
        let none = Core.gitWorkTreeRoot(
            containing: URL(fileURLWithPath: "/lab/repo/out", isDirectory: true),
            exists: { _ in false }
        )
        TestSupport.expectEqual(none, nil)
    }

    private static func testManifestParsing() {
        let base = URL(fileURLWithPath: "/lab", isDirectory: true)
        let home = URL(fileURLWithPath: "/home/synthetic", isDirectory: true)
        let entries = try? Core.parseManifest(
            "# audio\treference\n\nclip01.wav\tclip01.txt\nsub/clip02.wav\t/abs/clip02.txt\tterms.txt\n~/clip03.wav\tclip03.txt\n",
            baseDirectory: base,
            homeDirectory: home
        )
        TestSupport.expectEqual(entries?.count, 3)
        TestSupport.expectEqual(entries?[0].item, 1)
        TestSupport.expectEqual(entries?[0].line, 3)
        TestSupport.expectEqual(entries?[0].audio.path, "/lab/clip01.wav")
        TestSupport.expectEqual(entries?[0].reference.path, "/lab/clip01.txt")
        TestSupport.expectEqual(entries?[0].keyterms, nil)
        TestSupport.expectEqual(entries?[1].item, 2)
        TestSupport.expectEqual(entries?[1].line, 4)
        TestSupport.expectEqual(entries?[1].audio.path, "/lab/sub/clip02.wav")
        TestSupport.expectEqual(entries?[1].reference.path, "/abs/clip02.txt")
        TestSupport.expectEqual(entries?[1].keyterms?.path, "/lab/terms.txt")
        TestSupport.expectEqual(entries?[2].audio.path, "/home/synthetic/clip03.wav")

        func manifestError(_ text: String) -> Core.ParseError? {
            do {
                _ = try Core.parseManifest(text, baseDirectory: base, homeDirectory: home)
                return nil
            } catch {
                return error as? Core.ParseError
            }
        }
        TestSupport.expectEqual(manifestError("only-one-column"), .badManifestLine(line: 1))
        TestSupport.expectEqual(manifestError("a.wav\tb.txt\tc.txt\td.txt"), .badManifestLine(line: 1))
        TestSupport.expectEqual(manifestError("# nothing\n\n"), .emptyManifest)
        TestSupport.expectEqual(manifestError(""), .emptyManifest)
    }

    private static func testResultsCSVHasMetricsOnly() {
        let metrics = Core.makeMetrics(
            variant: "ep500",
            item: 3,
            repeatIndex: 1,
            status: .ok,
            audioSeconds: 2.5,
            reference: "Ship it on Friday.",
            hypothesis: "Ship it on",
            keyterms: ["Friday"],
            finals: [[
                Core.WordTiming(start: 0, end: 0.3),
                Core.WordTiming(start: 0.3, end: 0.5),
                Core.WordTiming(start: 0.5, end: 0.7),
            ]],
            resultCount: 3,
            unfinalizedAtEnd: false,
            millisecondsToFromFinalize: 180.5,
            millisecondsToMetadata: 240
        )
        let row = Core.csvRow(metrics)
        TestSupport.expectEqual(row, "ep500,3,1,ok,2.500,4,0,1,0,0.2500,0.2500,0,1,1,0,0,3,1,0,0,180.5,240.0")
        TestSupport.expectEqual(Core.csvHeader.split(separator: ",", omittingEmptySubsequences: false).count, 22)
        TestSupport.expectEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 22)
        TestSupport.expect(!row.lowercased().contains("ship"), "No transcript text in the row")

        let refused = Core.csvRow(Core.makeMetrics(
            variant: "ep500", item: 3, repeatIndex: 2, status: .httpError(401), audioSeconds: 2.5,
            reference: "Ship it on Friday.", hypothesis: "", keyterms: ["Friday"], finals: [],
            resultCount: 0, unfinalizedAtEnd: false, millisecondsToFromFinalize: nil, millisecondsToMetadata: nil
        ))
        let fields = refused.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        TestSupport.expectEqual(fields.count, 22)
        TestSupport.expectEqual(fields[3], "http_401")
        TestSupport.expect(Core.RunStatus.httpError(401).isAuthenticationFailure, "401 stops scheduling")
        TestSupport.expect(Core.RunStatus.httpError(403).isAuthenticationFailure, "403 stops scheduling")
        for status in [Core.RunStatus.httpError(500), .httpError(429), .timedOut, .ok, .connectFailed] {
            TestSupport.expect(!status.isAuthenticationFailure, "Only a refused key stops scheduling")
        }
        TestSupport.expect(fields[5...15].allSatisfy(\.isEmpty), "Scores are empty for a failed run")
        TestSupport.expectEqual(fields[20], "")
        TestSupport.expectEqual(fields[21], "")
    }
}
