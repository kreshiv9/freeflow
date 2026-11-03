import AVFAudio
import Foundation

/// The voice-processing tap's first-second digital-zero check: voice
/// processing can run yet deliver exact zeros, which the buffer watchdog
/// cannot see. Decides once, live on the first non-silent buffer or silent
/// after one second of zeros.
struct VoiceProcessingLiveness: Equatable {
    enum State: Equatable {
        case waiting
        case live
        case silent
    }

    static let silenceLimitSeconds: Double = 1

    private(set) var state: State = .waiting
    private(set) var silentFrames = 0

    /// Returns the new state only on the buffer that decides it, otherwise
    /// nil. Frames are counted, not seconds summed: ten 0.1 s buffers sum to
    /// just under one second. Empty buffers and invalid rates are ignored.
    mutating func observe(frameCount: Int, sampleRate: Double, isSilent: Bool) -> State? {
        guard state == .waiting, frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return nil }
        guard isSilent else {
            state = .live
            return .live
        }
        silentFrames += frameCount
        guard Double(silentFrames) >= sampleRate * Self.silenceLimitSeconds else { return nil }
        state = .silent
        return .silent
    }

    /// True when channel 0 of a Float32 buffer is all exact zeros (-0.0
    /// included, NaN counts as signal). Only channel 0 is checked because the
    /// resampler keeps only channel 0. Other formats count as signal, so they
    /// never force a fallback.
    static func isChannelZeroSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let channels = buffer.floatChannelData else {
            return false
        }
        let samples = channels[0]
        let stride = buffer.stride
        for frame in 0..<Int(buffer.frameLength) where samples[frame * stride] != 0 {
            return false
        }
        return true
    }
}
