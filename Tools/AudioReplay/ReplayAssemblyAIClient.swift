import Foundation

/// Streams prepared PCM16 chunks to AssemblyAI Universal-3.6 Pro with the app's request
/// (AssemblyAIStreamingCore.listenURL) at the variant's pace, starting at Begin, then sends
/// ForceEndpoint and Terminate like the app does on release. AssemblyAI bills the time the
/// socket is open, so every path closes it: Termination, an Error frame, a refused or
/// stalled handshake, a failed send and the timeout; the URL's inactivity_timeout bounds
/// the rest. Never prints or logs anything: no URL (it carries the keyterms and the
/// prompt), no key, no server error text and no transcript.
enum ReplayAssemblyAIClient {
    /// Limit for Begin after the socket starts, and for Termination after the last chunk.
    static let timeoutSeconds: TimeInterval = 10

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func stream(
        chunks: [Data],
        variant: ReplayEvalCore.Variant,
        keyterms: [String],
        key: ReplayEvalCore.Secret
    ) async -> ReplayStreamOutcome {
        var request = URLRequest(url: AssemblyAIStreamingCore.listenURL(
            for: ReplayEvalCore.assemblyAIConfiguration(for: variant, keyterms: keyterms)
        ))
        // The key travels only in the header.
        request.setValue(
            AssemblyAIStreamingCore.authorizationHeaderValue(apiKey: key.revealed),
            forHTTPHeaderField: "Authorization"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = DeepgramStreamingCore.socketIdleTimeoutSeconds
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { session.invalidateAndCancel() }

        let log = ReplayAssemblyAIReceiveLog()
        let receiver = Task {
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    // The close reason is matched against fixed markers and dropped.
                    log.recordClose(AssemblyAIStreamingCore.failure(
                        closeCode: task.closeCode == .invalid ? nil : task.closeCode.rawValue,
                        closeReason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) },
                        httpStatus: nil
                    ))
                    break
                }
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                if log.record(AssemblyAIStreamingCore.ServerMessage(data: data), data: data, at: now()) { break }
            }
            log.markEnded()
        }

        func finish(
            sendFailed: Bool,
            timedOut: Bool,
            lastFrameAt: TimeInterval?,
            commitAt: TimeInterval?
        ) -> ReplayStreamOutcome {
            let state = log.snapshot
            func milliseconds(_ event: TimeInterval?) -> Double? {
                guard let event, let lastFrameAt else { return nil }
                return (event - lastFrameAt) * 1000
            }
            let releaseToFinal = commitAt.flatMap { commitAt in state.endOfTurnTimes.first { $0 >= commitAt } }
            return ReplayStreamOutcome(
                status: ReplayEvalCore.assemblyAIRunStatus(
                    failure: state.failure,
                    closeFailure: state.closeFailure,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                    began: state.beganAt != nil,
                    sendFailed: sendFailed,
                    terminated: state.terminationAt != nil,
                    timedOut: timedOut
                ),
                finalTranscript: state.assembler.finalTranscript,
                finals: state.finals,
                resultCount: state.assembler.turnMessageCount,
                unfinalizedAtEnd: state.assembler.hasPartialTail,
                millisecondsToFromFinalize: milliseconds(releaseToFinal),
                millisecondsToMetadata: milliseconds(state.terminationAt)
            )
        }

        // Wait for Begin: the app holds audio until then too.
        let connectDeadline = now() + timeoutSeconds
        while !log.hasBegunOrEnded, now() < connectDeadline {
            try? await sleep(seconds: 0.01)
        }
        guard let beganAt = log.snapshot.beganAt else {
            await closeSocket(task, sendingTerminate: true)
            await receiver.value
            return finish(sendFailed: false, timedOut: false, lastFrameAt: nil, commitAt: nil)
        }

        // Absolute schedule from Begin, by the audio before each chunk. A session that has
        // already ended (an Error frame or a close) gets nothing more.
        let offsets = ReplayEvalCore.sendOffsetsMilliseconds(
            chunkByteCounts: chunks.map(\.count),
            sampleRate: variant.sampleRate,
            pacing: variant.pacing
        )
        var lastFrameAt = beganAt
        var commitAt: TimeInterval?
        do {
            for (index, chunk) in chunks.enumerated() where !log.hasEnded {
                try await sleep(seconds: beganAt + offsets[index] / 1000 - now())
                try await task.send(.data(chunk))
                lastFrameAt = now()
            }
            if !log.hasEnded {
                commitAt = now()
                for message in AssemblyAIStreamingCore.CommitPolicy.commitMessages {
                    try await task.send(.string(message))
                }
            }
        } catch {
            await closeSocket(task, sendingTerminate: true)
            await receiver.value
            return finish(sendFailed: true, timedOut: false, lastFrameAt: lastFrameAt, commitAt: commitAt)
        }
        guard commitAt != nil else {
            await closeSocket(task, sendingTerminate: true)
            await receiver.value
            return finish(sendFailed: false, timedOut: false, lastFrameAt: lastFrameAt, commitAt: nil)
        }

        // Terminate makes the server flush the last turn, send Termination and close.
        let watchdog = Task { () -> Bool in
            do {
                try await sleep(seconds: timeoutSeconds)
            } catch {
                return false
            }
            task.cancel(with: .normalClosure, reason: nil)
            return true
        }
        await receiver.value
        watchdog.cancel()
        let timedOut = await watchdog.value
        // Terminate already went out with the commit.
        await closeSocket(task, sendingTerminate: false)
        return finish(sendFailed: false, timedOut: timedOut, lastFrameAt: lastFrameAt, commitAt: commitAt)
    }

    /// Sends Terminate when asked, which ends the billed session even if the close frame is
    /// lost, then closes the socket; the close waits terminateFlushSeconds at most for that
    /// send, as in the app.
    private static func closeSocket(_ task: URLSessionWebSocketTask, sendingTerminate: Bool) async {
        if sendingTerminate {
            let flushDeadline = Task {
                try? await sleep(seconds: AssemblyAIStreamingCore.terminateFlushSeconds)
                task.cancel(with: .normalClosure, reason: nil)
            }
            try? await task.send(.string(AssemblyAIStreamingCore.CommitPolicy.terminateMessage))
            flushDeadline.cancel()
        }
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// What the receive loop has seen, under a lock: the Begin wait and the send loop read it
/// while the loop runs. Turn text stays in the assembler; Error text was dropped at parse.
private final class ReplayAssemblyAIReceiveLog: @unchecked Sendable {
    struct State {
        var assembler = AssemblyAIStreamingCore.TurnAssembler()
        /// Word timings of each ended turn with text, in arrival order.
        var finals: [[ReplayEvalCore.WordTiming]] = []
        var endedTurns = Set<Int>()
        /// When each turn ended, in systemUptime seconds.
        var endOfTurnTimes: [TimeInterval] = []
        var beganAt: TimeInterval?
        var terminationAt: TimeInterval?
        var failure: AssemblyAIStreamingError?
        /// What the close code and reason reported, when the socket closed under the loop.
        var closeFailure: AssemblyAIStreamingError?
        var ended = false
    }

    private let lock = NSLock()
    private var state = State()

    var snapshot: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var hasEnded: Bool { snapshot.ended }

    var hasBegunOrEnded: Bool {
        let current = snapshot
        return current.beganAt != nil || current.ended
    }

    /// True once nothing more is expected: after Termination or an Error frame.
    func record(_ message: AssemblyAIStreamingCore.ServerMessage, data: Data, at time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        state.assembler.apply(message)
        switch message {
        case .begin:
            if state.beganAt == nil { state.beganAt = time }
        case .turn(let order, let transcript, let endOfTurn, _):
            // The assembler ignores later messages for an ended turn; so does this.
            guard endOfTurn, state.endedTurns.insert(order).inserted else { return false }
            state.endOfTurnTimes.append(time)
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.finals.append(ReplayEvalCore.wordTimings(fromTurnJSON: data))
            }
        case .termination:
            state.terminationAt = time
            return true
        case .error(let failure):
            if state.failure == nil { state.failure = failure }
            return true
        case .unknown:
            break
        }
        return false
    }

    func recordClose(_ failure: AssemblyAIStreamingError?) {
        lock.lock()
        state.closeFailure = failure
        lock.unlock()
    }

    func markEnded() {
        lock.lock()
        state.ended = true
        lock.unlock()
    }
}
