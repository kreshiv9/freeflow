import Foundation

/// Keeps a per-recording estimate of whether the microphone heard speech, from
/// buffer RMS and duration numbers only, never the audio itself.
/// AudioRecorder protects this state with its speechActivityLock.
///
/// The noise floor is the quietest measurable buffer in a trailing window, so a
/// steady fan or room tone is absorbed within one buffer, while a long quiet
/// lead-in is never out-adapted. Two trade-offs are deliberate: a noise step
/// louder than the current floor is counted as speech until the quieter buffers
/// age out of the window (a false positive in the safe direction, the audio is
/// uploaded and left to the provider-side hallucination filter), and steady
/// noise above `maximumNoiseFloorRMS * noiseFloorRatio` always counts because
/// the floor cap exists so speech present from the very first buffer cannot
/// mask itself.
struct SpeechActivityTracker: Equatable, Sendable {
    /// Full-scale RMS (0...1) below which a buffer never counts as speech, whatever the noise floor (about -54 dBFS). Digital silence, a muted mic and a quiet room sit below it; quiet speech into a laptop mic sits well above.
    static let absoluteFloorRMS: Float = 0.002
    /// A buffer counts as speech when its RMS exceeds the noise floor by this factor (about +9.5 dB).
    static let noiseFloorRatio: Float = 3
    /// Cap on the floor used for the threshold, so the threshold never exceeds 0.012 (about -38 dBFS) and speech present from the very first buffer cannot seed a floor above itself. Steady noise louder than that is counted as speech and left to the provider-side hallucination filter.
    static let maximumNoiseFloorRMS: Float = 0.004
    /// The noise floor is the quietest measurable buffer inside this trailing window (a slow-tracking minimum of recent RMS).
    static let noiseFloorWindowMilliseconds: Double = 1500
    /// Buffers below this RMS are digital silence (capture warm-up, muted input, hardware gates). They count toward duration but never seed the floor, so a later steady noise cannot be mistaken for speech.
    static let minimumMeasurableRMS: Float = 0.0001
    /// An above-threshold run shorter than this is a click or desk bump, not speech.
    static let minimumSpeechRunMilliseconds: Double = 80
    /// Counted speech required before the recording has speech. A quick "yes" leaves roughly 250 ms above threshold, so this stays under the nominal ~300 ms to keep short real words.
    static let minimumSpeechMilliseconds: Double = 200

    private struct Sample: Equatable, Sendable {
        let rms: Float
        let durationMilliseconds: Double
    }

    private(set) var totalMilliseconds: Double = 0
    private(set) var peakRMS: Float = 0
    /// Completed runs that met `minimumSpeechRunMilliseconds`.
    private var countedSpeechMilliseconds: Double = 0
    /// Length of the current above-threshold run, not yet counted.
    private var currentRunMilliseconds: Double = 0
    /// `totalMilliseconds` when a counted speech buffer last ended.
    private var lastSpeechEndMilliseconds: Double?
    private var recentSamples: [Sample] = []
    private var recentMilliseconds: Double = 0

    /// Quietest measurable buffer in the trailing window; nil until one arrives.
    var noiseFloorRMS: Float? { recentSamples.map(\.rms).min() }

    var speechThresholdRMS: Float {
        max(Self.absoluteFloorRMS, min(noiseFloorRMS ?? 0, Self.maximumNoiseFloorRMS) * Self.noiseFloorRatio)
    }

    var speechMilliseconds: Double {
        countedSpeechMilliseconds
            + (currentRunMilliseconds >= Self.minimumSpeechRunMilliseconds ? currentRunMilliseconds : 0)
    }

    var hasSpeech: Bool {
        speechMilliseconds >= Self.minimumSpeechMilliseconds && peakRMS >= Self.absoluteFloorRMS
    }

    /// Audio since the last counted speech buffer; equals totalMilliseconds until speech is first counted.
    var silenceMillisecondsSinceLastSpeech: Double { totalMilliseconds - (lastSpeechEndMilliseconds ?? 0) }

    mutating func reset() { self = SpeechActivityTracker() }

    /// Classifies one capture buffer. The floor is updated before the buffer is
    /// classified so steady noise never counts, not even for its first buffer.
    mutating func track(rms: Float, durationMilliseconds: Double) {
        guard durationMilliseconds.isFinite, durationMilliseconds > 0 else { return }
        let level = rms.isFinite ? max(0, rms) : 0
        totalMilliseconds += durationMilliseconds
        peakRMS = max(peakRMS, level)
        if level >= Self.minimumMeasurableRMS {
            recentSamples.append(Sample(rms: level, durationMilliseconds: durationMilliseconds))
            recentMilliseconds += durationMilliseconds
            while recentSamples.count > 1, recentMilliseconds > Self.noiseFloorWindowMilliseconds {
                recentMilliseconds -= recentSamples.removeFirst().durationMilliseconds
            }
        }
        if level > speechThresholdRMS {
            currentRunMilliseconds += durationMilliseconds
            if currentRunMilliseconds >= Self.minimumSpeechRunMilliseconds {
                lastSpeechEndMilliseconds = totalMilliseconds
            }
        } else {
            if currentRunMilliseconds >= Self.minimumSpeechRunMilliseconds {
                countedSpeechMilliseconds += currentRunMilliseconds
            }
            currentRunMilliseconds = 0
        }
    }
}
