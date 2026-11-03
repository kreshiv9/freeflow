import Foundation

enum TranscriptTextCoreTests {
    static func run() {
        testJSONTranscriptParsing()
        testNonTranscriptJSONFallsBackToUTF8()
        testInvalidTranscriptResponses()
        testHighConfidenceHallucinationsAreSuppressed()
        testPossibleRealSpeechIsPreserved()
        testForeignSignOffSuppressedForEnglishRequestWithoutMetadata()
        testEnglishSignOffStillRequiresMetadata()
        testAmaraFamilyNeedsMetadata()
        testAmaraFamilyIgnoresOrdinaryDictation()
        testReferenceSegmentRuleRebuildsText()
        testCompressionRatioDropsOnlyBlocklistedSegments()
        testAllSegmentsDroppedReturnsEmpty()
        testWholeTextRuleUsesKeptSegments()
        testMissingSegmentFieldsTolerated()
        testNonBlocklistedForeignTextIsKept()
        testNormalizationHandlesPunctuationAndScripts()
        testPostProcessedTranscriptSanitization()
        testModeSpecificSanitization()
        testInstructionExecutionGuard()
    }

    private static func testJSONTranscriptParsing() {
        let data = jsonData(["text": "Synthetic transcript."])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(data),
            "Synthetic transcript."
        )

        let emptyData = jsonData(["text": ""])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(emptyData), "")
    }

    private static func testNonTranscriptJSONFallsBackToUTF8() {
        let data = Data("{\n  \"synthetic\": \"fallback\"\n}".utf8)
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(data),
            "{   \"synthetic\": \"fallback\" }"
        )
    }

    private static func testInvalidTranscriptResponses() {
        expectInvalidResponse(Data())
        expectInvalidResponse(Data(" \n\t ".utf8))
        expectInvalidResponse(Data("{malformed synthetic JSON".utf8))
        expectInvalidResponse(Data([0xFF, 0xFE]))
    }

    private static func testHighConfidenceHallucinationsAreSuppressed() {
        let atThreshold = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.1]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(atThreshold), "")

        let normalizedPhrase = jsonData([
            "text": "  THANK YOU FOR WATCHING!!!  ",
            "segments": [["no_speech_prob": 0.9]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(normalizedPhrase), "")
    }

    private static func testPossibleRealSpeechIsPreserved() {
        let lowProbability = jsonData([
            "text": "Thank you.",
            "segments": [["no_speech_prob": 0.099]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(lowProbability), "Thank you.")

        let missingMetadata = jsonData(["text": "Thank you."])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(missingMetadata), "Thank you.")

        let missingProbability = jsonData([
            "text": "Thank you.",
            "segments": [["synthetic": true]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(missingProbability), "Thank you.")

        let unrelatedSpeech = jsonData([
            "text": "Synthetic project update.",
            "segments": [["no_speech_prob": 0.95]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(unrelatedSpeech),
            "Synthetic project update."
        )
    }

    private static func testForeignSignOffSuppressedForEnglishRequestWithoutMetadata() {
        let korean = jsonData(["text": "시청해주셔서 감사합니다."])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(korean, expectedLanguage: "en"), "")
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(korean, expectedLanguage: "EN"), "")
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(korean, expectedLanguage: "en-US"), "")
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(korean, expectedLanguage: nil),
            "시청해주셔서 감사합니다."
        )
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(korean, expectedLanguage: "ko"),
            "시청해주셔서 감사합니다."
        )
        // Whisper also emits the sign-off with standard Korean spacing, which is a distinct normalized key.
        let koreanSpaced = jsonData(["text": "시청해 주셔서 감사합니다."])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(koreanSpaced, expectedLanguage: "en"), "")
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(koreanSpaced, expectedLanguage: nil),
            "시청해 주셔서 감사합니다."
        )

        let japanese = jsonData(["text": "ご視聴ありがとうございました。"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(japanese, expectedLanguage: "en"), "")
        let spanish = jsonData(["text": "Gracias por ver."])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(spanish, expectedLanguage: "en"), "")
        let french = jsonData(["text": "Merci d'avoir regardé !"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(french, expectedLanguage: "en"), "")
        let chinese = jsonData(["text": "字幕由 Amara.org 社区提供"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(chinese, expectedLanguage: "en"), "")
        // Chinese is normally written without spaces, which makes a distinct normalized key.
        let chineseUnspaced = jsonData(["text": "字幕由Amara.org社区提供"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(chineseUnspaced, expectedLanguage: "en"), "")
    }

    private static func testEnglishSignOffStillRequiresMetadata() {
        let confidentThankYou = jsonData([
            "text": "Thank you.",
            "segments": [[
                "text": " Thank you.",
                "no_speech_prob": 0.05,
                "avg_logprob": -0.3,
                "compression_ratio": 1.1
            ]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(confidentThankYou, expectedLanguage: "en"),
            "Thank you."
        )

        let thanksWithoutSegments = jsonData(["text": "Thanks for watching!"])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(thanksWithoutSegments, expectedLanguage: "en"),
            "Thanks for watching!"
        )

        let thanksWithMetadata = jsonData([
            "text": "Thanks for watching!",
            "segments": [["no_speech_prob": 0.5]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(thanksWithMetadata, expectedLanguage: "en"), "")

        let bye = jsonData([
            "text": "Bye.",
            "segments": [["no_speech_prob": 0.3]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(bye, expectedLanguage: "en"), "")

        let seeYou = jsonData([
            "text": "See you next time",
            "segments": [["no_speech_prob": 0.05]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(seeYou, expectedLanguage: "en"),
            "See you next time"
        )
    }

    private static func testAmaraFamilyNeedsMetadata() {
        let unlistedWithMetadata = jsonData([
            "text": "Subtitles created by the Amara.org community",
            "segments": [["no_speech_prob": 0.2]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(unlistedWithMetadata), "")

        let unlistedWithoutMetadata = jsonData(["text": "Subtitles created by the Amara.org community"])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(unlistedWithoutMetadata, expectedLanguage: "en"),
            "Subtitles created by the Amara.org community"
        )

        let portuguese = jsonData(["text": "Legendas pela comunidade Amara.org"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(portuguese, expectedLanguage: "en"), "")
    }

    /// The amara.org family rule must not reach into ordinary dictation: names
    /// such as McNamara are different tokens, and longer texts that mention the
    /// site are real speech. Matches are identified by a label that is either
    /// the blocklist entry or the family name, never free transcript text.
    private static func testAmaraFamilyIgnoresOrdinaryDictation() {
        let mcNamara = jsonData([
            "text": "McNamara organized the synthetic files.",
            "segments": [["no_speech_prob": 0.3, "avg_logprob": -0.2]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(mcNamara, expectedLanguage: "en"),
            "McNamara organized the synthetic files."
        )

        let tamara = jsonData([
            "text": "Tamara organised the synthetic plan.",
            "segments": [["no_speech_prob": 0.5]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(tamara, expectedLanguage: "en"),
            "Tamara organised the synthetic plan."
        )
        TestSupport.expectEqual(
            TranscriptionResponseParser.hallucinationMatch(
                for: TranscriptionResponseParser.normalized("Tamara organised the synthetic plan.")
            ),
            nil
        )

        let orgChart = jsonData([
            "text": "Samara org chart synthetic.",
            "segments": [[
                "text": " Samara org chart synthetic.",
                "compression_ratio": 2.5,
                "no_speech_prob": 0.0,
                "avg_logprob": -0.1
            ]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(orgChart), "Samara org chart synthetic.")

        let longMention = "Remind me to export the Amara.org subtitles for the synthetic project before Friday."
        let longWithMetadata = jsonData(["text": longMention, "segments": [["no_speech_prob": 0.2]]])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(longWithMetadata, expectedLanguage: "en"),
            longMention
        )
        let longWithoutMetadata = jsonData(["text": longMention])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(longWithoutMetadata, expectedLanguage: "en"),
            longMention
        )
        TestSupport.expectEqual(
            TranscriptionResponseParser.hallucinationMatch(for: TranscriptionResponseParser.normalized(longMention)),
            nil
        )

        TestSupport.expectEqual(
            TranscriptionResponseParser.hallucinationMatch(
                for: TranscriptionResponseParser.normalized("Subtitles created by the Amara.org community")
            ),
            TranscriptionResponseParser.HallucinationMatch(label: "amara.org family", language: "en")
        )
        TestSupport.expectEqual(
            TranscriptionResponseParser.hallucinationMatch(for: "thank you"),
            TranscriptionResponseParser.HallucinationMatch(label: "thank you", language: "en")
        )
        TestSupport.expectEqual(
            TranscriptionResponseParser.hallucinationMatch(for: "시청해주셔서 감사합니다"),
            TranscriptionResponseParser.HallucinationMatch(label: "시청해주셔서 감사합니다", language: "ko")
        )
    }

    private static func testReferenceSegmentRuleRebuildsText() {
        let mixed = jsonData([
            "text": "Synthetic alpha. Thank you for watching. Synthetic beta.",
            "segments": [
                ["text": " Synthetic alpha.", "no_speech_prob": 0.01, "avg_logprob": -0.2],
                ["text": " Thank you for watching.", "no_speech_prob": 0.9, "avg_logprob": -1.5],
                ["text": " Synthetic beta.", "no_speech_prob": 0.02, "avg_logprob": -0.3]
            ]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(mixed),
            "Synthetic alpha. Synthetic beta."
        )

        let boundary = jsonData([
            "text": "Synthetic boundary.",
            "segments": [["text": " Synthetic boundary.", "no_speech_prob": 0.6, "avg_logprob": -1.0]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(boundary), "Synthetic boundary.")

        let confidentButSilent = jsonData([
            "text": "Synthetic confident.",
            "segments": [["text": " Synthetic confident.", "no_speech_prob": 0.9, "avg_logprob": -0.5]]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(confidentButSilent), "Synthetic confident.")
    }

    private static func testCompressionRatioDropsOnlyBlocklistedSegments() {
        let data = jsonData([
            "text": "Please subscribe. Synthetic repeated synthetic repeated words.",
            "segments": [
                [
                    "text": " Please subscribe.",
                    "compression_ratio": 3.0,
                    "no_speech_prob": 0.1,
                    "avg_logprob": -0.4
                ],
                [
                    "text": " Synthetic repeated synthetic repeated words.",
                    "compression_ratio": 3.0,
                    "no_speech_prob": 0.05,
                    "avg_logprob": -0.2
                ]
            ]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(data),
            "Synthetic repeated synthetic repeated words."
        )
    }

    private static func testAllSegmentsDroppedReturnsEmpty() {
        let data = jsonData([
            "text": "Thank you for watching. Please subscribe.",
            "segments": [
                ["text": " Thank you for watching.", "no_speech_prob": 0.9, "avg_logprob": -2.0],
                ["text": " Please subscribe.", "no_speech_prob": 0.9, "avg_logprob": -2.0]
            ]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(data), "")
    }

    private static func testWholeTextRuleUsesKeptSegments() {
        let suppressed = jsonData([
            "text": "Synthetic noise. Thank you.",
            "segments": [
                ["text": " Synthetic noise.", "no_speech_prob": 0.95, "avg_logprob": -2.0],
                ["text": " Thank you.", "no_speech_prob": 0.5, "avg_logprob": -0.3]
            ]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(suppressed), "")

        let kept = jsonData([
            "text": "Synthetic noise. Thank you.",
            "segments": [
                ["text": " Synthetic noise.", "no_speech_prob": 0.95, "avg_logprob": -2.0],
                ["text": " Thank you.", "no_speech_prob": 0.05, "avg_logprob": -0.3]
            ]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(kept), "Thank you.")
    }

    private static func testMissingSegmentFieldsTolerated() {
        let partialSegments = jsonData([
            "text": "Synthetic original.",
            "segments": [
                [:],
                ["text": " Synthetic only text"],
                ["no_speech_prob": "high"],
                ["avg_logprob": -3.0],
                ["compression_ratio": 9.0]
            ]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(partialSegments), "Synthetic original.")

        let emptySegments = jsonData(["text": "Synthetic original.", "segments": []])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(emptySegments), "Synthetic original.")

        let malformedSegments = jsonData(["text": "Synthetic original.", "segments": "oops"])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(malformedSegments), "Synthetic original.")

        let keptWithoutText = jsonData([
            "text": "Thank you for watching. Synthetic.",
            "segments": [
                ["text": " Thank you for watching.", "no_speech_prob": 0.9, "avg_logprob": -2.0],
                ["no_speech_prob": 0.01]
            ]
        ])
        TestSupport.expectEqual(try? TranscriptionResponseParser.parse(keptWithoutText), "")
    }

    private static func testNonBlocklistedForeignTextIsKept() {
        let korean = jsonData(["text": "합성 프로젝트 업데이트입니다."])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(korean, expectedLanguage: "en"),
            "합성 프로젝트 업데이트입니다."
        )

        let koreanWithMetadata = jsonData([
            "text": "합성 프로젝트 업데이트입니다.",
            "segments": [["no_speech_prob": 0.95]]
        ])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(koreanWithMetadata, expectedLanguage: "en"),
            "합성 프로젝트 업데이트입니다."
        )

        let spanish = jsonData(["text": "Gracias por la actualización sintética."])
        TestSupport.expectEqual(
            try? TranscriptionResponseParser.parse(spanish, expectedLanguage: "en"),
            "Gracias por la actualización sintética."
        )
    }

    private static func testNormalizationHandlesPunctuationAndScripts() {
        TestSupport.expectEqual(
            TranscriptionResponseParser.normalized("  THANK YOU, for   watching!!! "),
            "thank you for watching"
        )
        TestSupport.expectEqual(
            TranscriptionResponseParser.normalized("Sous-titres réalisés par la communauté d'Amara.org"),
            "sous titres réalisés par la communauté d amara org"
        )
        TestSupport.expectEqual(TranscriptionResponseParser.normalized("谢谢观看。"), "谢谢观看")
    }

    private static func testPostProcessedTranscriptSanitization() {
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.postProcessedTranscript("  \"Synthetic output.\" \n"),
            "Synthetic output."
        )
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("EMPTY"), "")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("\"EMPTY\""), "")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("empty"), "empty")
        TestSupport.expectEqual(TranscriptOutputSanitizer.postProcessedTranscript("  \n "), "")
    }

    private static func testModeSpecificSanitization() {
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation("  \"EMPTY\"  "),
            "EMPTY"
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.verbatimTranslation(" \"Literal synthetic text.\" "),
            "Literal synthetic text."
        )
        TestSupport.expectEqual(
            TranscriptOutputSanitizer.commandModeTranscript("  \"Keep command quotes\" \n"),
            "\"Keep command quotes\""
        )
    }

    private static func testInstructionExecutionGuard() {
        TestSupport.expect(
            TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write an email asking Alex for the synthetic report.",
                cleanedTranscript: "Sure, here's a draft: Hello Alex, please send the report.",
                outputLanguage: ""
            ),
            "Assistant-style execution should be rejected"
        )
        TestSupport.expect(
            TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write a haiku about synthetic rain.",
                cleanedTranscript: "Soft drizzle taps windows.",
                outputLanguage: ""
            ),
            "Low-overlap instruction execution should be rejected"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Write an email asking Alex for the synthetic report.",
                cleanedTranscript: "Write an email asking Alex for the synthetic report.",
                outputLanguage: ""
            ),
            "Faithful cleanup should preserve instruction wording"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "The synthetic launch is Friday.",
                cleanedTranscript: "Sure, the synthetic launch is Friday.",
                outputLanguage: ""
            ),
            "Ordinary speech without an instruction marker should not trigger the guard"
        )
        TestSupport.expect(
            !TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
                rawTranscript: "Translate the synthetic update.",
                cleanedTranscript: "Aggiornamento sintetico.",
                outputLanguage: "Italian"
            ),
            "Explicit translation output should bypass the instruction guard"
        )
    }

    private static func jsonData(_ object: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            fatalError("Synthetic JSON fixture should be serializable")
        }
        return data
    }

    private static func expectInvalidResponse(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try TranscriptionResponseParser.parse(data)
            TestSupport.expect(false, "Expected invalid response error", file: file, line: line)
        } catch let error as TranscriptionResponseParsingError {
            TestSupport.expectEqual(error, .invalidResponse, file: file, line: line)
        } catch {
            TestSupport.expect(
                false,
                "Expected TranscriptionResponseParsingError, got \(error)",
                file: file,
                line: line
            )
        }
    }
}
