import Foundation

enum ModelConfigurationTests {
    static func run() {
        testProviderlessAliasesMatchCanonicalModels()
        testKnownModelSettingsRemainStable()
        testModelListsAreConsistent()
        testThinkTagStripping()
        testGroqSelectionMigration()
        testCleanupDefaults()
        testCleanupDefaultMigration()
        testCleanupFallbackAfterSelectingPrimary()
        testRetiredCleanupFallbackReplacement()
    }

    private static func testProviderlessAliasesMatchCanonicalModels() {
        assertSameConfig(" GPT-OSS-20B ", "openai/gpt-oss-20b")
        assertSameConfig("gpt-oss-120b", "openai/gpt-oss-120b")
        assertSameConfig("gpt-oss-safeguard-20b", "openai/gpt-oss-safeguard-20b")
        assertSameConfig("qwen3-32b", "qwen/qwen3-32b")
        assertSameConfig(" QWEN3.8-27B ", "qwen/qwen3.8-27b")
    }

    private static func testKnownModelSettingsRemainStable() {
        let gptOSS = ModelConfiguration.config(for: "openai/gpt-oss-20b")
        TestSupport.expectEqual(gptOSS.maxCompletionTokens, 4096)
        TestSupport.expectEqual(gptOSS.reasoningEffort, "low")
        TestSupport.expectEqual(gptOSS.includeReasoning, false)
        TestSupport.expectEqual(gptOSS.shouldStripThinkTags, false)

        let qwen = ModelConfiguration.config(for: "qwen/qwen3.8-27b")
        TestSupport.expectEqual(qwen.reasoningEffort, "none")
        TestSupport.expectEqual(qwen.includeReasoning, false)
        TestSupport.expectEqual(qwen.shouldStripThinkTags, true)

        let unknown = ModelConfiguration.config(for: "example/unknown-model")
        TestSupport.expectEqual(unknown.maxCompletionTokens, nil)
        TestSupport.expectEqual(unknown.reasoningEffort, nil)
        TestSupport.expectEqual(unknown.includeReasoning, nil)
        TestSupport.expectEqual(unknown.shouldStripThinkTags, false)
    }

    private static func testModelListsAreConsistent() {
        TestSupport.expectEqual(Set(ModelConfiguration.llmModels).count, ModelConfiguration.llmModels.count)
        TestSupport.expectEqual(Set(ModelConfiguration.visionModels).count, ModelConfiguration.visionModels.count)
        TestSupport.expectEqual(Set(ModelConfiguration.transcriptionModels).count, ModelConfiguration.transcriptionModels.count)
        TestSupport.expect(
            Set(ModelConfiguration.visionModels).isSubset(of: Set(ModelConfiguration.llmModels)),
            "Every vision model must also be selectable as an LLM"
        )
    }

    private static func testThinkTagStripping() {
        TestSupport.expectEqual(
            ModelConfiguration.stripThinkTags("<think>hidden</think> Visible output"),
            "Visible output"
        )
        TestSupport.expectEqual(
            ModelConfiguration.stripThinkTags("<think>one</think>\n<think>two</think>\nResult"),
            "Result"
        )
        TestSupport.expectEqual(ModelConfiguration.stripThinkTags("<think>unfinished"), "")
        TestSupport.expectEqual(
            ModelConfiguration.stripThinkTags("Ordinary output with a later <think> marker"),
            "Ordinary output with a later <think> marker"
        )
    }

    private static func testGroqSelectionMigration() {
        let suite = "FreeFlowTests.ModelMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = ["context_model", "post_processing_model", "post_processing_fallback_model"]
        for key in keys {
            for stored in ["qwen/qwen3.6-27b", " QWEN3.6-27B "] {
                defaults.set(stored, forKey: key)
                ModelConfiguration.migrateGroqSelection(key: key, baseURL: "https://api.groq.com/openai/v1/", defaults: defaults)
                TestSupport.expectEqual(defaults.string(forKey: key), "qwen/qwen3.8-27b")
                ModelConfiguration.migrateGroqSelection(key: key, baseURL: "https://api.groq.com/openai/v1", defaults: defaults)
                TestSupport.expectEqual(defaults.string(forKey: key), "qwen/qwen3.8-27b")
            }
            for provider in ["https://openrouter.ai/api/v1", "https://example.invalid/openai/v1", "https://api.groq.com/custom"] {
                defaults.set("qwen/qwen3.6-27b", forKey: key)
                ModelConfiguration.migrateGroqSelection(key: key, baseURL: provider, defaults: defaults)
                TestSupport.expectEqual(defaults.string(forKey: key), "qwen/qwen3.6-27b")
            }
            defaults.set("custom/synthetic", forKey: key)
            ModelConfiguration.migrateGroqSelection(key: key, baseURL: "https://api.groq.com/openai/v1", defaults: defaults)
            TestSupport.expectEqual(defaults.string(forKey: key), "custom/synthetic")
            defaults.removeObject(forKey: key)
            ModelConfiguration.migrateGroqSelection(key: key, baseURL: "https://api.groq.com/openai/v1", defaults: defaults)
            TestSupport.expect(defaults.object(forKey: key) == nil, "Migration should not populate missing preferences")
        }
        assertSameConfig("qwen3.6-27b", "qwen/qwen3.6-27b")
    }

    private static func testCleanupDefaults() {
        TestSupport.expectEqual(ModelConfiguration.defaultCleanupModel, "qwen/qwen3.8-27b")
        TestSupport.expectEqual(ModelConfiguration.defaultCleanupFallbackModel, "openai/gpt-oss-20b")
        TestSupport.expect(
            ModelConfiguration.defaultCleanupModel != ModelConfiguration.defaultCleanupFallbackModel,
            "Equal defaults would remove the fallback retry"
        )
        for model in [ModelConfiguration.defaultCleanupModel, ModelConfiguration.defaultCleanupFallbackModel] {
            TestSupport.expect(ModelConfiguration.llmModels.contains(model), "\(model) must be selectable in Settings")
        }
        let qwen = ModelConfiguration.config(for: ModelConfiguration.defaultCleanupModel)
        TestSupport.expectEqual(qwen.reasoningEffort, "none")
        TestSupport.expectEqual(qwen.includeReasoning, false)
    }

    private static func testCleanupDefaultMigration() {
        let groq = "https://api.groq.com/openai/v1"
        let modelKey = "post_processing_model"
        let fallbackKey = "post_processing_fallback_model"
        let flagKey = ModelConfiguration.cleanupDefaultMigrationKey
        TestSupport.expectEqual(flagKey, "post_processing_default_qwen_migrated")

        func migration(
            baseURL: String = "https://api.groq.com/openai/v1",
            model: String?,
            fallback: String?
        ) -> (model: String?, fallback: String?, flag: Bool) {
            let suite = "FreeFlowTests.CleanupDefaultMigration.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if let model { defaults.set(model, forKey: modelKey) }
            if let fallback { defaults.set(fallback, forKey: fallbackKey) }
            ModelConfiguration.migrateCleanupDefault(
                modelKey: modelKey, fallbackKey: fallbackKey, baseURL: baseURL, defaults: defaults
            )
            return (defaults.string(forKey: modelKey), defaults.string(forKey: fallbackKey), defaults.bool(forKey: flagKey))
        }

        // The old default pair moves to Qwen first, gpt-oss-20b second.
        for stored in ["openai/gpt-oss-20b", " openai/gpt-oss-20b "] {
            let migrated = migration(model: stored, fallback: "qwen/qwen3.8-27b")
            TestSupport.expectEqual(migrated.model, "qwen/qwen3.8-27b")
            TestSupport.expectEqual(migrated.fallback, "openai/gpt-oss-20b")
            TestSupport.expect(migrated.flag, "The migration must record that it ran")
        }
        let modelOnly = migration(model: "openai/gpt-oss-20b", fallback: nil)
        TestSupport.expectEqual(modelOnly.model, "qwen/qwen3.8-27b")
        TestSupport.expectEqual(modelOnly.fallback, nil)

        // Unset keys already load the new defaults.
        let unset = migration(model: nil, fallback: nil)
        TestSupport.expectEqual(unset.model, nil)
        TestSupport.expectEqual(unset.fallback, nil)
        TestSupport.expect(unset.flag, "The flag is set even when nothing changes")

        let fallbackOnly = migration(model: nil, fallback: "qwen/qwen3.8-27b")
        TestSupport.expectEqual(fallbackOnly.model, nil)
        TestSupport.expectEqual(fallbackOnly.fallback, "openai/gpt-oss-20b")

        // A blank primary loads as the default, so it is unset: the Qwen fallback still moves
        // and the retry survives.
        for blank in ["", "  "] {
            let blankPrimary = migration(model: blank, fallback: "qwen/qwen3.8-27b")
            TestSupport.expectEqual(blankPrimary.model, blank)
            TestSupport.expectEqual(blankPrimary.fallback, "openai/gpt-oss-20b")
        }

        // Any other stored primary is an explicit choice.
        let other = migration(model: "openai/gpt-oss-120b", fallback: "qwen/qwen3.8-27b")
        TestSupport.expectEqual(other.model, "openai/gpt-oss-120b")
        TestSupport.expectEqual(other.fallback, "qwen/qwen3.8-27b")
        let qwenPair = migration(model: "qwen/qwen3.8-27b", fallback: "qwen/qwen3.8-27b")
        TestSupport.expectEqual(qwenPair.model, "qwen/qwen3.8-27b")
        TestSupport.expectEqual(qwenPair.fallback, "qwen/qwen3.8-27b")

        // Runs once: switching back to gpt-oss-20b afterwards sticks.
        let suite = "FreeFlowTests.CleanupDefaultMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai/gpt-oss-20b", forKey: modelKey)
        ModelConfiguration.migrateCleanupDefault(modelKey: modelKey, fallbackKey: fallbackKey, baseURL: groq, defaults: defaults)
        TestSupport.expectEqual(defaults.string(forKey: modelKey), "qwen/qwen3.8-27b")
        defaults.set("openai/gpt-oss-20b", forKey: modelKey)
        ModelConfiguration.migrateCleanupDefault(modelKey: modelKey, fallbackKey: fallbackKey, baseURL: groq, defaults: defaults)
        TestSupport.expectEqual(defaults.string(forKey: modelKey), "openai/gpt-oss-20b")

        // Another provider keeps the old pair, so it is never sent Groq's Qwen ID by default.
        let openRouter = "https://openrouter.ai/api/v1"
        let pinned = migration(baseURL: openRouter, model: nil, fallback: nil)
        TestSupport.expectEqual(pinned.model, "openai/gpt-oss-20b")
        TestSupport.expectEqual(pinned.fallback, "qwen/qwen3.8-27b")
        TestSupport.expect(pinned.flag, "The migration must record that it ran")
        let kept = migration(baseURL: openRouter, model: "openai/gpt-oss-20b", fallback: nil)
        TestSupport.expectEqual(kept.model, "openai/gpt-oss-20b")
        TestSupport.expectEqual(kept.fallback, "qwen/qwen3.8-27b")
        let keptPair = migration(baseURL: openRouter, model: "openai/gpt-oss-20b", fallback: "custom/synthetic")
        TestSupport.expectEqual(keptPair.model, "openai/gpt-oss-20b")
        TestSupport.expectEqual(keptPair.fallback, "custom/synthetic")
        // Blank keys would resolve to Groq's Qwen ID, so they are pinned like unset ones.
        let blankPinned = migration(baseURL: openRouter, model: " ", fallback: "")
        TestSupport.expectEqual(blankPinned.model, "openai/gpt-oss-20b")
        TestSupport.expectEqual(blankPinned.fallback, "qwen/qwen3.8-27b")
    }

    /// Switching the primary back to gpt-oss-20b on Groq, with the fallback on its default,
    /// moves the fallback to Qwen so a retry stays and Settings shows it. Nothing else moves.
    private static func testCleanupFallbackAfterSelectingPrimary() {
        let groq = "https://api.groq.com/openai/v1"
        let qwen = ModelConfiguration.defaultCleanupModel
        let gptOSS = ModelConfiguration.defaultCleanupFallbackModel
        func moved(_ primary: String, _ fallback: String, baseURL: String = groq) -> String? {
            ModelConfiguration.cleanupFallback(afterSelectingPrimary: primary, fallback: fallback, baseURL: baseURL)
        }

        TestSupport.expectEqual(moved(gptOSS, gptOSS), qwen)
        TestSupport.expectEqual(moved(" \(gptOSS) ", gptOSS), qwen)
        TestSupport.expectEqual(moved(qwen, qwen), gptOSS)
        // A blank primary loads as the default, Qwen.
        TestSupport.expectEqual(moved("", qwen), gptOSS)

        // A distinct fallback is kept, and so is a custom pair: no built-in model to move to.
        TestSupport.expectEqual(moved(gptOSS, qwen), nil)
        TestSupport.expectEqual(moved(qwen, gptOSS), nil)
        TestSupport.expectEqual(moved(qwen, ""), nil)
        TestSupport.expectEqual(moved("openai/gpt-oss-120b", "openai/gpt-oss-120b"), nil)
        TestSupport.expectEqual(moved("custom/synthetic", gptOSS), nil)

        // Another provider is never switched to a model the user did not pick.
        for other in ["https://openrouter.ai/api/v1", "http://localhost:11434/v1"] {
            TestSupport.expectEqual(moved(gptOSS, gptOSS, baseURL: other), nil)
            TestSupport.expectEqual(moved(qwen, qwen, baseURL: other), nil)
        }
    }

    /// A stored retired Llama 4 Scout fallback is replaced by a built-in model distinct from
    /// the primary on both endpoints, so the retry survives the load.
    private static func testRetiredCleanupFallbackReplacement() {
        let qwen = ModelConfiguration.defaultCleanupModel
        let gptOSS = ModelConfiguration.defaultCleanupFallbackModel
        func replacement(_ primary: String, _ baseURL: String) -> String {
            ModelConfiguration.replacementForRetiredCleanupFallback(primary: primary, baseURL: baseURL)
        }

        let groq = "https://api.groq.com/openai/v1"
        TestSupport.expectEqual(replacement(qwen, groq), gptOSS)
        TestSupport.expectEqual(replacement("", groq), gptOSS)
        TestSupport.expectEqual(replacement(gptOSS, groq), qwen)
        TestSupport.expectEqual(replacement(" \(gptOSS) ", groq), qwen)
        TestSupport.expectEqual(replacement("custom/synthetic", groq), gptOSS)

        // Off Groq the migration pins the primary to gpt-oss-20b, so the old Qwen mapping stays.
        for other in ["https://openrouter.ai/api/v1", "http://localhost:11434/v1"] {
            TestSupport.expectEqual(replacement(gptOSS, other), qwen)
            TestSupport.expectEqual(replacement("custom/synthetic", other), qwen)
            TestSupport.expectEqual(replacement(qwen, other), gptOSS)
            TestSupport.expectEqual(replacement(" ", other), gptOSS)
        }

        for baseURL in [groq, "https://openrouter.ai/api/v1"] {
            for primary in [qwen, gptOSS, "", "custom/synthetic"] {
                let resolvedPrimary = primary.isEmpty ? qwen : primary
                TestSupport.expect(
                    replacement(primary, baseURL) != resolvedPrimary,
                    "The replacement fallback must differ from the primary: \(primary)"
                )
            }
        }
    }

    private static func assertSameConfig(_ alias: String, _ canonical: String) {
        let aliasConfig = ModelConfiguration.config(for: alias)
        let canonicalConfig = ModelConfiguration.config(for: canonical)
        TestSupport.expectEqual(aliasConfig.maxCompletionTokens, canonicalConfig.maxCompletionTokens)
        TestSupport.expectEqual(aliasConfig.reasoningEffort, canonicalConfig.reasoningEffort)
        TestSupport.expectEqual(aliasConfig.includeReasoning, canonicalConfig.includeReasoning)
        TestSupport.expectEqual(aliasConfig.shouldStripThinkTags, canonicalConfig.shouldStripThinkTags)
    }
}
