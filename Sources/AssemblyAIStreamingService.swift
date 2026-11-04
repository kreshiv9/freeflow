import AppKit
import Foundation
import os.log

private let assemblyAILog = OSLog(subsystem: "com.zachlatta.freeflow", category: "AssemblyAIStreaming")

/// Owns the delegate conformance so URLSession's strong delegate reference
/// never retains the service.
private final class AssemblyAISocketDelegate: NSObject, URLSessionWebSocketDelegate {
    weak var service: AssemblyAIStreamingService?

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

/// Streams the recorder's PCM16 chunks to AssemblyAI Universal-3.6 Pro over a WebSocket
/// while the shortcut is held, then sends ForceEndpoint and Terminate on release. Every
/// decision goes through AssemblyAIStreamingCore; this class only holds state and the
/// socket. AssemblyAI bills by socket-open time, so every path closes the socket: resolve,
/// fallback, timeout, server error, cancel, early throw, pending-audio overflow, app
/// termination and deinit (the receive loop holds the service weakly, so a dropped service
/// still closes it); the server's inactivity_timeout bounds any socket the app cannot close.
/// Logs carry counts, byte totals, close codes and transport error text only, never the
/// transcript, the URL (it carries the keyterms and prompt), the keyterms or the key.
final class AssemblyAIStreamingService: StreamingTranscriptionSession {
    typealias Configuration = AssemblyAIStreamingCore.Configuration
    private typealias Core = AssemblyAIStreamingCore
    private typealias CommitPolicy = AssemblyAIStreamingCore.CommitPolicy

    /// "assemblyai" until the commit resolves, then the path that produced the text.
    /// Read only off stateQueue (after the commit's await, or on the main thread).
    var transcriptionSource: String {
        stateQueue.sync { resolvedPath?.rawValue ?? PipelineStageTimings.assemblyAITranscriptionSource }
    }

    private let config: Configuration
    /// The connect URL's keyterms after AssemblyAI's caps; empty when keyterms are off.
    private let connectKeyterms: [String]
    private let maxPendingAudioBytes: Int

    // Every property below is guarded by stateQueue.
    private let stateQueue = DispatchQueue(label: "com.zachlatta.freeflow.assemblyai.state")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var socketOpened = false
    /// Begin arrived: audio and updates go out from here on.
    private var isReady = false
    /// When Begin arrived, for the throttle backlog estimate at the commit.
    private var readyAt: TimeInterval?
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    /// UpdateConfiguration messages waiting for Begin, sent before the buffered audio.
    private var pendingUpdates: [String] = []
    /// Regroups appended chunks into 50 ms frames; the commit sends the padded partial frame.
    private var frameAggregator: DeepgramStreamingCore.FrameAggregator
    private var assembler = AssemblyAIStreamingCore.TurnAssembler()
    /// The first failure the server reported (Error frame or error close).
    private var failure: AssemblyAIStreamingError?
    private var socketState = CommitPolicy.SocketState.open
    /// The server's close code from the delegate, when it arrives before the receive loop ends.
    private var serverCloseCode: Int?
    private var commitStartedAt: TimeInterval?
    /// Audio the server cannot have processed when the commit started (throttle estimate).
    private var backlogMillisecondsAtCommit = 0
    private var finalContinuation: CheckedContinuation<String, Error>?
    /// Set when the commit resolves; the Run Log source label.
    private var resolvedPath: CommitPolicy.TranscriptPath?
    /// The recorder's speech tracker verdict, set on stop. True until then, so an
    /// empty stream whose verdict never arrived tries the file instead of dropping speech.
    private var recorderHeardSpeech = true
    /// Ends the stream before the commit; the commit throws it so its Run Log reason survives.
    private var terminalError: AssemblyAIStreamingError?
    private var closed = false
    private var terminateSent = false
    /// Audio bytes handed to the socket, for the Run Log's keyterm timing.
    private var audioBytesSent = 0
    private var keytermUpdateRequested = false
    /// The keyterm update is among pendingUpdates.
    private var keytermUpdateHeld = false
    private var currentPromptScenario: AssemblyAIStreamingCore.PromptScenario?
    private var promptUpdateRequested = false
    /// On-screen names and code identifiers the one keyterm update added; nil until it is
    /// requested, and again if it never went out.
    private var screenKeytermCount: Int?
    private var identifierKeytermCount: Int?
    /// Audio already sent when the keyterm update went out; 0 when it was held for Begin.
    private var keytermUpdateAudioMilliseconds: Int?
    /// Cancels the stream when the app quits, so the billed socket is closed on the way out.
    private var terminationObserver: NSObjectProtocol?

    init(config: Configuration) {
        self.config = config
        connectKeyterms = config.keytermsEnabled ? AssemblyAIStreamingCore.normalizedKeyterms(config.keyterms) : []
        maxPendingAudioBytes = DeepgramStreamingCore.maxPendingAudioBytes(sampleRate: config.sampleRate)
        frameAggregator = DeepgramStreamingCore.FrameAggregator(
            frameBytes: AssemblyAIStreamingCore.frameBytes(sampleRate: config.sampleRate)
        )
        currentPromptScenario = config.promptScenario
    }

    deinit {
        // No other reference exists here, so the queue is not needed; nothing to do once
        // teardown already ran.
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        receiveTask?.cancel()
        Self.close(task: task, session: session, sendingTerminate: !closed && socketOpened && !terminateSent)
    }

    /// Monotonic seconds for the commit clock.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    // MARK: Lifecycle

    /// Opens the socket and starts the receive loop. No keep-alive: audio flows for the
    /// whole dictation, and inactivity_timeout ends a stalled session on the server.
    func start() throws {
        var request = URLRequest(url: AssemblyAIStreamingCore.listenURL(for: config))
        // The key travels only in the header; the URL never carries it.
        request.setValue(
            AssemblyAIStreamingCore.authorizationHeaderValue(apiKey: config.apiKey),
            forHTTPHeaderField: "Authorization"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = DeepgramStreamingCore.socketIdleTimeoutSeconds
        let delegate = AssemblyAISocketDelegate()
        delegate.service = self
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        let started: Bool = stateQueue.sync {
            guard !closed else { return false }
            self.session = session
            self.task = task
            // Holds the task, not the service, so a service nobody references deinits and closes the socket.
            receiveTask = Task { [weak self] in
                await Self.receiveLoop(task: task, service: { self })
            }
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.cancel()
            }
            return true
        }
        guard started else {
            session.invalidateAndCancel()
            return
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

    /// Called on the recorder's sample-buffer queue with mono PCM16 at the configured
    /// sample rate. Chunks are regrouped into 50 ms frames, buffered until Begin, then
    /// sent as binary frames; the partial frame is padded and sent on commit. Nothing is
    /// accepted once the commit has started.
    func appendPCM16(_ data: Data) {
        guard !data.isEmpty else { return }
        stateQueue.async { [self] in
            guard !closed, terminalError == nil, commitStartedAt == nil else { return }
            for frame in frameAggregator.append(data) {
                if isReady, let task {
                    sendAudioLocked(frame, over: task)
                    continue
                }
                pendingAudioBytes += frame.count
                guard pendingAudioBytes <= maxPendingAudioBytes else {
                    // The WAV is always recorded in parallel, so the fallback loses nothing.
                    os_log(
                        .error, log: assemblyAILog,
                        "session did not begin within %d bytes of audio — abandoning the stream",
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

    /// Send the padded partial frame, then ForceEndpoint and Terminate, then wait for
    /// ForceEndpoint's end_of_turn, Termination or the close within CommitPolicy.timeout.
    /// Throws at once when the server cannot have heard anything, so the file upload starts
    /// without waiting; every early throw tears the socket down.
    func commitAndAwaitFinal() async throws -> String {
        let commitTask: URLSessionWebSocketTask = try stateQueue.sync {
            if let error = terminalError ?? failure {
                teardownLocked()
                throw error
            }
            // A second commit must not tear down the one in flight.
            guard commitStartedAt == nil else { throw AssemblyAIStreamingError.notConnected }
            guard !closed, let task, isReady else {
                teardownLocked()
                throw AssemblyAIStreamingError.notConnected
            }
            guard socketState == .open else {
                teardownLocked()
                throw AssemblyAIStreamingError.socketClosedBeforeCommit
            }
            // The partial frame goes out before ForceEndpoint and Terminate, which follow on the same task.
            if let partialFrame = frameAggregator.flush() {
                sendAudioLocked(
                    AssemblyAIStreamingCore.paddedFinalChunk(partialFrame, frameBytes: frameAggregator.frameBytes),
                    over: task
                )
            }
            let now = Self.now()
            commitStartedAt = now
            backlogMillisecondsAtCommit = AssemblyAIStreamingCore.estimatedBacklogMilliseconds(
                audioMillisecondsSent: audioMillisecondsSentLocked,
                secondsSinceBegin: readyAt.map { now - $0 } ?? 0
            )
            assembler.markCommitted()
            terminateSent = true
            return task
        }

        for message in CommitPolicy.commitMessages {
            commitTask.send(.string(message)) { error in
                if let error {
                    os_log(.error, log: assemblyAILog, "commit send failed: %{public}@", error.localizedDescription)
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

    // MARK: Context

    /// Adds on-screen names, then code identifiers, to this stream's keyterms with one
    /// UpdateConfiguration planned by KeytermPlan; the connect keyterms come first, since
    /// keyterms_prompt replaces the whole list. Sent at most once, never after the commit
    /// or with keyterms off. Before Begin it is held and sent ahead of the buffered audio.
    /// Records only counts for keytermReport.
    func updateKeyterms(screenTerms: [String], identifiers: [String]) {
        guard config.keytermsEnabled,
              let plan = AssemblyAIStreamingCore.updateTerms(
                  connect: connectKeyterms, screenTerms: screenTerms, identifiers: identifiers
              ),
              let message = AssemblyAIStreamingCore.updateConfigurationMessage(keyterms: plan.terms, prompt: nil)
        else { return }
        stateQueue.async { [self] in
            guard !closed, terminalError == nil, commitStartedAt == nil, socketState == .open,
                  !keytermUpdateRequested else { return }
            keytermUpdateRequested = true
            screenKeytermCount = plan.screenCount
            identifierKeytermCount = plan.identifierCount
            if isReady, let task {
                keytermUpdateAudioMilliseconds = audioMillisecondsSentLocked
                sendUpdateLocked(message, over: task)
            } else {
                keytermUpdateAudioMilliseconds = 0
                keytermUpdateHeld = true
                pendingUpdates.append(message)
            }
            os_log(
                .info, log: assemblyAILog,
                "keyterm update: %d terms (%d screen, %d code), %d ms audio before",
                plan.terms.count, plan.screenCount, plan.identifierCount, keytermUpdateAudioMilliseconds ?? 0
            )
        }
    }

    /// Refines the scenario prompt once text context knows the page (chatgpt.com, google.com,
    /// Gmail, claude.ai). Ignored when the prompt is off, the scenario is unchanged, after a
    /// first refinement or after the commit; held until Begin like the keyterm update.
    func updatePromptScenario(_ scenario: AssemblyAIStreamingCore.PromptScenario) {
        guard config.promptScenario != nil,
              let message = AssemblyAIStreamingCore.updateConfigurationMessage(keyterms: nil, prompt: scenario)
        else { return }
        stateQueue.async { [self] in
            guard !closed, terminalError == nil, commitStartedAt == nil, socketState == .open,
                  !promptUpdateRequested, scenario != currentPromptScenario else { return }
            promptUpdateRequested = true
            currentPromptScenario = scenario
            if isReady, let task {
                sendUpdateLocked(message, over: task)
            } else {
                pendingUpdates.append(message)
            }
        }
    }

    /// Numbers only, for the Run Log.
    var keytermReport: DeepgramStreamingCore.KeytermReport {
        stateQueue.sync {
            DeepgramStreamingCore.KeytermReport(
                connectCount: connectKeyterms.count,
                screenCount: screenKeytermCount,
                identifierCount: identifierKeytermCount,
                audioMillisecondsBeforeUpdate: keytermUpdateAudioMilliseconds
            )
        }
    }

    // MARK: Socket events

    fileprivate func socketDidOpen() {
        stateQueue.async { [self] in
            guard !closed else { return }
            socketOpened = true
        }
    }

    /// Only records the code: the delegate can run before the receive loop has applied
    /// the last queued frames, so the close itself is reported by the receive loop once
    /// every delivered frame has been handled.
    fileprivate func socketDidClose(code: Int) {
        os_log(.info, log: assemblyAILog, "socket closed with code %d", code)
        stateQueue.async { [self] in
            serverCloseCode = code
        }
    }

    /// Strong only while handling one message, so a dropped service deinits (closing the
    /// socket), which ends the loop.
    private static func receiveLoop(
        task: URLSessionWebSocketTask,
        service: () -> AssemblyAIStreamingService?
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard let current = service() else { return }
                current.handle(message)
            } catch {
                service()?.receiveEnded(error: error)
                return
            }
        }
        service()?.receiveEnded(error: nil)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            return
        }
        let parsed = AssemblyAIStreamingCore.ServerMessage(data: data)
        stateQueue.sync {
            guard !closed else { return }
            switch parsed {
            case .begin:
                beginLocked()
            case .error(let error):
                // Provider responses are untrusted input: only the fixed reason is logged.
                os_log(
                    .error, log: assemblyAILog, "server error received: %{public}@",
                    error.errorDescription ?? ""
                )
                if failure == nil { failure = error }
                guard commitStartedAt != nil else {
                    // Nothing can be transcribed now; close at once, since the socket is billed.
                    if terminalError == nil { terminalError = error }
                    teardownLocked()
                    return
                }
            case .turn, .termination, .unknown:
                assembler.apply(parsed)
            }
            evaluateLocked()
        }
    }

    private func receiveEnded(error: Error?) {
        stateQueue.sync {
            if let error, !closed {
                os_log(.info, log: assemblyAILog, "receive ended: %{public}@", error.localizedDescription)
            }
            markSocketClosedLocked()
        }
    }

    // MARK: Locked helpers (stateQueue only)

    /// Held updates go out before the buffered audio, so all of that audio uses them
    /// (updates are not retroactive).
    private func beginLocked() {
        guard !isReady, let task else { return }
        isReady = true
        readyAt = Self.now()
        socketOpened = true
        let updates = pendingUpdates
        pendingUpdates = []
        keytermUpdateHeld = false
        for message in updates {
            sendUpdateLocked(message, over: task)
        }
        let chunks = pendingAudio
        pendingAudio = []
        pendingAudioBytes = 0
        for chunk in chunks {
            sendAudioLocked(chunk, over: task)
        }
        os_log(
            .info, log: assemblyAILog,
            "session began; sent %d held updates and %d buffered chunks (%d keyterms at connect)",
            updates.count, chunks.count, connectKeyterms.count
        )
    }

    private var audioMillisecondsSentLocked: Int {
        DeepgramStreamingCore.audioMilliseconds(bytes: audioBytesSent, sampleRate: config.sampleRate)
    }

    private func sendAudioLocked(_ data: Data, over task: URLSessionWebSocketTask) {
        audioBytesSent += data.count
        task.send(.data(data)) { [weak self] error in
            guard let error, let self else { return }
            self.stateQueue.async {
                guard !self.closed, self.terminalError == nil else { return }
                os_log(.error, log: assemblyAILog, "audio send failed: %{public}@", error.localizedDescription)
                self.terminalError = .socketClosedBeforeCommit
            }
        }
    }

    /// A failed send keeps the starting configuration, so it never ends the stream. Logs
    /// never carry the terms or the prompt.
    private func sendUpdateLocked(_ message: String, over task: URLSessionWebSocketTask) {
        task.send(.string(message)) { error in
            if let error {
                os_log(.error, log: assemblyAILog, "configuration update send failed: %{public}@", error.localizedDescription)
            }
        }
    }

    /// Called once, from the receive loop's exit. The close is normal only when the
    /// server's close frame carried 1000. Before the commit any close ends the stream:
    /// the reason is the server's failure, a failure the close itself reports (code or
    /// refused handshake), notConnected when the socket never opened, or
    /// socketClosedBeforeCommit, and the socket is torn down.
    private func markSocketClosedLocked() {
        guard socketState == .open else { return }
        let normalClosure = URLSessionWebSocketTask.CloseCode.normalClosure.rawValue
        let closeCode = serverCloseCode ?? task?.closeCode.rawValue
        let httpStatus = (task?.response as? HTTPURLResponse)?.statusCode
        socketState = closeCode == normalClosure ? .closedNormally : .closedAbnormally
        pendingAudio = []
        pendingAudioBytes = 0
        if failure == nil {
            failure = AssemblyAIStreamingCore.failure(closeCode: closeCode, httpStatus: httpStatus)
        }
        if commitStartedAt == nil {
            if !closed, terminalError == nil {
                terminalError = failure ?? (socketOpened ? .socketClosedBeforeCommit : .notConnected)
            }
            teardownLocked()
            return
        }
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
            failure: failure,
            elapsedSinceCommit: elapsed,
            recorderHeardSpeech: recorderHeardSpeech,
            audioMillisecondsSent: audioMillisecondsSentLocked,
            backlogMillisecondsAtCommit: backlogMillisecondsAtCommit
        )
        switch decision {
        case .wait:
            return
        case .resolve(let text, let path):
            finalContinuation = nil
            resolvedPath = path
            // Resolved: close now rather than wait for Termination, since the socket is billed.
            teardownLocked()
            os_log(
                .info, log: assemblyAILog,
                "resolved via %{public}@ after %d turn messages: %d characters",
                path.rawValue, assembler.turnMessageCount, text.count
            )
            continuation.resume(returning: text)
        case .fallBack(let error):
            finalContinuation = nil
            teardownLocked()
            os_log(
                .error, log: assemblyAILog,
                "falling back to the file upload after %d turn messages: %{public}@",
                assembler.turnMessageCount, error.errorDescription ?? ""
            )
            continuation.resume(throwing: error)
        }
    }

    /// Idempotent. Sends Terminate when the socket opened and it has not gone out yet, then
    /// closes the socket and invalidates the session.
    private func teardownLocked() {
        let sendsTerminate = !closed && socketOpened && !terminateSent
        closed = true
        if sendsTerminate { terminateSent = true }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        receiveTask?.cancel()
        receiveTask = nil
        Self.close(task: task, session: session, sendingTerminate: sendsTerminate)
        task = nil
        session = nil
        pendingAudio = []
        pendingAudioBytes = 0
        _ = frameAggregator.flush()
        // A held keyterm update that never went out must not show in the Run Log.
        if keytermUpdateHeld {
            screenKeytermCount = nil
            identifierKeytermCount = nil
            keytermUpdateAudioMilliseconds = nil
        }
        keytermUpdateHeld = false
        pendingUpdates = []
    }

    /// Terminate (when asked), then the close frame and the session. The close waits for
    /// Terminate's send to complete, or terminateFlushSeconds at most, so the server sees
    /// Terminate before the close; either one ends the billed session. Holds only the task
    /// and session, so it also runs from deinit.
    private static func close(task: URLSessionWebSocketTask?, session: URLSession?, sendingTerminate: Bool) {
        let closer = AssemblyAISocketCloser(task: task, session: session)
        guard sendingTerminate, let task else {
            closer.close()
            return
        }
        task.send(.string(CommitPolicy.terminateMessage)) { _ in
            closer.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + AssemblyAIStreamingCore.terminateFlushSeconds
        ) {
            closer.close()
        }
    }
}

/// Closes one socket and its session exactly once, from whichever of Terminate's send
/// completion and the flush deadline comes first.
private final class AssemblyAISocketCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    init(task: URLSessionWebSocketTask?, session: URLSession?) {
        self.task = task
        self.session = session
    }

    func close() {
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }
}

// Mirrors Deepgram's calls, so AppState drives both through one protocol.
extension AssemblyAIStreamingService: KeytermStreamingSession {}
