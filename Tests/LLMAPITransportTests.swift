import Foundation

private final class StubLLMURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { fatalError("Missing test handler") }
        Self.requests.append(request)
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Fails the queued requests with the given URL errors, then answers 200 with a valid completion.
private final class DroppedConnectionURLProtocol: URLProtocol {
    static var failures: [URLError.Code] = []
    static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        if !Self.failures.isEmpty {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failures.removeFirst()))
            return
        }
        let data = Data("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]}".utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Answers provider.invalid with a 301 to another host and records every request it sees.
/// The 301 is also delivered as a response: when the task delegate refuses the redirect,
/// the loading system expects the original response to finish the task.
private final class RedirectingURLProtocol: URLProtocol {
    static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requestedURLs.append(url.absoluteString)
        if url.host == "provider.invalid" {
            let target = URL(string: "https://elsewhere.invalid/")!
            let response = HTTPURLResponse(
                url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func bodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4096)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

enum LLMAPITransportTests {
    static func run() async {
        func perform(_ replies: [(Int, String)], body payload: [String: Any] = ["model": "fixture", "temperature": 0, "top_p": 0.7, "max_completion_tokens": 128, "messages": []], endpoint: String = UUID().uuidString, cache: TemperatureCapabilityCache = TemperatureCapabilityCache(defaults: UserDefaults(suiteName: "transport-\(UUID().uuidString)")!)) async throws -> [URLRequest] {
            StubLLMURLProtocol.requests = []
            var remaining = replies
            StubLLMURLProtocol.handler = { _ in
                let next = remaining.removeFirst()
                return (next.0, Data(next.1.utf8))
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubLLMURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let body = try JSONSerialization.data(withJSONObject: payload)
            var request = URLRequest(url: URL(string: "https://provider.invalid/\(endpoint)/chat")!)
            request.httpMethod = "POST"
            request.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (_, response) = try await LLMAPITransport.data(for: request, using: session, cache: cache)
            session.invalidateAndCancel()
            _ = response
            return StubLLMURLProtocol.requests
        }

        let rejected = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":\"temperature\",\"message\":\"temperature is unsupported\"}}"
        let accepted = "{\"choices\":[]}"
        let retry = try! await perform([(400, rejected), (200, accepted)])
        TestSupport.expect(retry.count == 2, "Unsupported temperature should retry once")
        let original = try! JSONSerialization.jsonObject(with: bodyData(retry[0])!) as! [String: Any]
        let retried = try! JSONSerialization.jsonObject(with: bodyData(retry[1])!) as! [String: Any]
        TestSupport.expect(original["temperature"] != nil, "Initial body retains temperature")
        TestSupport.expect(retried["temperature"] == nil && retried["model"] as? String == "fixture" && retried["messages"] != nil && retried["top_p"] as? Double == 0.7 && retried["max_completion_tokens"] as? Int == 128, "Retry removes only temperature")
        TestSupport.expect(retry.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token" && $0.value(forHTTPHeaderField: "Content-Type") == "application/json" }, "Retry preserves authorization and content type")

        let openAIStyle = "{\"error\":{\"code\":\"unsupported_value\",\"param\":\"temperature\",\"message\":\"Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported.\"}}"
        let openAIRetry = try! await perform([(400, openAIStyle), (200, accepted)])
        TestSupport.expect(openAIRetry.count == 2, "OpenAI unsupported_value response retries once")

        let otherParameter = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":\"max_tokens\",\"message\":\"Unsupported parameter\"}}"
        let wrongParam = try! await perform([(400, otherParameter)])
        TestSupport.expect(wrongParam.count == 1, "Unsupported parameter other than temperature does not retry")

        let nullParam = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":null,\"message\":\"temperature is not supported with this model\"}}"
        let nullParamResult = try! await perform([(400, nullParam)])
        TestSupport.expect(nullParamResult.count == 1, "Missing temperature parameter identity does not retry")

        let mixedParameter = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":null,\"message\":\"temperature is supported; top_p is unsupported\"}}"
        let mixedParameterResult = try! await perform([(400, mixedParameter)])
        TestSupport.expect(mixedParameterResult.count == 1, "Mixed-parameter rejection does not remove temperature")

        let unrelatedMessage = "{\"error\":{\"code\":\"unsupported_parameter\",\"param\":\"temperature\",\"message\":\"value must be between 0 and 2\"}}"
        let unrelatedMessageResult = try! await perform([(400, unrelatedMessage)])
        TestSupport.expect(unrelatedMessageResult.count == 1, "Temperature validation errors do not imply unsupported capability")

        let success = try! await perform([(200, accepted)])
        TestSupport.expect(success.count == 1, "Successful call does not retry")
        let retained = try! JSONSerialization.jsonObject(with: bodyData(success[0])!) as! [String: Any]
        TestSupport.expect(retained["temperature"] != nil, "Compatible call retains temperature")

        let unrelated = try! await perform([(400, "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"bad key\"}}")])
        TestSupport.expect(unrelated.count == 1, "Unrelated 400 does not retry")
        let noTemperature = try! await perform([(400, rejected)], body: ["model": "fixture", "messages": []])
        TestSupport.expect(noTemperature.count == 1, "Request without temperature does not retry")

        let rejectedAgain = try! await perform([(400, rejected), (400, rejected)])
        TestSupport.expect(rejectedAgain.count == 2, "Second rejection stops after one retry")

        let persistentCache = TemperatureCapabilityCache(defaults: UserDefaults(suiteName: "transport-persistent-\(UUID().uuidString)")!)
        let endpoint = UUID().uuidString
        let first = try! await perform([(400, rejected), (200, accepted)], endpoint: endpoint, cache: persistentCache)
        let subsequent = try! await perform([(200, accepted)], endpoint: endpoint, cache: persistentCache)
        let omittedBody = try! JSONSerialization.jsonObject(with: bodyData(subsequent[0])!) as! [String: Any]
        TestSupport.expect(first.count == 2 && subsequent.count == 1 && omittedBody["temperature"] == nil, "Runtime rejection is cached and subsequent call omits temperature")

        let staleSuite = "transport-stale-\(UUID().uuidString)"
        let staleDefaults = UserDefaults(suiteName: staleSuite)!
        defer { staleDefaults.removePersistentDomain(forName: staleSuite) }
        let staleCache = TemperatureCapabilityCache(defaults: staleDefaults)
        let sharedEndpoint = UUID().uuidString
        var sharedRequest = URLRequest(url: URL(string: "https://provider.invalid/\(sharedEndpoint)/chat")!)
        sharedRequest.setValue("Bearer synthetic-test-token", forHTTPHeaderField: "Authorization")
        sharedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sharedRequest.httpBody = try! JSONSerialization.data(withJSONObject: ["model": "fixture", "temperature": 0, "top_p": 0.7, "max_completion_tokens": 128, "messages": []])
        let staleObservation = staleCache.beginObservation(for: sharedRequest)
        _ = try! await perform([(400, rejected), (200, accepted)], endpoint: sharedEndpoint, cache: staleCache)
        staleCache.record(.supported, for: sharedRequest, observation: staleObservation)
        TestSupport.expect(staleCache.capability(for: sharedRequest) == .unsupported, "Cache ignores stale success after newer runtime rejection")

        let supportedCache = TemperatureCapabilityCache(defaults: UserDefaults(suiteName: "transport-supported-\(UUID().uuidString)")!)
        let supportedEndpoint = UUID().uuidString
        let validCompletion = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]}"
        _ = try! await perform([(200, validCompletion)], endpoint: supportedEndpoint, cache: supportedCache)
        let supportedCall = try! await perform([(200, validCompletion)], endpoint: supportedEndpoint, cache: supportedCache)
        let supportedBody = try! JSONSerialization.jsonObject(with: bodyData(supportedCall[0])!) as! [String: Any]
        TestSupport.expect(supportedCall.count == 1 && supportedBody["temperature"] != nil, "Successful supported response preserves temperature on later calls")

        for (status, body, label) in [
            (401, "{\"error\":{\"code\":\"invalid_api_key\",\"message\":\"bad key\"}}", "auth"),
            (429, "{\"error\":{\"code\":\"rate_limit_exceeded\"}}", "rate limit"),
            (400, "{\"error\":{\"code\":\"invalid_request\",\"message\":\"bad request\"}}", "unrelated 400")
        ] {
            let isolated = TemperatureCapabilityCache(defaults: UserDefaults(suiteName: "transport-\(label)-\(UUID().uuidString)")!)
            let isolatedEndpoint = UUID().uuidString
            _ = try! await perform([(status, body)], endpoint: isolatedEndpoint, cache: isolated)
            let next = try! await perform([(200, validCompletion)], endpoint: isolatedEndpoint, cache: isolated)
            let nextBody = try! JSONSerialization.jsonObject(with: bodyData(next[0])!) as! [String: Any]
            TestSupport.expect(next.count == 1 && nextBody["temperature"] != nil, "\(label) errors do not poison capability cache")
        }

        testPreconnectRequest()
        await testPreconnectRefusesRedirects()
        await testKeepAliveRetry()
        testKeepAliveConfiguration()
    }

    /// The shared session adds no timeout ceiling of its own, so a hidden timeout override
    /// above the old 300 s cap still governs cleanup, Edit Mode and translation; and it keeps
    /// no cookies, cache or credentials between requests.
    private static func testKeepAliveConfiguration() {
        let configuration = LLMAPITransport.keepAliveConfiguration()
        TestSupport.expectEqual(configuration.timeoutIntervalForResource, 7 * 24 * 60 * 60)
        TestSupport.expect(
            configuration.timeoutIntervalForResource > 3_600,
            "The resource timeout must stay above any hidden timeout override"
        )
        TestSupport.expect(configuration.httpCookieStorage == nil, "No cookie storage")
        TestSupport.expect(!configuration.httpShouldSetCookies, "No cookies sent")
        TestSupport.expectEqual(configuration.httpCookieAcceptPolicy, .never)
        TestSupport.expect(configuration.urlCache == nil, "No response cache")
        TestSupport.expect(configuration.urlCredentialStorage == nil, "No credential storage")
        TestSupport.expectEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    /// The pre-connect only warms the configured host: a redirect to another one is not
    /// followed. The control request shows the stub's redirect is followed by default.
    private static func testPreconnectRefusesRedirects() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        RedirectingURLProtocol.requestedURLs = []
        _ = try? await session.data(for: URLRequest(url: URL(string: "https://provider.invalid/")!))
        TestSupport.expectEqual(
            RedirectingURLProtocol.requestedURLs,
            ["https://provider.invalid/", "https://elsewhere.invalid/"]
        )

        RedirectingURLProtocol.requestedURLs = []
        await LLMAPITransport.preconnect(baseURL: "https://provider.invalid/openai/v1", using: session)
        TestSupport.expectEqual(RedirectingURLProtocol.requestedURLs, ["https://provider.invalid/"])

        RedirectingURLProtocol.requestedURLs = []
        await LLMAPITransport.preconnect(baseURL: "http://provider.invalid/v1", using: session)
        TestSupport.expectEqual(RedirectingURLProtocol.requestedURLs, [])
    }

    /// The pre-connect carries nothing but the provider's origin: no path, query, user info,
    /// key, body or header of FreeFlow's own. URLSession adds its defaults (Host, Accept,
    /// Accept-Language, Accept-Encoding, User-Agent, Connection) only when it sends the
    /// request, as for every cleanup POST, so they cannot show here; the list is documented
    /// on `preconnectRequest`.
    private static func testPreconnectRequest() {
        let groq = LLMAPITransport.preconnectRequest(baseURL: " https://api.groq.com/openai/v1 ")
        TestSupport.expectEqual(groq?.url?.absoluteString, "https://api.groq.com/")
        TestSupport.expectEqual(groq?.httpMethod, "HEAD")
        TestSupport.expect(groq?.httpBody == nil && groq?.httpBodyStream == nil, "A pre-connect has no body")
        TestSupport.expect(
            groq?.allHTTPHeaderFields?.isEmpty ?? true,
            "FreeFlow sets no header of its own on a pre-connect; only URLSession's defaults are sent"
        )
        TestSupport.expect(groq?.value(forHTTPHeaderField: "Authorization") == nil, "A pre-connect never carries the key")
        TestSupport.expectEqual(groq?.timeoutInterval, LLMAPITransport.preconnectTimeoutSeconds)
        TestSupport.expectEqual(groq?.cachePolicy, .reloadIgnoringLocalCacheData)

        let stripped = LLMAPITransport.preconnectRequest(baseURL: "https://user:secret@example.invalid:8443/v1?x=1")
        TestSupport.expectEqual(stripped?.url?.absoluteString, "https://example.invalid:8443/")

        for invalid in ["http://localhost:1234/v1", "", "not a url"] {
            TestSupport.expect(LLMAPITransport.preconnectRequest(baseURL: invalid) == nil, "No pre-connect for: \(invalid)")
        }
    }

    /// A pooled connection that died is retried once; any other failure is not.
    private static func testKeepAliveRetry() async {
        let cases: [(failures: [URLError.Code], requests: Int, succeeds: Bool)] = [
            ([.networkConnectionLost], 2, true),
            ([.networkConnectionLost, .networkConnectionLost], 2, false),
            ([.timedOut], 1, false),
            ([], 1, true)
        ]
        for testCase in cases {
            DroppedConnectionURLProtocol.failures = testCase.failures
            DroppedConnectionURLProtocol.requestCount = 0
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DroppedConnectionURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let suite = "transport-keepalive-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let cache = TemperatureCapabilityCache(defaults: defaults)
            var request = URLRequest(url: URL(string: "https://provider.invalid/\(UUID().uuidString)/chat")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try! JSONSerialization.data(withJSONObject: ["model": "fixture", "temperature": 0, "messages": []])
            let succeeded: Bool
            do {
                _ = try await LLMAPITransport.keepAliveData(for: request, using: session, cache: cache)
                succeeded = true
            } catch {
                succeeded = false
            }
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            TestSupport.expectEqual(succeeded, testCase.succeeds)
            TestSupport.expectEqual(DroppedConnectionURLProtocol.requestCount, testCase.requests)
        }
    }
}
