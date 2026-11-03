import Foundation

/// Runs one transform (Polish, Prompt Engineer or a custom prompt) through the post-processing
/// endpoint. The request, fallback, cooldown and timeout handling mirror
/// `PostProcessingService.commandTransform`; only the chosen text leaves the machine, with no
/// context section, screenshot or custom vocabulary.
final class TransformService {
    private let apiKey: String
    private let baseURL: String
    private let preferredModel: String
    private let preferredFallbackModel: String
    private let instructionExecutionGuardEnabled: Bool
    private let transport: PostProcessingService.Transport
    private let defaultModel = "openai/gpt-oss-20b"
    private let defaultFallbackModel = "qwen/qwen3.8-27b"
    private let defaultModelReasoningEffort = "low"
    private let maxCompletionTokens = 4096
    private var timeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "post_processing_timeout_seconds")
        return override > 0 ? override : 20
    }

    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        preferredModel: String = "",
        preferredFallbackModel: String = "",
        instructionExecutionGuardEnabled: Bool = true,
        transport: @escaping PostProcessingService.Transport = { try await LLMAPITransport.data(for: $0) }
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.preferredModel = preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredFallbackModel = preferredFallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.transport = transport
    }

    /// Blank text throws `invalidInput` before any request; otherwise the same timeout as cleanup applies.
    func transform(_ text: String, kind: TransformKind) async throws -> PostProcessingResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessingError.invalidInput("Transform input must not be empty")
        }

        let timeoutSeconds = timeoutSeconds
        return try await withThrowingTaskGroup(of: PostProcessingResult.self) { group in
            group.addTask { [weak self] in
                guard let self else {
                    throw PostProcessingError.invalidResponse("Transform service deallocated")
                }
                return try await self.transformWithFallback(text: text, kind: kind)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw PostProcessingError.requestTimedOut(timeoutSeconds)
            }

            do {
                guard let result = try await group.next() else {
                    throw PostProcessingError.invalidResponse("No transform result")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func transformWithFallback(text: String, kind: TransformKind) async throws -> PostProcessingResult {
        var primaryModel = resolvedPrimaryModel()
        let retryModel = resolvedRetryModel(for: primaryModel)

        // Circuit breaker: pick a model that isn't cooling down. When BOTH are cooling, fail instead of
        // returning the input unchanged: a no-op must never be reported as a successful transform.
        guard let availableModel = await LLMCooldownManager.shared.effectivePrimary(primaryModel, fallback: retryModel) else {
            throw PostProcessingError.requestFailed(429, "All post-processing models are cooling down")
        }
        primaryModel = availableModel

        do {
            return try await perform(text: text, kind: kind, model: primaryModel)
        } catch let error as PostProcessingError {
            // Same fallback policy as Edit Mode: retry once on the other model for a rate limit (the
            // cooldown was already registered inside perform()) or an empty output, never the same model.
            let shouldFallback: Bool
            switch error {
            case .rateLimited, .emptyOutput:
                shouldFallback = true
            default:
                shouldFallback = false
            }

            guard shouldFallback, let retryModel, primaryModel != retryModel else {
                throw error
            }

            return try await perform(text: text, kind: kind, model: retryModel)
        }
    }

    private func resolvedPrimaryModel() -> String {
        preferredModel.isEmpty ? defaultModel : preferredModel
    }

    private func resolvedRetryModel(for primaryModel: String) -> String? {
        if !preferredFallbackModel.isEmpty {
            return preferredFallbackModel == primaryModel ? nil : preferredFallbackModel
        }
        if primaryModel == defaultModel {
            return defaultFallbackModel
        }
        if primaryModel == defaultFallbackModel {
            return defaultModel
        }
        return nil
    }

    private func perform(text: String, kind: TransformKind, model: String) async throws -> PostProcessingResult {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        let systemPrompt = TransformCore.systemPrompt(for: kind)
        let userMessage = TransformCore.userMessage(text: text)

        let promptForDisplay = """
Model: \(model)

[System]
\(systemPrompt)

[User]
\(userMessage)
"""

        var payload: [String: Any] = [
            "model": model,
            "temperature": 0.0,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userMessage
                ]
            ]
        ]
        let config = ModelConfiguration.config(for: model)
        payload.merge(ModelConfiguration.nonContentRequestOptions(
            model: model,
            temperature: 0,
            defaultModel: defaultModel,
            defaultReasoningEffort: defaultModelReasoningEffort,
            defaultMaxCompletionTokens: maxCompletionTokens
        )) { _, new in new }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await transport(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PostProcessingError.invalidResponse("No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            // Register the cooldown for whichever model hit the limit, then surface the error.
            if httpResponse.statusCode == 429 {
                let cooldown = LLMCooldownManager.rateLimitCooldown(from: httpResponse)
                await LLMCooldownManager.shared.setCooldown(model, retryAfterSeconds: cooldown.seconds, persist: cooldown.isDaily)
                throw PostProcessingError.rateLimited(model: model, retryAfter: cooldown.seconds)
            }
            let message = String(data: data, encoding: .utf8) ?? ""
            throw PostProcessingError.requestFailed(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            throw PostProcessingError.invalidResponse("Missing choices[0].message.content")
        }

        var content = rawContent
        if config.shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }

        // Trims, strips one pair of wrapping quotes the input did not have and maps EMPTY to "", which
        // then counts as no output so the fallback model gets its one try.
        let sanitizedTranscript = TransformCore.sanitizedOutput(content, input: text)
        guard !sanitizedTranscript.isEmpty else {
            throw PostProcessingError.emptyOutput
        }
        // Polish returns its input reworded, so the cleanup guard applies: an output that reads like an
        // answer to the input is refused (no fallback) and the caller keeps the untransformed text.
        // Prompt Engineer and custom prompts legitimately differ from their input and are not checked.
        if instructionExecutionGuardEnabled, kind == .polish,
           TranscriptOutputSanitizer.appearsToHaveExecutedInstruction(
               rawTranscript: text,
               cleanedTranscript: sanitizedTranscript,
               outputLanguage: ""
           ) {
            throw PostProcessingError.suspectedInstructionExecution
        }

        return PostProcessingResult(
            transcript: sanitizedTranscript,
            prompt: promptForDisplay
        )
    }
}
