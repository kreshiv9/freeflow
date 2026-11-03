import Accelerate
import Foundation

/// Pure rules for the developer replay tool (Tools/AudioReplay): transcript
/// scoring, keyterm and word-timing metrics, variant and manifest parsing,
/// pacing, level statistics and paired comparisons. No I/O and no logging.
/// Nothing it produces for results.csv carries transcript text or the key.
/// Compiled into the test runner; never part of the app.
enum ReplayEvalCore {
    // MARK: Text scoring

    /// Lowercased words: letters and digits form tokens; an apostrophe (', ’ or ʼ)
    /// is kept as ' only between two letters or digits; everything else separates.
    static func normalizedWords(_ text: String) -> [String] {
        let characters = Array(text.lowercased())
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            if isWordCharacter(character) {
                current.append(character)
                continue
            }
            if apostrophes.contains(character), !current.isEmpty,
               index + 1 < characters.count, isWordCharacter(characters[index + 1]) {
                current.append("'")
                continue
            }
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Whitespace-separated tokens with case and punctuation kept, for formatted WER.
    static func formattedWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}"]

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    struct Alignment: Equatable {
        var referenceWords = 0
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var firstWordDeleted = false
        var lastWordDeleted = false

        var errors: Int { substitutions + deletions + insertions }
        /// nil when the reference is empty.
        var wordErrorRate: Double? {
            referenceWords > 0 ? Double(errors) / Double(referenceWords) : nil
        }
    }

    /// Levenshtein alignment with unit costs. The backtrace runs from the end and
    /// prefers, on ties, the diagonal (match or substitution), then a deletion,
    /// then an insertion. The first/last-word flags do not depend on that
    /// tie-break: each is set when some optimal alignment deletes that word, so
    /// a clipped start and a clipped end of the same shape are flagged alike.
    static func align(reference: [String], hypothesis: [String]) -> Alignment {
        let n = reference.count
        let m = hypothesis.count
        let width = m + 1
        let cost = editCosts(reference: reference, hypothesis: hypothesis)

        var result = Alignment(referenceWords: n)
        var a = n
        var b = m
        while a > 0 || b > 0 {
            let here = cost[a * width + b]
            if a > 0, b > 0 {
                let mismatch = reference[a - 1] == hypothesis[b - 1] ? 0 : 1
                if here == cost[(a - 1) * width + b - 1] + mismatch {
                    result.substitutions += mismatch
                    a -= 1
                    b -= 1
                    continue
                }
            }
            if a > 0, here == cost[(a - 1) * width + b] + 1 {
                result.deletions += 1
                a -= 1
            } else {
                result.insertions += 1
                b -= 1
            }
        }
        result.lastWordDeleted = n > 0 && cost[(n - 1) * width + m] + 1 == cost[n * width + m]
        if n > 0 {
            // The same test on the reversed sequences asks about the first word.
            let reversed = editCosts(reference: reference.reversed(), hypothesis: hypothesis.reversed())
            result.firstWordDeleted = reversed[(n - 1) * width + m] + 1 == reversed[n * width + m]
        }
        return result
    }

    /// Row-major (reference.count + 1) × (hypothesis.count + 1) edit-distance table.
    private static func editCosts(reference: [String], hypothesis: [String]) -> [Int] {
        let n = reference.count
        let m = hypothesis.count
        let width = m + 1
        var cost = [Int](repeating: 0, count: (n + 1) * width)
        for a in 0...n { cost[a * width] = a }
        for b in 0...m { cost[b] = b }
        if n > 0, m > 0 {
            for a in 1...n {
                for b in 1...m {
                    let diagonal = cost[(a - 1) * width + b - 1] + (reference[a - 1] == hypothesis[b - 1] ? 0 : 1)
                    cost[a * width + b] = min(diagonal, cost[(a - 1) * width + b] + 1, cost[a * width + b - 1] + 1)
                }
            }
        }
        return cost
    }

    // MARK: Keyterms

    /// Splits on newline, CR, comma and semicolon like the app's vocabulary field,
    /// collapses internal whitespace, drops empties and dedupes case-insensitively
    /// in order. Unlike the app, applies no count or length cap.
    static func keytermList(fromText text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.components(separatedBy: CharacterSet(charactersIn: "\n\r,;")) {
            let collapsed = piece.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty, seen.insert(collapsed.lowercased()).inserted else { continue }
            result.append(collapsed)
        }
        return result
    }

    struct KeytermScore: Equatable {
        var expected = 0
        var recalled = 0
        var falseInsertions = 0
    }

    /// Counts non-overlapping occurrences of each keyterm's normalized words in the
    /// reference (r) and hypothesis (h): recalled += min(r, h), expected += r,
    /// falseInsertions += max(0, h - r). Keyterms that normalize alike count once.
    static func keytermScore(keyterms: [String], reference: String, hypothesis: String) -> KeytermScore {
        let referenceWords = normalizedWords(reference)
        let hypothesisWords = normalizedWords(hypothesis)
        var seen = Set<[String]>()
        var score = KeytermScore()
        for keyterm in keyterms {
            let tokens = normalizedWords(keyterm)
            guard !tokens.isEmpty, seen.insert(tokens).inserted else { continue }
            let inReference = occurrences(of: tokens, in: referenceWords)
            let inHypothesis = occurrences(of: tokens, in: hypothesisWords)
            score.expected += inReference
            score.recalled += min(inReference, inHypothesis)
            score.falseInsertions += max(0, inHypothesis - inReference)
        }
        return score
    }

    private static func occurrences(of needle: [String], in words: [String]) -> Int {
        guard !needle.isEmpty, needle.count <= words.count else { return 0 }
        var count = 0
        var index = 0
        while index + needle.count <= words.count {
            if words[index..<(index + needle.count)].elementsEqual(needle) {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }

    // MARK: Deepgram results

    struct WordTiming: Equatable {
        var start: Double
        var end: Double
    }

    /// channel.alternatives[0].words[].start/end of a Results frame. Words without
    /// numeric times are skipped; anything else malformed gives [].
    static func wordTimings(fromResultsJSON data: Data) -> [WordTiming] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channel = object["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let words = alternatives.first?["words"] as? [[String: Any]] else { return [] }
        return words.compactMap { word in
            guard let start = word["start"] as? Double, let end = word["end"] as? Double else { return nil }
            return WordTiming(start: start, end: end)
        }
    }

    /// Finals whose first word starts strictly before the previous non-empty
    /// final's last word ends: words Deepgram may have emitted twice.
    static func overlapCount(finals: [[WordTiming]]) -> Int {
        var count = 0
        var previousEnd: Double?
        for final in finals {
            guard let first = final.first, let last = final.last else { continue }
            if let previousEnd, first.start < previousEnd { count += 1 }
            previousEnd = last.end
        }
        return count
    }

    // MARK: Variants

    enum Resampler: String, CaseIterable {
        /// MinimumPhase at max quality (PR 1's converter).
        case minimumPhase = "minphase"
        case masteringHigh = "mastering-high"
        case masteringMax = "mastering-max"
        /// An untouched AVAudioConverter (Normal, medium quality).
        case normal = "default"
        /// Today's stream: untouched conversion to 16 kHz, then untouched 16 -> 24 kHz.
        case legacyChain = "legacy-chain"
    }

    enum Pacing: String, CaseIterable {
        case realtime
        case faster = "1.25x"
        case burst

        /// Wall-clock seconds spent sending one second of audio.
        var wallTimeFactor: Double {
            switch self {
            case .realtime: 1
            case .faster: 1 / 1.25
            case .burst: 0
            }
        }
    }

    enum KeytermSelection: Equatable {
        case none
        case all
        case top(Int)

        /// The keyterms a variant sends, taken in manifest order.
        func select(from keyterms: [String]) -> [String] {
            switch self {
            case .none: []
            case .all: keyterms
            case .top(let count): Array(keyterms.prefix(count))
            }
        }
    }

    enum Isolation: Equatable {
        case off
        case highQualityVoice(wetPercent: Int)
        case voice(wetPercent: Int)

        var spec: String {
            switch self {
            case .off: "off"
            case .highQualityVoice(let wetPercent): "hq\(wetPercent)"
            case .voice(let wetPercent): "voice\(wetPercent)"
            }
        }
    }

    /// One listen-URL query item. A nil value removes the item from the URL.
    struct QueryItem: Equatable {
        var name: String
        var value: String?
    }

    /// The tool's defaults: PR 2's request plus explicit formatting flags.
    static let defaultQuery = [
        QueryItem(name: "language", value: "en"),
        QueryItem(name: "endpointing", value: "500"),
        QueryItem(name: "mip_opt_out", value: "true"),
        QueryItem(name: "smart_format", value: "true"),
        QueryItem(name: "punctuate", value: "true"),
        QueryItem(name: "interim_results", value: "true"),
    ]

    struct Variant: Equatable {
        var name: String
        var sampleRate = 16000
        var resampler = Resampler.minimumPhase
        var query = ReplayEvalCore.defaultQuery
        var keyterms = KeytermSelection.none
        var frameMilliseconds = 50
        var pacing = Pacing.realtime
        var isolation = Isolation.off
        var gainDecibels = 0.0

        /// Cache key for prepared audio: variants that differ only in Deepgram
        /// parameters, frames or pacing share the same samples.
        var audioKey: String {
            "\(sampleRate)|\(resampler.rawValue)|\(isolation.spec)|\(gainDecibels)"
        }
    }

    enum ParseError: Error, Equatable, CustomStringConvertible {
        case noVariants
        case invalidName(line: Int)
        case duplicateName(line: Int)
        /// Carries no text from the field: the file may not be a variants file at all.
        case missingEquals(line: Int)
        /// The key is cut to its first 20 characters.
        case unknownKey(line: Int, key: String)
        case duplicateKey(line: Int, key: String)
        case invalidValue(line: Int, key: String)
        case inconsistent(line: Int, reason: String)
        case emptyManifest
        case badManifestLine(line: Int)

        var description: String {
            switch self {
            case .noVariants:
                "no variants found"
            case .invalidName(let line):
                "line \(line): a variant name is 1-40 characters from A-Z a-z 0-9 . _ -"
            case .duplicateName(let line):
                "line \(line): this variant name is already used"
            case .missingEquals(let line):
                "line \(line): expected key=value after the variant name"
            case .unknownKey(let line, let key):
                "line \(line): unknown key \(key)"
            case .duplicateKey(let line, let key):
                "line \(line): \(key) is set twice"
            case .invalidValue(let line, let key):
                "line \(line): invalid \(key); allowed: \(ReplayEvalCore.allowedValues[key] ?? "see variants.example.txt")"
            case .inconsistent(let line, let reason):
                "line \(line): \(reason)"
            case .emptyManifest:
                "the manifest has no entries"
            case .badManifestLine(let line):
                "manifest line \(line): expected audio<TAB>reference[<TAB>keyterms]"
            }
        }
    }

    static let allowedRates: Set<Int> = [8000, 16000, 22050, 24000, 32000, 44100, 48000]
    private static let booleanQueryKeys: Set<String> = ["mip_opt_out", "smart_format", "punctuate", "interim_results"]
    private static let knownKeys: Set<String> = [
        "rate", "src", "endpointing", "language", "mip_opt_out", "smart_format", "punctuate",
        "interim_results", "keyterms", "frame_ms", "pacing", "isolation", "gain_db",
    ]

    /// Human-readable allowed values per key, for error messages.
    static let allowedValues: [String: String] = [
        "rate": "8000, 16000, 22050, 24000, 32000, 44100, 48000",
        "src": Resampler.allCases.map(\.rawValue).joined(separator: ", "),
        "endpointing": "1-10000, false, default",
        "language": "a code like en or en-US, or omit",
        "mip_opt_out": "true, false, default",
        "smart_format": "true, false, default",
        "punctuate": "true, false, default",
        "interim_results": "true, false, default",
        "keyterms": "none, all, top-N (N 1-100)",
        "frame_ms": "10-1000",
        "pacing": Pacing.allCases.map(\.rawValue).joined(separator: ", "),
        "isolation": "off, hqN, voiceN (N 0-100)",
        "gain_db": "-40 to 40",
    ]

    /// `name key=value ...`, split on whitespace. Unset keys keep the defaults.
    static func parseVariant(_ line: String, lineNumber: Int = 1) throws -> Variant {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = fields.first, isValidName(name) else {
            throw ParseError.invalidName(line: lineNumber)
        }
        var variant = Variant(name: name)
        var seenKeys = Set<String>()
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else {
                throw ParseError.missingEquals(line: lineNumber)
            }
            let key = String(field[..<equals])
            let value = String(field[field.index(after: equals)...])
            guard knownKeys.contains(key) else {
                throw ParseError.unknownKey(line: lineNumber, key: String(key.prefix(20)))
            }
            guard seenKeys.insert(key).inserted else { throw ParseError.duplicateKey(line: lineNumber, key: key) }
            guard apply(key: key, value: value, to: &variant) else {
                throw ParseError.invalidValue(line: lineNumber, key: key)
            }
        }
        if variant.resampler == .legacyChain, variant.sampleRate != 24000 {
            throw ParseError.inconsistent(line: lineNumber, reason: "src=legacy-chain requires rate=24000")
        }
        return variant
    }

    /// One variant per line; blank lines and lines starting with # are skipped.
    /// Names must be unique. The first variant is the paired baseline.
    static func parseVariants(_ text: String) throws -> [Variant] {
        var variants: [Variant] = []
        var names = Set<String>()
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let variant = try parseVariant(line, lineNumber: index + 1)
            guard names.insert(variant.name).inserted else { throw ParseError.duplicateName(line: index + 1) }
            variants.append(variant)
        }
        guard !variants.isEmpty else { throw ParseError.noVariants }
        return variants
    }

    /// False when the value is not allowed for the key.
    private static func apply(key: String, value: String, to variant: inout Variant) -> Bool {
        switch key {
        case "rate":
            guard let rate = boundedInteger(value, 1...48000), allowedRates.contains(rate) else { return false }
            variant.sampleRate = rate
        case "src":
            guard let resampler = Resampler(rawValue: value) else { return false }
            variant.resampler = resampler
        case "endpointing":
            switch value {
            case "default", "omit": setQuery("endpointing", nil, in: &variant)
            case "false": setQuery("endpointing", "false", in: &variant)
            default:
                guard let milliseconds = boundedInteger(value, 1...10000) else { return false }
                setQuery("endpointing", String(milliseconds), in: &variant)
            }
        case "language":
            switch value {
            case "default", "omit": setQuery("language", nil, in: &variant)
            default:
                guard isValidLanguage(value) else { return false }
                setQuery("language", value, in: &variant)
            }
        case _ where booleanQueryKeys.contains(key):
            switch value {
            case "default", "omit": setQuery(key, nil, in: &variant)
            case "true", "false": setQuery(key, value, in: &variant)
            default: return false
            }
        case "keyterms":
            switch value {
            case "none": variant.keyterms = .none
            case "all": variant.keyterms = .all
            default:
                guard value.hasPrefix("top-"), let count = boundedInteger(String(value.dropFirst(4)), 1...100) else {
                    return false
                }
                variant.keyterms = .top(count)
            }
        case "frame_ms":
            guard let milliseconds = boundedInteger(value, 10...1000) else { return false }
            variant.frameMilliseconds = milliseconds
        case "pacing":
            guard let pacing = Pacing(rawValue: value) else { return false }
            variant.pacing = pacing
        case "isolation":
            if value == "off" {
                variant.isolation = .off
            } else if value.hasPrefix("hq"), let wet = boundedInteger(String(value.dropFirst(2)), 0...100) {
                variant.isolation = .highQualityVoice(wetPercent: wet)
            } else if value.hasPrefix("voice"), let wet = boundedInteger(String(value.dropFirst(5)), 0...100) {
                variant.isolation = .voice(wetPercent: wet)
            } else {
                return false
            }
        case "gain_db":
            guard !value.isEmpty, value.allSatisfy({ "0123456789.+-".contains($0) }),
                  let decibels = Double(value), decibels.isFinite, (-40...40).contains(decibels) else { return false }
            variant.gainDecibels = decibels
        default:
            return false
        }
        return true
    }

    private static func setQuery(_ name: String, _ value: String?, in variant: inout Variant) {
        if let index = variant.query.firstIndex(where: { $0.name == name }) {
            variant.query[index].value = value
        } else {
            variant.query.append(QueryItem(name: name, value: value))
        }
    }

    /// ASCII digits only (no sign), within the range.
    private static func boundedInteger(_ text: String, _ range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    private static func isValidName(_ name: String) -> Bool {
        (1...40).contains(name.count) && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }

    /// ^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$, which admits en, en-US and multi.
    private static func isValidLanguage(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first, (2...8).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    // MARK: Presets

    /// Each preset isolates one variable; its first variant is the paired baseline
    /// (today's app behavior where known).
    static let presetNames = ["rate", "src", "endpointing", "keyterms", "language", "isolation", "frames", "determinism"]

    private static let presets: [String: String] = [
        "rate": """
            legacy24 rate=24000 src=legacy-chain
            dg16-minphase rate=16000 src=minphase
            dg16-mastering rate=16000 src=mastering-high
            dg48-native rate=48000 src=minphase
            """,
        "src": """
            src-default src=default
            src-minphase src=minphase
            src-mastering-high src=mastering-high
            """,
        "endpointing": """
            ep10 endpointing=10
            ep300 endpointing=300
            ep500 endpointing=500
            ep1000 endpointing=1000
            ep-false endpointing=false
            """,
        "keyterms": """
            kt-all keyterms=all
            kt-top20 keyterms=top-20
            kt-none keyterms=none
            """,
        "language": """
            lang-omit language=omit
            lang-en language=en
            lang-en-US language=en-US
            lang-multi language=multi
            """,
        "isolation": """
            iso-off isolation=off
            iso-hq70 isolation=hq70
            iso-hq100 isolation=hq100
            """,
        "frames": """
            f50 frame_ms=50
            f20 frame_ms=20
            f100 frame_ms=100
            f250 frame_ms=250
            f50-1.25x frame_ms=50 pacing=1.25x
            f50-burst frame_ms=50 pacing=burst
            """,
        "determinism": """
            same-1
            same-2
            same-3
            """,
    ]

    /// The variants text of a preset, or nil for an unknown name.
    static func preset(named name: String) -> String? {
        presets[name]
    }

    // MARK: Query and streaming

    /// Removes every percent-encoded pair whose name is overridden, then appends
    /// the overrides that have a value, in order. Existing items are never re-encoded.
    static func overridingQuery(of url: URL, with overrides: [QueryItem]) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let overridden = Set(overrides.map { percentEncoded($0.name) })
        var pairs = (components.percentEncodedQuery ?? "")
            .split(separator: "&")
            .map(String.init)
            .filter { pair in
                let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return !overridden.contains(String(name))
            }
        pairs += overrides.compactMap { item in
            item.value.map { "\(percentEncoded(item.name))=\(percentEncoded($0))" }
        }
        components.percentEncodedQuery = pairs.isEmpty ? nil : pairs.joined(separator: "&")
        return components.url ?? url
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    /// Send time of each frame relative to the first: k·F for realtime,
    /// k·F/1.25 for 1.25x, 0 for burst.
    static func sendOffsetsMilliseconds(frameCount: Int, frameMilliseconds: Int, pacing: Pacing) -> [Double] {
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { index in
            let realtime = Double(index * frameMilliseconds)
            switch pacing {
            case .realtime: return realtime
            case .faster: return realtime / 1.25
            case .burst: return 0
            }
        }
    }

    static func littleEndianData(_ samples: [Int16]) -> Data {
        samples.map(\.littleEndian).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Slices PCM16 bytes into frames of (rate·ms/1000)·2 bytes. The last partial
    /// frame is kept; an empty frame (which closes a Deepgram stream) never is.
    static func frames(of pcm: Data, sampleRate: Int, frameMilliseconds: Int) -> [Data] {
        let frameBytes = max(1, sampleRate * frameMilliseconds / 1000) * MemoryLayout<Int16>.size
        var result: [Data] = []
        var start = pcm.startIndex
        while start < pcm.endIndex {
            let end = min(start + frameBytes, pcm.endIndex)
            result.append(pcm.subdata(in: start..<end))
            start = end
        }
        return result
    }

    /// Nova-3 streaming pay-as-you-go list price per minute; an estimate that may be stale.
    static let defaultPricePerMinuteUSD = 0.0077

    static func estimatedCostUSD(
        audioSeconds: Double,
        variants: Int,
        repeats: Int,
        pricePerMinute: Double = defaultPricePerMinuteUSD
    ) -> Double {
        audioSeconds / 60 * Double(variants * repeats) * pricePerMinute
    }

    // MARK: Level statistics

    struct LevelStats: Equatable {
        var peakDBFS: Double
        /// RMS over active 50 ms frames; nil when no frame is active.
        var activeRMSDBFS: Double?
        /// Share of samples in active frames.
        var activeFraction: Double
        /// Shares of spectral energy strictly above each cutoff, over active blocks.
        var energyAbove4kHz: Double
        var energyAbove7kHz: Double
        var energyAbove8kHz: Double
    }

    /// Frames and blocks quieter than this are treated as silence.
    static let activityThresholdDBFS = -50.0

    static func dbfs(_ linear: Double) -> Double {
        20 * log10(max(linear, 1e-12))
    }

    static func levelStats(_ samples: [Float], sampleRate: Double) -> LevelStats {
        var peak: Float = 0
        if !samples.isEmpty {
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        }
        let active = activeLevel(samples, sampleRate: sampleRate)
        let shares = energyShares(samples, sampleRate: sampleRate, above: [4000, 7000, 8000])
        return LevelStats(
            peakDBFS: dbfs(Double(peak)),
            activeRMSDBFS: active.rmsDBFS,
            activeFraction: active.fraction,
            energyAbove4kHz: shares[0],
            energyAbove7kHz: shares[1],
            energyAbove8kHz: shares[2]
        )
    }

    private static func activeLevel(_ samples: [Float], sampleRate: Double) -> (rmsDBFS: Double?, fraction: Double) {
        guard !samples.isEmpty else { return (nil, 0) }
        let frameLength = max(1, Int(sampleRate * 0.05))
        let threshold = pow(10, activityThresholdDBFS / 20)
        var sumOfSquares = 0.0
        var activeSamples = 0
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var start = 0
            while start < samples.count {
                let count = min(frameLength, samples.count - start)
                var meanSquare: Float = 0
                vDSP_measqv(base + start, 1, &meanSquare, vDSP_Length(count))
                if Double(meanSquare).squareRoot() > threshold {
                    sumOfSquares += Double(meanSquare) * Double(count)
                    activeSamples += count
                }
                start += count
            }
        }
        guard activeSamples > 0 else { return (nil, 0) }
        return (dbfs((sumOfSquares / Double(activeSamples)).squareRoot()), Double(activeSamples) / Double(samples.count))
    }

    /// 2048-point Hann-windowed DFT blocks above the activity threshold; bins
    /// strictly above each cutoff, so a 16 kHz file has 0 above 8 kHz.
    private static func energyShares(_ samples: [Float], sampleRate: Double, above cutoffs: [Double]) -> [Double] {
        let size = 2048
        let half = size / 2
        let zeros = cutoffs.map { _ in 0.0 }
        guard samples.count >= size,
              let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else { return zeros }
        defer { vDSP_DFT_DestroySetup(setup) }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        let threshold = pow(10, activityThresholdDBFS / 20)
        var power = [Double](repeating: 0, count: half + 1)
        var inputReal = [Float](repeating: 0, count: half)
        var inputImaginary = [Float](repeating: 0, count: half)
        var outputReal = [Float](repeating: 0, count: half)
        var outputImaginary = [Float](repeating: 0, count: half)
        var blocks = 0
        var start = 0
        while start + size <= samples.count {
            var meanSquare: Float = 0
            samples.withUnsafeBufferPointer { pointer in
                vDSP_measqv(pointer.baseAddress! + start, 1, &meanSquare, vDSP_Length(size))
            }
            if Double(meanSquare).squareRoot() > threshold {
                // zrop takes the real block packed as even/odd pairs.
                for index in 0..<half {
                    inputReal[index] = samples[start + 2 * index] * window[2 * index]
                    inputImaginary[index] = samples[start + 2 * index + 1] * window[2 * index + 1]
                }
                vDSP_DFT_Execute(setup, inputReal, inputImaginary, &outputReal, &outputImaginary)
                // outputReal[0] is DC and outputImaginary[0] is Nyquist; the other
                // bins stand for both signs of frequency, so they count twice.
                power[0] += Double(outputReal[0] * outputReal[0])
                power[half] += Double(outputImaginary[0] * outputImaginary[0])
                for bin in 1..<half {
                    power[bin] += 2 * Double(outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin])
                }
                blocks += 1
            }
            start += size
        }
        let total = power.reduce(0, +)
        guard blocks > 0, total > 0 else { return zeros }
        return cutoffs.map { cutoff in
            var above = 0.0
            for bin in 0...half where Double(bin) * sampleRate / Double(size) > cutoff {
                above += power[bin]
            }
            return above / total
        }
    }

    /// Soft-limiter knee and ceiling for positive gain.
    static let limiterKneeLinear = pow(10, -6.0 / 20)
    static let limiterCeilingLinear = pow(10, -1.0 / 20)

    /// 0 dB returns the input unchanged; any other gain only scales, so a boost
    /// can exceed full scale until softLimited runs.
    static func scaled(_ samples: [Float], decibels: Double) -> [Float] {
        guard decibels != 0 else { return samples }
        let gain = Float(pow(10, decibels / 20))
        return samples.map { $0 * gain }
    }

    /// The gain step. When isolation follows, it runs at 48 kHz directly before
    /// AUSoundIsolation and also soft-limits a boost, so the effect never gets
    /// input above -1 dBFS (the app's capture is bounded at 0 dBFS); otherwise
    /// it only scales, before resampling. The limit after resampling runs either way.
    static func gained(_ samples: [Float], decibels: Double, isolationFollows: Bool) -> [Float] {
        let boosted = scaled(samples, decibels: decibels)
        return isolationFollows && decibels > 0 ? softLimited(boosted) : boosted
    }

    /// Unchanged up to -6 dBFS; above, tanh compresses toward -1 dBFS, which the
    /// output never exceeds. Memoryless: it must run after the last resampling,
    /// because a converter's ringing can push limited peaks past the ceiling.
    static func softLimited(_ samples: [Float]) -> [Float] {
        let knee = Float(limiterKneeLinear)
        let ceiling = Float(limiterCeilingLinear)
        return samples.map { sample in
            let magnitude = abs(sample)
            guard magnitude > knee else { return sample }
            let limited = knee + (ceiling - knee) * tanh((magnitude - knee) / (ceiling - knee))
            return sample < 0 ? -limited : limited
        }
    }

    // MARK: Offline alignment

    /// The candidate offset at which output[offset..<offset + input.count] best
    /// matches the input by normalized correlation, or nil when none matches
    /// clearly: the best must reach minimumCorrelation and beat every other
    /// candidate by minimumMargin. A silent input, or a candidate whose window
    /// does not fit in the output, never matches.
    static func bestAlignmentOffset(
        output: [Float],
        input: [Float],
        candidates: [Int],
        minimumCorrelation: Double = 0.2,
        minimumMargin: Double = 0.1
    ) -> Int? {
        guard !input.isEmpty else { return nil }
        let length = vDSP_Length(input.count)
        var inputEnergy: Float = 0
        vDSP_svesq(input, 1, &inputEnergy, length)
        guard inputEnergy > 0 else { return nil }
        let scored: [(offset: Int, correlation: Double)] = candidates.map { offset in
            guard offset >= 0, offset + input.count <= output.count else { return (offset, -1) }
            var product: Float = 0
            var energy: Float = 0
            output.withUnsafeBufferPointer { pointer in
                let window = pointer.baseAddress! + offset
                vDSP_dotpr(window, 1, input, 1, &product, length)
                vDSP_svesq(window, 1, &energy, length)
            }
            guard energy > 0 else { return (offset, 0) }
            return (offset, Double(product) / (Double(energy) * Double(inputEnergy)).squareRoot())
        }
        guard let best = scored.max(by: { $0.correlation < $1.correlation }),
              best.correlation >= minimumCorrelation else { return nil }
        let clear = scored.allSatisfy { $0.offset == best.offset || best.correlation - $0.correlation >= minimumMargin }
        return clear ? best.offset : nil
    }

    // MARK: Comparisons

    /// Two-sided sign test: min(1, 2·Σ_{i≤min(w,l)} C(n,i)/2^n), in log space. n = 0 gives 1.
    static func signTestPValue(wins: Int, losses: Int) -> Double {
        let n = max(0, wins) + max(0, losses)
        guard n > 0 else { return 1 }
        let smaller = min(max(0, wins), max(0, losses))
        let logTotal = Double(n) * log(2.0)
        var tail = 0.0
        for index in 0...smaller {
            tail += exp(lgamma(Double(n + 1)) - lgamma(Double(index + 1)) - lgamma(Double(n - index + 1)) - logTotal)
        }
        return min(1, 2 * tail)
    }

    struct PairedComparison: Equatable {
        var files: Int
        /// Files where the candidate made fewer errors than the baseline.
        var wins: Int
        var losses: Int
        var ties: Int
        /// Mean of candidate - baseline WER; negative is better.
        var meanDelta: Double
        var pValue: Double
    }

    /// Items present in both maps only; |delta| < 1e-9 is a tie.
    static func pairedComparison(baseline: [Int: Double], candidate: [Int: Double]) -> PairedComparison {
        var wins = 0
        var losses = 0
        var ties = 0
        var sum = 0.0
        for item in baseline.keys.sorted() {
            guard let base = baseline[item], let other = candidate[item] else { continue }
            let delta = other - base
            if abs(delta) < 1e-9 {
                ties += 1
            } else if delta < 0 {
                wins += 1
            } else {
                losses += 1
            }
            sum += delta
        }
        let files = wins + losses + ties
        return PairedComparison(
            files: files,
            wins: wins,
            losses: losses,
            ties: ties,
            meanDelta: files > 0 ? sum / Double(files) : 0,
            pValue: signTestPValue(wins: wins, losses: losses)
        )
    }

    /// Nearest-rank percentile; nil for no values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    // MARK: Runs

    enum RunStatus: Equatable {
        case ok
        case connectFailed
        case httpError(Int)
        case serverError
        case sendFailed
        case closedEarly
        case timedOut

        var csvValue: String {
            switch self {
            case .ok: "ok"
            case .connectFailed: "connect_failed"
            case .httpError(let code): "http_\(code)"
            case .serverError: "server_error"
            case .sendFailed: "send_failed"
            case .closedEarly: "closed_early"
            case .timedOut: "timeout"
            }
        }

        /// 401 or 403: the key was refused, so later runs would fail the same way.
        var isAuthenticationFailure: Bool {
            self == .httpError(401) || self == .httpError(403)
        }
    }

    /// One replay's numbers. Holds no transcript, reference or keyterm text.
    struct RunMetrics: Equatable {
        var variant: String
        var item: Int
        var repeatIndex: Int
        var status: RunStatus
        var audioSeconds: Double
        /// Scores are nil unless the run is .ok.
        var normalized: Alignment?
        var formatted: Alignment?
        var keyterms: KeytermScore?
        var resultCount: Int
        var finals: Int
        var overlaps: Int
        var unfinalizedAtEnd: Bool
        var millisecondsToFromFinalize: Double?
        var millisecondsToMetadata: Double?
    }

    /// Scores a run. The texts are used here and never stored in the result.
    static func makeMetrics(
        variant: String,
        item: Int,
        repeatIndex: Int,
        status: RunStatus,
        audioSeconds: Double,
        reference: String,
        hypothesis: String,
        keyterms: [String],
        finals: [[WordTiming]],
        resultCount: Int,
        unfinalizedAtEnd: Bool,
        millisecondsToFromFinalize: Double?,
        millisecondsToMetadata: Double?
    ) -> RunMetrics {
        let scored = status == .ok
        return RunMetrics(
            variant: variant,
            item: item,
            repeatIndex: repeatIndex,
            status: status,
            audioSeconds: audioSeconds,
            normalized: scored
                ? align(reference: normalizedWords(reference), hypothesis: normalizedWords(hypothesis)) : nil,
            formatted: scored
                ? align(reference: formattedWords(reference), hypothesis: formattedWords(hypothesis)) : nil,
            keyterms: scored ? keytermScore(keyterms: keyterms, reference: reference, hypothesis: hypothesis) : nil,
            resultCount: resultCount,
            finals: finals.count,
            overlaps: overlapCount(finals: finals),
            unfinalizedAtEnd: unfinalizedAtEnd,
            millisecondsToFromFinalize: millisecondsToFromFinalize,
            millisecondsToMetadata: millisecondsToMetadata
        )
    }

    static let csvHeader = [
        "variant", "item", "repeat", "status", "audio_seconds", "ref_words", "substitutions", "deletions",
        "insertions", "wer", "formatted_wer", "first_word_deleted", "last_word_deleted", "keyterms_expected",
        "keyterms_recalled", "keyterm_false_insertions", "results", "finals", "overlaps", "unfinalized_at_end",
        "ms_to_from_finalize", "ms_to_metadata",
    ].joined(separator: ",")

    /// Numbers, the validated variant name and the status; empty when unknown.
    static func csvRow(_ metrics: RunMetrics) -> String {
        let normalized = metrics.normalized
        let keyterms = metrics.keyterms
        func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }
        func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "" }
        func rate(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "" }
        func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
        let fields = [
            metrics.variant,
            String(metrics.item),
            String(metrics.repeatIndex),
            metrics.status.csvValue,
            String(format: "%.3f", metrics.audioSeconds),
            integer(normalized?.referenceWords),
            integer(normalized?.substitutions),
            integer(normalized?.deletions),
            integer(normalized?.insertions),
            rate(normalized?.wordErrorRate),
            rate(metrics.formatted?.wordErrorRate),
            flag(normalized?.firstWordDeleted),
            flag(normalized?.lastWordDeleted),
            integer(keyterms?.expected),
            integer(keyterms?.recalled),
            integer(keyterms?.falseInsertions),
            String(metrics.resultCount),
            String(metrics.finals),
            String(metrics.overlaps),
            flag(metrics.unfinalizedAtEnd),
            milliseconds(metrics.millisecondsToFromFinalize),
            milliseconds(metrics.millisecondsToMetadata),
        ]
        return fields.joined(separator: ",")
    }

    /// Per-item WER averaged over repeats, from .ok runs with a WER only.
    static func perItemMeanWER(_ runs: [RunMetrics]) -> [Int: Double] {
        var totals: [Int: (sum: Double, count: Int)] = [:]
        for run in runs where run.status == .ok {
            guard let wer = run.normalized?.wordErrorRate else { continue }
            let current = totals[run.item] ?? (0, 0)
            totals[run.item] = (current.sum + wer, current.count + 1)
        }
        return totals.mapValues { $0.sum / Double($0.count) }
    }

    struct VariantSummary: Equatable {
        /// Distinct items with at least one .ok run.
        var files = 0
        var runs = 0
        var failed = 0
        var referenceWords = 0
        var substitutions = 0
        var deletions = 0
        var insertions = 0
        var firstWordDeletions = 0
        var lastWordDeletions = 0
        var keytermsExpected = 0
        var keytermsRecalled = 0
        var keytermFalseInsertions = 0
        var overlaps = 0
        var unfinalized = 0
        var fromFinalizeP50: Double?
        var fromFinalizeP95: Double?
        var metadataP50: Double?
        var metadataP95: Double?

        /// Micro-averaged: total errors over total reference words.
        var wordErrorRate: Double? {
            referenceWords > 0 ? Double(substitutions + deletions + insertions) / Double(referenceWords) : nil
        }
    }

    /// Totals over .ok runs; failed counts the rest.
    static func summarize(_ runs: [RunMetrics]) -> VariantSummary {
        var summary = VariantSummary()
        var items = Set<Int>()
        var fromFinalize: [Double] = []
        var metadata: [Double] = []
        summary.runs = runs.count
        for run in runs {
            guard run.status == .ok else {
                summary.failed += 1
                continue
            }
            items.insert(run.item)
            if let alignment = run.normalized {
                summary.referenceWords += alignment.referenceWords
                summary.substitutions += alignment.substitutions
                summary.deletions += alignment.deletions
                summary.insertions += alignment.insertions
                summary.firstWordDeletions += alignment.firstWordDeleted ? 1 : 0
                summary.lastWordDeletions += alignment.lastWordDeleted ? 1 : 0
            }
            if let keyterms = run.keyterms {
                summary.keytermsExpected += keyterms.expected
                summary.keytermsRecalled += keyterms.recalled
                summary.keytermFalseInsertions += keyterms.falseInsertions
            }
            summary.overlaps += run.overlaps
            summary.unfinalized += run.unfinalizedAtEnd ? 1 : 0
            if let value = run.millisecondsToFromFinalize { fromFinalize.append(value) }
            if let value = run.millisecondsToMetadata { metadata.append(value) }
        }
        summary.files = items.count
        summary.fromFinalizeP50 = percentile(fromFinalize, 50)
        summary.fromFinalizeP95 = percentile(fromFinalize, 95)
        summary.metadataP50 = percentile(metadata, 50)
        summary.metadataP95 = percentile(metadata, 95)
        return summary
    }

    // MARK: Safety and manifest

    /// Holds the Deepgram key. Prints, interpolates, dumps and mirrors as
    /// <redacted>; `revealed` is read only for the Authorization header.
    struct Secret: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        private let value: String

        /// What a key must look like, for error messages that never show the value.
        static let requirement = "one line of 20-128 ASCII letters, digits, '-', '_' or '.', and nothing else"

        /// Trims surrounding whitespace, then accepts only one key token. Anything
        /// else, such as a second line, a comment or a NAME=value entry, is refused
        /// rather than sent in the Authorization header.
        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (20...128).contains(trimmed.count), trimmed.allSatisfy({ character in
                character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
            }) else { return nil }
            value = trimmed
        }

        var revealed: String { value }
        var description: String { "<redacted>" }
        var debugDescription: String { "<redacted>" }
        var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    /// True when a variant name contains the key, as when the key file is passed
    /// as --variants: a key is a valid name, and names are printed and written.
    static func variantNamesExposeKey(_ names: [String], key: Secret) -> Bool {
        names.contains { $0.contains(key.revealed) }
    }

    /// The nearest directory at or above the standardized URL that has a `.git`
    /// entry (a folder, or a file in a linked worktree), or nil.
    static func gitWorkTreeRoot(containing url: URL, exists: (String) -> Bool) -> URL? {
        var path = url.standardized.path
        while true {
            let candidate = (path as NSString).appendingPathComponent(".git")
            if exists(candidate) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
    }

    struct ManifestEntry: Equatable {
        /// 1-based entry index; results identify files only by this number.
        var item: Int
        var line: Int
        var audio: URL
        var reference: URL
        var keyterms: URL?
    }

    /// `audio<TAB>reference[<TAB>keyterms]` per line; # and blank lines are
    /// skipped. A leading ~/ expands to the home folder; relative paths resolve
    /// against the manifest's folder.
    static func parseManifest(
        _ text: String,
        baseDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = index + 1
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (2...3).contains(columns.count), !columns.contains(where: \.isEmpty) else {
                throw ParseError.badManifestLine(line: lineNumber)
            }
            func resolve(_ path: String) -> URL {
                let expanded: String
                if path.hasPrefix("~/") {
                    expanded = (homeDirectory.path as NSString).appendingPathComponent(String(path.dropFirst(2)))
                } else if path.hasPrefix("/") {
                    expanded = path
                } else {
                    expanded = (baseDirectory.path as NSString).appendingPathComponent(path)
                }
                return URL(fileURLWithPath: expanded, isDirectory: false).standardized
            }
            entries.append(ManifestEntry(
                item: entries.count + 1,
                line: lineNumber,
                audio: resolve(columns[0]),
                reference: resolve(columns[1]),
                keyterms: columns.count == 3 ? resolve(columns[2]) : nil
            ))
        }
        guard !entries.isEmpty else { throw ParseError.emptyManifest }
        return entries
    }
}
