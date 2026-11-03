import AVFAudio
import Foundation

/// How the microphone is asked for audio. Both choices save a 16 kHz WAV and
/// stream 16 kHz to Deepgram; they differ in who converts from the device rate.
enum CaptureFormatPreference: String, CaseIterable, Identifiable {
    /// Float32 at the device's own rate, converted in-app by PCMStreamResampler.
    case native
    /// The previous request: 16 kHz Int16, converted by the capture output.
    case legacy16k

    var id: String { rawValue }

    static let storageKey = "capture_format"
    static let defaultValue: CaptureFormatPreference = .native

    var displayName: String {
        switch self {
        case .native: "Native rate (recommended)"
        case .legacy16k: "16 kHz (previous)"
        }
    }

    /// Shown under the Settings picker.
    static let caption = "Native rate records at your microphone's own rate (48 kHz on a MacBook mic) and converts to 16 kHz with a high-quality filter. 16 kHz (previous) lets macOS do that conversion, as earlier versions did. Both save a 16 kHz recording and stream 16 kHz to Deepgram."

    /// A stored value that parses wins; missing, invalid or non-string values
    /// give the default. Never persists.
    static func load(from defaults: UserDefaults) -> CaptureFormatPreference {
        if let raw = defaults.object(forKey: storageKey) as? String,
           let format = CaptureFormatPreference(rawValue: raw) {
            return format
        }
        return defaultValue
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    /// AVCaptureAudioDataOutput settings. Neither choice sets the
    /// sample-rate-converter keys, so `.legacy16k` stays the exact previous request.
    func audioSettings() -> [String: Any] {
        switch self {
        case .native:
            // No AVSampleRateKey: the output delivers the device's own rate.
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .legacy16k:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}
