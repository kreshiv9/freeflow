import Foundation

/// Every secret below is invented and assembled by concatenation, so no literal in this file
/// has the shape of a real credential.
enum SecretFilterTests {
    static func run() {
        testKnownPrefixesAreRedacted()
        testAssignmentValuesAreRedactedKeepingKeyNames()
        testBearerPemHexAndRandomTokens()
        testBenignTextIsUnchanged()
        testCodeNamesWithDigitsAreUnchanged()
        testKeyBodiesWithoutBeginLine()
        testOffsetsFollowRedaction()
        testLongRunsRedactQuickly()
        testLongGluedKeyNamesAreRedacted()
        testRedactionIsIdempotent()
        testIsSecretLike()
    }

    /// One fake value per prefix family the filter knows.
    static let prefixedFixtures: [String] = [
        "sk-" + "proj-" + "FAKEfake0000FAKEfake0000",
        "sk-" + "ant-" + "api03-FAKEfakeFAKEfake0123",
        "gs" + "k_" + "FAKEfake1234FAKEfake5678",
        "gh" + "p_" + String(repeating: "FAKEfake", count: 4),
        "github" + "_pat_" + "FAKEfake_FAKEfake_1234",
        "gl" + "pat-" + "FAKEfakeFAKEfake1234",
        "xo" + "xb-" + "1234-FAKEfakeFAKE",
        "AK" + "IA" + "FAKEFAKEFAKEFAKE",
        "AI" + "za" + "Sy" + String(repeating: "FAKEfake", count: 4) + "0",
        "hf" + "_" + "FAKEfakeFAKEfakeFAKE",
        "rk" + "_live_" + "FakeFakeFakeFake",
        "wh" + "sec_" + "FAKEfakeFAKEfake1234",
        "ey" + "JhbGciOiJGQUtFIn0" + ".ey" + "JzdWIiOiJGQUtFIn0" + ".sig" + "FAKE0123",
    ]

    private static let pemBlock = "-----BEGIN " + "PRIVATE KEY-----\n" + "MIIEvQ" + "IBADANFAKEfakeFAKEfake\n"
        + "-----END " + "PRIVATE KEY-----"

    private static func testKnownPrefixesAreRedacted() {
        for fixture in prefixedFixtures {
            let redacted = SecretFilter.redact("key \(fixture) end")
            TestSupport.expect(!redacted.contains(fixture), "A \(fixture.prefix(4))… value must be redacted")
            TestSupport.expect(redacted.contains(SecretFilter.placeholder), "Redaction leaves the placeholder")
            TestSupport.expect(redacted.hasPrefix("key ") && redacted.hasSuffix(" end"), "Surrounding text is kept")
        }
    }

    private static func testAssignmentValuesAreRedactedKeepingKeyNames() {
        let cases: [(String, String)] = [
            ("DB_PASSWORD=" + "CorrectHorse" + "BatteryStaple", "DB_PASSWORD=[secret]"),
            ("export API_TOKEN=" + "FAKEvalue1", "export API_TOKEN=[secret]"),
            ("session_token: " + "FAKEvalueHere", "session_token: [secret]"),
            ("{\"apiKey\": \"" + "FAKEvalue1234" + "\"}", "{\"apiKey\": \"[secret]\"}"),
            ("SECRET_KEY_BASE=" + "FAKEbaseValue", "SECRET_KEY_BASE=[secret]"),
            ("  api_token: " + "FAKEyamlValue", "  api_token: [secret]"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(SecretFilter.redact(input), expected)
        }
    }

    private static func testBearerPemHexAndRandomTokens() {
        let bearerValue = "FAKEbearer" + "Value0123456789"
        let bearer = SecretFilter.redact("Authorization: Bearer " + bearerValue)
        TestSupport.expect(!bearer.contains(bearerValue), "A bearer credential must be redacted")
        TestSupport.expect(bearer.hasPrefix("Authorization: Bearer "), "The header name stays")

        let pem = SecretFilter.redact("before\n" + pemBlock + "\nafter")
        TestSupport.expect(!pem.contains("MIIEvQ"), "A private key block must be redacted")
        TestSupport.expect(pem.hasPrefix("before\n") && pem.hasSuffix("\nafter"), "Text around the block stays")
        let unterminated = SecretFilter.redact("-----BEGIN " + "PRIVATE KEY-----\n" + "MIIEvQ" + "IBADANFAKE")
        TestSupport.expect(!unterminated.contains("MIIEvQ"), "A cut-off key block is redacted to the end")

        let hex = String(repeating: "3f9a1c0b7e", count: 4)
        TestSupport.expectEqual(SecretFilter.redact("hash " + hex), "hash [secret]")

        let random = "AbCdEf" + "123456" + "GhIjKlMn"
        TestSupport.expectEqual(SecretFilter.redact("id " + random + " here"), "id [secret] here")
    }

    private static func testBenignTextIsUnchanged() {
        let benign = "use pipelineHistoryStore and DeepgramStreamingCore.normalizedKeyterms; see "
            + "https://github.com/example/freeflow/pull/18 and commit d78eec4. tokenizer: wordpiece. "
            + "author: Jane Doe. Open AppContextService.swift in Visual Studio Code."
        TestSupport.expectEqual(SecretFilter.redact(benign), benign)
        TestSupport.expectEqual(SecretFilter.redact("the auth flow needs a retry"), "the auth flow needs a retry")
        TestSupport.expectEqual(SecretFilter.redact(""), "")
    }

    /// Code names with a few digits, and code names after "token" or "basic" in prose, are
    /// not credentials.
    private static func testCodeNamesWithDigitsAreUnchanged() {
        for text in [
            "Use kAudioFormatLinearPCM16 and utf8EncodedDataLength",
            "call convertToPCM16Samples with base64EncodedStringOptions",
            "x86_64TargetTriple and UInt8BufferPointerSize",
            "refresh token DeepgramStreamingCore.normalizedKeyterms",
            "a basic configurationOptions struct",
            "pass the token validationMiddleware here",
        ] {
            TestSupport.expectEqual(SecretFilter.redact(text), text)
        }
        let value = "abc123" + "def456" + "ghi789"
        TestSupport.expectEqual(SecretFilter.redact("use token " + value + "."), "use token [secret].")
        TestSupport.expectEqual(SecretFilter.redact("Bearer " + "FAKEbearer" + "Value.part2"), "Bearer [secret]")
    }

    /// A text that starts inside a key block, or holds only its body lines, is redacted too.
    private static func testKeyBodiesWithoutBeginLine() {
        let line = String(repeating: "MIIEvQ" + "FAKEfake0+/", count: 4)
        let endOnly = SecretFilter.redact(line + "\n" + line + "\n-----END " + "PRIVATE KEY-----\nafter")
        TestSupport.expectEqual(endOnly, "[secret]\nafter")
        let bodyOnly = SecretFilter.redact("before\n" + line + "\n" + line + "\n" + line + "\nafter")
        TestSupport.expectEqual(bodyOnly, "before\n[secret]\nafter")
        TestSupport.expectEqual(SecretFilter.redact("before\n" + line + "\nafter"), "before\n" + line + "\nafter")
    }

    /// Offsets inside a redacted span move to the end of its placeholder; others shift with it.
    private static func testOffsetsFollowRedaction() {
        let key = "gh" + "p_" + String(repeating: "FAKEfake", count: 4)
        let text = "a " + key + " b"
        var offsets = [0, 2, 10, 2 + (key as NSString).length, (text as NSString).length]
        let redacted = SecretFilter.redact(text, mapping: &offsets)
        TestSupport.expectEqual(redacted, "a [secret] b")
        TestSupport.expectEqual(offsets, [0, 2, 10, 10, 12])
    }

    /// Long runs of name characters (an inline SVG path, dash rules, URL-safe base64) cost
    /// linear time, not quadratic.
    private static func testLongRunsRedactQuickly() {
        var state: UInt64 = 11
        func next(_ bound: UInt64) -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state >> 33) % bound
        }
        var path = ""
        while path.count < 3_000 {
            path += ["M", "l", "c", "h", "v"][Int(next(5))] + "\(next(40)).\(next(10))-\(next(20)).\(next(10))"
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let base64 = String((0..<4_000).map { _ in alphabet[Int(next(64))] })
        for text in [
            path, String(repeating: "a-", count: 3_000), String(repeating: "-", count: 2_000),
            String(repeating: "x_", count: 3_000), base64,
        ] {
            let started = CFAbsoluteTimeGetCurrent()
            _ = SecretFilter.redact("before " + text + " after")
            TestSupport.expect(CFAbsoluteTimeGetCurrent() - started < 0.25, "A long run must not stall redaction")
        }
    }

    /// A key name glued to a long run of name characters has no length limit: the value after
    /// it is redacted in one call, whether the run is a plain prefix or hex.
    private static func testLongGluedKeyNamesAreRedacted() {
        let value = "CorrectHorse" + "BatteryStaple"
        let longPrefix = String(repeating: "service_", count: 20)
        TestSupport.expect(longPrefix.count > 100, "The fixture's key name must pass the old 100-character limit")
        TestSupport.expectEqual(
            SecretFilter.redact(longPrefix + "DB_PASSWORD=" + value + " end"),
            longPrefix + "DB_PASSWORD=[secret] end"
        )
        let gluedCamelCase = "x" + String(repeating: "y", count: 150) + "Token: " + value
        TestSupport.expectEqual(SecretFilter.redact(gluedCamelCase), String(gluedCamelCase.dropLast(value.count)) + "[secret]")
        TestSupport.expectEqual(SecretFilter.redact(gluedKeyName), "[secret]_PASSWORD=[secret] ")
        // A long run with a secret-like word but no assignment stays as it is.
        let noAssignment = longPrefix + "token_handler.swift"
        TestSupport.expectEqual(SecretFilter.redact(noAssignment), noAssignment)
    }

    private static func testRedactionIsIdempotent() {
        let inputs = prefixedFixtures.map { "key \($0) end" } + [
            "DB_PASSWORD=" + "CorrectHorse" + "BatteryStaple",
            "{\"apiKey\": \"" + "FAKEvalue1234" + "\"}",
            "Authorization: Bearer " + "FAKEbearer" + "Value0123456789",
            pemBlock,
            "hash " + String(repeating: "3f9a1c0b7e", count: 4),
            "id " + "AbCdEf" + "123456" + "GhIjKlMn",
            "plain prose with GPT-5 and useAuth",
            gluedKeyName,
            String(repeating: "service_", count: 20) + "DB_PASSWORD=" + "CorrectHorse" + "BatteryStaple",
            "x" + String(repeating: "y", count: 150) + "Token: " + "CorrectHorse" + "BatteryStaple",
            // Inputs that need a second pass: a placeholder splits a run, and another rule then
            // sees a separate token.
            "basic " + String(repeating: "MIIEvQ" + "FAKEfake0+/", count: 3) + "/." + "FAKEfake0000" + "FAKEfake0000"
                + "_/" + String(repeating: "MIIEvQ" + "FAKEfake0+/", count: 3),
            "token sk-" + String(repeating: "MIIEvQ" + "FAKEfake0+/", count: 3) + "9xauthauth"
                + String(repeating: "MIIEvQ" + "FAKEfake0+/", count: 3) + "+.proj-'",
        ]
        for input in inputs {
            let once = SecretFilter.redact(input)
            TestSupport.expectEqual(SecretFilter.redact(once), once)
        }
    }

    /// 120 hex characters glued to a key name.
    private static let gluedKeyName = String(repeating: "3f9a1c0b7e", count: 12) + "DB_PASSWORD="
        + "CorrectHorse" + "Batteryworld. "

    private static func testIsSecretLike() {
        TestSupport.expect(SecretFilter.isSecretLike("1234567"), "More than six digits is secret-like")
        for fixture in prefixedFixtures {
            TestSupport.expect(SecretFilter.isSecretLike(fixture), "Prefixed keys are secret-like")
        }
        for name in ["GPT-5", "useAuth", "Nova-3", "Qwen3", "123456"] {
            TestSupport.expect(!SecretFilter.isSecretLike(name), "\(name) is not secret-like")
        }
    }
}
