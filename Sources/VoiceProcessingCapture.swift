import AVFAudio
import Foundation
import os

/// Experimental capture through AVAudioEngine with Apple voice processing,
/// which makes macOS offer its Mic Mode menu (Voice Isolation) to this app.
/// Built only when a recording starts with that backend, and fully torn down
/// by `stop()`. Hands copied mono Float32 tap buffers to the caller's queue.
///
/// Does no logging: AudioRecorder logs the report, errors and stop status.
/// Not thread-safe. AudioRecorder only touches it on its session queue.
final class VoiceProcessingCapture {
    enum Step: String {
        case enableVoiceProcessing
        case startEngine
    }

    enum CaptureError: Error {
        case unsupportedOS
        case noInput(channels: AVAudioChannelCount, sampleRate: Double)
        /// The input node's voice-processed output format.
        case noInputNodeOutput(channels: AVAudioChannelCount, sampleRate: Double)
        case noOutput(channels: AVAudioChannelCount, sampleRate: Double)
        case invalidClientFormat
        case failed(Step, OSStatus)

        /// The OSStatus of a failed step, otherwise 0.
        var status: OSStatus {
            if case .failed(_, let status) = self { return status }
            return 0
        }

        /// Content-free: the step, or the channel count and rate.
        var logLabel: String {
            switch self {
            case .unsupportedOS: "unsupportedOS"
            case .noInput(let channels, let sampleRate): "noInput channels=\(channels) rate=\(sampleRate)"
            case .noInputNodeOutput(let channels, let sampleRate): "noInputNodeOutput channels=\(channels) rate=\(sampleRate)"
            case .noOutput(let channels, let sampleRate): "noOutput channels=\(channels) rate=\(sampleRate)"
            case .invalidClientFormat: "invalidClientFormat"
            case .failed(let step, _): step.rawValue
            }
        }
    }

    /// What a successful start set up; AGC and ducking are read back from the node.
    struct StartReport {
        let setupMilliseconds: Double
        let hardwareFormat: AVAudioFormat
        let tapFormat: AVAudioFormat
        let isAGCEnabled: Bool
        let duckingLevel: Int
    }

    /// Voice-processing AGC stays off for transcription; no UI changes it.
    static let isAGCEnabled = false
    /// Tap buffer length; the tap accepts 100-400 ms.
    static let tapBufferSeconds = 0.1

    /// A format's channel count and rate, as the start checks read them.
    typealias FormatShape = (channels: AVAudioChannelCount, sampleRate: Double)

    /// The error for the first input-side format with no channels or no
    /// rate, hardware first, carrying the format that failed; nil when both
    /// are usable.
    static func inputFormatError(hardware: FormatShape, inputNodeOutput: FormatShape) -> CaptureError? {
        guard hardware.channels > 0, hardware.sampleRate > 0 else {
            return .noInput(channels: hardware.channels, sampleRate: hardware.sampleRate)
        }
        guard inputNodeOutput.channels > 0, inputNodeOutput.sampleRate > 0 else {
            return .noInputNodeOutput(channels: inputNodeOutput.channels, sampleRate: inputNodeOutput.sampleRate)
        }
        return nil
    }

    private var engine: AVAudioEngine?
    private var isTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    /// Cleared first in `stop()`, so no buffer is queued after it returns.
    private let isDelivering = OSAllocatedUnfairLock(initialState: false)

    var isRunning: Bool { engine?.isRunning ?? false }

    deinit {
        stop()
    }

    /// Enables voice processing before any connection or tap, then starts the
    /// engine. Each tap buffer is copied (the tap reuses its buffers) and
    /// `onBuffer` runs on `queue`. `onConfigurationChange` runs on an arbitrary
    /// thread and must not stop the capture there. A throw leaves nothing running.
    func start(
        deliverOn queue: DispatchQueue,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onConfigurationChange: @escaping () -> Void
    ) throws -> StartReport {
        guard #available(macOS 14.0, *) else { throw CaptureError.unsupportedOS }
        let t0 = CFAbsoluteTimeGetCurrent()
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                throw CaptureError.failed(.enableVoiceProcessing, OSStatus(truncatingIfNeeded: (error as NSError).code))
            }
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            input.isVoiceProcessingAGCEnabled = Self.isAGCEnabled

            // A zero rate or channel count makes connect and installTap raise
            // exceptions Swift cannot catch, so it becomes a fallback here.
            let hardwareFormat = input.inputFormat(forBus: 0)
            let nodeFormat = input.outputFormat(forBus: 0)
            if let formatError = Self.inputFormatError(
                hardware: (hardwareFormat.channelCount, hardwareFormat.sampleRate),
                inputNodeOutput: (nodeFormat.channelCount, nodeFormat.sampleRate)
            ) {
                throw formatError
            }
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            guard outputFormat.channelCount > 0, outputFormat.sampleRate > 0 else {
                throw CaptureError.noOutput(channels: outputFormat.channelCount, sampleRate: outputFormat.sampleRate)
            }
            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: nodeFormat.sampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw CaptureError.invalidClientFormat
            }

            // The input node's output format must equal the output node's
            // input format, so both use the client format; nothing is played.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: clientFormat)
            engine.mainMixerNode.outputVolume = 0

            let isDelivering = self.isDelivering
            isDelivering.withLock { $0 = true }
            let bufferFrames = AVAudioFrameCount((clientFormat.sampleRate * Self.tapBufferSeconds).rounded())
            input.installTap(onBus: 0, bufferSize: bufferFrames, format: clientFormat) { buffer, _ in
                guard buffer.frameLength > 0,
                      let copy = PCMStreamResampler.slice(buffer, from: 0, count: buffer.frameLength) else { return }
                isDelivering.withLockUnchecked { delivering in
                    guard delivering else { return }
                    queue.async { onBuffer(copy) }
                }
            }
            isTapInstalled = true

            engine.prepare()
            do {
                try engine.start()
            } catch {
                throw CaptureError.failed(.startEngine, OSStatus(truncatingIfNeeded: (error as NSError).code))
            }

            // The engine stops itself on a device change and must not be
            // released inside this notification, so the handler only reports it.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                onConfigurationChange()
            }

            return StartReport(
                setupMilliseconds: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                hardwareFormat: hardwareFormat,
                tapFormat: clientFormat,
                isAGCEnabled: input.isVoiceProcessingAGCEnabled,
                duckingLevel: input.voiceProcessingOtherAudioDuckingConfiguration.duckingLevel.rawValue
            )
        } catch {
            stop()
            throw error
        }
    }

    /// Removes the tap, stops the engine, disables voice processing and
    /// releases the engine. Idempotent. Buffers already queued still run;
    /// a tap cannot be flushed, so the audio since its last delivery (under
    /// one tap period) is dropped.
    /// Returns the OSStatus of disabling voice processing (0 on success),
    /// since a failure there can leave other apps ducked.
    @discardableResult
    func stop() -> OSStatus {
        isDelivering.withLock { $0 = false }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return 0 }
        self.engine = nil
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
        do {
            try engine.inputNode.setVoiceProcessingEnabled(false)
        } catch {
            return OSStatus(truncatingIfNeeded: (error as NSError).code)
        }
        return 0
    }
}
