import Foundation
import os.log

private let deepgramLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "DeepgramStreaming")

/// Owns the delegate conformance so URLSession's strong delegate reference
/// never retains the service.
private final class DeepgramSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var service: DeepgramStreamingService?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        service?.socketDidOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        service?.socketDidClose(code: closeCode.rawValue)
    }
}

/// Streams the recorder's PCM16 chunks to Deepgram Nova-3 over a WebSocket
/// while the shortcut is held, then finalizes on release. Every decision goes
/// through DeepgramStreamingCore; this class only holds state and the socket.
/// Logs carry counts, byte totals, close codes and transport error text only,
/// never the transcript, the URL (it carries the vocabulary keyterms), the
/// keyterms or the key.
final class DeepgramStreamingService: StreamingTranscriptionSession {
    typealias Configuration = DeepgramStreamingCore.Configuration
    private typealias CommitPolicy = DeepgramStreamingCore.CommitPolicy
    private typealias KeepAlivePolicy = DeepgramStreamingCore.KeepAlivePolicy

    /// "deepgram" until the commit resolves, then the path that produced the text.
    /// Read only off stateQueue (after the commit's await, or on the main thread).
    var transcriptionSource: String {
        stateQueue.sync { resolvedPath?.rawValue ?? PipelineStageTimings.deepgramTranscriptionSource }
    }

    private let config: Configuration
    private let maxPendingAudioBytes: Int
    /// The connect URL's keyterm count, for the Run Log.
    private let connectKeytermCount: Int

    // Every property below is guarded by stateQueue.
    private let stateQueue = DispatchQueue(label: "com.zachlatta.freeflow.deepgram.state")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTimer: DispatchSourceTimer?
    private var isOpen = false
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    /// Regroups appended chunks into frameMilliseconds frames; commitAndAwaitFinal sends the partial frame.
    private var frameAggregator: DeepgramStreamingCore.FrameAggregator
    private var lastAudioSentAt: TimeInterval?
    private var assembler = DeepgramStreamingCore.TranscriptAssembler()
    private var serverErrorMessage: String?
    private var socketState = CommitPolicy.SocketState.open
    /// The server's close code from the delegate, when it arrives before the receive loop ends.
    private var serverCloseCode: Int?
    private var commitStartedAt: TimeInterval?
    private var finalContinuation: CheckedContinuation<String, Error>?
    /// Set when the commit resolves; the Run Log source label.
    private var resolvedPath: CommitPolicy.TranscriptPath?
    /// The recorder's speech tracker verdict, set on stop. True until then, so an
    /// empty stream whose verdict never arrived tries the file instead of dropping speech.
    private var recorderHeardSpeech = true
    private var terminalError: DeepgramStreamingError?
    private var closed = false
    private var keytermUpdateRequested = false
    /// A Configure message waiting for the socket to open.
    private var pendingKeytermUpdate: String?
    /// Audio bytes handed to the socket, for the Run Log's keyterm timing.
    private var audioBytesSent = 0
    /// On-screen names and code identifiers the one Configure added; nil until it is
    /// requested, and again if it never went out.
    private var screenKeytermCount: Int?
    private var identifierKeytermCount: Int?
    /// Audio already sent when the Configure went out; 0 when it was held for the socket.
    private var keytermUpdateAudioMilliseconds: Int?

    init(config: Configuration) {
        self.config = config
        maxPendingAudioBytes = DeepgramStreamingCore.maxPendingAudioBytes(sampleRate: config.sampleRate)
        connectKeytermCount = DeepgramStreamingCore.normalizedKeyterms(config.keyterms).count
        frameAggregator = DeepgramStreamingCore.FrameAggregator(
            frameBytes: DeepgramStreamingCore.frameBytes(sampleRate: config.sampleRate)
        )
    }

    /// Monotonic seconds for the keep-alive and commit clocks.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: Lifecycle

    /// Opens the socket and starts the receive loop and keep-alive timer. The
    /// URL is static, so this throws nothing in practice; the signature keeps
    /// AppState's start path symmetric with Realtime.
    func start() throws {
        var request = URLRequest(url: DeepgramStreamingCore.listenURL(for: config))
        // The key travels only in the header; the URL never carries it.
        request.setValue(
            DeepgramStreamingCore.authorizationHeaderValue(apiKey: config.apiKey),
            forHTTPHeaderField: "Authorization"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = DeepgramStreamingCore.socketIdleTimeoutSeconds
        let delegate = DeepgramSocketDelegate()
        delegate.service = self
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + KeepAlivePolicy.interval, repeating: KeepAlivePolicy.interval)
        timer.setEventHandler { [weak self] in
            self?.sendKeepAliveIfIdleLocked()
        }

        stateQueue.sync {
            self.session = session
            self.task = task
            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            timer.resume()
            keepAliveTimer = timer
        }
        task.resume()
    }

    /// Cancel the socket and any in-flight commit. Safe to call multiple times.
    func cancel() {
        stateQueue.sync {
            let continuation = finalContinuation
            finalContinuation = nil
            teardownLocked()
            continuation?.resume(throwing: CancellationError())
        }
    }

    // MARK: Producer

    /// Called on the recorder's sample-buffer queue with mono PCM16 at the
    /// configured sample rate. Chunks are regrouped into
    /// DeepgramStreamingCore.frameMilliseconds frames, buffered until the socket
    /// opens, then sent as binary frames; the partial frame is sent on commit.
    /// Nothing is accepted once the commit has started.
    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        stateQueue.async { [self] in
            guard !closed, terminalError == nil, commitStartedAt == nil else { return }
            lastAudioSentAt = Self.now()
            for frame in frameAggregator.append(data) {
                if isOpen, let task {
                    sendAudioLocked(frame, over: task)
                    continue
                }
                pendingAudioBytes += frame.count
                guard pendingAudioBytes <= maxPendingAudioBytes else {
                    // The WAV is always recorded in parallel, so the fallback loses nothing.
                    os_log(
                        .error, log: deepgramLog,
                        "socket did not open within %d bytes of audio — abandoning the stream",
                        pendingAudioBytes
                    )
                    terminalError = .notConnected
                    teardownLocked()
                    return
                }
                pendingAudio.append(frame)
            }
        }
    }

    /// Whether the recorder's speech tracker counted speech in this recording.
    /// Called on stop, before commitAndAwaitFinal; an empty stream transcript
    /// for counted speech falls back to the file upload.
    func setRecorderHeardSpeech(_ heardSpeech: Bool) {
        stateQueue.async { [self] in
            recorderHeardSpeech = heardSpeech
        }
    }

    /// Send any partial audio frame, then Finalize and CloseStream, then wait
    /// for the from_finalize final, Metadata or the close within
    /// CommitPolicy.timeout. Throws when the server cannot have heard anything
    /// so the file upload starts at once instead of after the timeout; every
    /// early throw tears the socket down so a late handshake cannot flush the
    /// buffered audio to a stream nobody is waiting on.
    func commitAndAwaitFinal() async throws -> String {
        let commitTask: URLSessionWebSocketTask = try stateQueue.sync {
            if let terminalError {
                teardownLocked()
                throw terminalError
            }
            // A second commit must not tear down the one in flight.
            guard commitStartedAt == nil else { throw DeepgramStreamingError.notConnected }
            guard !closed, let task, isOpen else {
                teardownLocked()
                throw DeepgramStreamingError.notConnected
            }
            guard socketState == .open else {
                teardownLocked()
                throw DeepgramStreamingError.socketClosedBeforeCommit
            }
            // The partial frame goes out before Finalize and CloseStream, which follow on the same task.
            if let partialFrame = frameAggregator.flush() {
                sendAudioLocked(partialFrame, over: task)
            }
            commitStartedAt = Self.now()
            keepAliveTimer?.cancel()
            keepAliveTimer = nil
            return task
        }

        for message in CommitPolicy.commitMessages {
            commitTask.send(.string(message)) { error in
                if let error {
                    os_log(.error, log: deepgramLog, "commit send failed: %{public}@", error.localizedDescription)
                }
            }
        }
        scheduleCommitTimeout()

        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.sync {
                // Only cancel() can close the service between the commit and
                // this registration, so a closed service means a cancelled one.
                guard !closed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                finalContinuation = continuation
                // An Error or close that arrived before registration resolves at once.
                evaluateLocked()
            }
        }
    }

    /// Re-evaluates once the commit timeout elapses; a no-op after resolution.
    private func scheduleCommitTimeout() {
        stateQueue.asyncAfter(deadline: .now() + CommitPolicy.timeout) { [weak self] in
            self?.evaluateLocked()
        }
    }

    // MARK: Keyterms

    /// Adds on-screen names, then code identifiers, to this stream's keyterms with one
    /// Configure message planned by KeytermPlan; the connect keyterms come first, unchanged.
    /// Sent at most once per stream, because Deepgram refuses a second Configure while one is
    /// pending, and never after the commit. Before the socket opens it is held and sent ahead
    /// of the buffered audio. A refused update keeps the starting keyterms. Records only
    /// counts for keytermReport.
    func updateKeyterms(screenTerms: [String], identifiers: [String]) {
        guard let plan = DeepgramStreamingCore.KeytermPlan.configureTerms(
            connect: config.keyterms, screenTerms: screenTerms, identifiers: identifiers
        ), let message = DeepgramStreamingCore.configureMessage(keyterms: plan.terms) else { return }
        stateQueue.async { [self] in
            guard !closed, terminalError == nil, commitStartedAt == nil, socketState == .open,
                  !keytermUpdateRequested else { return }
            keytermUpdateRequested = true
            screenKeytermCount = plan.screenCount
            identifierKeytermCount = plan.identifierCount
            if isOpen, let task {
                keytermUpdateAudioMilliseconds = DeepgramStreamingCore.audioMilliseconds(
                    bytes: audioBytesSent, sampleRate: config.sampleRate
                )
                sendKeytermUpdateLocked(message, over: task)
            } else {
                keytermUpdateAudioMilliseconds = 0
                pendingKeytermUpdate = message
            }
        }
    }

    /// Numbers only, for the Run Log.
    var keytermReport: DeepgramStreamingCore.KeytermReport {
        stateQueue.sync {
            DeepgramStreamingCore.KeytermReport(
                connectCount: connectKeytermCount,
                screenCount: screenKeytermCount,
                identifierCount: identifierKeytermCount,
                audioMillisecondsBeforeUpdate: keytermUpdateAudioMilliseconds
            )
        }
    }

    // MARK: Socket events

    fileprivate func socketDidOpen() {
        stateQueue.async { [self] in
            guard !closed, let task else { return }
            isOpen = true
            // Before the buffered audio, so that audio already uses the new keyterms.
            if let message = pendingKeytermUpdate {
                pendingKeytermUpdate = nil
                sendKeytermUpdateLocked(message, over: task)
            }
            let chunks = pendingAudio
            pendingAudio = []
            pendingAudioBytes = 0
            for chunk in chunks {
                sendAudioLocked(chunk, over: task)
            }
            os_log(
                .info, log: deepgramLog,
                "socket open; flushed %d buffered chunks (%d-byte frames)",
                chunks.count, frameAggregator.frameBytes
            )
        }
    }

    /// Only records the code: the delegate can run before the receive loop has
    /// applied the last queued Results and Metadata frames, so the close itself
    /// is reported by receiveLoop once every delivered frame has been handled.
    fileprivate func socketDidClose(code: Int) {
        os_log(.info, log: deepgramLog, "socket closed with code %d", code)
        stateQueue.async { [self] in
            serverCloseCode = code
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let currentTask: URLSessionWebSocketTask? = stateQueue.sync {
                task
            }
            guard let currentTask else { break }
            do {
                let message = try await currentTask.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let payload):
                    data = payload
                @unknown default:
                    continue
                }
                handleServerMessage(DeepgramStreamingCore.ServerMessage(data: data))
            } catch {
                let wasClosed: Bool = stateQueue.sync { closed }
                if !wasClosed {
                    os_log(.info, log: deepgramLog, "receive ended: %{public}@", error.localizedDescription)
                }
                break
            }
        }
        stateQueue.sync {
            markSocketClosedLocked()
        }
    }

    private func handleServerMessage(_ message: DeepgramStreamingCore.ServerMessage) {
        stateQueue.sync {
            assembler.apply(message)
            if case .error(let errorMessage) = message {
                // Provider responses are untrusted input: the message feeds the
                // decision and tests, never the log.
                os_log(.error, log: deepgramLog, "server error received")
                serverErrorMessage = errorMessage
            }
            evaluateLocked()
        }
    }

    // MARK: Locked helpers (stateQueue only)

    private func sendAudioLocked(_ data: Data, over task: URLSessionWebSocketTask) {
        audioBytesSent += data.count
        task.send(.data(data)) { [weak self] error in
            guard let error, let self else { return }
            self.stateQueue.async {
                guard !self.closed, self.terminalError == nil else { return }
                os_log(.error, log: deepgramLog, "audio send failed: %{public}@", error.localizedDescription)
                self.terminalError = .socketClosedBeforeCommit
            }
        }
    }

    private func sendKeepAliveIfIdleLocked() {
        guard isOpen, !closed, socketState == .open, commitStartedAt == nil, let task,
              KeepAlivePolicy.shouldSendKeepAlive(lastAudioSentAt: lastAudioSentAt, now: Self.now()) else {
            return
        }
        task.send(.string(KeepAlivePolicy.message)) { error in
            if let error {
                os_log(.error, log: deepgramLog, "keep-alive send failed: %{public}@", error.localizedDescription)
            }
        }
    }

    /// A failed send keeps the starting keyterms, so it never ends the stream. Logs never
    /// carry the terms.
    private func sendKeytermUpdateLocked(_ message: String, over task: URLSessionWebSocketTask) {
        task.send(.string(message)) { error in
            if let error {
                os_log(.error, log: deepgramLog, "keyterm update send failed: %{public}@", error.localizedDescription)
            }
        }
        os_log(
            .info, log: deepgramLog,
            "sent keyterm update: %d terms (%d screen, %d code), %d ms audio before",
            connectKeytermCount + (screenKeytermCount ?? 0) + (identifierKeytermCount ?? 0),
            screenKeytermCount ?? 0, identifierKeytermCount ?? 0, keytermUpdateAudioMilliseconds ?? 0
        )
    }

    /// Called once, from the receive loop's exit. The close is normal only when
    /// the server's close frame carried 1000, read from the delegate's code or,
    /// when the delegate has not run yet, from the task itself; a transport
    /// error or a missing close frame leaves the task's code at .invalid.
    private func markSocketClosedLocked() {
        guard socketState == .open else { return }
        let normalClosure = URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
        let closeCode = serverCloseCode ?? task?.closeCode.rawValue
        socketState = closeCode == normalClosure ? .closedNormally : .closedAbnormally
        pendingAudio = []
        pendingAudioBytes = 0
        evaluateLocked()
    }

    /// Runs the commit decision over the current state and resumes the pending
    /// continuation exactly once when it is no longer `.wait`.
    private func evaluateLocked() {
        guard let continuation = finalContinuation else { return }
        let elapsed = commitStartedAt.map { Self.now() - $0 } ?? 0
        let decision = CommitPolicy.decision(
            assembler: assembler,
            socketState: socketState,
            serverErrorMessage: serverErrorMessage,
            elapsedSinceCommit: elapsed,
            recorderHeardSpeech: recorderHeardSpeech
        )
        switch decision {
        case .wait:
            return
        case .resolve(let text, let path):
            finalContinuation = nil
            resolvedPath = path
            teardownLocked()
            os_log(
                .info, log: deepgramLog,
                "resolved via %{public}@ after %d results: %d characters",
                path.rawValue, assembler.resultCount, text.count
            )
            continuation.resume(returning: text)
        case .fallBack(let error):
            finalContinuation = nil
            teardownLocked()
            os_log(
                .error, log: deepgramLog,
                "falling back to the file upload after %d results: %{public}@",
                assembler.resultCount, error.localizedDescription
            )
            continuation.resume(throwing: error)
        }
    }

    private func teardownLocked() {
        closed = true
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        pendingAudio = []
        pendingAudioBytes = 0
        _ = frameAggregator.flush()
        // A held Configure that never went out must not show in the Run Log.
        if pendingKeytermUpdate != nil {
            screenKeytermCount = nil
            identifierKeytermCount = nil
            keytermUpdateAudioMilliseconds = nil
        }
        pendingKeytermUpdate = nil
    }
}

// The existing setRecorderHeardSpeech, updateKeyterms and keytermReport satisfy it unchanged,
// so the shared AppState seam leaves Deepgram's requests as they were.
extension DeepgramStreamingService: KeytermStreamingSession {
    /// Deepgram always takes the one Configure, as before the shared seam.
    var acceptsKeytermUpdates: Bool { true }
}
