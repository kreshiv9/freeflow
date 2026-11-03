import Foundation

enum TransformCoreTests {
    static func run() {
        testWordCounting()
        testScopeResolutionTable()
        testCustomTransformValidation()
        testCustomTransformJSONRoundTrip()
        testAutoApplyPreferenceDefaultAndRoundTrip()
        testAutoApplyDecision()
        testDefaultShortcuts()
        testSystemPromptsKeepKeyRules()
        testOutputSanitizing()
        testLaunchShortcuts()
        testShortcutValidationRules()
        testManualModifierTransformCollisions()
        testPinnedStrings()
    }

    /// `count` synthetic words separated by single spaces.
    private static func words(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let suite = "FreeFlowTests.TransformCore.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private static func testWordCounting() {
        TestSupport.expectEqual(TransformCore.wordCount(""), 0)
        TestSupport.expectEqual(TransformCore.wordCount("  \n"), 0)
        TestSupport.expectEqual(TransformCore.wordCount("one"), 1)
        TestSupport.expectEqual(TransformCore.wordCount("one two\nthree\tfour"), 4)
        TestSupport.expectEqual(TransformCore.wordCount("a--b"), 1)
        TestSupport.expectEqual(TransformCore.wordCount(words(3_000)), 3_000)

        TestSupport.expectEqual(TransformCore.minimumInputWords, 1)
        TestSupport.expectEqual(TransformCore.maximumInputWords, 3_000)
        TestSupport.expect(!TransformCore.isWithinInputBounds(""), "Empty text is out of bounds")
        TestSupport.expect(!TransformCore.isWithinInputBounds(words(3_001)), "3,001 words is out of bounds")
        TestSupport.expect(TransformCore.isWithinInputBounds("one"), "One word is in bounds")
        TestSupport.expect(TransformCore.isWithinInputBounds(words(3_000)), "3,000 words is in bounds")
    }

    private static func testScopeResolutionTable() {
        TestSupport.expectEqual(TransformCore.lastDictationWindow, 60)
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: "synthetic selection", fieldText: "field", lastDictation: "last", lastDictationAge: 1),
            .selection("synthetic selection")
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: "  \n", fieldText: "field", lastDictation: "last", lastDictationAge: 1),
            .wholeField("field")
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: "  ", lastDictation: "last", lastDictationAge: 59),
            .lastDictation("last")
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: nil, lastDictation: "last", lastDictationAge: 60.0),
            .lastDictation("last")
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: nil, lastDictation: "last", lastDictationAge: 60.1),
            nil
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: nil, lastDictation: "last", lastDictationAge: nil),
            nil
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: nil, lastDictation: "", lastDictationAge: 1),
            nil
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: nil, lastDictation: nil, lastDictationAge: nil),
            nil
        )
        // An over-limit candidate never falls through to another source.
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: words(3_001), fieldText: "field", lastDictation: "last", lastDictationAge: 1),
            nil
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: words(3_000), fieldText: nil, lastDictation: nil, lastDictationAge: nil),
            .selection(words(3_000))
        )
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: nil, fieldText: words(3_001), lastDictation: "last", lastDictationAge: 1),
            nil
        )
        // The candidate keeps its exact text.
        TestSupport.expectEqual(
            TransformCore.resolveScope(selection: "  padded selection \n", fieldText: nil, lastDictation: nil, lastDictationAge: nil),
            .selection("  padded selection \n")
        )
    }

    private static func testCustomTransformValidation() {
        let valid = CustomTransform(
            name: "Synthetic name",
            instructions: "Shorten the text and keep bullet points.",
            samples: [words(50), words(500)]
        )
        TestSupport.expectEqual(valid.validationMessage, nil)

        var noName = valid
        noName.name = "   "
        TestSupport.expectEqual(noName.validationMessage, "Give the prompt a name.")

        var blankInstructions = valid
        blankInstructions.instructions = " \n"
        TestSupport.expectEqual(blankInstructions.validationMessage, "Instructions are required.")

        var longInstructions = valid
        longInstructions.instructions = words(51)
        TestSupport.expectEqual(
            longInstructions.validationMessage,
            "Instructions are limited to 50 words (currently 51)."
        )
        var maxInstructions = valid
        maxInstructions.instructions = words(50)
        TestSupport.expectEqual(maxInstructions.validationMessage, nil)

        var tooManySamples = valid
        tooManySamples.samples = Array(repeating: words(60), count: 6)
        TestSupport.expectEqual(tooManySamples.validationMessage, "A prompt can have at most five samples.")

        var shortSample = valid
        shortSample.samples = [words(60), words(49)]
        TestSupport.expectEqual(shortSample.validationMessage, "Sample 2 must be 50 to 500 words (currently 49).")

        var longSample = valid
        longSample.samples = [words(501)]
        TestSupport.expectEqual(longSample.validationMessage, "Sample 1 must be 50 to 500 words (currently 501).")

        var longName = valid
        longName.name = "  " + String(repeating: "n", count: 50) + "  "
        TestSupport.expectEqual(longName.trimmedName.count, CustomTransform.maxNameLength)
        TestSupport.expectEqual(longName.normalized.name, String(repeating: "n", count: 40))

        var padded = valid
        padded.name = " Padded "
        padded.instructions = "\n Keep it short. \n"
        padded.samples = [" " + words(50) + " "]
        padded.shortcut = .disabled
        let normalized = padded.normalized
        TestSupport.expectEqual(normalized.id, padded.id)
        TestSupport.expectEqual(normalized.name, "Padded")
        TestSupport.expectEqual(normalized.instructions, "Keep it short.")
        TestSupport.expectEqual(normalized.samples, [words(50)])
        TestSupport.expectEqual(normalized.shortcut, nil)

        TestSupport.expectEqual(CustomTransform.maxCount, 8)
        TestSupport.expectEqual(CustomTransform.maxSamples, 5)
        TestSupport.expectEqual(CustomTransform.sampleWordRange, 50...500)
    }

    private static func testCustomTransformJSONRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(CustomTransform.storageKey, "custom_transforms")
        TestSupport.expectEqual(CustomTransform.load(from: defaults), [])
        TestSupport.expect(
            defaults.object(forKey: CustomTransform.storageKey) == nil,
            "Loading with no records must not persist anything"
        )

        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let controlOptionThree = ShortcutBinding(
            keyCode: 20,
            keyDisplay: "3",
            modifiers: [.control, .option],
            kind: .key,
            preset: nil,
            exactModifierKeyCodes: [59, 58]
        )
        let records = [
            CustomTransform(id: firstID, name: "First", instructions: "Make it friendlier.", samples: [words(50)], shortcut: controlOptionThree),
            CustomTransform(id: secondID, name: "Second", instructions: "Make it formal.")
        ]
        CustomTransform.save(records, to: defaults)
        TestSupport.expectEqual(CustomTransform.load(from: defaults), records)

        defaults.set(Data("not json".utf8), forKey: CustomTransform.storageKey)
        TestSupport.expectEqual(CustomTransform.load(from: defaults), [])
        defaults.set("a string", forKey: CustomTransform.storageKey)
        TestSupport.expectEqual(CustomTransform.load(from: defaults), [])

        let nine = (0..<9).map { CustomTransform(name: "Prompt \($0)", instructions: "Rewrite it.") }
        CustomTransform.save(nine, to: defaults)
        TestSupport.expectEqual(CustomTransform.load(from: defaults).count, 8)
        TestSupport.expectEqual(CustomTransform.load(from: defaults).map(\.name), (0..<8).map { "Prompt \($0)" })

        let invalid = CustomTransform(name: "Too long", instructions: words(51))
        CustomTransform.save([records[1], invalid], to: defaults)
        TestSupport.expectEqual(CustomTransform.load(from: defaults), [records[1]])
    }

    private static func testAutoApplyPreferenceDefaultAndRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        TestSupport.expectEqual(TransformAutoApplyPreference.storageKey, "transform_auto_apply")
        TestSupport.expectEqual(TransformAutoApplyPreference.aiAppsOnlyStorageKey, "transform_auto_apply_ai_apps_only")
        TestSupport.expectEqual(TransformAutoApplyPreference.load(from: defaults), .off)
        TestSupport.expect(
            defaults.object(forKey: TransformAutoApplyPreference.storageKey) == nil,
            "Loading the default must not persist a preference"
        )
        defaults.set("bogus", forKey: TransformAutoApplyPreference.storageKey)
        TestSupport.expectEqual(TransformAutoApplyPreference.load(from: defaults), .off)
        defaults.set("custom:not-a-uuid", forKey: TransformAutoApplyPreference.storageKey)
        TestSupport.expectEqual(TransformAutoApplyPreference.load(from: defaults), .off)
        defaults.set(3, forKey: TransformAutoApplyPreference.storageKey)
        TestSupport.expectEqual(TransformAutoApplyPreference.load(from: defaults), .off)

        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        for preference in [TransformAutoApplyPreference.polish, .promptEngineer, .custom(id), .off] {
            preference.save(to: defaults)
            TestSupport.expectEqual(TransformAutoApplyPreference.load(from: defaults), preference)
            TestSupport.expectEqual(TransformAutoApplyPreference(rawValue: preference.rawValue), preference)
        }
        TestSupport.expectEqual(TransformAutoApplyPreference.custom(id).rawValue, "custom:33333333-3333-3333-3333-333333333333")
        TestSupport.expectEqual(TransformAutoApplyPreference.off.rawValue, "off")
        TestSupport.expectEqual(TransformAutoApplyPreference.polish.rawValue, "polish")
        TestSupport.expectEqual(TransformAutoApplyPreference.promptEngineer.rawValue, "promptEngineer")

        TestSupport.expectEqual(TransformAutoApplyPreference.defaultAIAppsOnly, true)
        TestSupport.expectEqual(TransformAutoApplyPreference.loadAIAppsOnly(from: defaults), true)
        defaults.set(false, forKey: TransformAutoApplyPreference.aiAppsOnlyStorageKey)
        TestSupport.expectEqual(TransformAutoApplyPreference.loadAIAppsOnly(from: defaults), false)
        defaults.set("yes", forKey: TransformAutoApplyPreference.aiAppsOnlyStorageKey)
        TestSupport.expectEqual(TransformAutoApplyPreference.loadAIAppsOnly(from: defaults), true)
    }

    private static func testAutoApplyDecision() {
        let record = CustomTransform(name: "Synthetic name", instructions: "Rewrite it.")
        func decide(
            _ preference: TransformAutoApplyPreference,
            text: String = "synthetic dictated text",
            isCommandMode: Bool = false,
            isVoiceMacro: Bool = false,
            category: DictationAppCategory? = .aiChat,
            aiAppsOnly: Bool = true,
            customTransforms: [CustomTransform] = []
        ) -> TransformKind? {
            TransformCore.autoApplyKind(
                preference: preference,
                customTransforms: customTransforms,
                text: text,
                isCommandMode: isCommandMode,
                isVoiceMacro: isVoiceMacro,
                category: category,
                aiAppsOnly: aiAppsOnly
            )
        }

        TestSupport.expectEqual(decide(.off), nil)
        TestSupport.expectEqual(decide(.polish), .polish)
        TestSupport.expectEqual(decide(.promptEngineer, category: .coding), nil)
        TestSupport.expectEqual(decide(.promptEngineer, category: .coding, aiAppsOnly: false), .promptEngineer)
        TestSupport.expectEqual(decide(.polish, category: nil, aiAppsOnly: false), .polish)
        TestSupport.expectEqual(decide(.polish, category: nil), nil)
        TestSupport.expectEqual(decide(.polish, isCommandMode: true), nil)
        TestSupport.expectEqual(decide(.polish, isVoiceMacro: true), nil)
        TestSupport.expectEqual(decide(.polish, text: ""), nil)
        TestSupport.expectEqual(decide(.polish, text: words(3_001)), nil)
        TestSupport.expectEqual(decide(.custom(record.id)), nil)
        TestSupport.expectEqual(decide(.custom(record.id), customTransforms: [record]), .custom(record))
    }

    private static func testDefaultShortcuts() {
        let polish = ShortcutBinding.defaultPolishTransform
        let promptEngineer = ShortcutBinding.defaultPromptEngineerTransform
        TestSupport.expectEqual(polish.keyCode, 18)
        TestSupport.expectEqual(promptEngineer.keyCode, 19)
        for binding in [polish, promptEngineer] {
            TestSupport.expectEqual(binding.modifiers, [.control, .option])
            TestSupport.expectEqual(binding.exactModifierKeyCodes, [58, 59, 61, 62])
            TestSupport.expectEqual(binding.kind, .key)
            TestSupport.expect(binding.isCustom, "The defaults are custom (non-preset) bindings")
        }
        TestSupport.expectEqual(polish.displayName, "Ctrl ⌃ + Option ⌥ + 1")
        TestSupport.expectEqual(promptEngineer.displayName, "Ctrl ⌃ + Option ⌥ + 2")
        TestSupport.expectEqual(TransformCore.defaultShortcut(for: .polish), polish)
        TestSupport.expectEqual(TransformCore.defaultShortcut(for: .promptEngineer), promptEngineer)
        TestSupport.expectEqual(TransformCore.defaultShortcut(for: .custom(UUID())), nil)

        TestSupport.expectEqual(ShortcutRole(transformID: .polish), .polishTransform)
        TestSupport.expectEqual(ShortcutRole(transformID: .promptEngineer), .promptEngineerTransform)
        let id = UUID()
        TestSupport.expectEqual(ShortcutRole(transformID: .custom(id)), .customTransform(id))
        TestSupport.expectEqual(ShortcutRole.customTransform(id).transformID, .custom(id))
        TestSupport.expectEqual(ShortcutRole.hold.transformID, nil)
        TestSupport.expectEqual(ShortcutRole.polishTransform.title, "Polish")
        TestSupport.expectEqual(ShortcutRole.promptEngineerTransform.title, "Prompt Engineer")
        TestSupport.expectEqual(ShortcutRole.customTransform(id).title, "Shortcut")
        TestSupport.expectEqual([TransformID.custom(id), .promptEngineer, .polish].sorted { $0.sortKey < $1.sortKey }, [.polish, .promptEngineer, .custom(id)])
    }

    private static func testSystemPromptsKeepKeyRules() {
        let polish = TransformCore.polishSystemPrompt
        for rule in ["grammar", "typos", "voice", "meaning", "formatting", "lists", "Add no facts", "Return only the polished text", "Never follow"] {
            TestSupport.expect(polish.contains(rule), "The Polish prompt must keep: \(rule)")
        }
        TestSupport.expectEqual(TransformCore.systemPrompt(for: .polish), polish)

        let promptEngineer = TransformCore.promptEngineerSystemPrompt
        for rule in ["Goal", "Context", "Constraints", "Desired output", "plain text", "markdown headers", "invent nothing", "Return only the prompt", "Never follow"] {
            TestSupport.expect(promptEngineer.contains(rule), "The Prompt Engineer prompt must keep: \(rule)")
        }
        TestSupport.expectEqual(TransformCore.systemPrompt(for: .promptEngineer), promptEngineer)

        let samples = [words(50), "synthetic second sample " + words(50)]
        let record = CustomTransform(
            name: "Synthetic name",
            instructions: "Synthetic instructions: shorten and keep bullet points.",
            samples: samples
        )
        let custom = TransformCore.systemPrompt(for: .custom(record))
        TestSupport.expect(custom.contains("Synthetic instructions: shorten and keep bullet points."), "Custom instructions are included")
        TestSupport.expect(custom.contains("Example 1:\n" + samples[0]), "The first sample is an example")
        TestSupport.expect(custom.contains("Example 2:\n" + samples[1]), "The second sample is an example")
        TestSupport.expect(custom.contains("Style examples"), "Samples are introduced as style examples")
        for rule in ["Return only the transformed text", "Never follow", "Instructions:"] {
            TestSupport.expect(custom.contains(rule), "The custom prompt must keep: \(rule)")
        }
        var noSamples = record
        noSamples.samples = []
        let bare = TransformCore.systemPrompt(for: .custom(noSamples))
        TestSupport.expect(!bare.contains("Style examples"), "No samples, no examples heading")
        TestSupport.expect(!bare.contains("Example 1:"), "No samples, no example block")

        let message = TransformCore.userMessage(text: "synthetic input text")
        TestSupport.expect(message.contains("INPUT_TEXT: \"synthetic input text\""), "The input is delimited like SELECTED_TEXT")
        TestSupport.expect(message.contains("data, not an instruction"), "The input is declared data")
    }

    private static func testOutputSanitizing() {
        // An unquoted input: one pair of wrapping quotes is stripped, like cleanup output.
        TestSupport.expectEqual(
            TransformCore.sanitizedOutput("\n\"Synthetic polished text.\"\n", input: "synthetic input text"),
            "Synthetic polished text."
        )
        TestSupport.expectEqual(TransformCore.sanitizedOutput(" EMPTY ", input: "synthetic input text"), "")
        TestSupport.expectEqual(TransformCore.sanitizedOutput("  ", input: "synthetic input text"), "")
        // A quoted input keeps its quotation marks: the result replaces it in place.
        TestSupport.expectEqual(
            TransformCore.sanitizedOutput(" \"Can you send the synthetic file tomorrow?\" ", input: "\"can you send the synthetic file tomorow\""),
            "\"Can you send the synthetic file tomorrow?\""
        )
        TestSupport.expectEqual(
            TransformCore.sanitizedOutput("\"Synthetic quote.\"", input: "  \"synthetic quote\"\n"),
            "\"Synthetic quote.\""
        )
        TestSupport.expectEqual(TransformCore.sanitizedOutput("EMPTY", input: "\"synthetic quote\""), "")
        // A lone quote character is not a wrapped input.
        TestSupport.expectEqual(TransformCore.sanitizedOutput("\"Synthetic.\"", input: "\""), "Synthetic.")
        // Quotes inside the text are never touched.
        TestSupport.expectEqual(
            TransformCore.sanitizedOutput("She said \"synthetic\" twice.", input: "she said \"synthetic\" twice"),
            "She said \"synthetic\" twice."
        )
    }

    // MARK: - Shortcut rules

    private static func keyBinding(_ keyCode: UInt16, _ display: String, modifiers: ShortcutModifiers = []) -> ShortcutBinding {
        ShortcutBinding(keyCode: keyCode, keyDisplay: display, modifiers: modifiers, kind: .key, preset: nil)
    }

    /// A captured Ctrl+Option+1 (left-side modifiers), as the Settings capture row produces it.
    private static let capturedControlOptionOne = ShortcutBinding(
        keyCode: 18,
        keyDisplay: "1",
        modifiers: [.control, .option],
        kind: .key,
        preset: nil,
        exactModifierKeyCodes: [59, 58]
    )

    private static func testLaunchShortcuts() {
        let polishDefault = ShortcutBinding.defaultPolishTransform
        let promptEngineerDefault = ShortcutBinding.defaultPromptEngineerTransform
        func launch(
            storedPolish: ShortcutBinding? = nil,
            storedPromptEngineer: ShortcutBinding? = nil,
            hold: ShortcutBinding = .defaultHold,
            toggle: ShortcutBinding = .defaultToggle,
            copyAgain: ShortcutBinding = .disabled,
            manualModifier: ShortcutModifiers? = nil,
            customShortcuts: [ShortcutBinding] = []
        ) -> (polish: ShortcutBinding, promptEngineer: ShortcutBinding) {
            TransformCore.launchShortcuts(
                storedPolish: storedPolish,
                storedPromptEngineer: storedPromptEngineer,
                hold: hold,
                toggle: toggle,
                copyAgain: copyAgain,
                manualModifier: manualModifier,
                customShortcuts: customShortcuts
            )
        }

        let fresh = launch()
        TestSupport.expectEqual(fresh.polish, polishDefault)
        TestSupport.expectEqual(fresh.promptEngineer, promptEngineerDefault)

        // Regression: Prompt Engineer's stored ⌃⌥1 is never shadowed by a re-applied Polish default.
        let explicitPromptEngineer = launch(storedPromptEngineer: capturedControlOptionOne)
        TestSupport.expectEqual(explicitPromptEngineer.polish, .disabled)
        TestSupport.expectEqual(explicitPromptEngineer.promptEngineer, capturedControlOptionOne)
        // A stored Disabled for Prompt Engineer reserves nothing.
        let disabledPromptEngineer = launch(storedPromptEngineer: .disabled)
        TestSupport.expectEqual(disabledPromptEngineer.polish, polishDefault)
        TestSupport.expectEqual(disabledPromptEngineer.promptEngineer, .disabled)

        // Stored choices win, Disabled included; the other default still avoids them.
        let disabledPolish = launch(storedPolish: .disabled)
        TestSupport.expectEqual(disabledPolish.polish, .disabled)
        TestSupport.expectEqual(disabledPolish.promptEngineer, promptEngineerDefault)
        let polishOnTwo = launch(storedPolish: promptEngineerDefault)
        TestSupport.expectEqual(polishOnTwo.polish, promptEngineerDefault)
        TestSupport.expectEqual(polishOnTwo.promptEngineer, .disabled)
        let storedDespiteConflict = launch(storedPolish: polishDefault, copyAgain: capturedControlOptionOne)
        TestSupport.expectEqual(storedDespiteConflict.polish, polishDefault)

        // Defaults skip the dictation shortcuts, Paste Again and custom prompt shortcuts.
        TestSupport.expectEqual(launch(copyAgain: capturedControlOptionOne).polish, .disabled)
        TestSupport.expectEqual(launch(hold: capturedControlOptionOne).polish, .disabled)
        TestSupport.expectEqual(launch(toggle: capturedControlOptionOne).polish, .disabled)
        let customOnOne = launch(customShortcuts: [capturedControlOptionOne])
        TestSupport.expectEqual(customOnOne.polish, .disabled)
        TestSupport.expectEqual(customOnOne.promptEngineer, promptEngineerDefault)

        // The manual Edit Mode press for a Ctrl+1 hold with the Option modifier is ⌃⌥1.
        let controlOne = keyBinding(18, "1", modifiers: [.control])
        TestSupport.expectEqual(launch(hold: controlOne, manualModifier: .option).polish, .disabled)
        TestSupport.expectEqual(launch(hold: controlOne).polish, polishDefault)
        TestSupport.expectEqual(launch(toggle: controlOne, manualModifier: .option).polish, .disabled)
        TestSupport.expectEqual(launch(hold: controlOne, manualModifier: .command).polish, polishDefault)
    }

    private static func testShortcutValidationRules() {
        let customID = UUID()
        let otherCustomID = UUID()
        let f5 = keyBinding(96, "F5")
        let f6 = keyBinding(97, "F6")
        let f8 = keyBinding(100, "F8")
        let optionF8 = keyBinding(100, "F8", modifiers: [.option])
        let rightOption = ShortcutPreset.rightOption.binding
        let transforms = [
            TransformShortcutEntry(id: .polish, title: "Polish", binding: .defaultPolishTransform),
            TransformShortcutEntry(id: .promptEngineer, title: "Prompt Engineer", binding: .defaultPromptEngineerTransform),
            TransformShortcutEntry(id: .custom(customID), title: "Synthetic prompt", binding: f6)
        ]
        func message(
            _ binding: ShortcutBinding,
            for role: ShortcutRole,
            hold: ShortcutBinding = .defaultHold,
            toggle: ShortcutBinding = .defaultToggle,
            copyAgain: ShortcutBinding = f5,
            transforms: [TransformShortcutEntry] = transforms,
            manualModifier: ShortcutModifiers? = nil
        ) -> String? {
            TransformCore.shortcutValidationMessage(
                binding,
                for: role,
                assignments: ShortcutAssignments(
                    hold: hold, toggle: toggle, copyAgain: copyAgain, transforms: transforms, manualModifier: manualModifier
                )
            )
        }

        // A role is never checked against its own binding, so re-saving keeps the shortcut.
        TestSupport.expectEqual(message(f6, for: .customTransform(customID)), nil)
        TestSupport.expectEqual(message(.defaultPolishTransform, for: .polishTransform), nil)
        TestSupport.expectEqual(message(capturedControlOptionOne, for: .polishTransform), nil)
        TestSupport.expectEqual(message(.defaultPromptEngineerTransform, for: .promptEngineerTransform), nil)

        // Transforms stay clear of each other.
        TestSupport.expectEqual(message(f6, for: .customTransform(otherCustomID)), "This shortcut is already used by Synthetic prompt.")
        TestSupport.expectEqual(message(f6, for: .polishTransform), "This shortcut is already used by Synthetic prompt.")
        TestSupport.expectEqual(message(capturedControlOptionOne, for: .promptEngineerTransform), "This shortcut is already used by Polish.")
        TestSupport.expectEqual(message(.defaultPromptEngineerTransform, for: .customTransform(customID)), "This shortcut is already used by Prompt Engineer.")

        // Transforms against the dictation shortcuts and Paste Again.
        TestSupport.expectEqual(message(.defaultHold, for: .polishTransform), "This shortcut is already used by Hold to Talk.")
        TestSupport.expectEqual(message(.defaultToggle, for: .customTransform(customID)), "This shortcut is already used by Tap to Toggle.")
        TestSupport.expectEqual(message(f5, for: .promptEngineerTransform), "This shortcut is already used by Paste Again.")
        TestSupport.expectEqual(message(.disabled, for: .polishTransform, manualModifier: .option), nil)
        TestSupport.expectEqual(message(f8, for: .customTransform(otherCustomID)), nil)

        // Every role stays clear of the transforms.
        TestSupport.expectEqual(message(.defaultPolishTransform, for: .hold), "This shortcut is already used by Polish.")
        TestSupport.expectEqual(message(.defaultPromptEngineerTransform, for: .toggle), "This shortcut is already used by Prompt Engineer.")
        TestSupport.expectEqual(message(f6, for: .copyAgain), "This shortcut is already used by Synthetic prompt.")

        // The pre-existing dictation and Paste Again rules keep their messages and order.
        TestSupport.expectEqual(message(.defaultToggle, for: .hold), "Hold and tap shortcuts must be distinct.")
        TestSupport.expectEqual(message(f5, for: .hold), "This shortcut is already used by Paste Again.")
        TestSupport.expectEqual(message(.defaultHold, for: .copyAgain), "Paste Again cannot share a shortcut with Hold to Talk.")
        TestSupport.expectEqual(message(.defaultToggle, for: .copyAgain), "Paste Again cannot share a shortcut with Tap to Toggle.")
        TestSupport.expectEqual(message(optionF8, for: .copyAgain, manualModifier: .option), "Paste Again cannot share the Edit Mode modifier.")
        TestSupport.expectEqual(message(rightOption, for: .copyAgain, manualModifier: .option), "Paste Again cannot share the Edit Mode modifier.")
        TestSupport.expectEqual(message(optionF8, for: .copyAgain), nil)
        TestSupport.expectEqual(message(f5, for: .copyAgain), nil)

        // Manual Edit Mode: a transform may not be the modifier key itself or the actual manual press.
        TestSupport.expectEqual(message(rightOption, for: .polishTransform, manualModifier: .option), "This shortcut is already the Edit Mode press.")
        TestSupport.expectEqual(message(rightOption, for: .polishTransform), nil)
        TestSupport.expectEqual(message(rightOption, for: .polishTransform, manualModifier: .command), nil)
        TestSupport.expectEqual(
            message(optionF8, for: .customTransform(otherCustomID), hold: f8, manualModifier: .option),
            "This shortcut is already the Edit Mode press."
        )
        TestSupport.expectEqual(
            message(optionF8, for: .customTransform(otherCustomID), toggle: f8, manualModifier: .option),
            "This shortcut is already the Edit Mode press."
        )
        TestSupport.expectEqual(message(optionF8, for: .customTransform(otherCustomID), hold: f8), nil)
        TestSupport.expectEqual(
            message(optionF8, for: .customTransform(otherCustomID), hold: keyBinding(101, "F9"), manualModifier: .option),
            nil
        )
        TestSupport.expectEqual(
            message(optionF8, for: .customTransform(otherCustomID), hold: .disabled, toggle: .disabled, manualModifier: .option),
            nil
        )
        // Merely containing the manual modifier is fine for a transform.
        TestSupport.expectEqual(message(capturedControlOptionOne, for: .polishTransform, manualModifier: .option), nil)

        // Manual Edit Mode from the dictation side: a hold or tap whose manual press is a transform.
        let optionF8Transform = [TransformShortcutEntry(id: .custom(customID), title: "Synthetic prompt", binding: optionF8)]
        TestSupport.expectEqual(
            message(f8, for: .hold, transforms: optionF8Transform, manualModifier: .option),
            "With the Edit Mode modifier this is the Synthetic prompt shortcut."
        )
        TestSupport.expectEqual(
            message(f8, for: .toggle, transforms: optionF8Transform, manualModifier: .option),
            "With the Edit Mode modifier this is the Synthetic prompt shortcut."
        )
        TestSupport.expectEqual(message(f8, for: .hold, transforms: optionF8Transform), nil)
        TestSupport.expectEqual(message(f8, for: .copyAgain, transforms: optionF8Transform, manualModifier: .option), nil)
        // The custom prompt's own entry is excluded only for its own role.
        TestSupport.expectEqual(
            message(optionF8, for: .customTransform(customID), hold: f8, transforms: optionF8Transform, manualModifier: .option),
            "This shortcut is already the Edit Mode press."
        )
        TestSupport.expectEqual(message(optionF8, for: .customTransform(customID), transforms: optionF8Transform), nil)
    }

    private static func testManualModifierTransformCollisions() {
        let f8 = keyBinding(100, "F8")
        let f9 = keyBinding(101, "F9")
        let optionF8 = keyBinding(100, "F8", modifiers: [.option])
        let optionF9 = keyBinding(101, "F9", modifiers: [.option])
        func message(
            _ manualModifier: ShortcutModifiers,
            hold: ShortcutBinding = .defaultHold,
            toggle: ShortcutBinding = .defaultToggle,
            transforms: [TransformShortcutEntry]
        ) -> String? {
            TransformCore.manualModifierTransformCollisionMessage(
                manualModifier, hold: hold, toggle: toggle, transforms: transforms
            )
        }
        let defaults = [
            TransformShortcutEntry(id: .polish, title: "Polish", binding: .defaultPolishTransform),
            TransformShortcutEntry(id: .promptEngineer, title: "Prompt Engineer", binding: .defaultPromptEngineerTransform)
        ]

        // Containing the modifier is fine; the defaults never block an Option or Control modifier.
        TestSupport.expectEqual(message(.option, transforms: defaults), nil)
        TestSupport.expectEqual(message(.control, transforms: defaults), nil)
        TestSupport.expectEqual(message(.option, transforms: []), nil)

        let rightOptionTransform = [TransformShortcutEntry(id: .polish, title: "Polish", binding: ShortcutPreset.rightOption.binding)]
        TestSupport.expectEqual(message(.option, transforms: rightOptionTransform), "That modifier is already the Polish shortcut.")
        TestSupport.expectEqual(message(.command, transforms: rightOptionTransform), nil)

        let customID = UUID()
        let holdPress = [TransformShortcutEntry(id: .custom(customID), title: "Synthetic prompt", binding: optionF8)]
        TestSupport.expectEqual(
            message(.option, hold: f8, transforms: holdPress),
            "That modifier plus the hold shortcut is already the Synthetic prompt shortcut."
        )
        TestSupport.expectEqual(message(.option, hold: f9, transforms: holdPress), nil)
        TestSupport.expectEqual(message(.option, hold: .disabled, transforms: holdPress), nil)

        let tapPress = [TransformShortcutEntry(id: .custom(customID), title: "Synthetic prompt", binding: optionF9)]
        TestSupport.expectEqual(
            message(.option, toggle: f9, transforms: tapPress),
            "That modifier plus the tap shortcut is already the Synthetic prompt shortcut."
        )
        TestSupport.expectEqual(message(.option, toggle: .disabled, transforms: tapPress), nil)
    }

    private static func testPinnedStrings() {
        let record = CustomTransform(name: " Synthetic name ", instructions: "Rewrite it.")
        TestSupport.expectEqual(TransformKind.polish.processingStatus, "Transform: Polish")
        TestSupport.expectEqual(TransformKind.promptEngineer.processingStatus, "Transform: Prompt Engineer")
        TestSupport.expectEqual(TransformKind.custom(record).processingStatus, "Transform: Synthetic name")
        TestSupport.expectEqual(TransformKind.polish.autoApplyStatusSuffix, ", polished")
        TestSupport.expectEqual(TransformKind.promptEngineer.autoApplyStatusSuffix, ", prompt engineered")
        TestSupport.expectEqual(TransformKind.custom(record).autoApplyStatusSuffix, ", Synthetic name")
        TestSupport.expectEqual(TransformKind.custom(record).id, .custom(record.id))
        TestSupport.expectEqual(TransformKind.polish.id, .polish)
        TestSupport.expectEqual(TransformKind.promptEngineer.title, "Prompt Engineer")
        TestSupport.expectEqual(TransformCore.autoApplyFailedStatusSuffix, ", transform failed")
        let failed = TransformCore.failedProcessingStatus(for: .polish, error: PostProcessingError.emptyOutput)
        TestSupport.expect(failed.hasPrefix("Error: Transform: Polish failed"), "The failure status names the transform")
        TestSupport.expect(failed.contains(PostProcessingError.emptyOutput.localizedDescription), "The failure status carries the error")
        TestSupport.expectEqual(TransformCore.transformingStatusText, "Transforming…")
        TestSupport.expectEqual(TransformCore.nothingToTransformStatusText, "Nothing to transform")
        TestSupport.expectEqual(TransformCore.failedStatusText, "Transform failed")
        TestSupport.expectEqual(TransformCore.resultCopiedStatusText, "Transform result copied")
        TestSupport.expectEqual(
            TransformCore.settingsCaption,
            "Transforms rewrite the selected text, the current text field, or your last dictation. Polish keeps your voice; Prompt Engineer turns rambling into a structured AI prompt."
        )
        TestSupport.expectEqual(TransformScope.selection("a").text, "a")
        TestSupport.expectEqual(TransformScope.wholeField("b").text, "b")
        TestSupport.expectEqual(TransformScope.lastDictation("c").text, "c")
        TestSupport.expectEqual(PipelineHistoryItemIntent.transform.rawValue, "transform")
        TestSupport.expectEqual(PipelineHistoryItemIntent(rawValue: "transform"), .transform)
    }
}
