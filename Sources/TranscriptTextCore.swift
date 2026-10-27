import Foundation
import os.log

private let transcriptTextLog = OSLog(
    subsystem: "com.zachlatta.freeflow",
    category: "Transcription"
)

enum TranscriptionResponseParsingError: Error, Equatable {
    case invalidResponse
}

enum TranscriptionResponseParser {
    // Whisper can emit these stock sign-offs for silence or background noise,
    // mostly subtitle credits from its training data. They are compared against
    // the whole normalized text and only suppressed when segment metadata
    // independently reports a high probability of no speech, which protects
    // genuine short dictations. Non-English phrases returned for an English
    // request cannot be real dictation and are dropped without metadata.
    private struct HallucinationPhrase {
        let text: String
        let language: String
    }

    private static let hallucinationPhrases: [HallucinationPhrase] = [
        HallucinationPhrase(text: "thank you", language: "en"),
        HallucinationPhrase(text: "thank you for watching", language: "en"),
        HallucinationPhrase(text: "thank you very much", language: "en"),
        HallucinationPhrase(text: "thank you so much", language: "en"),
        HallucinationPhrase(text: "thanks for watching", language: "en"),
        HallucinationPhrase(text: "see you next time", language: "en"),
        HallucinationPhrase(text: "bye", language: "en"),
        HallucinationPhrase(text: "please subscribe", language: "en"),
        HallucinationPhrase(text: "like and subscribe", language: "en"),
        HallucinationPhrase(text: "subtitles by", language: "en"),
        HallucinationPhrase(text: "subtitles by the amara.org community", language: "en"),
        HallucinationPhrase(text: "you", language: "en"),
        HallucinationPhrase(text: "시청해주셔서 감사합니다", language: "ko"),
        HallucinationPhrase(text: "시청해 주셔서 감사합니다", language: "ko"),
        HallucinationPhrase(text: "구독과 좋아요 부탁드립니다", language: "ko"),
        HallucinationPhrase(text: "감사합니다", language: "ko"),
        HallucinationPhrase(text: "ご視聴ありがとうございました", language: "ja"),
        HallucinationPhrase(text: "チャンネル登録お願いします", language: "ja"),
        HallucinationPhrase(text: "谢谢观看", language: "zh"),
        HallucinationPhrase(text: "请订阅", language: "zh"),
        HallucinationPhrase(text: "字幕由 amara.org 社区提供", language: "zh"),
        HallucinationPhrase(text: "字幕由amara.org社区提供", language: "zh"),
        HallucinationPhrase(text: "gracias por ver", language: "es"),
        HallucinationPhrase(text: "suscríbete", language: "es"),
        HallucinationPhrase(text: "legendas pela comunidade amara.org", language: "pt"),
        HallucinationPhrase(text: "obrigado por assistir", language: "pt"),
        HallucinationPhrase(text: "sous-titres réalisés par la communauté d'amara.org", language: "fr"),
        HallucinationPhrase(text: "merci d'avoir regardé", language: "fr"),
        HallucinationPhrase(text: "untertitel im auftrag des zdf", language: "de"),
        HallucinationPhrase(text: "danke fürs zuschauen", language: "de"),
        HallucinationPhrase(text: "субтитры сделал dimatorzok", language: "ru"),
        HallucinationPhrase(text: "спасибо за просмотр", language: "ru"),
        HallucinationPhrase(text: "ترجمة نانسي قنقر", language: "ar")
    ]

    /// Normalized phrase -> language code, built with the same normalizer that
    /// is applied to transcripts so punctuation and spacing cannot defeat a match.
    private static let normalizedHallucinationPhrases: [String: String] = Dictionary(
        hallucinationPhrases.map { (normalized($0.text), $0.language) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Any subtitle credit naming amara.org is a hallucination in every language.
    /// Unlisted wordings are recognised by the adjacent tokens "amara org" in a
    /// credit-length text and still need metadata support. Longer texts are real
    /// dictation that happens to mention the site, and a name such as "McNamara"
    /// or "Samara" is a different token and never matches.
    private static let amaraFamilyMaximumTokens = 10
    /// Logged in place of the transcript for family matches, which are free text.
    private static let amaraFamilyLabel = "amara.org family"

    /// A blocklist hit. `label` is the matched entry or the family label, never
    /// free transcript text, so it is the only part that reaches the log.
    struct HallucinationMatch: Equatable {
        let label: String
        let language: String
    }

    // Tuned conservatively against roughly 500 quiet, noisy, and real-speech
    // samples to minimize the chance of filtering genuine short dictations.
    private static let hallucinationNoSpeechThreshold = 0.1

    // Reference Whisper's defaults for discarding a decoded window the model is
    // both unsure about (avg_logprob below -1.0) and believes is silent
    // (no_speech_prob above 0.6); compression_ratio above 2.4 marks degenerate
    // repetition and is only trusted here together with a blocklisted phrase.
    private static let segmentNoSpeechThreshold = 0.6
    private static let segmentLogProbThreshold = -1.0
    private static let segmentCompressionRatioThreshold = 2.4

    static func parse(_ data: Data, expectedLanguage: String? = nil) throws -> String {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        if let json = object as? [String: Any],
           let text = json["text"] as? String {
            var transcript = text
            var segments = json["segments"] as? [[String: Any]]
            if let allSegments = segments, !allSegments.isEmpty {
                let kept = allSegments.filter { !shouldDropSegment($0) }
                if kept.count != allSegments.count {
                    os_log(
                        .info,
                        log: transcriptTextLog,
                        "Dropped %d of %d transcription segments as probable non-speech",
                        allSegments.count - kept.count,
                        allSegments.count
                    )
                    guard !kept.isEmpty else { return "" }
                    transcript = kept
                        .compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    segments = kept
                }
            }
            if isHallucination(text: transcript, segments: segments, expectedLanguage: expectedLanguage) {
                return ""
            }
            return transcript
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionResponseParsingError.invalidResponse
        }

        return text
    }

    /// Lowercases and keeps only letters and digits joined by single spaces, so
    /// "Thank you for watching!!!" and "subtitles by the Amara.org community"
    /// compare the same in any script. Applied to the phrase list and the input alike.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .joined(separator: " ")
    }

    private static func shouldDropSegment(_ segment: [String: Any]) -> Bool {
        if let noSpeechProb = segment["no_speech_prob"] as? Double,
           let avgLogProb = segment["avg_logprob"] as? Double,
           noSpeechProb > segmentNoSpeechThreshold, avgLogProb < segmentLogProbThreshold {
            return true
        }
        if let compressionRatio = segment["compression_ratio"] as? Double,
           compressionRatio > segmentCompressionRatioThreshold,
           let segmentText = segment["text"] as? String,
           hallucinationMatch(for: normalized(segmentText)) != nil {
            return true
        }
        return false
    }

    /// The blocklist entry equal to `normalizedText`, the amara.org family for a
    /// short text containing the adjacent tokens "amara org", nil otherwise.
    static func hallucinationMatch(for normalizedText: String) -> HallucinationMatch? {
        if let language = normalizedHallucinationPhrases[normalizedText] {
            return HallucinationMatch(label: normalizedText, language: language)
        }
        let tokens = normalizedText.split(separator: " ")
        let namesAmara = zip(tokens, tokens.dropFirst()).contains { $0 == "amara" && $1 == "org" }
        guard namesAmara, tokens.count <= amaraFamilyMaximumTokens else { return nil }
        return HallucinationMatch(label: amaraFamilyLabel, language: "en")
    }

    /// Primary language subtag, lowercased ("en-US" and "en_US" -> "en"); nil when empty.
    private static func primaryLanguageCode(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let code = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
              !code.isEmpty else { return nil }
        return String(code)
    }

    private static func isHallucination(
        text: String,
        segments: [[String: Any]]?,
        expectedLanguage: String?
    ) -> Bool {
        guard let match = hallucinationMatch(for: normalized(text)) else {
            return false
        }

        if primaryLanguageCode(expectedLanguage) == "en", match.language != "en" {
            os_log(
                .info,
                log: transcriptTextLog,
                "Suppressing '%{public}@' (%{public}@ sign-off) returned for an English transcription request",
                match.label,
                match.language
            )
            return true
        }

        guard let segments else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response has no segments/no_speech metadata",
                match.label
            )
            return false
        }

        guard let noSpeechProb = segments.first?["no_speech_prob"] as? Double else {
            os_log(
                .info,
                log: transcriptTextLog,
                "Skipping hallucination filter for '%{public}@': provider response omitted no_speech_prob",
                match.label
            )
            return false
        }
        return noSpeechProb >= hallucinationNoSpeechThreshold
    }
}

enum TranscriptOutputSanitizer {
    // Verbatim translation deliberately preserves the cleanup prompt's EMPTY
    // sentinel because "empty" can be legitimate translated speech here.
    static func verbatimTranslation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    static func postProcessedTranscript(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 1 {
            result.removeFirst()
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if result == "EMPTY" {
            return ""
        }

        return result
    }

    static func commandModeTranscript(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func appearsToHaveExecutedInstruction(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rawTokens = significantTokens(in: rawTranscript)
        let cleanedTokens = significantTokens(in: cleanedTranscript)
        guard !rawTokens.isEmpty, !cleanedTokens.isEmpty else { return false }

        let instructionMarkers: Set<String> = [
            "ask", "answer", "compose", "create", "draft", "email", "generate", "make",
            "message", "prompt", "reply", "respond", "response", "summarize", "tell",
            "translate", "write", "claude", "chatgpt", "ai", "llm"
        ]
        let rawMarkers = rawTokens.intersection(instructionMarkers)
        guard !rawMarkers.isEmpty else { return false }

        let preservedMarkers = rawMarkers.intersection(cleanedTokens)
        let overlap = rawTokens.intersection(cleanedTokens)
        let overlapRatio = Double(overlap.count) / Double(max(rawTokens.count, 1))
        let assistantPreamblePattern = #"(?i)^\s*(sure|certainly|absolutely|here(?:'s| is)|i(?:'d| would) be happy to|i can)\b"#
        let cleanedHasAssistantPreamble = cleanedTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil
        let rawHasSamePreamble = rawTranscript.range(
            of: assistantPreamblePattern,
            options: .regularExpression
        ) != nil

        return (cleanedHasAssistantPreamble && !rawHasSamePreamble)
            || (preservedMarkers.isEmpty && overlapRatio < 0.35)
    }

    private static func significantTokens(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
            "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
            "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
            "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
            "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
            "would", "you", "your"
        ]

        let normalized = text.lowercased()
        let parts = normalized.split { character in
            !character.isLetter && !character.isNumber
        }

        return Set(parts.map(String.init).filter { token in
            token.count > 1 && !stopWords.contains(token)
        })
    }
}
