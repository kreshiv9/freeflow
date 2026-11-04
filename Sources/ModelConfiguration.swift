import Foundation

public struct ModelConfig {
    public let maxCompletionTokens: Int?
    public let reasoningEffort: String?
    public let includeReasoning: Bool?
    public let shouldStripThinkTags: Bool
}

public struct ModelConfiguration {
    public static func nonContentRequestOptions(
        model: String,
        temperature: Double,
        defaultModel: String? = nil,
        defaultReasoningEffort: String? = nil,
        defaultMaxCompletionTokens: Int? = nil
    ) -> [String: Any] {
        var options: [String: Any] = ["model": model, "temperature": temperature]
        let config = config(for: model)
        if let maxTokens = config.maxCompletionTokens {
            options["max_completion_tokens"] = maxTokens
        } else if model == defaultModel, let defaultMaxCompletionTokens {
            options["max_completion_tokens"] = defaultMaxCompletionTokens
        }
        if let effort = config.reasoningEffort {
            options["reasoning_effort"] = effort
        } else if model == defaultModel, let defaultReasoningEffort {
            options["reasoning_effort"] = defaultReasoningEffort
        }
        if let include = config.includeReasoning {
            options["include_reasoning"] = include
        } else if model == defaultModel {
            options["include_reasoning"] = false
        }
        return options
    }

    public static let llmModels = [
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-safeguard-20b",
        "qwen/qwen3.8-27b"
    ]

    /// Cleanup defaults. Qwen 3.8 is the only Groq model that turns reasoning fully off
    /// ("none"); gpt-oss always reasons first, so it is the fallback, which keeps the
    /// primary and fallback distinct.
    static let defaultCleanupModel = "qwen/qwen3.8-27b"
    static let defaultCleanupFallbackModel = "openai/gpt-oss-20b"
    static let previousDefaultCleanupModel = "openai/gpt-oss-20b"
    static let previousDefaultCleanupFallbackModel = "qwen/qwen3.8-27b"
    static let cleanupDefaultMigrationKey = "post_processing_default_qwen_migrated"

    // MARK: - Vision-capable models

    /// Models that accept image input. The context model must support vision for screenshot analysis to work.
    public static let visionModels = [
        "qwen/qwen3.8-27b"
    ]

    public static let transcriptionModels = [
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ]

    static func isGroqEndpoint(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "api.groq.com"
            && url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "openai/v1"
    }

    /// Only migrate retired IDs on Groq's own endpoint. Other providers can
    /// still serve Qwen 3.6 under the same model name.
    static func migrateGroqSelection(key: String, baseURL: String, defaults: UserDefaults) {
        guard isGroqEndpoint(baseURL),
              let stored = defaults.string(forKey: key) else { return }
        let model = stored.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if model == "qwen/qwen3.6-27b" || model == "qwen3.6-27b" {
            defaults.set("qwen/qwen3.8-27b", forKey: key)
        }
    }

    /// One-time move of the cleanup default from gpt-oss-20b to Qwen 3.8. A stored value
    /// equal to the old default cannot be told apart from an explicit choice, so the flag
    /// is set first and the move never repeats: switching back in Settings sticks. Any
    /// other stored model is kept. Off Groq, unset keys are pinned to the old pair so
    /// another provider is never sent Groq's Qwen ID.
    static func migrateCleanupDefault(modelKey: String, fallbackKey: String, baseURL: String, defaults: UserDefaults) {
        guard !defaults.bool(forKey: cleanupDefaultMigrationKey) else { return }
        defaults.set(true, forKey: cleanupDefaultMigrationKey)

        // A blank value (Settings can store one) loads as the default, so it counts as unset.
        func storedModel(_ key: String) -> String? {
            guard let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !stored.isEmpty else { return nil }
            return stored
        }
        let stored = storedModel(modelKey)
        guard stored == nil || stored == previousDefaultCleanupModel else { return }

        guard isGroqEndpoint(baseURL) else {
            if stored == nil {
                defaults.set(previousDefaultCleanupModel, forKey: modelKey)
            }
            if storedModel(fallbackKey) == nil {
                defaults.set(previousDefaultCleanupFallbackModel, forKey: fallbackKey)
            }
            return
        }

        if stored != nil {
            defaults.set(defaultCleanupModel, forKey: modelKey)
        }
        // The primary is now Qwen; a fallback still on the old default would equal it and
        // remove the retry.
        if storedModel(fallbackKey) == previousDefaultCleanupFallbackModel {
            defaults.set(defaultCleanupFallbackModel, forKey: fallbackKey)
        }
    }

    /// The fallback to store after the cleanup primary changes, or nil to keep it. A fallback
    /// equal to the primary means no retry, so on Groq a primary that lands on the fallback's
    /// built-in model (switching back to gpt-oss-20b, the default fallback) moves the fallback
    /// to the other built-in model: the retry stays and Settings shows the model retried.
    /// Other providers are never sent a model the user did not pick.
    static func cleanupFallback(afterSelectingPrimary primary: String, fallback: String, baseURL: String) -> String? {
        guard isGroqEndpoint(baseURL) else { return nil }
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank primary loads as the default.
        let resolvedPrimary = trimmedPrimary.isEmpty ? defaultCleanupModel : trimmedPrimary
        guard fallback.trimmingCharacters(in: .whitespacesAndNewlines) == resolvedPrimary else { return nil }
        switch resolvedPrimary {
        case defaultCleanupModel: return defaultCleanupFallbackModel
        case defaultCleanupFallbackModel: return defaultCleanupModel
        default: return nil
        }
    }

    /// The fallback that replaces a stored retired Llama 4 Scout fallback: the endpoint's
    /// default fallback (gpt-oss-20b on Groq, Qwen 3.8 elsewhere, as before), or the other
    /// built-in model when the primary already is that one, so the retry stays.
    static func replacementForRetiredCleanupFallback(primary: String, baseURL: String) -> String {
        let trimmedPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank primary loads as the default.
        let resolvedPrimary = trimmedPrimary.isEmpty ? defaultCleanupModel : trimmedPrimary
        let preferred = isGroqEndpoint(baseURL) ? defaultCleanupFallbackModel : previousDefaultCleanupFallbackModel
        guard resolvedPrimary == preferred else { return preferred }
        return preferred == defaultCleanupModel ? defaultCleanupFallbackModel : defaultCleanupModel
    }

    public static func config(for model: String) -> ModelConfig {
        var cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        // Normalize providerless aliases
        if cleanModel == "qwen3-32b" { cleanModel = "qwen/qwen3-32b" }
        else if cleanModel == "qwen3.6-27b" { cleanModel = "qwen/qwen3.6-27b" }
        else if cleanModel == "qwen3.8-27b" { cleanModel = "qwen/qwen3.8-27b" }
        else if cleanModel == "gpt-oss-20b" { cleanModel = "openai/gpt-oss-20b" }
        else if cleanModel == "gpt-oss-120b" { cleanModel = "openai/gpt-oss-120b" }
        else if cleanModel == "gpt-oss-safeguard-20b" { cleanModel = "openai/gpt-oss-safeguard-20b" }
        
        if cleanModel == "openai/gpt-oss-20b" {
            return ModelConfig(
                maxCompletionTokens: 4096,
                reasoningEffort: "low",
                includeReasoning: false,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-120b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "openai/gpt-oss-safeguard-20b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "qwen/qwen3-32b" {
            // Model that requires sanitization of thought tags
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "qwen/qwen3.8-27b" || cleanModel == "qwen/qwen3.6-27b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: "none",
                includeReasoning: false,
                shouldStripThinkTags: true
            )
        } else if cleanModel == "llama-3.1-8b-instant" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "llama-3.3-70b-versatile" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-4-scout-17b-16e-instruct" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-22m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "meta-llama/llama-prompt-guard-2-86m" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "allam-2-7b" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-arabic-saudi" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "canopylabs/orpheus-v1-english" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "groq/compound-mini" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        } else if cleanModel == "whisper-large-v3-turbo" {
            return ModelConfig(
                maxCompletionTokens: nil,
                reasoningEffort: nil,
                includeReasoning: nil,
                shouldStripThinkTags: false
            )
        }
        
        // Generic fallback for any model not explicitly listed above
        return ModelConfig(
            maxCompletionTokens: nil,
            reasoningEffort: nil,
            includeReasoning: nil,
            shouldStripThinkTags: false
        )
    }
    
    /// Utility method to remove <think>...</think> tags and everything inside them.
    /// This also handles unclosed tags gracefully (e.g. if the model runs out of tokens).
    public static func stripThinkTags(_ text: String) -> String {
        var cleaned = text
        
        // First, replace fully closed tags: <think>...</think>
        // We use a group with + to catch multiple consecutive think blocks.
        let closedRegexPattern = "^(?:\\s*<think>[\\s\\S]*?</think>)+"
        if let regex = try? NSRegularExpression(pattern: closedRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        // Next, if there is an unclosed <think> tag remaining (meaning it started thinking but got truncated),
        // we strip from the opening <think> tag to the very end of the string.
        let openRegexPattern = "^\\s*<think>[\\s\\S]*$"
        if let regex = try? NSRegularExpression(pattern: openRegexPattern, options: []) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
