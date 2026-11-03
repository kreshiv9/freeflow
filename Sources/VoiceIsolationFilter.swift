import AVFAudio
import AudioToolbox
import Foundation

/// Apple's on-device voice isolation (AUSoundIsolation, High Quality Voice
/// model) on 48 kHz mono Float32 capture buffers, run in an offline
/// manual-rendering engine: no audio hardware, input node or permission.
/// Output is latency-compensated so a recording keeps its exact length.
///
/// Not thread-safe. AudioRecorder builds it off the capture path, then uses
/// it on its sample-buffer queue only.
final class VoiceIsolationFilter {
    enum FilterError: LocalizedError, Equatable {
        case unsupportedFormat
        case finished
        case renderFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "Voice isolation needs 48 kHz mono Float32 audio."
            case .finished: "Voice isolation was already finished."
            case .renderFailed(let status): "Voice isolation render failed (OSStatus \(status))."
            }
        }
    }

    static let sampleRate: Double = 48_000

    /// The AUSoundIsolation component is registered. No instance is created.
    static var isComponentAvailable: Bool {
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    /// macOS 15 or later (High Quality Voice model) and the component exists.
    static var isAvailable: Bool {
        guard #available(macOS 15, *) else { return false }
        return isComponentAvailable
    }

    let wetDryPercent: Float
    /// Model delay in frames (about 4,440 = 92.5 ms); dropped from the start.
    let latencyFrames: Int
    private let engine: AVAudioEngine
    private let effect: AVAudioUnitEffect
    private let fifo: SampleFIFO
    /// Raw input not yet emitted, for takeUnemittedInput.
    private let heldInput = SampleFIFO()
    private let renderBuffer: AVAudioPCMBuffer
    private var inputFrames = 0
    private var renderedFrames = 0
    private var emittedFrames = 0
    private var emitFormat: AVAudioFormat?
    private var isFinished = false
    /// False while the model may hold input that no silence has pushed out.
    private var isDrained = true

    /// Nil below macOS 15, when the component is missing, or when any engine
    /// step fails. Never touches the engine's input node.
    init?(wetDryPercent: Float, maximumFrameCount: AVAudioFrameCount = 4_096) {
        guard #available(macOS 15, *), Self.isComponentAvailable,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            return nil
        }
        let engine = AVAudioEngine()
        do {
            // Before mainMixerNode: touching it first would wire the hardware output.
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
        } catch {
            return nil
        }
        let fifo = SampleFIFO()
        // A source node pulls exactly the frames each render asks for. A
        // player node fed per chunk adds a variable delay of up to one render
        // slice, which breaks the latency compensation.
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers.first?.mData else { return noErr }
            fifo.read(into: data.assumingMemoryBound(to: Float.self), count: Int(frameCount))
            return noErr
        }
        let effect = AVAudioUnitEffect(audioComponentDescription: Self.componentDescription)
        engine.attach(source)
        engine.attach(effect)
        engine.connect(source, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        guard AudioUnitSetParameter(
            effect.audioUnit,
            AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
            kAudioUnitScope_Global,
            0,
            AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice),
            0
        ) == noErr, AudioUnitSetParameter(
            effect.audioUnit,
            AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
            kAudioUnitScope_Global,
            0,
            wetDryPercent,
            0
        ) == noErr else {
            return nil
        }
        do {
            try engine.start()
        } catch {
            return nil
        }
        guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrameCount) else {
            return nil
        }
        self.wetDryPercent = wetDryPercent
        // Valid only once the engine has started.
        self.latencyFrames = max(0, Int((effect.auAudioUnit.latency * Self.sampleRate).rounded()))
        self.engine = engine
        self.effect = effect
        self.fifo = fifo
        self.renderBuffer = renderBuffer
    }

    deinit {
        engine.stop()
    }

    /// The model the effect reports it runs (kAUSoundIsolationSoundType_*;
    /// High Quality Voice is 0). Nil when the read fails or is not a whole
    /// number.
    var appliedSoundToIsolate: Int? {
        parameter(AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate)).flatMap { Int(exactly: $0) }
    }

    /// The wet/dry mix the effect reports it applies. Nil when the read fails.
    var appliedWetDryPercent: Float? {
        parameter(AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent))
    }

    private func parameter(_ id: AudioUnitParameterID) -> AudioUnitParameterValue? {
        var value: AudioUnitParameterValue = 0
        guard AudioUnitGetParameter(effect.audioUnit, id, kAudioUnitScope_Global, 0, &value) == noErr else {
            return nil
        }
        return value
    }

    /// Isolates one capture buffer and emits the processed audio, delayed by
    /// `latencyFrames` and in the input buffer's format. The first
    /// `latencyFrames` of a recording emit nothing; `finish` returns them.
    /// `unsupportedFormat` and `finished` are thrown before the buffer is
    /// taken; after `renderFailed` it is part of `takeUnemittedInput()`.
    func process(_ input: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !isFinished else { throw FilterError.finished }
        let format = input.format
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 1,
              format.sampleRate == Self.sampleRate,
              let samples = input.floatChannelData?[0] else {
            throw FilterError.unsupportedFormat
        }
        let count = Int(input.frameLength)
        guard count > 0 else { return }
        emitFormat = format
        fifo.append(samples, count: count)
        heldInput.append(samples, count: count)
        inputFrames += count
        isDrained = false
        try render(count, emit: emit)
    }

    /// Pushes the model's delay worth of silence and emits the held-back
    /// tail, so total output equals total input. Later calls emit nothing.
    func finish(emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !isFinished else { return }
        isFinished = true
        guard inputFrames > 0 else { return }
        fifo.appendSilence(count: latencyFrames)
        try render(inputFrames + latencyFrames - renderedFrames, emit: emit)
        isDrained = true
    }

    /// Ends the run for a caller that gives up on the filter: returns the raw
    /// input taken but not yet emitted (the model's delay, plus the failing
    /// buffer after `renderFailed`), so it can go on unprocessed with no gap
    /// and no repeats. Nil when nothing is held. Later `process` calls throw
    /// `finished` until `reset()`.
    func takeUnemittedInput() -> AVAudioPCMBuffer? {
        isFinished = true
        let count = heldInput.count
        guard count > 0,
              let format = emitFormat,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let destination = output.floatChannelData?[0] else {
            return nil
        }
        heldInput.read(into: destination, count: count)
        output.frameLength = AVAudioFrameCount(count)
        emittedFrames += count
        return output
    }

    /// Clears the model state, queued samples and counters so nothing from
    /// one recording reaches the next, and restarts a stopped engine.
    /// engine.reset() keeps the input the model is holding, so a run that
    /// finish did not flush (a cancelled or failed recording) is drained
    /// with silence first.
    func reset() {
        if !isDrained {
            drain()
        }
        engine.reset()
        if !engine.isRunning {
            try? engine.start()
        }
        fifo.removeAll()
        heldInput.removeAll()
        inputFrames = 0
        renderedFrames = 0
        emittedFrames = 0
        emitFormat = nil
        isFinished = false
        isDrained = true
    }

    /// Renders the model's delay worth of silence and discards it, as finish
    /// does, so the model holds only zeros. Stops at a render failure.
    private func drain() {
        // Unread input is dropped; an empty FIFO reads as silence.
        fifo.removeAll()
        var remaining = latencyFrames
        while remaining > 0 {
            let request = AVAudioFrameCount(min(remaining, Int(renderBuffer.frameCapacity)))
            guard (try? engine.renderOffline(request, to: renderBuffer)) == .success,
                  renderBuffer.frameLength > 0 else {
                return
            }
            remaining -= Int(renderBuffer.frameLength)
        }
    }

    private func render(_ frameCount: Int, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        var remaining = frameCount
        while remaining > 0 {
            let request = AVAudioFrameCount(min(remaining, Int(renderBuffer.frameCapacity)))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(request, to: renderBuffer)
            } catch {
                throw FilterError.renderFailed(OSStatus(truncatingIfNeeded: (error as NSError).code))
            }
            let rendered = Int(renderBuffer.frameLength)
            guard status == .success, rendered > 0 else {
                throw FilterError.renderFailed(OSStatus(truncatingIfNeeded: status.rawValue))
            }
            // Drop the model's delay at the start, and never emit past the input.
            let skip = max(0, min(rendered, latencyFrames - renderedFrames))
            let take = min(rendered - skip, inputFrames - emittedFrames)
            renderedFrames += rendered
            remaining -= rendered
            guard take > 0 else { continue }
            guard let format = emitFormat,
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(take)),
                  let source = renderBuffer.floatChannelData?[0],
                  let destination = output.floatChannelData?[0] else {
                throw FilterError.renderFailed(OSStatus(kAudio_MemFullError))
            }
            output.frameLength = AVAudioFrameCount(take)
            destination.update(from: source + skip, count: take)
            emittedFrames += take
            heldInput.discard(take)
            try emit(output)
        }
    }

    private static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

/// Samples waiting for the engine to pull them. Shortfalls read as silence.
private final class SampleFIFO {
    private var samples: [Float] = []
    private var readIndex = 0

    var count: Int { samples.count - readIndex }

    func append(_ source: UnsafePointer<Float>, count: Int) {
        compact()
        samples.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
    }

    func appendSilence(count: Int) {
        compact()
        samples.append(contentsOf: repeatElement(0, count: count))
    }

    func read(into destination: UnsafeMutablePointer<Float>, count: Int) {
        let available = max(0, min(count, samples.count - readIndex))
        if available > 0 {
            samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress! + readIndex, count: available) }
            readIndex += available
        }
        if available < count {
            (destination + available).update(repeating: 0, count: count - available)
        }
    }

    func discard(_ count: Int) {
        readIndex = min(samples.count, readIndex + count)
    }

    func removeAll() {
        samples.removeAll(keepingCapacity: true)
        readIndex = 0
    }

    private func compact() {
        guard readIndex > 0 else { return }
        samples.removeFirst(readIndex)
        readIndex = 0
    }
}
