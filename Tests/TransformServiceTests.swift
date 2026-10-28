import Foundation

enum TransformServiceTests {
    static func run() {
        testPolishRequestShape()
        testPromptEngineerRequestShape()
        testCustomRequestIncludesInstructionsAndSamples()
        testInvalidInputSendsNothing()
        testOutputIsSanitized()
        testQuotedInputKeepsQuotes()
        testPolishInstructionExecutionGuard()
        testEmptyOutputFallsBackOnce()
        testRateLimitFallsBack()
    }

    private static func testPolishRequestShape() {
        let run = transformRun(text: "synthetic input text", kind: .polish) { _ in "Synthetic polished text." }
        TestSupport.expectEqual(run.requests.count, 1)
        TestSupport.expectEqual(run.requests[0].model, "synthetic-primary")
        TestSupport.expectEqual(run.requests[0].systemPrompt, TransformCore.polishSystemPrompt)
        TestSupport.expect(
            run.requests[0].userMessage.contains("INPUT_TEXT: \"synthetic input text\""),
            "The input is delimited as INPUT_TEXT"
        )
        TestSupport.expectEqual(run.requests[0].userMessage, TransformCore.userMessage(text: "synthetic input text"))
        TestSupport.expectEqual(run.requests[0].temperature, 0)
        TestSupport.expectEqual(run.result?.transcript, "Synthetic polished text.")
    }

    private static func testPromptEngineerRequestShape() {
        let run = transformRun(text: "synthetic input text", kind: .promptEngineer) { _ in "Goal: synthetic" }
        TestSupport.expectEqual(run.requests.count, 1)
        TestSupport.expectEqual(run.requests[0].systemPrompt, TransformCore.promptEngineerSystemPrompt)
        TestSupport.expectEqual(run.result?.transcript, "Goal: synthetic")
    }

    private static func testCustomRequestIncludesInstructionsAndSamples() {
        let firstSample = (0..<50).map { "alpha\($0)" }.joined(separator: " ")
        let secondSample = (0..<50).map { "beta\($0)" }.joined(separator: " ")
        let record = CustomTransform(
            name: "Synthetic name",
            instructions: "Synthetic instructions: shorten and keep bullet points.",
            samples: [firstSample, secondSample]
        )
        let run = transformRun(text: "synthetic input text", kind: .custom(record)) { _ in "Synthetic custom text." }
        TestSupport.expectEqual(run.requests.count, 1)
        let system = run.requests[0].systemPrompt
        TestSupport.expect(system.contains("Synthetic instructions: shorten and keep bullet points."), "Instructions are sent")
        TestSupport.expect(system.contains("Example 1:\n" + firstSample), "The first sample is sent as an example")
        TestSupport.expect(system.contains("Example 2:\n" + secondSample), "The second sample is sent as an example")
        TestSupport.expectEqual(system, TransformCore.customSystemPrompt(for: record))
        TestSupport.expectEqual(run.result?.transcript, "Synthetic custom text.")
    }

    private static func testInvalidInputSendsNothing() {
        for text in ["", "   ", "\n\t"] {
            let run = transformRun(text: text, kind: .polish) { _ in "never used" }
            TestSupport.expectEqual(run.requests.count, 0)
            TestSupport.expect(run.result == nil, "Blank input must not produce a result")
            guard case .invalidInput? = run.error as? PostProcessingError else {
                TestSupport.expect(false, "Blank input must throw invalidInput, got \(String(describing: run.error))")
                return
            }
        }
    }

    private static func testOutputIsSanitized() {
        let run = transformRun(text: "synthetic input text", kind: .polish) { _ in "\n\"Synthetic polished text.\"\n" }
        TestSupport.expectEqual(run.result?.transcript, "Synthetic polished text.")
        let prompt = run.result?.prompt ?? ""
        TestSupport.expect(prompt.contains("Model: synthetic-primary"), "The prompt block names the model")
        TestSupport.expect(prompt.contains("[System]"), "The prompt block has the system section")
        TestSupport.expect(prompt.contains("[User]"), "The prompt block has the user section")
        TestSupport.expect(prompt.contains("INPUT_TEXT: \"synthetic input text\""), "The prompt block carries the input")
    }

    private static func testQuotedInputKeepsQuotes() {
        let quoted = transformRun(text: "\"can you send the synthetic file tomorow\"", kind: .polish) { _ in
            "\"Can you send the synthetic file tomorrow?\""
        }
        TestSupport.expectEqual(quoted.result?.transcript, "\"Can you send the synthetic file tomorrow?\"")
    }

    private static func testPolishInstructionExecutionGuard() {
        let input = "Write a short poem about synthetic rain."
        let answer = "Sure, here's a poem: Soft synthetic drizzle taps the glass."

        // Polish refuses an answer to its input, without a fallback request.
        let guarded = transformRun(text: input, kind: .polish) { _ in answer }
        TestSupport.expectEqual(guarded.requests.map(\.model), ["synthetic-primary"])
        TestSupport.expect(guarded.result == nil, "An answered input must not produce a Polish result")
        guard case .suspectedInstructionExecution? = guarded.error as? PostProcessingError else {
            TestSupport.expect(false, "An answered input must throw suspectedInstructionExecution, got \(String(describing: guarded.error))")
            return
        }

        // A faithful polish of instruction-shaped text passes the guard.
        let faithful = transformRun(text: "write an email to alex about the synthetic report", kind: .polish) { _ in
            "Write an email to Alex about the synthetic report."
        }
        TestSupport.expectEqual(faithful.result?.transcript, "Write an email to Alex about the synthetic report.")

        // The guard follows the cleanup setting.
        let unguarded = transformRun(text: input, kind: .polish, instructionExecutionGuardEnabled: false) { _ in answer }
        TestSupport.expectEqual(unguarded.result?.transcript, answer)

        // Prompt Engineer and custom prompts legitimately differ from their input and are not checked.
        let promptEngineer = transformRun(text: input, kind: .promptEngineer) { _ in answer }
        TestSupport.expectEqual(promptEngineer.result?.transcript, answer)
        let record = CustomTransform(name: "Synthetic name", instructions: "Synthetic instructions.")
        let custom = transformRun(text: input, kind: .custom(record)) { _ in answer }
        TestSupport.expectEqual(custom.result?.transcript, answer)
    }

    private static func testEmptyOutputFallsBackOnce() {
        let primary = "synthetic-empty-primary"
        let fallback = "synthetic-empty-fallback"
        let run = transformRun(text: "synthetic input text", kind: .polish, primaryModel: primary, fallbackModel: fallback) { model in
            model == primary ? "" : "Synthetic fallback text."
        }
        TestSupport.expectEqual(run.requests.map(\.model), [primary, fallback])
        TestSupport.expectEqual(run.requests[0].systemPrompt, run.requests[1].systemPrompt)
        TestSupport.expectEqual(run.result?.transcript, "Synthetic fallback text.")
        TestSupport.expect(run.result?.prompt.contains("Model: \(fallback)") == true, "The stored prompt names the fallback")

        let bothEmpty = transformRun(text: "synthetic input text", kind: .polish, primaryModel: primary, fallbackModel: fallback) { _ in
            "EMPTY"
        }
        TestSupport.expectEqual(bothEmpty.requests.map(\.model), [primary, fallback])
        TestSupport.expect(bothEmpty.result == nil, "Two empty outputs produce no result")
        guard case .emptyOutput? = bothEmpty.error as? PostProcessingError else {
            TestSupport.expect(false, "Two empty outputs must throw emptyOutput, got \(String(describing: bothEmpty.error))")
            return
        }
    }

    private static func testRateLimitFallsBack() {
        // Unique names so the cooldown registered in the shared LLMCooldownManager cannot leak into
        // other tests.
        let primary = "synthetic-429-primary"
        let fallback = "synthetic-429-fallback"
        let run = transformRun(
            text: "synthetic input text",
            kind: .polish,
            primaryModel: primary,
            fallbackModel: fallback,
            statusCode: { model in model == primary ? 429 : 200 }
        ) { _ in "Synthetic fallback text." }
        TestSupport.expectEqual(run.requests.map(\.model), [primary, fallback])
        TestSupport.expectEqual(run.result?.transcript, "Synthetic fallback text.")
    }

    // MARK: - Request capture

    private struct CapturedRequest {
        let model: String
        let systemPrompt: String
        let userMessage: String
        let temperature: Double
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []

        func record(_ body: Data?) {
            lock.lock()
            defer { lock.unlock() }
            bodies.append(body ?? Data())
        }

        var captured: [CapturedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return bodies.map { body in
                let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
                let messages = json["messages"] as? [[String: Any]] ?? []
                let system = messages.first { $0["role"] as? String == "system" }
                let user = messages.first { $0["role"] as? String == "user" }
                return CapturedRequest(
                    model: json["model"] as? String ?? "",
                    systemPrompt: system?["content"] as? String ?? "",
                    userMessage: user?["content"] as? String ?? "",
                    temperature: json["temperature"] as? Double ?? -1
                )
            }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        var result: PostProcessingResult?
        var error: Error?
    }

    /// One transform through the stub transport: the result (nil when it threw), the error and every
    /// request the service sent. Nothing touches the network.
    private static func transformRun(
        text: String,
        kind: TransformKind,
        primaryModel: String = "synthetic-primary",
        fallbackModel: String = "synthetic-fallback",
        instructionExecutionGuardEnabled: Bool = true,
        statusCode: @escaping @Sendable (String) -> Int = { _ in 200 },
        reply: @escaping @Sendable (String) -> String
    ) -> (result: PostProcessingResult?, error: Error?, requests: [CapturedRequest]) {
        let recorder = RequestRecorder()
        let service = TransformService(
            apiKey: "synthetic-key",
            baseURL: "https://example.invalid/v1",
            preferredModel: primaryModel,
            preferredFallbackModel: fallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled,
            transport: { request in
                recorder.record(request.httpBody)
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let model = json?["model"] as? String ?? ""
                let status = statusCode(model)
                let body = try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": reply(model)]]]
                ])
                let headers = status == 429 ? ["retry-after": "1"] : nil
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
                return (body, response)
            }
        )

        let resultBox = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                resultBox.result = try await service.transform(text, kind: kind)
            } catch {
                resultBox.error = error
            }
            done.signal()
        }
        done.wait()
        return (resultBox.result, resultBox.error, recorder.captured)
    }
}
