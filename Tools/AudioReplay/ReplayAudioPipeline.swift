import AVFAudio
import AudioToolbox
import Foundation

/// Offline audio preparation for the replay tool: decode a file, apply the
/// variant's gain and optional AUSoundIsolation, and convert to the mono Int16
/// stream the variant sends. Tool-local copies of the PR 1 resampler settings
/// and the PR 3 isolation recipe. Works on whole files in memory, never opens an
/// audio device and never logs.
enum ReplayAudioPipeline {
    /// Fixed messages; none contains a path.
    enum PipelineError: Error, CustomStringConvertible {
        case unreadable
        case empty
        case converterUnavailable
        case conversionFailed
        case isolationNeedsHighRate(sampleRate: Double)
        case isolationUnavailable
        case renderFailed
        case isolationUnaligned

        var description: String {
            switch self {
            case .unreadable:
                "the audio file could not be read"
            case .empty:
                "the audio file has no samples"
            case .converterUnavailable:
                "no sample-rate converter for this format"
            case .conversionFailed:
                "sample-rate conversion failed"
            case .isolationNeedsHighRate(let sampleRate):
                "isolation needs a 44.1 or 48 kHz source; this one is \(Int(sampleRate)) Hz"
            case .isolationUnavailable:
                "AUSoundIsolation is unavailable here (hq needs macOS 15)"
            case .renderFailed:
                "isolation rendering failed"
            case .isolationUnaligned:
                "the isolated audio could not be aligned with the input (isolation may have removed nearly all of it)"
            }
        }
    }

    struct SourceAudio {
        /// Channel 0 as Float32 at the file's rate.
        var samples: [Float]
        var sampleRate: Double
        var channelCount: Int
        /// File format FourCC (lpcm, alac, aac), plus the bit depth for lpcm.
        var formatName: String

        var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    }

    /// Reads the whole file as AVAudioFile's standard deinterleaved Float32 and
    /// keeps channel 0, which equals a converter channelMap of [0].
    static func load(_ url: URL) throws -> SourceAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw PipelineError.unreadable
        }
        let format = file.processingFormat
        guard file.length > 0 else { throw PipelineError.empty }
        guard file.length < Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PipelineError.unreadable
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw PipelineError.unreadable
        }
        // frameLength, not file.length: the length of a compressed file is an estimate.
        guard buffer.frameLength > 0 else { throw PipelineError.empty }
        guard let channel = buffer.floatChannelData?[0] else { throw PipelineError.unreadable }
        return SourceAudio(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            formatName: formatName(of: file.fileFormat)
        )
    }

    private static func formatName(of format: AVAudioFormat) -> String {
        let description = format.streamDescription.pointee
        let id = description.mFormatID
        let bytes = [24, 16, 8, 0].map { UInt8((id >> UInt32($0)) & 0xFF) }
        var name = bytes.allSatisfy({ (0x20...0x7E).contains($0) })
            ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            : "unknown"
        if id == kAudioFormatLinearPCM {
            let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            name += " \(description.mBitsPerChannel)-bit\(isFloat ? " float" : "")"
        }
        return name
    }

    /// Gain (with a soft limiter for a boost when isolation follows), then
    /// isolation (if on), then conversion to the variant's rate as mono Int16.
    /// With isolation, the gain step runs inside isolate at 48 kHz, directly
    /// before the effect, so the model never gets input above -1 dBFS. A boost
    /// is also soft-limited after resampling, just before the first
    /// quantization to Int16, so the converter cannot push limited peaks back
    /// past the ceiling.
    static func render(_ source: SourceAudio, for variant: ReplayEvalCore.Variant) throws -> [Int16] {
        guard !source.samples.isEmpty else { throw PipelineError.empty }
        let samples: [Float]
        var sampleRate = source.sampleRate
        switch variant.isolation {
        case .off:
            samples = ReplayEvalCore.gained(source.samples, decibels: variant.gainDecibels, isolationFollows: false)
        case .highQualityVoice(let wetPercent):
            samples = try isolate(
                source.samples,
                sampleRate: sampleRate,
                gainDecibels: variant.gainDecibels,
                highQuality: true,
                wetPercent: wetPercent
            )
            sampleRate = isolationSampleRate
        case .voice(let wetPercent):
            samples = try isolate(
                source.samples,
                sampleRate: sampleRate,
                gainDecibels: variant.gainDecibels,
                highQuality: false,
                wetPercent: wetPercent
            )
            sampleRate = isolationSampleRate
        }
        let input = try floatBuffer(samples, sampleRate: sampleRate)
        let limits = variant.gainDecibels > 0
        let output: AVAudioPCMBuffer
        switch variant.resampler {
        case .legacyChain:
            // Stage 1 stands in for the capture output's undocumented 16 kHz conversion
            // (format only for a 16 kHz source); stage 2 is AudioRecorder's 16 -> 24 kHz
            // stream converter. Both are left at AVAudioConverter's defaults. A boost
            // is limited before stage 2, whose upsampling can overshoot it slightly.
            let capture = try quantized(try resampled(input, to: 16_000, configure: { _ in }), limits: limits)
            output = try convert(capture, to: int16Format(Double(variant.sampleRate)), configure: { _ in })
        default:
            let atRate = try resampled(input, to: Double(variant.sampleRate)) { converter in
                configure(converter, for: variant.resampler)
            }
            output = try quantized(atRate, limits: limits)
        }
        guard let channel = output.int16ChannelData?[0] else { throw PipelineError.conversionFailed }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Float32 at the target rate. Resampling to Float32 and then quantizing at
    /// the same rate gave the same Int16 samples as one Float32 -> Int16
    /// conversion with the same settings for every src on synthetic signals, so
    /// splitting the steps changes nothing without a boost.
    private static func resampled(
        _ input: AVAudioPCMBuffer,
        to sampleRate: Double,
        configure: (AVAudioConverter) -> Void
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw PipelineError.converterUnavailable
        }
        return try convert(input, to: format, configure: configure)
    }

    /// Optionally soft-limits, then converts Float32 to Int16 at the same rate.
    private static func quantized(_ input: AVAudioPCMBuffer, limits: Bool) throws -> AVAudioPCMBuffer {
        var buffer = input
        if limits {
            guard let channel = input.floatChannelData?[0] else { throw PipelineError.conversionFailed }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
            buffer = try floatBuffer(ReplayEvalCore.softLimited(samples), sampleRate: input.format.sampleRate)
        }
        return try convert(buffer, to: int16Format(input.format.sampleRate), configure: { _ in })
    }

    private static func configure(_ converter: AVAudioConverter, for resampler: ReplayEvalCore.Resampler) {
        switch resampler {
        case .minimumPhase:
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_MinimumPhase
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.dither = false
        case .masteringHigh:
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter.dither = false
        case .masteringMax:
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.dither = false
        case .normal, .legacyChain:
            // Untouched: Normal algorithm, medium quality, AVAudioConverter's default dither.
            break
        }
    }

    private static func int16Format(_ sampleRate: Double) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true) else {
            throw PipelineError.converterUnavailable
        }
        return format
    }

    private static func floatBuffer(_ samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty else { throw PipelineError.empty }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw PipelineError.converterUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }

    /// Whole-buffer conversion: the input block hands out slices of at most the
    /// requested size, then .endOfStream once the input is used up, and the loop
    /// drains 4096-frame output chunks while the converter reports .haveData.
    private static func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        configure: (AVAudioConverter) -> Void
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            throw PipelineError.converterUnavailable
        }
        configure(converter)
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 4096
        guard let result = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity),
              let chunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
            throw PipelineError.converterUnavailable
        }
        let inputBytesPerFrame = Int(input.format.streamDescription.pointee.mBytesPerFrame)
        let outputBytesPerFrame = Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        var offset: AVAudioFrameCount = 0
        var emptyHaveDataCount = 0

        while true {
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { requested, inputStatus in
                let remaining = input.frameLength - offset
                guard remaining > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(remaining, requested)
                guard let piece = slice(input, from: offset, count: count, bytesPerFrame: inputBytesPerFrame) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                offset += count
                inputStatus.pointee = .haveData
                return piece
            }
            if status == .error { throw PipelineError.conversionFailed }
            if chunk.frameLength > 0 {
                guard result.frameLength + chunk.frameLength <= result.frameCapacity else {
                    throw PipelineError.conversionFailed
                }
                try copyFrames(of: chunk, into: result, bytesPerFrame: outputBytesPerFrame)
                emptyHaveDataCount = 0
            } else if status == .haveData {
                // Guards against a converter that keeps answering .haveData with nothing.
                emptyHaveDataCount += 1
                if emptyHaveDataCount > 16 { throw PipelineError.conversionFailed }
            }
            if status != .haveData { break }
        }
        return result
    }

    /// Copies `count` frames starting at `start` into a new buffer, every buffer of the list.
    private static func slice(
        _ source: AVAudioPCMBuffer,
        from start: AVAudioFrameCount,
        count: AVAudioFrameCount,
        bytesPerFrame: Int
    ) -> AVAudioPCMBuffer? {
        guard let slice = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else { return nil }
        slice.frameLength = count
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let sourceData = from[index].mData, let destination = to[index].mData else { return nil }
            memcpy(destination, sourceData.advanced(by: Int(start) * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        return slice
    }

    private static func copyFrames(of chunk: AVAudioPCMBuffer, into result: AVAudioPCMBuffer, bytesPerFrame: Int) throws {
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: chunk.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let sourceData = from[index].mData, let destination = to[index].mData else {
                throw PipelineError.conversionFailed
            }
            memcpy(
                destination.advanced(by: Int(result.frameLength) * bytesPerFrame),
                sourceData,
                Int(chunk.frameLength) * bytesPerFrame
            )
        }
        result.frameLength += chunk.frameLength
    }

    // MARK: Isolation

    private static let isolationSampleRate = 48_000.0
    private static let isolationMaxFrames: AVAudioFrameCount = 4096

    private static let isolationDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Runs AUSoundIsolation in an offline manual-rendering engine at 48 kHz mono.
    /// A 44.1 kHz source is first converted to 48 kHz (MinimumPhase/max), then
    /// the gain step runs, so a boost is soft-limited directly before the effect
    /// and no conversion sits between the limiter and the effect's input. The
    /// output is aligned with that input and has its length. Never touches the
    /// engine's input node, so no device or permission is involved.
    private static func isolate(
        _ samples: [Float],
        sampleRate: Double,
        gainDecibels: Double,
        highQuality: Bool,
        wetPercent: Int
    ) throws -> [Float] {
        guard sampleRate >= 44_100 else { throw PipelineError.isolationNeedsHighRate(sampleRate: sampleRate) }
        let soundType: Float
        if highQuality {
            guard #available(macOS 15, *) else { throw PipelineError.isolationUnavailable }
            soundType = Float(kAUSoundIsolationSoundType_HighQualityVoice)
        } else {
            soundType = Float(kAUSoundIsolationSoundType_Voice)
        }
        var description = isolationDescription
        guard AudioComponentFindNext(nil, &description) != nil else { throw PipelineError.isolationUnavailable }

        var input = samples
        if sampleRate != isolationSampleRate {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: isolationSampleRate, channels: 1) else {
                throw PipelineError.converterUnavailable
            }
            let converted = try convert(try floatBuffer(samples, sampleRate: sampleRate), to: format) { converter in
                configure(converter, for: .minimumPhase)
            }
            guard let channel = converted.floatChannelData?[0] else { throw PipelineError.conversionFailed }
            input = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        }
        // The conversion is linear, so gain after it equals gain before it; only
        // the limiter's place changes, and here a converter's ringing cannot
        // push the effect's input back past -1 dBFS.
        input = ReplayEvalCore.gained(input, decibels: gainDecibels, isolationFollows: true)
        guard !input.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: isolationSampleRate, channels: 1) else {
            throw PipelineError.empty
        }

        let engine = AVAudioEngine()
        // Manual rendering must be enabled before mainMixerNode is first touched.
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: isolationMaxFrames)
        } catch {
            throw PipelineError.isolationUnavailable
        }
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: isolationDescription)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        guard AudioUnitSetParameter(
            effect.audioUnit,
            AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),
            kAudioUnitScope_Global, 0, soundType, 0
        ) == noErr,
            AudioUnitSetParameter(
                effect.audioUnit,
                AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),
                kAudioUnitScope_Global, 0, Float(wetPercent), 0
            ) == noErr else {
            throw PipelineError.isolationUnavailable
        }
        do {
            try engine.start()
        } catch {
            throw PipelineError.isolationUnavailable
        }
        defer { engine.stop() }
        player.play()

        // The reported latency is not always the real offline delay: many instances
        // after the first one or two in a process run one render slice
        // (isolationMaxFrames) later. Render enough padding for either delay and keep
        // the one whose window matches the input; the dry mix, or the isolated
        // speech, correlates far better there than one slice away.
        let latencyFrames = Int((effect.auAudioUnit.latency * isolationSampleRate).rounded())
        let candidates = [latencyFrames, latencyFrames + Int(isolationMaxFrames)]
        let padded = input + [Float](repeating: 0, count: latencyFrames + Int(isolationMaxFrames) + 960)
        let scheduled = try floatBuffer(padded, sampleRate: isolationSampleRate)
        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: isolationMaxFrames) else {
            throw PipelineError.renderFailed
        }
        player.scheduleBuffer(scheduled, at: nil)

        var output: [Float] = []
        output.reserveCapacity(padded.count)
        while output.count < padded.count {
            let frames = min(AVAudioFrameCount(padded.count - output.count), isolationMaxFrames)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(frames, to: rendered)
            } catch {
                throw PipelineError.renderFailed
            }
            guard status == .success, rendered.frameLength > 0,
                  let channel = rendered.floatChannelData?[0] else { throw PipelineError.renderFailed }
            output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(rendered.frameLength)))
        }
        guard let offset = ReplayEvalCore.bestAlignmentOffset(output: output, input: input, candidates: candidates) else {
            throw PipelineError.isolationUnaligned
        }
        return Array(output[offset..<(offset + input.count)])
    }
}
