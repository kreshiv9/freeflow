import Foundation

enum LLMAPITransport {
    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // URLSession's resource timeout is session-scoped, while each caller
        // already puts its configured timeout on the URLRequest. Keep both
        // session timers aligned with that request instead of applying one
        // global timeout to every provider and operation.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    private static func timeout(for request: URLRequest) -> TimeInterval {
        let requestTimeout = request.timeoutInterval
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return 60
        }
        return requestTimeout
    }

    /// URLSession's own 7-day resource default, set explicitly so the shared session adds no
    /// ceiling: every caller sets the request's own timeoutInterval, which wins over the
    /// session's 60 s request timeout, and enforces its own deadline, so a
    /// post_processing_timeout_seconds above the old 300 s cap still applies.
    static let keepAliveResourceTimeoutSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// One app-lifetime session so cleanup reuses a warm TCP/TLS connection instead of
    /// paying a handshake per call.
    private static let sharedSession = URLSession(configuration: keepAliveConfiguration())

    /// Cookies, cache and credential storage are off, so the pooled connection is the only
    /// state kept between requests.
    static func keepAliveConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = keepAliveResourceTimeoutSeconds
        return configuration
    }

    static func keepAliveData(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await keepAliveData(for: request, using: sharedSession, cache: TemperatureCapabilityCache.shared)
    }

    /// An idle pooled connection can die (sleep, network change) and URLSession never
    /// replays a POST by itself, so a lost connection is retried once on a fresh one.
    static func keepAliveData(
        for request: URLRequest,
        using session: URLSession,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        do {
            return try await data(for: request, using: session, cache: cache)
        } catch let error as URLError where error.code == .networkConnectionLost {
            try Task.checkCancellation()
            return try await data(for: request, using: session, cache: cache)
        }
    }

    static let preconnectTimeoutSeconds: TimeInterval = 5

    /// A HEAD to the https origin root of `baseURL`: no path, query, user info, Authorization,
    /// API key, body or header of FreeFlow's own. What reaches the provider is `HEAD /`, Host,
    /// and the defaults URLSession adds to every request, cleanup POSTs included: `Accept: */*`,
    /// `Accept-Language` from the macOS preferred languages (such as `en-US,en;q=0.9`),
    /// `Accept-Encoding` (`gzip, deflate`; CFNetwork may add `br` over https), a `User-Agent`
    /// of the app's bundle name and build number with the CFNetwork and Darwin versions, and
    /// `Connection: keep-alive` on HTTP/1.1. Nil for anything but an https URL with a host.
    static func preconnectRequest(baseURL: String) -> URLRequest? {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.percentEncodedHost, !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.percentEncodedHost = host
        origin.port = components.port
        origin.path = "/"
        guard let url = origin.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: preconnectTimeoutSeconds)
        request.httpMethod = "HEAD"
        return request
    }

    /// Opens the shared session's connection to the provider while the user is still
    /// speaking, so the cleanup POST skips the handshake. Sends no content and no key, only
    /// the request `preconnectRequest` describes; refuses redirects, ignores the response and
    /// logs nothing.
    static func preconnect(baseURL: String) {
        guard preconnectRequest(baseURL: baseURL) != nil else { return }
        Task.detached(priority: .utility) {
            await preconnect(baseURL: baseURL, using: sharedSession)
        }
    }

    /// The awaitable pre-connect on a given session, so tests can check it with a stub.
    static func preconnect(baseURL: String, using session: URLSession) async {
        guard let request = preconnectRequest(baseURL: baseURL) else { return }
        _ = try? await session.data(for: request, delegate: RedirectRefusingDelegate.shared)
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let session = makeEphemeralSession(timeout: timeout(for: request))
        defer { session.finishTasksAndInvalidate() }
        return try await data(for: request, using: session)
    }

    static func data(
        for request: URLRequest,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        let session = makeEphemeralSession(timeout: timeout(for: request))
        defer { session.finishTasksAndInvalidate() }
        return try await data(for: request, using: session, cache: cache)
    }

    static func data(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await data(for: request, using: session, cache: TemperatureCapabilityCache.shared)
    }

    static func data(
        for request: URLRequest,
        using session: URLSession,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        let observation = cache.beginObservation(for: request)
        let capability = observation.capability
        let outgoing = capability == .unsupported ? requestWithoutTemperature(request) ?? request : request
        let result = try await session.data(for: outgoing)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 200,
           isValidCompletionResponse(result.0), payloadHasTemperature(outgoing) {
            cache.record(.supported, for: outgoing, observation: observation)
        }
        guard capability != .unsupported,
              let response = result.1 as? HTTPURLResponse,
              response.statusCode == 400,
              let retry = requestWithoutUnsupportedTemperature(outgoing, errorData: result.0) else {
            return result
        }
        cache.record(.unsupported, for: outgoing, observation: observation)
        let retried = try await session.data(for: retry)
        return retried
    }

    private static func payloadHasTemperature(_ request: URLRequest) -> Bool {
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return payload["temperature"] != nil
    }

    private static func isValidCompletionResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], !choices.isEmpty,
              let message = choices[0]["message"] as? [String: Any] else { return false }
        return message["content"] != nil || message["reasoning"] != nil
    }

    private static func requestWithoutTemperature(_ request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload.removeValue(forKey: "temperature") != nil,
              let retryBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var retry = request
        retry.httpBody = retryBody
        return retry
    }

    private static func requestWithoutUnsupportedTemperature(
        _ request: URLRequest,
        errorData: Data
    ) -> URLRequest? {
        guard request.httpBody != nil,
              let error = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
              let details = error["error"] as? [String: Any] else {
            return nil
        }
        let code = (details["code"] as? String ?? "").lowercased()
        let param = (details["param"] as? String ?? "").lowercased()
        let message = (details["message"] as? String ?? "").lowercased()
        let unsupportedCode = code == "unsupported_parameter" || code == "unsupported_value"
        let unsupportedMessage = message.contains("unsupported") ||
            message.contains("not supported") || message.contains("does not support")
        guard unsupportedCode && param == "temperature" && unsupportedMessage else {
            return nil
        }
        return requestWithoutTemperature(request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        // Fresh session per upload — no poisoned connection re-use.
        let session = makeEphemeralSession(timeout: timeout(for: request))
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: bodyData)
    }
}

/// The pre-connect only warms the configured host; a redirect would contact another one.
private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectRefusingDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
