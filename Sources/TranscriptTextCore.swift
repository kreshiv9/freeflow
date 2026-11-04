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

    /// Delimiter lines and labels from the cleanup user message. A model sometimes echoes them
    /// ("store RAW_TRANSCRIPTION"); they never belong in pasted text.
    private static let scaffoldingLines: Set<String> = [
        "RAW_TRANSCRIPTION", "RAW_TRANSCRIPTION:", "<<<RAW_TRANSCRIPTION",
        "CONTEXT", "CONTEXT:", "<<<CONTEXT"
    ]

    /// Removes echoed prompt scaffolding: whole delimiter lines, an echoed CONTEXT header line, and
    /// a RAW_TRANSCRIPTION token at either end of the output. The uppercase underscore token cannot
    /// come from dictated speech, so stripping it is safe.
    static func strippingPromptScaffolding(_ value: String) -> String {
        let keptLines = value.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !scaffoldingLines.contains(trimmed) && !trimmed.hasPrefix(TextContextCore.promptHeader)
        }
        var result = keptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"^(?:<<<)?RAW_TRANSCRIPTION:?\s*"#, #"\s*(?:<<<)?RAW_TRANSCRIPTION:?$"#] {
            while let range = result.range(of: pattern, options: .regularExpression) {
                result.removeSubrange(range)
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    static func postProcessedTranscript(_ value: String) -> String {
        var result = strippingPromptScaffolding(value)
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

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "could",
        "for", "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
        "in", "into", "is", "it", "its", "just", "me", "my", "of", "on", "or", "our",
        "please", "she", "so", "that", "the", "their", "them", "then", "there", "this",
        "to", "um", "uh", "was", "we", "were", "what", "when", "where", "who", "with",
        "would", "you", "your"
    ]

    private static func significantTokens(in text: String) -> Set<String> {
        Set(words(in: text).filter { $0.count > 1 && !stopWords.contains($0) })
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - Content-loss guard

    /// Light keeps nearly every content word; Medium may reword, so its bar is lower.
    static let lightContentRecallThreshold = 0.75
    static let mediumContentRecallThreshold = 0.5
    /// Shorter dictations are left alone: a few dropped fillers would swing the ratio.
    static let minimumContentWordsForLossCheck = 10
    /// A raw sentence with at least this many content words must keep some of them.
    static let minimumSentenceWordsForLossCheck = 3
    static let sentenceRecallThreshold = 0.4

    /// Words cleanup is expected to remove or rewrite: fillers, spoken formatting commands
    /// ("comma", "new line"), and number and currency words that become digits or symbols.
    private static let rewrittenWords: Set<String> = [
        "like", "basically", "literally", "yeah", "okay", "ok", "well", "right", "know", "mean",
        "kind", "sort", "kinda", "sorta", "erm", "hmm", "mm", "ah", "oh", "really", "totally",
        "honestly", "anyway", "not", "will", "am", "don", "doesn", "didn", "won", "isn", "aren",
        "wasn", "weren", "let", "lets", "ll", "ve", "re",
        "comma", "period", "colon", "semicolon", "question", "mark", "exclamation", "point",
        "dash", "hyphen", "underscore", "quote", "unquote", "new", "next", "line", "paragraph",
        "break", "skip", "bullet", "numbered", "list", "em", "full", "stop", "dot", "slash",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth", "firstly", "secondly", "thirdly", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "percent", "dollar", "dollars", "cent", "cents", "zero", "number"
    ]

    /// Explicit self-corrections legitimately delete the abandoned wording, so the guard steps aside.
    /// The cleanup fast path reuses it to send any self-correction to the model.
    static let backtrackMarkerPattern =
        #"(?i)\b(actually|scratch that|strike that|delete that|cancel that|never ?mind|i mean|sorry|wait|or rather|rather|instead|correction|let me rephrase|make that|de fapt|perd[oó]n)\b"#

    /// "no" after punctuation ("Monday. No, Tuesday."), "no no", "I meant" and "oops", which
    /// backtrackMarkerPattern lacks, with the common non-English negations an unaccented
    /// Auto-detect dictation can still carry.
    private static let punctuatedBacktrackMarkerPattern =
        #"(?i)[,.;:!?]\s*(?:no|nu|non|nein|não)\b|\bno,?\s+no\b|\bi meant\b|\b(?:wh)?oops\b"#
    /// The markers above plus "no" anywhere but the start ("tokyo no osaka"). The cleanup fast
    /// path sends any of them to the model; the number guard steps aside for them.
    static let extraBacktrackMarkerPattern =
        punctuatedBacktrackMarkerPattern + #"|(?i)\S\s+(?:no|nu|non|nein|não)\b"#

    /// True when cleanup dropped meaning the speaker never retracted: content-word recall fell below
    /// the level's bar, or, at Light, a whole raw sentence with three or more content words lost most
    /// of them. Skipped for translation and whenever the speaker used an explicit backtrack marker.
    static func appearsToHaveDroppedContent(
        rawTranscript: String,
        cleanedTranscript: String,
        allowsRewording: Bool,
        outputLanguage: String
    ) -> Bool {
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawTranscript.range(of: backtrackMarkerPattern, options: .regularExpression) == nil else {
            return false
        }
        let rawWords = contentWords(in: rawTranscript)
        guard rawWords.count >= minimumContentWordsForLossCheck else { return false }
        let cleanedWords = contentWords(in: cleanedTranscript)
        let recall = Double(rawWords.intersection(cleanedWords).count) / Double(rawWords.count)
        if recall < (allowsRewording ? mediumContentRecallThreshold : lightContentRecallThreshold) {
            return true
        }
        guard !allowsRewording else { return false }
        for sentence in rawTranscript.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            let sentenceWords = contentWords(in: sentence)
            guard sentenceWords.count >= minimumSentenceWordsForLossCheck else { continue }
            let kept = Double(sentenceWords.intersection(cleanedWords).count) / Double(sentenceWords.count)
            if kept < sentenceRecallThreshold { return true }
        }
        return false
    }

    private static func contentWords(in text: String) -> Set<String> {
        Set(words(in: text).filter { $0.count > 1 && !stopWords.contains($0) && !rewrittenWords.contains($0) })
    }

    // MARK: - Negation and number guard

    /// "not", "never", "cannot" and every n't contraction, straight or curly. "no" is left out
    /// because it is also a backtrack marker ("Monday, no, Tuesday").
    private static let negationPattern = try! NSRegularExpression(pattern: #"(?i)\b(?:not|never|cannot)\b|n['’]t\b"#)

    /// A marker word right after a negation is not a self-correction: "can't wait", "don't actually".
    private static let unnegatedBacktrackMarkerPattern =
        #"(?i)(?<!n['’]t\s)(?<!\bnot\s)(?<!\bnever\s)(?<!\bcannot\s)(?:"# + backtrackMarkerPattern + ")"
    /// The negation check skips a bare mid-sentence "no", which is usually a determiner ("there's
    /// no time"); the number check counts it ("room 5 no room 6").
    private static let negationCorrectionMarkers = try! NSRegularExpression(
        pattern: unnegatedBacktrackMarkerPattern + "|" + punctuatedBacktrackMarkerPattern
    )
    private static let numberCorrectionMarkers = try! NSRegularExpression(
        pattern: unnegatedBacktrackMarkerPattern + "|" + extraBacktrackMarkerPattern
    )

    /// True when cleanup removed a negation or lost a number the speaker never retracted. "do not"
    /// -> "don't", "five" -> "5", "2 thousand" -> "2,000" and "is not empty" -> "isNotEmpty" pass;
    /// an added negation or digit is not checked. A stutter ("we can't, we can't") counts once,
    /// and after a self-correction marker only the wording after the last one is the speaker's
    /// final version. Skipped for translation.
    static func appearsToHaveChangedNegationOrNumber(
        rawTranscript: String,
        cleanedTranscript: String,
        outputLanguage: String
    ) -> Bool {
        guard outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let spoken = withoutRepeatedPhrases(splittingIdentifiers(rawTranscript).lowercased())
        let cleaned = splittingIdentifiers(cleanedTranscript)
        if negationCount(in: cleaned) < negationCount(in: finalVersion(of: spoken, after: negationCorrectionMarkers)) {
            return true
        }
        let spokenDigits = digits(in: withoutRestatedNumbers(finalVersion(of: spoken, after: numberCorrectionMarkers)))
        return !isSubsequence(spokenDigits, of: digits(in: withNumberWordsAsDigits(cleaned)))
    }

    private static func negationCount(in text: String) -> Int {
        negationPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// "is_not_empty" and "isNotEmpty" read as the words the Developer syntax rule joined.
    private static func splittingIdentifiers(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?<=\p{Ll})(?=\p{Lu})"#, with: " ", options: .regularExpression)
    }

    /// A stutter or duplicate start of one to four words, which cleanup removes, counts once:
    /// "i don't, i don't think" -> "i don't think". Lowercased input: backreferences are case-sensitive.
    private static func withoutRepeatedPhrases(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\b([\w'’]+(?:\s+[\w'’]+){0,3})(?:[\s,;:.\-–—]+\1\b)+"#,
            with: "$1",
            options: .regularExpression
        )
    }

    /// Marker words that are often filler: with no wording after them they correct nothing ("we
    /// can't ship it actually"), unlike a final "scratch that", which retracts everything.
    private static let fillerMarkers: Set<String> = ["actually", "i mean", "sorry", "wait", "rather", "instead"]

    /// The wording after the last self-correction marker, or all of it when there is none.
    private static func finalVersion(of text: String, after markers: NSRegularExpression) -> String {
        let nsText = text as NSString
        for match in markers.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let rest = nsText.substring(from: NSMaxRange(match.range))
            if rest.contains(where: { $0.isLetter || $0.isNumber })
                || !fillerMarkers.contains(nsText.substring(with: match.range)) {
                return rest
            }
        }
        return text
    }

    /// A number restated in the same slot without a marker ("at 2, 3", "2 or 3", "at 2, at 3")
    /// is the abandoned one, as the prompt's restatement rule says.
    private static func withoutRestatedNumbers(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[0-9]+(?=(?:\s*,\s+|(?:\s*,)?\s+(?:no|or),?\s+)(?:[a-z]+\s+)?[0-9])"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static let numberWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty"
    ]

    /// A digit the cleanup wrote as a word ("use two spaces") still counts.
    private static func withNumberWordsAsDigits(_ text: String) -> String {
        numberWords.enumerated().reduce(text) { text, entry in
            text.replacingOccurrences(
                of: "\\b\(entry.element)\\b",
                with: String(entry.offset),
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    /// ASCII digits in order, so regrouping ("5 5 5 1 2 3 4" -> "555-1234", "230" -> "2:30",
    /// "1,000" -> "1000") keeps them. Snippet placeholders (⟦S1⟧) are skipped because
    /// SnippetExpansionPlan.resolve reports a dropped one.
    private static func digits(in text: String) -> String {
        text.replacingOccurrences(of: "\u{27E6}[^\u{27E7}]*\u{27E7}", with: " ", options: .regularExpression)
            .filter { $0.isASCII && $0.isNumber }
    }

    /// Every raw digit appears in the cleaned text in the same order; extra cleaned digits
    /// ("2 thousand" -> "2,000", a numbered list) are allowed.
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
        }
        return remaining.isEmpty
    }
}
