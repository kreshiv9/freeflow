import Foundation

/// Replaces secret-shaped spans (provider keys, tokens, passwords in assignments, private
/// key blocks, long random strings) with `placeholder` before screen text reaches any
/// consumer: the cleanup CONTEXT block, the Run Log, identifier and name extraction, and
/// Deepgram keyterms. Rules follow the gitleaks defaults. Pure: no logging, no I/O.
enum SecretFilter {
    static let placeholder = "[secret]"

    /// `-----BEGIN … PRIVATE KEY-----` up to its END line, or to the end of the text when
    /// the block is cut off.
    private static let privateKeyBlockPattern = try! NSRegularExpression(
        pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#
    )
    /// The mirror, for a text that starts inside a key block whose BEGIN line was not read:
    /// from the start up to the last END line. Runs after `privateKeyBlockPattern`, which
    /// leaves no BEGIN line behind.
    private static let privateKeyTailPattern = try! NSRegularExpression(
        pattern: #"\A[\s\S]*-----END [A-Z ]*PRIVATE KEY-----"#
    )
    /// Two or more whole lines of 40 or more base64 characters: a key body read without its
    /// BEGIN and END lines.
    private static let base64LinesPattern = try! NSRegularExpression(
        pattern: #"(?m)^[A-Za-z0-9+/=]{40,}(?:\r?\n[A-Za-z0-9+/=]{40,})+$"#
    )
    /// Known credential prefixes (OpenAI, Anthropic, Groq, GitHub, GitLab, Slack, AWS, Google,
    /// Hugging Face, Stripe, webhook secrets) and JWTs.
    private static let prefixedKeyPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:sk-ant-[A-Za-z0-9_\-]{16,}|sk-(?:proj|svcacct|admin)-[A-Za-z0-9_\-]{16,}|sk-[A-Za-z0-9]{20,}|gsk_[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_\-]{20,}|xox[abposr]-[A-Za-z0-9\-]{10,}|(?:A3T[A-Z0-9]|AKIA|ASIA)[A-Z2-7]{16}|AIza[0-9A-Za-z_\-]{35}|hf_[A-Za-z0-9]{20,}|[rs]k_(?:live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{16,}|ey[A-Za-z0-9_\-]{8,}\.ey[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*)"#
    )
    /// `NAME=value`, `NAME: value` and `"name": "value"` where the name ends, at a separator,
    /// in a secret-like word, so `author`, `tokenizer` and `secretary` are not names. Group 2
    /// is the value; the name is kept. A name starts only where a run of name characters
    /// starts, so each run is scanned from one place only, and the pieces after the
    /// secret-like word are bounded: a long run (an SVG path, a dash rule) costs linear time,
    /// not quadratic. The name has no length cap, so a value after a long glued name
    /// ("<long prefix>_DB_PASSWORD=…") is still found in the first pass.
    private static let assignmentPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<![A-Za-z0-9_.\-])([A-Za-z0-9_.\-]*?(?:secret|token|passw(?:or)?d|pwd|api[_\-]?key|apikey|private[_\-]?key|credentials?|auth|bearer|signature|session[_\-]?id|access[_\-]?key)(?:[_.\-][A-Za-z0-9]+){0,8})(?![A-Za-z0-9])["']?\s*[:=]\s*["']?([^\s"',;}<>]{4,})"#
    )
    /// An Authorization header or a Bearer credential; group 1 is the credential.
    private static let authorizationPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\bauthorization\s*:\s*(?:bearer|basic|token)?|\bbearer)\s+([A-Za-z0-9_\-+/=.]{16,})"#
    )
    /// "basic" or "token" before a credential in prose; group 1 is the credential. The value
    /// needs a digit and no dotted continuation, so code names after the word ("refresh token
    /// DeepgramStreamingCore.normalizedKeyterms", "a basic configurationOptions struct") stay.
    private static let tokenWordPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(?:basic|token)\s+(?=[A-Za-z0-9_\-+/=]*[0-9])([A-Za-z0-9_\-+/=]{16,})(?![A-Za-z0-9_\-+/=]|\.[A-Za-z0-9])"#
    )
    /// API keys and full commit hashes alike (an accepted loss).
    private static let hexRunPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[0-9a-fA-F]{32,}(?![A-Za-z0-9])"#
    )
    /// Candidate unlabeled tokens, kept unless `looksRandom`. No "/", so URL paths survive.
    private static let longTokenPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=]{20,}"#)

    /// Idempotent: a span that is already the placeholder is never replaced again, and the
    /// rules run until the text stops changing, so `redact(redact(x)) == redact(x)`.
    static func redact(_ text: String) -> String {
        var offsets: [Int] = []
        return redact(text, mapping: &offsets)
    }

    /// A guard on the passes over the rules; the loop stops at the first pass that changes
    /// nothing, which is the fixed point. A later pass is needed only when a placeholder
    /// splits a run so that another rule now sees a separate token (two passes on synthetic
    /// fuzzing). The passes always end: a pass that changes the text replaces spans that are
    /// not the placeholder, and no replaced span starts or ends inside a placeholder, so each
    /// change either removes characters outside placeholders or merges whole placeholders.
    private static let maxPasses = 8

    /// `redact`, also moving UTF-16 `offsets` in `text` to the same places in the result. An
    /// offset inside a redacted span moves to the end of its placeholder, so a secret that the
    /// cursor splits is replaced whole on one side and leaves nothing on the other.
    static func redact(_ text: String, mapping offsets: inout [Int]) -> String {
        var result = text
        for _ in 0..<maxPasses {
            let next = redactOnce(result, mapping: &offsets)
            if next == result { break }
            result = next
        }
        return result
    }

    private static func redactOnce(_ text: String, mapping offsets: inout [Int]) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = replace(privateKeyBlockPattern, in: result, group: 0, offsets: &offsets)
        result = replace(privateKeyTailPattern, in: result, group: 0, offsets: &offsets)
        result = replace(base64LinesPattern, in: result, group: 0, offsets: &offsets)
        result = replace(prefixedKeyPattern, in: result, group: 0, offsets: &offsets)
        result = replace(assignmentPattern, in: result, group: 2, offsets: &offsets)
        result = replace(authorizationPattern, in: result, group: 1, offsets: &offsets)
        result = replace(tokenWordPattern, in: result, group: 1, offsets: &offsets)
        result = replace(hexRunPattern, in: result, group: 0, offsets: &offsets)
        result = replace(longTokenPattern, in: result, group: 0, offsets: &offsets, when: looksRandom)
        return result
    }

    /// True for a single token that must never leave the Mac as a keyterm: one that
    /// `redact` would change, or one with more than six digits (phone, account and card
    /// numbers).
    static func isSecretLike(_ token: String) -> Bool {
        if redact(token) != token { return true }
        return token.filter(\.isNumber).count > 6
    }

    /// At least 20 characters with a digit and a letter, not shaped like a code name, and
    /// either Shannon entropy of 3.5 bits per character or three or more letter/digit
    /// switches. Plain identifiers, which have no digits, never qualify.
    private static func looksRandom(_ token: String) -> Bool {
        guard token.count >= 20, token.contains(where: \.isNumber), token.contains(where: \.isLetter) else {
            return false
        }
        let characters = Array(token)
        var switches = 0
        for index in characters.indices.dropFirst() {
            let previous = characters[index - 1]
            let current = characters[index]
            if (previous.isLetter && current.isNumber) || (previous.isNumber && current.isLetter) {
                switches += 1
            }
        }
        guard switches >= 3 || !isCodeName(characters) else { return false }
        return entropy(of: token) >= 3.5 || switches >= 3
    }

    /// A code name with a few digits (kAudioFormatLinearPCM16, utf8EncodedDataLength): ASCII
    /// letters, digits and underscores, a lowercase letter, at most four digits, and letter
    /// parts (split at "_", digits and camelCase humps) of three or more letters on average.
    /// Generated tokens break into much shorter parts. The caller checks the switches.
    private static func isCodeName(_ characters: [Character]) -> Bool {
        guard characters.contains(where: \.isLowercase),
              characters.filter(\.isNumber).count <= 4,
              characters.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else {
            return false
        }
        var parts: [Int] = []
        var current = 0
        for index in characters.indices {
            let character = characters[index]
            guard character.isLetter else {
                if current > 0 { parts.append(current) }
                current = 0
                continue
            }
            if current > 0 {
                let previous = characters[index - 1]
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                if (previous.isLowercase && character.isUppercase)
                    || (previous.isUppercase && character.isUppercase && next?.isLowercase == true) {
                    parts.append(current)
                    current = 0
                }
            }
            current += 1
        }
        if current > 0 { parts.append(current) }
        guard !parts.isEmpty else { return false }
        return Double(parts.reduce(0, +)) / Double(parts.count) >= 3
    }

    private static func entropy(of text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let length = Double(text.count)
        return counts.values.reduce(0) { total, count in
            let probability = Double(count) / length
            return total - probability * log2(probability)
        }
    }

    /// Replaces each match's `group` with the placeholder, last match first so earlier
    /// ranges stay valid; skips spans that are already the placeholder or fail `predicate`.
    /// Moves `offsets` past each replacement; one inside a span goes to its placeholder's end.
    private static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        group: Int,
        offsets: inout [Int],
        when predicate: ((String) -> Bool)? = nil
    ) -> String {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: text)
        let placeholderLength = (placeholder as NSString).length
        for match in matches.reversed() {
            let range = match.range(at: group)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let span = nsText.substring(with: range)
            if span == placeholder { continue }
            if let predicate, !predicate(span) { continue }
            result.replaceCharacters(in: range, with: placeholder)
            for index in offsets.indices {
                if offsets[index] >= NSMaxRange(range) {
                    offsets[index] += placeholderLength - range.length
                } else if offsets[index] > range.location {
                    offsets[index] = range.location + placeholderLength
                }
            }
        }
        return result as String
    }
}
