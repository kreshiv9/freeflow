import Foundation

enum DictationStyleTests {
    static func run() {
        testDisplayNamesAndDirectives()
        testAllowedStylesAndDefaults()
        testCategoryMapping()
        testResolvedStyle()
        testPersistenceRoundTrip()
    }

    private static func testDisplayNamesAndDirectives() {
        TestSupport.expectEqual(DictationStyle.allCases, [.formal, .casual, .veryCasual, .excited])
        TestSupport.expectEqual(
            DictationStyle.allCases.map(\.displayName),
            ["Formal.", "Casual", "very casual", "Excited!"]
        )
        for style in DictationStyle.allCases {
            TestSupport.expectEqual(style.id, style.rawValue)
            TestSupport.expect(!style.directive.isEmpty, "\(style.rawValue) must have a directive")
            TestSupport.expect(!style.directive.contains("\n"), "\(style.rawValue) directive must be a single line")
            TestSupport.expect(!style.directive.contains("—"), "\(style.rawValue) directive must not use an em dash")
        }
        TestSupport.expectEqual(Set(DictationStyle.allCases.map(\.directive)).count, DictationStyle.allCases.count)

        TestSupport.expect(DictationStyle.veryCasual.directive.contains("lowercase"), "very casual must drop capitals")
        TestSupport.expect(DictationStyle.excited.directive.contains("exclamation"), "Excited must add exclamation points")
        TestSupport.expect(DictationStyle.formal.directive.contains("full punctuation"), "Formal must keep full punctuation")
        TestSupport.expect(DictationStyle.casual.directive.contains("lighter punctuation"), "Casual must lighten punctuation")
        TestSupport.expect(DictationStyle.casual.directive.contains("no trailing period"), "Casual must drop a trailing period")
    }

    private static func testAllowedStylesAndDefaults() {
        TestSupport.expectEqual(StyleCategory.allCases, [.personal, .work, .email, .other])
        TestSupport.expectEqual(
            StyleCategory.allCases.map(\.displayName),
            ["Personal messages", "Work", "Email", "Other"]
        )

        TestSupport.expectEqual(StyleCategory.personal.allowedStyles, [.formal, .casual, .veryCasual, .excited])
        for category in [StyleCategory.work, .email, .other] {
            TestSupport.expectEqual(category.allowedStyles, [.formal, .casual, .excited])
        }
        for category in StyleCategory.allCases {
            TestSupport.expectEqual(category.allowedStyles.contains(.veryCasual), category == .personal)
            TestSupport.expect(
                category.allowedStyles.contains(category.defaultStyle),
                "\(category.rawValue) default must be one of its allowed styles"
            )
        }

        TestSupport.expectEqual(StyleCategory.email.defaultStyle, .formal)
        for category in [StyleCategory.work, .personal, .other] {
            TestSupport.expectEqual(category.defaultStyle, .casual)
        }
        TestSupport.expectEqual(
            StyleCategory.defaultStyles,
            [.personal: .casual, .work: .casual, .email: .formal, .other: .casual]
        )

        for category in StyleCategory.allCases {
            TestSupport.expectEqual(category.style(in: [:]), category.defaultStyle)
        }
        TestSupport.expectEqual(StyleCategory.email.style(in: [.email: .veryCasual]), .formal)
        TestSupport.expectEqual(StyleCategory.email.style(in: [.email: .excited]), .excited)
    }

    /// DictationAppCategory is not CaseIterable, so every case is listed.
    private static func testCategoryMapping() {
        let table: [(category: DictationAppCategory, styleCategory: StyleCategory?)] = [
            (.email, .email),
            (.workMessaging, .work),
            (.personalMessaging, .personal),
            (.coding, .other),
            (.other, .other),
            (.aiChat, nil)
        ]
        for row in table {
            TestSupport.expectEqual(StyleCategory.styleCategory(for: row.category), row.styleCategory)
        }
    }

    /// The style is keyed on the raw-paste decision, not the AI-apps toggle: a transcript
    /// pasted raw has no style, and an AI chat that is cleaned anyway takes Other. The
    /// stop path and the Run Log retry are pinned together, since only the stop path
    /// ever pastes raw.
    private static func testResolvedStyle() {
        let styles: [StyleCategory: DictationStyle] = [.email: .formal, .work: .excited]
        let cleanedStyle: [(category: DictationAppCategory, style: DictationStyle)] = [
            (.email, .formal),
            (.workMessaging, .excited),
            (.personalMessaging, .casual),
            (.coding, .casual),
            (.other, .casual),
            (.aiChat, .casual)
        ]

        for row in cleanedStyle {
            TestSupport.expectEqual(
                StyleCategory.resolvedStyle(for: row.category, styles: styles, rawTranscriptForAIApp: false),
                row.style
            )
            TestSupport.expectEqual(
                StyleCategory.resolvedStyle(for: row.category, styles: styles, rawTranscriptForAIApp: true),
                nil
            )
        }

        // Stop path: the same category feeds feature 03's decision and the style. Only a
        // plain dictation into an AI chat with the setting on is raw, and only that case
        // has no style; an AI chat cleaned because the setting is off takes Other.
        for enabled in [true, false] {
            for row in cleanedStyle {
                for isCommandMode in [true, false] {
                    let rawTranscriptForAIApp = AIAppRawTranscriptPreference.shouldPasteRawTranscript(
                        enabled: enabled,
                        category: row.category,
                        isCommandMode: isCommandMode
                    )
                    let style = StyleCategory.resolvedStyle(
                        for: row.category,
                        styles: styles,
                        rawTranscriptForAIApp: rawTranscriptForAIApp
                    )
                    let pastesRaw = enabled && row.category == .aiChat && !isCommandMode
                    TestSupport.expectEqual(rawTranscriptForAIApp, pastesRaw)
                    TestSupport.expectEqual(style, pastesRaw ? nil : row.style)
                }
            }
        }

        // Retry: always cleans, so an AI chat row is styled as Other even with the
        // setting on, exactly like the stop path with the setting off.
        var otherExcited = styles
        otherExcited[.other] = .excited
        TestSupport.expectEqual(
            StyleCategory.resolvedStyle(for: .aiChat, styles: otherExcited, rawTranscriptForAIApp: false),
            .excited
        )
        TestSupport.expectEqual(
            StyleCategory.resolvedStyle(for: .aiChat, styles: styles, rawTranscriptForAIApp: false),
            StyleCategory.resolvedStyle(
                for: .aiChat,
                styles: styles,
                rawTranscriptForAIApp: AIAppRawTranscriptPreference.shouldPasteRawTranscript(
                    enabled: false,
                    category: .aiChat,
                    isCommandMode: false
                )
            )
        )
    }

    private static func testPersistenceRoundTrip() {
        let suite = "FreeFlowTests.DictationStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(
            StyleCategory.allCases.map(\.storageKey),
            ["dictation_style_personal", "dictation_style_work", "dictation_style_email", "dictation_style_other"]
        )

        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults), StyleCategory.defaultStyles)
        for category in StyleCategory.allCases {
            TestSupport.expect(
                defaults.object(forKey: category.storageKey) == nil,
                "Loading the defaults must not persist \(category.rawValue)"
            )
        }

        let chosen: [StyleCategory: DictationStyle] = [
            .personal: .veryCasual, .work: .excited, .email: .casual, .other: .formal
        ]
        StyleCategory.saveStyles(chosen, to: defaults)
        let reloaded = UserDefaults(suiteName: suite)!
        TestSupport.expectEqual(StyleCategory.loadStyles(from: reloaded), chosen)
        for (category, style) in chosen {
            TestSupport.expectEqual(reloaded.object(forKey: category.storageKey) as? String, style.rawValue)
        }

        defaults.set("shouty", forKey: StyleCategory.work.storageKey)
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults)[.work], .casual)
        defaults.set(3, forKey: StyleCategory.personal.storageKey)
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults)[.personal], .casual)
        defaults.set("veryCasual", forKey: StyleCategory.email.storageKey)
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults)[.email], .formal)
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults)[.other], .formal)

        StyleCategory.saveStyles([.email: .veryCasual], to: defaults)
        TestSupport.expectEqual(defaults.object(forKey: StyleCategory.email.storageKey) as? String, "formal")
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults), StyleCategory.defaultStyles)

        StyleCategory.saveStyles(chosen, to: defaults)
        defaults.removeObject(forKey: StyleCategory.work.storageKey)
        var expected = chosen
        expected[.work] = .casual
        TestSupport.expectEqual(StyleCategory.loadStyles(from: defaults), expected)
    }
}
