import Foundation

/// What one replay produced. finalTranscript is returned to the caller only for
/// scoring and the opt-in transcript files; it is never printed.
struct ReplayStreamOutcome {
    var status: ReplayEvalCore.RunStatus
    var finalTranscript: String
    var finals: [[ReplayEvalCore.WordTiming]]
    var resultCount: Int
    var unfinalizedAtEnd: Bool
    var millisecondsToFromFinalize: Double?
    var millisecondsToMetadata: Double?
}

/// Streams prepared PCM16 frames to Deepgram's live endpoint at the variant's
/// pace, then sends Finalize and CloseStream like the app does on release.
/// Never prints or logs anything: no URL (it carries the keyterms), no key, no
/// server error text and no transcript.
enum ReplayDeepgramClient {
    /// Limit for the socket to open, and for Metadata or the close after the last frame.
    static let timeoutSeconds: TimeInterval = 10

    /// The app's listen URL for the variant's rate and keyterms, with the
    /// variant's query items replacing the app's by name.
    static func listenURL(for variant: ReplayEvalCore.Variant, keyterms: [String]) -> URL {
        ReplayEvalCore.overridingQuery(
            of: DeepgramStreamingCore.listenURL(for: .init(
                apiKey: "",
                language: nil,
                sampleRate: variant.sampleRate,
                keyterms: keyterms
            )),
            with: variant.query
        )
    }

    private struct ReceiveState {
        var assembler = DeepgramStreamingCore.TranscriptAssembler()
        var finals: [[ReplayEvalCore.WordTiming]] = []
        var fromFinalizeAt: TimeInterval?
        var metadataAt: TimeInterval?
        var serverError = false
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func stream(
        frames: [Data],
        variant: ReplayEvalCore.Variant,
        keyterms: [String],
        key: ReplayEvalCore.Secret
    ) async -> ReplayStreamOutcome {
        var request = URLRequest(url: listenURL(for: variant, keyterms: keyterms))
        // The key travels only in the header.
        request.setValue(
            DeepgramStreamingCore.authorizationHeaderValue(apiKey: key.revealed),
            forHTTPHeaderField: "Authorization"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = DeepgramStreamingCore.socketIdleTimeoutSeconds
        let delegate = ReplaySocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { session.invalidateAndCancel() }

        let receiver = Task { () -> ReceiveState in
            var state = ReceiveState()
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    break
                }
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                let parsed = DeepgramStreamingCore.ServerMessage(data: data)
                state.assembler.apply(parsed)
                switch parsed {
                case .results(let transcript, let isFinal, _, let fromFinalize):
                    if isFinal, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        state.finals.append(ReplayEvalCore.wordTimings(fromResultsJSON: data))
                    }
                    if fromFinalize, state.fromFinalizeAt == nil { state.fromFinalizeAt = now() }
                case .metadata:
                    if state.metadataAt == nil { state.metadataAt = now() }
                case .error:
                    // The message text is dropped; only the fact is kept.
                    state.serverError = true
                case .utteranceEnd, .speechStarted, .unknown:
                    break
                }
            }
            return state
        }

        func outcome(_ status: ReplayEvalCore.RunStatus, _ state: ReceiveState, lastFrameAt: TimeInterval?) -> ReplayStreamOutcome {
            func milliseconds(_ event: TimeInterval?) -> Double? {
                guard let event, let lastFrameAt else { return nil }
                return (event - lastFrameAt) * 1000
            }
            return ReplayStreamOutcome(
                status: status,
                finalTranscript: state.assembler.finalTranscript,
                finals: state.finals,
                resultCount: state.assembler.resultCount,
                unfinalizedAtEnd: state.assembler.hasUnfinalizedSpeech,
                millisecondsToFromFinalize: milliseconds(state.fromFinalizeAt),
                millisecondsToMetadata: milliseconds(state.metadataAt)
            )
        }

        // Wait for the handshake.
        let connectDeadline = now() + timeoutSeconds
        while !delegate.isOpen, !delegate.isComplete, now() < connectDeadline {
            try? await sleep(seconds: 0.01)
        }
        guard delegate.isOpen, let openedAt = delegate.openedAt else {
            let statusCode = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel(with: .goingAway, reason: nil)
            let state = await receiver.value
            let status: ReplayEvalCore.RunStatus = statusCode.map { .httpError($0) } ?? .connectFailed
            return outcome(status, state, lastFrameAt: nil)
        }

        // Absolute schedule from the moment the socket opened.
        let offsets = ReplayEvalCore.sendOffsetsMilliseconds(
            frameCount: frames.count,
            frameMilliseconds: variant.frameMilliseconds,
            pacing: variant.pacing
        )
        var lastFrameAt = openedAt
        do {
            for (index, frame) in frames.enumerated() {
                try await sleep(seconds: openedAt + offsets[index] / 1000 - now())
                try await task.send(.data(frame))
                lastFrameAt = now()
            }
            for message in DeepgramStreamingCore.CommitPolicy.commitMessages {
                try await task.send(.string(message))
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            let state = await receiver.value
            return outcome(state.serverError ? .serverError : .sendFailed, state, lastFrameAt: lastFrameAt)
        }

        let watchdog = Task { () -> Bool in
            do {
                try await sleep(seconds: timeoutSeconds)
            } catch {
                return false
            }
            task.cancel(with: .goingAway, reason: nil)
            return true
        }
        let state = await receiver.value
        watchdog.cancel()
        let timedOut = await watchdog.value

        let status: ReplayEvalCore.RunStatus
        if state.serverError {
            status = .serverError
        } else if state.metadataAt != nil {
            status = .ok
        } else if timedOut {
            status = .timedOut
        } else {
            status = .closedEarly
        }
        return outcome(status, state, lastFrameAt: lastFrameAt)
    }
}

/// Records the handshake outcome for the polling loop, under a lock because
/// URLSession calls it on its own queue. URLSession keeps its delegate until
/// invalidateAndCancel.
private final class ReplaySocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: TimeInterval?
    private var completed = false

    /// When the handshake finished, in systemUptime seconds; nil until then.
    var openedAt: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    var isOpen: Bool { openedAt != nil }

    /// The task ended, for example because the handshake was refused.
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        opened = now
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completed = true
        lock.unlock()
    }
}
