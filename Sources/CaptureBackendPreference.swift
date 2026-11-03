import Foundation

/// Which path records the microphone. Standard is the capture session; Apple
/// voice processing is an experimental engine path that turns on the macOS
/// Mic Mode menu and switches back to Standard on its own when it fails.
enum CaptureBackendPreference: String, CaseIterable, Identifiable {
    /// The AVCaptureSession path every earlier version used.
    case standard
    /// AVAudioEngine with Apple voice processing (macOS 14+).
    case appleVoiceProcessing

    var id: String { rawValue }

    static let storageKey = "capture_backend"
    static let defaultValue: CaptureBackendPreference = .standard

    var displayName: String {
        switch self {
        case .standard: "Standard (recommended)"
        case .appleVoiceProcessing: "Apple voice processing (experimental)"
        }
    }

    /// Shown under the Settings picker.
    static let caption = "Apple voice processing turns on the macOS Mic Mode menu for this app while you record (Control Center > Mic Mode > Voice Isolation). That system mode is separate from the Voice isolation setting above; leave that Off while you use Mic Mode Voice Isolation, since running both can clip the start of words. Experimental: it may lower other apps' volume while you dictate, works only with the System Default microphone and the Native rate format, and switches back to Standard automatically if it fails."

    /// A stored value that parses wins; missing, invalid or non-string values
    /// give the default. Never persists.
    static func load(from defaults: UserDefaults) -> CaptureBackendPreference {
        if let raw = defaults.object(forKey: storageKey) as? String,
           let backend = CaptureBackendPreference(rawValue: raw) {
            return backend
        }
        return defaultValue
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }

    /// The voice-processing ducking configuration needs macOS 14.
    static var osSupportsDucking: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Why a recording uses Standard although voice processing was chosen.
    /// Raw values are content-free log labels; `message` is the UI text.
    enum FallbackReason: String, Equatable {
        case requiresMacOS14
        case requiresNativeFormat
        case requiresDefaultMicrophone

        var message: String {
            switch self {
            case .requiresMacOS14: "Apple voice processing needs macOS 14 or later."
            case .requiresNativeFormat: "Apple voice processing needs the Native rate recording format."
            case .requiresDefaultMicrophone: "Apple voice processing works only with the System Default microphone."
            }
        }
    }

    struct Resolution: Equatable {
        let backend: CaptureBackendPreference
        let reason: FallbackReason?
    }

    /// The backend a recording starts with. Standard never resolves to voice
    /// processing; otherwise the first failing check (OS, format, mic) wins.
    static func resolve(
        preference: CaptureBackendPreference,
        osSupportsDucking: Bool,
        isDefaultInputSelected: Bool,
        captureFormat: CaptureFormatPreference
    ) -> Resolution {
        guard preference == .appleVoiceProcessing else {
            return Resolution(backend: .standard, reason: nil)
        }
        if !osSupportsDucking {
            return Resolution(backend: .standard, reason: .requiresMacOS14)
        }
        if captureFormat != .native {
            return Resolution(backend: .standard, reason: .requiresNativeFormat)
        }
        if !isDefaultInputSelected {
            return Resolution(backend: .standard, reason: .requiresDefaultMicrophone)
        }
        return Resolution(backend: .appleVoiceProcessing, reason: nil)
    }

    /// Why the Settings picker is disabled, or nil when it can be used. The
    /// microphone is checked per start, so it never disables the picker.
    static func unavailableReason(osSupportsDucking: Bool, captureFormat: CaptureFormatPreference) -> FallbackReason? {
        resolve(
            preference: .appleVoiceProcessing,
            osSupportsDucking: osSupportsDucking,
            isDefaultInputSelected: true,
            captureFormat: captureFormat
        ).reason
    }

    /// True for System Default (nil, empty or "default", as the recorder
    /// treats them) or an exact match with the current default input's UID.
    static func isDefaultInputSelected(selectedDeviceUID: String?, defaultDeviceUID: String?) -> Bool {
        guard let selectedDeviceUID, !selectedDeviceUID.isEmpty, selectedDeviceUID != "default" else {
            return true
        }
        return selectedDeviceUID == defaultDeviceUID
    }
}
