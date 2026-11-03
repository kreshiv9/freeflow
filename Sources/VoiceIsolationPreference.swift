import AVFAudio
import Foundation

/// Optional on-device voice isolation (Apple's AUSoundIsolation) applied to
/// the native capture buffers before they are converted for the WAV and the
/// stream. Off by default: speech-to-text services do best on unprocessed audio.
enum VoiceIsolationPreference: String, CaseIterable, Identifiable {
    case off
    case light
    case strong

    var id: String { rawValue }

    static let storageKey = "voice_isolation_mode"
    static let defaultValue: VoiceIsolationPreference = .off

    var displayName: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .strong: "Strong"
        }
    }

    /// The effect's wet/dry mix. Nil means no filter is built.
    var wetDryPercent: Float? {
        switch self {
        case .off: nil
        case .light: 70
        case .strong: 100
        }
    }

    /// Shown under the Settings picker.
    static let caption = "Removes background noise with Apple's on-device Voice Isolation before transcription. Speech-to-text services recommend unprocessed audio in quiet rooms, so leave this Off unless you dictate somewhere noisy. Needs macOS 15 and a 48 kHz microphone (the built-in mic qualifies) and adds about 0.1 s to live text."

    /// A stored value that parses wins; missing, invalid or non-string values
    /// give the default. Never persists.
    static func load(from defaults: UserDefaults) -> VoiceIsolationPreference {
        if let raw = defaults.object(forKey: storageKey) as? String,
           let mode = VoiceIsolationPreference(rawValue: raw) {
            return mode
        }
        return defaultValue
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    /// Capture formats the filter runs on. Measured: 16 kHz input distorts
    /// clean speech and 44.1 kHz loses about 3 dB, so only 48 kHz mono
    /// Float32 qualifies; anything else bypasses the filter.
    static func isSupported(sourceSampleRate: Double, channelCount: AVAudioChannelCount, isFloat32: Bool) -> Bool {
        sourceSampleRate == 48_000 && channelCount == 1 && isFloat32
    }

    /// Why the Settings picker is disabled, or nil when it can be used.
    static func unavailableReason(isSystemSupported: Bool, captureFormat: CaptureFormatPreference) -> String? {
        if !isSystemSupported {
            return "Voice isolation isn't available on this Mac. It needs macOS 15 or later."
        }
        if captureFormat == .legacy16k {
            return "Voice isolation needs the Native rate recording format."
        }
        return nil
    }

    /// The mode recordings use: Off whenever the Settings picker is disabled,
    /// so no filter is kept loaded that could never run.
    func effective(isSystemSupported: Bool, captureFormat: CaptureFormatPreference) -> VoiceIsolationPreference {
        Self.unavailableReason(isSystemSupported: isSystemSupported, captureFormat: captureFormat) == nil ? self : .off
    }

    /// Label for an `AVCaptureDevice.MicrophoneMode` raw value (0 standard,
    /// 1 wide spectrum, 2 voice isolation). Takes the raw value so this file
    /// stays free of AVFoundation.
    static func micModeDisplayName(rawValue: Int) -> String {
        switch rawValue {
        case 0: "Standard"
        case 1: "Wide Spectrum"
        case 2: "Voice Isolation"
        default: "Unknown"
        }
    }
}
