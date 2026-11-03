import Foundation

/// Wall-clock durations for one dictation's stop path, in milliseconds per
/// stage. A nil stage did not run (for example no paste after an empty
/// transcript). Holds numbers and a fixed source label only, never transcript
/// content, so it is safe to persist and log.
struct PipelineStageTimings: Codable, Equatable, Sendable {
    static let realtimeTranscriptionSource = "realtime"
    static let fileTranscriptionSource = "file"

    /// Shortcut release until the audio file is ready for transcription.
    var audioFinalizeMilliseconds: Int? = nil
    /// Duration of resolveRawTranscript (realtime commit or file upload).
    var transcriptionMilliseconds: Int? = nil
    /// Which transcription path produced the transcript; nil when it never completed.
    var transcriptionSource: String? = nil
    /// Time spent waiting inside resolveSessionContext.
    var contextWaitMilliseconds: Int? = nil
    /// Duration of processTranscript.
    var cleanupMilliseconds: Int? = nil
    /// End of cleanup until the paste or insertion action fired.
    var pasteDispatchMilliseconds: Int? = nil
    /// Shortcut release until the paste or insertion action fired.
    var totalMilliseconds: Int? = nil

    /// Raw CFAbsoluteTime marks captured along the stop path. Each mark is nil
    /// until its point in the pipeline is reached.
    struct Marks: Equatable, Sendable {
        var stopRequested: CFAbsoluteTime? = nil
        var audioReady: CFAbsoluteTime? = nil
        var transcriptionStarted: CFAbsoluteTime? = nil
        var transcriptionFinished: CFAbsoluteTime? = nil
        var transcriptionSource: String? = nil
        var contextStarted: CFAbsoluteTime? = nil
        var contextFinished: CFAbsoluteTime? = nil
        var cleanupStarted: CFAbsoluteTime? = nil
        var cleanupFinished: CFAbsoluteTime? = nil
        var pasteFired: CFAbsoluteTime? = nil

        var timings: PipelineStageTimings {
            PipelineStageTimings(marks: self)
        }
    }

    /// Stages joined with " · " in pipeline order, omitting nil stages.
    /// Example: "audio 40 ms · transcription 820 ms · context 0 ms · cleanup 610 ms · paste 35 ms · total 1.5 s".
    var summaryLine: String {
        var parts: [String] = []
        if let audioFinalizeMilliseconds {
            parts.append("audio \(Self.formatted(milliseconds: audioFinalizeMilliseconds))")
        }
        if let transcriptionMilliseconds {
            var part = "transcription \(Self.formatted(milliseconds: transcriptionMilliseconds))"
            if let transcriptionSource, !transcriptionSource.isEmpty {
                part += " (\(transcriptionSource))"
            }
            parts.append(part)
        }
        if let contextWaitMilliseconds {
            parts.append("context \(Self.formatted(milliseconds: contextWaitMilliseconds))")
        }
        if let cleanupMilliseconds {
            parts.append("cleanup \(Self.formatted(milliseconds: cleanupMilliseconds))")
        }
        if let pasteDispatchMilliseconds {
            parts.append("paste \(Self.formatted(milliseconds: pasteDispatchMilliseconds))")
        }
        if let totalMilliseconds {
            parts.append("total \(Self.formatted(milliseconds: totalMilliseconds))")
        }
        return parts.joined(separator: " · ")
    }

    /// Milliseconds below one second, otherwise seconds with one decimal
    /// (integer round-half-up so the output is locale independent).
    static func formatted(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds) ms"
        }
        let tenths = (milliseconds + 50) / 100
        return "\(tenths / 10).\(tenths % 10) s"
    }

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Extra initializers live in an extension so the memberwise init survives.
extension PipelineStageTimings {
    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PipelineStageTimings.self, from: data) else {
            return nil
        }
        self = decoded
    }

    init(marks: Marks) {
        self.init(
            audioFinalizeMilliseconds: Self.milliseconds(from: marks.stopRequested, to: marks.audioReady),
            transcriptionMilliseconds: Self.milliseconds(
                from: marks.transcriptionStarted, to: marks.transcriptionFinished
            ),
            transcriptionSource: marks.transcriptionSource,
            contextWaitMilliseconds: Self.milliseconds(from: marks.contextStarted, to: marks.contextFinished),
            cleanupMilliseconds: Self.milliseconds(from: marks.cleanupStarted, to: marks.cleanupFinished),
            pasteDispatchMilliseconds: Self.milliseconds(from: marks.cleanupFinished, to: marks.pasteFired),
            totalMilliseconds: Self.milliseconds(from: marks.stopRequested, to: marks.pasteFired)
        )
    }

    /// Nil when either mark is missing; negative deltas clamp to 0 because
    /// CFAbsoluteTimeGetCurrent() is wall-clock time and can step backwards.
    static func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1000).rounded()))
    }

    /// Carries one dictation's paste-fired handler from the stop path to the
    /// shortcut-release gate. The paste-fired mark is sampled as the gate
    /// opens, but the handler's bookkeeping (store write, published updates,
    /// logging) runs only after the gated action, keeping it off the path
    /// between the gate and the keystroke. An action that returns without
    /// dispatching a paste or insert reports `dispatched: false` itself; the
    /// handler then receives nil so the paste and total stages stay empty
    /// instead of claiming a paste that never happened.
    final class PasteGate {
        typealias Handler = (CFAbsoluteTime?) -> Void

        private let now: () -> CFAbsoluteTime
        private var scheduledHandler: Handler?
        private var armedHandler: Handler?
        private var armedFiredAt: CFAbsoluteTime?

        init(now: @escaping () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent) {
            self.now = now
        }

        /// Called by the stop path right before it dispatches a paste.
        func schedule(_ handler: @escaping Handler) {
            scheduledHandler = handler
        }

        /// Wraps the next gated action with the scheduled handler, or returns
        /// the action unchanged when nothing is scheduled.
        func wrappingScheduledPaste(_ action: @escaping () -> Void) -> () -> Void {
            guard let handler = scheduledHandler else { return action }
            scheduledHandler = nil
            return { [self] in
                armedHandler = handler
                armedFiredAt = now()
                action()
                report(dispatched: true)
            }
        }

        /// Runs the armed handler once, with the mark when the paste or
        /// insertion was dispatched and nil when the action skipped it. Later
        /// reports for the same action are ignored.
        func report(dispatched: Bool) {
            guard let handler = armedHandler, let firedAt = armedFiredAt else { return }
            armedHandler = nil
            armedFiredAt = nil
            handler(dispatched ? firedAt : nil)
        }
    }
}
