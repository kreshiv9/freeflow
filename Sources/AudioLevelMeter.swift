import AVFAudio
import Foundation

/// Level numbers computed from sample values only. They feed the live meter,
/// the speech-activity tracker and content-free logs; the audio itself is
/// never logged.
enum AudioLevelMeter {
    /// Full-scale RMS (0...1) over every sample of every channel.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var totalSamples = 0
        var sumOfSquares: Double = 0

        for audioBuffer in audioBuffers {
            guard let baseAddress = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                continue
            }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let pointer = baseAddress.assumingMemoryBound(to: Float.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index])
                    sumOfSquares += sample * sample
                }
            case .pcmFormatFloat64:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                let pointer = baseAddress.assumingMemoryBound(to: Double.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = pointer[index]
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt16:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 32768.0
                    sumOfSquares += sample * sample
                }
            case .pcmFormatInt32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
                totalSamples += samples
                for index in 0..<samples {
                    let sample = Double(pointer[index]) / 2147483648.0
                    sumOfSquares += sample * sample
                }
            default:
                continue
            }
        }

        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    /// Full-scale RMS in dBFS; zero maps to -180 dBFS.
    static func dbfs(_ rms: Float) -> Float {
        20 * log10(max(rms, 1e-9))
    }
}
