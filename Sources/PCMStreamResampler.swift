import AVFAudio
import Foundation

/// Converts a live PCM stream (any PCM capture format, typically 48 kHz
/// Float32) to mono Int16 at a fixed output rate with an explicitly configured
/// sample-rate converter. Use one instance per output stream per recording:
/// feed every capture buffer to `process(_:emit:)` in order, then call
/// `finish(emit:)` once at stop to flush the filter's held-back tail.
///
/// Not thread-safe. AudioRecorder only touches it on its sample-buffer queue.
final class PCMStreamResampler {
    enum Algorithm {
        case minimumPhase
        case mastering
        case normal

        fileprivate var converterValue: String {
            switch self {
            case .minimumPhase: AVSampleRateConverterAlgorithm_MinimumPhase
            case .mastering: AVSampleRateConverterAlgorithm_Mastering
            case .normal: AVSampleRateConverterAlgorithm_Normal
            }
        }
    }

    enum ResamplerError: LocalizedError, Equatable {
        case unsupportedFormat
        case formatMismatch
        case finished
        case outputAllocationFailed
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                "Audio format conversion is not supported for this input."
            case .formatMismatch:
                "Audio buffer format does not match the converter input."
            case .finished:
                "Audio converter was already finished."
            case .outputAllocationFailed:
                "Could not allocate the converted audio buffer."
            case .conversionFailed(let details):
                "Audio conversion failed: \(details)"
            }
        }
    }

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let ratio: Double
    private let outputCapacityLimit: AVAudioFrameCount?
    private var isFinished = false

    /// `outputCapacityLimit` is a test seam that caps every output buffer so
    /// tests can force the drain loops; production leaves it nil.
    init(
        inputFormat: AVAudioFormat,
        outputSampleRate: Double,
        algorithm: Algorithm = .minimumPhase,
        quality: AVAudioQuality = .max,
        outputCapacityLimit: AVAudioFrameCount? = nil
    ) throws {
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: output) else {
            throw ResamplerError.unsupportedFormat
        }
        // Configured before the first convert.
        converter.sampleRateConverterAlgorithm = algorithm.converterValue
        converter.sampleRateConverterQuality = quality.rawValue
        converter.dither = false
        if inputFormat.channelCount > 1 {
            // Keep channel 0. The default map and downmix both give exact
            // silence for discrete multichannel layouts (B11).
            converter.channelMap = [0]
        }
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
        self.ratio = outputSampleRate / inputFormat.sampleRate
        self.outputCapacityLimit = outputCapacityLimit.map { max($0, 1) }
    }

    /// Converts one capture buffer and emits every ready output chunk. A call
    /// that emits nothing is normal: some filters hold the first frames until
    /// more input arrives (B3).
    func process(_ input: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !isFinished else { throw ResamplerError.finished }
        guard input.format == inputFormat else { throw ResamplerError.formatMismatch }
        let total = input.frameLength
        guard total > 0 else { return }

        var offset: AVAudioFrameCount = 0
        let capacity = outputCapacity(AVAudioFrameCount(ceil(Double(total) * ratio)) + 64)
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw ResamplerError.outputAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                let remaining = total - offset
                guard remaining > 0 else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                // Honor the request size: handing the converter more than it
                // asked for parks the excess and adds 16-170 ms of lag for
                // large capture buffers.
                let count = min(remaining, requested)
                guard let slice = Self.slice(input, from: offset, count: count) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                offset += count
                inputStatus.pointee = .haveData
                return slice
            }
            if status == .error {
                throw ResamplerError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            if output.frameLength > 0 {
                try emit(output)
            }
            // .haveData means the output filled up with input left over, so
            // drain again; a single call would drop the rest of the chunk (B1).
            // Zero frames with .haveData would never progress, so stop there.
            guard status == .haveData, output.frameLength > 0 else { break }
        }
    }

    /// Flushes the filter tail (B2). Call once at stop, before closing the WAV
    /// or finalizing the provider stream. Later calls emit nothing.
    func finish(emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard !isFinished else { return }
        isFinished = true
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity(4096)) else {
                throw ResamplerError.outputAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error {
                throw ResamplerError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            if output.frameLength > 0 {
                try emit(output)
            }
            guard status == .haveData, output.frameLength > 0 else { break }
        }
    }

    /// Channel 0 of an Int16 buffer as bytes in host order, which is
    /// little-endian on every supported Mac. Empty for other formats.
    static func littleEndianData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard buffer.frameLength > 0, let samples = buffer.int16ChannelData?[0] else { return Data() }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Content-free log label, e.g. "pcmFormatFloat32 48000Hz 1 ch interleaved=true".
    static func formatSummary(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32: commonFormat = "pcmFormatFloat32"
        case .pcmFormatFloat64: commonFormat = "pcmFormatFloat64"
        case .pcmFormatInt16: commonFormat = "pcmFormatInt16"
        case .pcmFormatInt32: commonFormat = "pcmFormatInt32"
        default: commonFormat = "otherFormat"
        }
        return String(
            format: "%@ %.0fHz %u ch interleaved=%@",
            commonFormat,
            format.sampleRate,
            format.channelCount,
            String(format.isInterleaved)
        )
    }

    private func outputCapacity(_ preferred: AVAudioFrameCount) -> AVAudioFrameCount {
        guard let outputCapacityLimit else { return preferred }
        return min(preferred, outputCapacityLimit)
    }

    /// Copies `count` frames starting at `start` into a new buffer (all
    /// channels, interleaved or not). Also copies the voice-processing tap's
    /// reused buffers.
    static func slice(_ source: AVAudioPCMBuffer, from start: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let slice = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else { return nil }
        slice.frameLength = count
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let sourceData = from[index].mData, let destinationData = to[index].mData else { return nil }
            memcpy(destinationData, sourceData.advanced(by: Int(start) * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        return slice
    }
}
