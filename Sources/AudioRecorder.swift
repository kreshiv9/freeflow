import AVFoundation
import CoreMedia
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

struct AudioDevice: Identifiable {
    let id: String
    let uid: String
    let name: String

    fileprivate static func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func availableInputDevices() -> [AudioDevice] {
        var seenUIDs = Set<String>()
        return captureDevices()
            .compactMap { device in
                let uid = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty, !name.isEmpty, seenUIDs.insert(uid).inserted else {
                    return nil
                }
                return AudioDevice(id: uid, uid: uid, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case noAudioBuffersReceived
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case failedToBeginFileRecording(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        case .noAudioBuffersReceived:
            return "No audio buffers were received from the selected microphone."
        case .failedToCreateCaptureInput(let details):
            return "Could not open the selected microphone: \(details)"
        case .failedToStartCaptureSession(let details):
            return "Could not start the capture session: \(details)"
        case .failedToBeginFileRecording(let details):
            return "Could not begin recording audio: \(details)"
        }
    }
}

final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private static let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private var captureSession: AVCaptureSession?
    private var currentInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var tempFileURL: URL?
    private var recordingStartTime: CFAbsoluteTime = 0
    private let _bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private let fileWriteErrorLock = OSAllocatedUnfairLock(initialState: ())
    private var watchdogTimer: DispatchSourceTimer?
    private let sessionQueue = DispatchQueue(label: "com.zachlatta.freeflow.capture.session")
    private let sampleBufferQueue = DispatchQueue(label: "com.zachlatta.freeflow.capture.samples")
    private var activeAudioFile: AVAudioFile?
    private var activeAudioFormat: AVAudioFormat?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var fileWriteError: Error?
    private var isSessionInterrupted = false
    /// Session queue only: the running voice-processing capture (nil once it
    /// is stopped or replaced), the start count that keeps a late fallback
    /// request from touching a newer recording, and the microphone the
    /// fallback reopens.
    private var voiceProcessingCapture: VoiceProcessingCapture?
    private var captureGeneration: UInt64 = 0
    private var requestedDeviceUID: String?

    @Published var isRecording = false
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())
    /// Fed on the sample-buffer queue, snapshotted on the session queue.
    private let speechActivityLock = OSAllocatedUnfairLock(initialState: SpeechActivityTracker())

    /// Delivered on the main queue only while the capture generation is current.
    var onRecordingReady: ((ContinuousClock.Instant) -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    /// Fires on the sample-buffer queue with mono little-endian PCM16 at the
    /// `streamSampleRate` passed to ``startRecording``, one chunk per converted
    /// buffer, and never when that rate is nil. The tail is flushed through it
    /// inside ``stopRecording`` before its completion runs. Lock-backed because
    /// AppState sets and clears it on main while the capture queue reads it
    /// (B12), as a plain locked property: OSAllocatedUnfairLock<closure>
    /// re-wraps the closure on every read, which overflowed the capture stack.
    /// The recorder writes a 16 kHz mono PCM16 WAV file independently.
    var onPCM16Samples: ((Data) -> Void)? {
        get { pcm16SamplesHandler.load() }
        set { pcm16SamplesHandler.store(newValue) }
    }
    private let pcm16SamplesHandler = PCMSampleHandlerSlot()
    private let recordingTargetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }()
    /// Capture pipeline state, including the voice isolation mode and filter.
    /// Set in makeSession before capture starts, otherwise touched only on the
    /// sample-buffer queue, then flushed and cleared in finishAudioFileLocked.
    private var requestedCaptureFormat: CaptureFormatPreference = .native
    private var streamSampleRate: Int?
    private var pipelineSourceFormat: AVAudioFormat?
    private var wavResampler: PCMStreamResampler?
    private var streamResampler: PCMStreamResampler?
    private var pipelineBuildCount = 0
    private let streamFailed = OSAllocatedUnfairLock(initialState: false)
    private var voiceIsolationMode: VoiceIsolationPreference = .off
    /// This recording's filter; nil sends the raw audio straight to the converters.
    private var voiceIsolationFilter: VoiceIsolationFilter?
    /// First-second digital-zero check for voice-processing buffers.
    private var voiceProcessingLiveness = VoiceProcessingLiveness()
    /// The filter built ahead of time by prepareVoiceIsolation for the
    /// selected mode, so no recording waits for the model to load.
    private struct PreparedVoiceIsolation {
        var requestedMode: VoiceIsolationPreference = .off
        var builtMode: VoiceIsolationPreference = .off
        var filter: VoiceIsolationFilter?
    }
    private let preparedVoiceIsolation = OSAllocatedUnfairLock(initialState: PreparedVoiceIsolation())
    private let voiceIsolationQueue = DispatchQueue(label: "com.zachlatta.freeflow.capture.isolation", qos: .utility)
    private let captureTiming = OSAllocatedUnfairLock(initialState: RecordingCaptureTiming())
    private var failureReported = false
    private static let watchdogTimeout: TimeInterval = 2.0
    private static let sampleRateLogLimit = 40
    /// Content-free log labels for leaving voice processing mid-start or mid-recording.
    private enum VoiceProcessingFallback: String {
        case setupFailed
        case silentFirstSecond
        case noBuffers
        case configurationChange
    }

    /// True once this recording's stream conversion failed, so the caller
    /// should transcribe the WAV instead. Reset when the next recording starts.
    var didStreamFail: Bool {
        streamFailed.withLock { $0 }
    }

    override init() {
        super.init()
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)
    }

    deinit {
        let cleanup = {
            self.cancelWatchdog()
            self.teardownSessionLocked()
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    private static func captureDevice(forUID uid: String) -> AVCaptureDevice? {
        AudioDevice.captureDevices().first(where: { $0.uniqueID == uid })
    }

    private static func defaultCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio) ?? AudioDevice.captureDevices().first
    }

    private func preferredCaptureDevice(
        for requestedDeviceUID: String?,
        reason: String
    ) throws -> AVCaptureDevice {
        guard let requestedDeviceUID, !requestedDeviceUID.isEmpty, requestedDeviceUID != "default" else {
            guard let device = Self.defaultCaptureDevice() else {
                throw AudioRecorderError.missingInputDevice
            }
            os_log(.info, log: recordingLog, "%{public}@ — using system default device: %{public}@", reason, device.localizedName)
            return device
        }

        if let device = Self.captureDevice(forUID: requestedDeviceUID) {
            os_log(.info, log: recordingLog, "%{public}@ — keeping selected device: %{public}@ [uid=%{public}@]", reason, device.localizedName, device.uniqueID)
            return device
        }

        guard let fallbackDevice = Self.defaultCaptureDevice() else {
            throw AudioRecorderError.missingInputDevice
        }

        os_log(
            .info,
            log: recordingLog,
            "%{public}@ — selected device unavailable [uid=%{public}@], falling back to system default: %{public}@ [uid=%{public}@]",
            reason,
            requestedDeviceUID,
            fallbackDevice.localizedName,
            fallbackDevice.uniqueID
        )
        return fallbackDevice
    }

    private func installSessionObservers(for session: AVCaptureSession) {
        removeSessionObservers()

        let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let wrapped = error.map { AudioRecorderError.failedToStartCaptureSession($0.localizedDescription) }
                ?? AudioRecorderError.failedToStartCaptureSession("Unknown runtime error")
            self?.reportRecordingFailure(wrapped)
        }
        sessionObservers.append(runtimeObserver)

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterrupted(notification)
        }
        sessionObservers.append(interruptionObserver)

        let interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification)
        }
        sessionObservers.append(interruptionEndedObserver)
    }

    private func removeSessionObservers() {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func teardownSessionLocked() {
        removeSessionObservers()
        isSessionInterrupted = false

        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }

        captureSession = nil
        currentInput = nil
        audioDataOutput = nil
        stopVoiceProcessingLocked()
    }

    private func reportRecordingFailure(_ error: Error, completion: ((URL?) -> Void)? = nil) {
        captureTiming.withLock { $0.invalidate() }
        sessionQueue.async {
            guard !self.failureReported else { return }
            self.failureReported = true
            self.cancelWatchdog()
            self._recording.withLock { $0 = false }

            let completion = completion
            let discardURL = self.finishAudioFileLocked(discard: true)
            self.teardownSessionLocked()
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            self.speechActivityLock.withLock { $0.reset() }
            if let discardURL {
                try? FileManager.default.removeItem(at: discardURL)
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                self.onRecordingFailure?(error)
                completion?(nil)
            }
        }
    }

    private func startBufferWatchdog() {
        let baselineCount = _bufferCount.withLock { $0 }
        cancelWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self._recording.withLock({ $0 }) else { return }
            guard !self.isSessionInterrupted else {
                os_log(.info, log: recordingLog, "watchdog suspended while capture session is interrupted")
                return
            }

            let count = self._bufferCount.withLock { $0 }
            if count == baselineCount {
                if self.voiceProcessingCapture != nil {
                    self.fallBackToCaptureSessionLocked(.noBuffers, generation: self.captureGeneration)
                    return
                }
                os_log(.error, log: recordingLog, "watchdog: no new buffers after %.1fs — giving up", Self.watchdogTimeout)
                self.reportRecordingFailure(AudioRecorderError.noAudioBuffersReceived)
            } else {
                os_log(.info, log: recordingLog, "watchdog: %d new buffers after %.1fs — healthy", count - baselineCount, Self.watchdogTimeout)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func finishAudioFileLocked(discard: Bool) -> URL? {
        var finalizedURL: URL?
        var shouldKeepFile = false

        // Drain all queued sample-buffer callbacks before releasing the writer.
        sampleBufferQueue.sync {
            // Write and stream the converters' tails while the writer and the
            // stream handler are still set; a failed tail write sets
            // fileWriteError, so the file is not returned, as for a failed
            // capture write.
            if !discard {
                self.flushCapturePipeline()
            }
            self.voiceIsolationFilter = nil
            self.wavResampler = nil
            self.streamResampler = nil
            self.pipelineSourceFormat = nil
            finalizedURL = self.tempFileURL
            shouldKeepFile = !discard && self.recordedFrameCount > 0 && self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError == nil
            }
            self.activeAudioFile = nil
            self.activeAudioFormat = nil
        }

        defer {
            self.recordedFrameCount = 0
            self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError = nil
            }
            if !shouldKeepFile {
                self.tempFileURL = nil
            }
        }

        return shouldKeepFile ? finalizedURL : nil
    }

    private func handleSessionInterrupted(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = true
            self.cancelWatchdog()
            os_log(.info, log: recordingLog, "capture session interrupted — waiting for recovery")
        }
    }

    private func handleSessionInterruptionEnded(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = false
            os_log(.info, log: recordingLog, "capture session interruption ended — restarting watchdog")
            self.startBufferWatchdog()
        }
    }

    // MARK: Capture pipeline (sample-buffer queue only)

    /// Decodes a capture buffer once; nil for an empty buffer.
    private func decodeCaptureBuffer(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioRecorderError.invalidInputFormat("Could not determine audio format from sample buffer.")
        }
        let rawSourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let sourceFormat = try validatedPCMBufferFormat(
            rawSourceFormat,
            context: "capture sample buffer"
        )

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        return try makePCMBuffer(from: sampleBuffer, format: sourceFormat, frameCount: frameCount)
    }

    /// Runs one capture buffer through voice isolation when it is on, then
    /// converts the result into the 16 kHz WAV (which also feeds the speech
    /// tracker and a 16 kHz stream) and, for another stream rate, into the
    /// stream. A filter error only bypasses the filter (the raw audio it still
    /// held goes on unprocessed); WAV errors throw; stream errors only stop
    /// the stream.
    private func processCaptureBuffer(_ buffer: AVAudioPCMBuffer) throws {
        if let fileWriteError = fileWriteErrorLock.withLock({ _ in
            self.fileWriteError
        }) {
            throw fileWriteError
        }

        if pipelineSourceFormat != buffer.format {
            try rebuildCapturePipeline(for: buffer.format)
        }
        if let voiceIsolationFilter {
            do {
                try voiceIsolationFilter.process(buffer) { try self.convertCaptureChunk($0) }
                return
            } catch let error as VoiceIsolationFilter.FilterError {
                bypassVoiceIsolation("error \(error)")
                if let unemitted = voiceIsolationFilter.takeUnemittedInput() {
                    try convertCaptureChunk(unemitted)
                }
                // After a render failure the unemitted audio included this buffer.
                if case .renderFailed = error { return }
            }
        }
        try convertCaptureChunk(buffer)
    }

    /// Feeds one capture-format chunk to the WAV and stream converters.
    private func convertCaptureChunk(_ chunk: AVAudioPCMBuffer) throws {
        try wavResampler?.process(chunk) { try self.writeRecordingChunk($0) }
        if let streamResampler {
            do {
                try streamResampler.process(chunk) { self.emitStreamChunk($0) }
            } catch {
                markStreamFailed(error)
            }
        }
    }

    /// Flushes voice isolation and the converters built for the previous
    /// source format, then builds new ones for `sourceFormat`.
    private func rebuildCapturePipeline(for sourceFormat: AVAudioFormat) throws {
        if pipelineSourceFormat != nil {
            // The held-back isolation tail belongs to the old format's converters.
            try finishVoiceIsolation()
        }
        let previousWAVResampler = wavResampler
        let previousStreamResampler = streamResampler
        wavResampler = nil
        streamResampler = nil
        try previousWAVResampler?.finish { try self.writeRecordingChunk($0) }
        if let previousStreamResampler {
            do {
                try previousStreamResampler.finish { self.emitStreamChunk($0) }
            } catch {
                markStreamFailed(error)
            }
        }

        wavResampler = try PCMStreamResampler(
            inputFormat: sourceFormat,
            outputSampleRate: recordingTargetFormat.sampleRate
        )
        if let streamSampleRate,
           streamSampleRate != Int(recordingTargetFormat.sampleRate),
           !didStreamFail {
            do {
                streamResampler = try PCMStreamResampler(
                    inputFormat: sourceFormat,
                    outputSampleRate: Double(streamSampleRate)
                )
            } catch {
                markStreamFailed(error)
            }
        }
        pipelineSourceFormat = sourceFormat
        pipelineBuildCount += 1

        os_log(
            .info,
            log: recordingLog,
            "capture audio format source=%{public}@ request=%{public}@ wav=%.0fHz stream=%{public}@ converter=minimumPhase/max build=%d",
            PCMStreamResampler.formatSummary(sourceFormat),
            requestedCaptureFormat.rawValue,
            recordingTargetFormat.sampleRate,
            streamSampleRate.map { "\($0)Hz" } ?? "off",
            pipelineBuildCount
        )

        if let voiceIsolationFilter {
            if VoiceIsolationPreference.isSupported(
                sourceSampleRate: sourceFormat.sampleRate,
                channelCount: sourceFormat.channelCount,
                isFloat32: sourceFormat.commonFormat == .pcmFormatFloat32
            ) {
                // Re-arms the filter after the previous recording's finish or cancel.
                voiceIsolationFilter.reset()
            } else {
                bypassVoiceIsolation("unsupported format \(PCMStreamResampler.formatSummary(sourceFormat))")
            }
        }
    }

    /// Writes one 16 kHz chunk to the lazily created WAV, tracks its speech
    /// activity and, when the stream runs at 16 kHz, streams the same samples.
    private func writeRecordingChunk(_ chunk: AVAudioPCMBuffer) throws {
        let targetFormat = recordingTargetFormat
        if activeAudioFile == nil {
            guard let outputURL = tempFileURL else {
                throw AudioRecorderError.failedToBeginFileRecording("Missing temporary output URL.")
            }
            let settings = pcmFileSettings(for: targetFormat)
            let audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            activeAudioFile = audioFile
            activeAudioFormat = targetFormat
            os_log(.info, log: recordingLog, "audio file writer created at %{public}@", outputURL.path)
        }

        guard let activeAudioFile else {
            throw AudioRecorderError.failedToBeginFileRecording("Audio file writer was not initialized.")
        }

        try activeAudioFile.write(from: chunk)
        recordedFrameCount += AVAudioFramePosition(chunk.frameLength)

        let rms = AudioLevelMeter.rms(chunk)
        let chunkMilliseconds = Double(chunk.frameLength) / chunk.format.sampleRate * 1000
        speechActivityLock.withLock {
            $0.track(rms: rms, durationMilliseconds: chunkMilliseconds)
        }

        if streamSampleRate == Int(targetFormat.sampleRate) {
            emitStreamChunk(chunk)
        }
    }

    private func emitStreamChunk(_ chunk: AVAudioPCMBuffer) {
        guard !didStreamFail, let handler = onPCM16Samples else { return }
        let data = PCMStreamResampler.littleEndianData(chunk)
        guard !data.isEmpty else { return }
        handler(data)
    }

    /// Stops the stream for the rest of this recording; the WAV keeps going.
    private func markStreamFailed(_ error: Error) {
        streamResampler = nil
        let isFirstFailure = streamFailed.withLock { failed -> Bool in
            defer { failed = true }
            return !failed
        }
        if isFirstFailure {
            os_log(.error, log: recordingLog, "stream conversion failed, stream stopped for this recording: %{public}@", error.localizedDescription)
        }
    }

    /// Sends voice isolation's held-back tail through the current converters.
    /// A filter error bypasses it and sends the rest of the tail raw;
    /// converter and WAV errors throw.
    private func finishVoiceIsolation() throws {
        guard let voiceIsolationFilter else { return }
        do {
            try voiceIsolationFilter.finish { try self.convertCaptureChunk($0) }
        } catch let error as VoiceIsolationFilter.FilterError {
            bypassVoiceIsolation("error \(error)")
            if let unemitted = voiceIsolationFilter.takeUnemittedInput() {
                try convertCaptureChunk(unemitted)
            }
        }
    }

    /// Sends raw audio to the converters for the rest of this recording.
    /// The reason is content-free and logged once.
    private func bypassVoiceIsolation(_ reason: String) {
        guard voiceIsolationFilter != nil else { return }
        voiceIsolationFilter = nil
        let type: OSLogType = reason.hasPrefix("error") ? .error : .info
        os_log(type, log: recordingLog, "voice isolation bypassed: %{public}@ (mode=%{public}@)", reason, voiceIsolationMode.rawValue)
    }

    /// Writes and streams voice isolation's and the converters' held-back
    /// tails at stop, in that order.
    private func flushCapturePipeline() {
        do {
            try finishVoiceIsolation()
            try wavResampler?.finish { try self.writeRecordingChunk($0) }
        } catch {
            fileWriteErrorLock.withLock { _ in
                fileWriteError = error
            }
            os_log(.error, log: recordingLog, "audio file flush failed: %{public}@", error.localizedDescription)
        }
        do {
            try streamResampler?.finish { self.emitStreamChunk($0) }
        } catch {
            markStreamFailed(error)
        }
    }

    private func validatedPCMBufferFormat(
        _ format: AVAudioFormat,
        context: String
    ) throws -> AVAudioFormat {
        let isPCM = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatFloat64
            || format.commonFormat == .pcmFormatInt16
            || format.commonFormat == .pcmFormatInt32

        guard isPCM else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) is not PCM (commonFormat=\(String(describing: format.commonFormat)), settings=\(format.settings))."
            )
        }

        guard format.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported zero channels."
            )
        }

        guard format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported an invalid sample rate (\(format.sampleRate))."
            )
        }

        return format
    }

    private func pcmFileSettings(for format: AVAudioFormat) -> [String: Any] {
        let isFloat = isFloatFormat(format.commonFormat)
        let bitDepth = bitDepth(for: format.commonFormat)

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }

    private func isFloatFormat(_ commonFormat: AVAudioCommonFormat) -> Bool {
        commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64
    }

    private func bitDepth(for commonFormat: AVAudioCommonFormat) -> Int {
        switch commonFormat {
        case .pcmFormatFloat64:
            64
        case .pcmFormatFloat32, .pcmFormatInt32:
            32
        case .pcmFormatInt16:
            16
        default:
            0
        }
    }

    private func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not allocate PCM buffer for format \(format.settings).")
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not copy sample buffer data (OSStatus \(copyStatus)).")
        }
        return inputBuffer
    }

    private func makeSession(
        deviceUID: String?,
        outputURL: URL,
        captureFormat: CaptureFormatPreference,
        streamSampleRate: Int?,
        voiceIsolation: VoiceIsolationPreference,
        captureBackend: CaptureBackendPreference
    ) throws {
        teardownSessionLocked()

        let device = try preferredCaptureDevice(for: deviceUID, reason: "initial start")

        activeAudioFile = nil
        activeAudioFormat = nil
        requestedCaptureFormat = captureFormat
        self.streamSampleRate = streamSampleRate
        pipelineSourceFormat = nil
        wavResampler = nil
        streamResampler = nil
        pipelineBuildCount = 0
        streamFailed.withLock { $0 = false }
        // Only a filter already built for this mode is used; it is reset
        // when the first buffer builds the pipeline.
        let prepared = preparedVoiceIsolation.withLock { ($0.builtMode, $0.filter) }
        let isIsolationBuilt = voiceIsolation != .off && prepared.0 == voiceIsolation
        let isolationFilter = isIsolationBuilt ? prepared.1 : nil
        voiceIsolationMode = voiceIsolation
        voiceIsolationFilter = isolationFilter
        recordedFrameCount = 0
        fileWriteErrorLock.withLock { _ in
            fileWriteError = nil
        }
        voiceProcessingLiveness = VoiceProcessingLiveness()
        captureGeneration &+= 1
        requestedDeviceUID = deviceUID

        if !startVoiceProcessingIfChosenLocked(captureBackend, deviceUID: deviceUID, captureFormat: captureFormat) {
            try startCaptureSessionLocked(device: device, captureFormat: captureFormat)
        }

        logVoiceIsolationStart(mode: voiceIsolation, filter: isolationFilter, isBuilt: isIsolationBuilt)
        tempFileURL = outputURL
    }

    /// Builds and starts the capture session on `device`: the Standard path,
    /// and the replacement when voice processing fails.
    private func startCaptureSessionLocked(device: AVCaptureDevice, captureFormat: CaptureFormatPreference) throws {
        let session = AVCaptureSession()
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.audioSettings = captureFormat.audioSettings()
        dataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.failedToCreateCaptureInput(error.localizedDescription)
        }

        session.beginConfiguration()
        var needsCommitConfiguration = true
        defer {
            if needsCommitConfiguration {
                session.commitConfiguration()
            }
        }

        guard session.canAddInput(input) else {
            throw AudioRecorderError.failedToCreateCaptureInput("Session rejected device input for \(device.localizedName).")
        }
        session.addInput(input)

        guard session.canAddOutput(dataOutput) else {
            throw AudioRecorderError.failedToStartCaptureSession("Session rejected audio data output.")
        }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        needsCommitConfiguration = false

        captureSession = session
        currentInput = input
        audioDataOutput = dataOutput
        isSessionInterrupted = false
        installSessionObservers(for: session)

        os_log(.info, log: recordingLog, "configured capture session with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.failedToStartCaptureSession("Session failed to enter running state.")
        }

        os_log(.info, log: recordingLog, "capture session running with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)
    }

    /// Starts Apple voice processing when it was chosen and its gate passes.
    /// False means the caller starts the capture session; Standard returns
    /// before any device lookup or log. A setup failure stops the engine
    /// itself and is logged here.
    private func startVoiceProcessingIfChosenLocked(
        _ captureBackend: CaptureBackendPreference,
        deviceUID: String?,
        captureFormat: CaptureFormatPreference
    ) -> Bool {
        guard captureBackend == .appleVoiceProcessing else { return false }
        let resolution = CaptureBackendPreference.resolve(
            preference: captureBackend,
            osSupportsDucking: CaptureBackendPreference.osSupportsDucking,
            isDefaultInputSelected: CaptureBackendPreference.isDefaultInputSelected(
                selectedDeviceUID: deviceUID,
                defaultDeviceUID: AVCaptureDevice.default(for: .audio)?.uniqueID
            ),
            captureFormat: captureFormat
        )
        guard resolution.backend == .appleVoiceProcessing else {
            os_log(
                .info,
                log: recordingLog,
                "capture backend=captureSession requested=appleVoiceProcessing reason=%{public}@",
                resolution.reason?.rawValue ?? "none"
            )
            return false
        }

        let generation = captureGeneration
        let capture = VoiceProcessingCapture()
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let report = try capture.start(
                deliverOn: sampleBufferQueue,
                onBuffer: { [weak self] buffer in
                    self?.handleVoiceProcessingBuffer(buffer, generation: generation)
                },
                onConfigurationChange: { [weak self] in
                    self?.sessionQueue.async {
                        self?.fallBackToCaptureSessionLocked(.configurationChange, generation: generation)
                    }
                }
            )
            voiceProcessingCapture = capture
            os_log(
                .info,
                log: recordingLog,
                "capture backend=voiceProcessing setup=%.0fms hw=%{public}@ tap=%{public}@ agc=%{public}@ ducking=%ld micMode preferred=%ld active=%ld",
                report.setupMilliseconds,
                PCMStreamResampler.formatSummary(report.hardwareFormat),
                PCMStreamResampler.formatSummary(report.tapFormat),
                String(report.isAGCEnabled),
                report.duckingLevel,
                AVCaptureDevice.preferredMicrophoneMode.rawValue,
                AVCaptureDevice.activeMicrophoneMode.rawValue
            )
            return true
        } catch {
            let captureError = error as? VoiceProcessingCapture.CaptureError
            os_log(
                .error,
                log: recordingLog,
                "capture backend fallback: voiceProcessing -> captureSession reason=%{public}@ error=%{public}@ status=%d after=%.0fms",
                VoiceProcessingFallback.setupFailed.rawValue,
                captureError?.logLabel ?? String(describing: type(of: error)),
                captureError?.status ?? 0,
                (CFAbsoluteTimeGetCurrent() - t0) * 1000
            )
            return false
        }
    }

    /// Voice-processing tap buffers, on the sample-buffer queue. Silent
    /// buffers are fed too, so the WAV and stream keep their timeline; a
    /// first second of exact zeros switches to the capture session.
    private func handleVoiceProcessingBuffer(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard _recording.withLock({ $0 }) else { return }
        let change = voiceProcessingLiveness.observe(
            frameCount: Int(buffer.frameLength),
            sampleRate: buffer.format.sampleRate,
            isSilent: VoiceProcessingLiveness.isChannelZeroSilent(buffer)
        )
        if change == .live {
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: recordingLog, "voice processing first non-silent buffer at %.0fms", elapsed)
        }
        consumeCaptureBuffer { buffer }
        if change == .silent {
            sessionQueue.async {
                self.fallBackToCaptureSessionLocked(.silentFirstSecond, generation: generation)
            }
        }
    }

    /// Replaces this recording's voice-processing capture with the capture
    /// session, on the session queue. One-way: stale and repeated requests
    /// are ignored. The WAV, converters, isolation filter and stream carry
    /// on, and the new buffer format rebuilds the converters.
    private func fallBackToCaptureSessionLocked(_ reason: VoiceProcessingFallback, generation: UInt64) {
        guard generation == captureGeneration,
              let capture = voiceProcessingCapture,
              _recording.withLock({ $0 }),
              !failureReported else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(
            .error,
            log: recordingLog,
            "capture backend fallback: voiceProcessing -> captureSession reason=%{public}@ engineRunning=%{public}@ at=%.0fms",
            reason.rawValue,
            String(capture.isRunning),
            (t0 - recordingStartTime) * 1000
        )
        stopVoiceProcessingLocked()

        do {
            let device = try preferredCaptureDevice(for: requestedDeviceUID, reason: "voice processing fallback")
            try startCaptureSessionLocked(device: device, captureFormat: requestedCaptureFormat)
        } catch {
            reportRecordingFailure(error)
            return
        }
        os_log(.info, log: recordingLog, "capture backend fallback: captureSession running after %.0fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        startBufferWatchdog()
    }

    /// Tears down the voice-processing capture, if any, without waiting for
    /// the tap's partly filled buffer (see VoiceProcessingCapture.stop). A
    /// nonzero disable status is logged as an error because other apps may
    /// stay ducked.
    private func stopVoiceProcessingLocked() {
        guard let capture = voiceProcessingCapture else { return }
        voiceProcessingCapture = nil
        let preferredMicMode = AVCaptureDevice.preferredMicrophoneMode.rawValue
        let activeMicMode = AVCaptureDevice.activeMicrophoneMode.rawValue
        let t0 = CFAbsoluteTimeGetCurrent()
        let disableStatus = capture.stop()
        os_log(
            disableStatus == 0 ? .info : .error,
            log: recordingLog,
            "voice processing stopped: teardown=%.0fms disableStatus=%d micMode preferred=%ld active=%ld",
            (CFAbsoluteTimeGetCurrent() - t0) * 1000,
            disableStatus,
            preferredMicMode,
            activeMicMode
        )
    }

    /// Content-free: the isolation mode, model, wet mix and latency, and the
    /// raw macOS Mic Mode values (read-only class properties, no permission).
    private func logVoiceIsolationStart(mode: VoiceIsolationPreference, filter: VoiceIsolationFilter?, isBuilt: Bool) {
        let preferredMicMode = AVCaptureDevice.preferredMicrophoneMode.rawValue
        let activeMicMode = AVCaptureDevice.activeMicrophoneMode.rawValue
        if let filter {
            os_log(
                .info,
                log: recordingLog,
                "voice isolation mode=%{public}@ model=highQualityVoice wet=%.0f%% latency=%.1fms micMode preferred=%ld active=%ld",
                mode.rawValue,
                Double(filter.wetDryPercent),
                Double(filter.latencyFrames) / VoiceIsolationFilter.sampleRate * 1000,
                preferredMicMode,
                activeMicMode
            )
        } else if mode == .off {
            os_log(.info, log: recordingLog, "voice isolation mode=off micMode preferred=%ld active=%ld", preferredMicMode, activeMicMode)
        } else {
            os_log(
                .info,
                log: recordingLog,
                "voice isolation bypassed: %{public}@ (mode=%{public}@) micMode preferred=%ld active=%ld",
                isBuilt ? "unavailable" : "not ready",
                mode.rawValue,
                preferredMicMode,
                activeMicMode
            )
        }
    }

    /// Called before scheduling capture setup so cancellation also invalidates pending starts.
    func prepareRecordingTiming() -> UInt64 {
        captureTiming.withLock { $0.prepare() }
    }

    /// Builds the voice isolation filter for `mode` on a utility queue (a
    /// cold setup takes about 0.3 s), or releases it for `.off`, so starting
    /// a recording never waits for the model. Fast toggling skips stale builds.
    func prepareVoiceIsolation(_ mode: VoiceIsolationPreference) {
        let released = preparedVoiceIsolation.withLock { state -> VoiceIsolationFilter? in
            state.requestedMode = mode
            guard mode == .off else { return nil }
            defer {
                state.builtMode = .off
                state.filter = nil
            }
            return state.filter
        }
        voiceIsolationQueue.async { [weak self] in
            // A released model is freed here, off the caller's queue.
            withExtendedLifetime(released) {}
            guard let self, let wetDryPercent = mode.wetDryPercent else { return }
            let needsBuild = self.preparedVoiceIsolation.withLock { state in
                state.requestedMode == mode && !(state.builtMode == mode && state.filter != nil)
            }
            guard needsBuild else { return }

            let t0 = CFAbsoluteTimeGetCurrent()
            let filter = VoiceIsolationFilter(wetDryPercent: wetDryPercent)
            let setupMilliseconds = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            // Stored only if the mode is still wanted. The replaced filter is
            // returned so it is freed outside the lock.
            let (isStored, replaced) = self.preparedVoiceIsolation.withLock { state -> (Bool, VoiceIsolationFilter?) in
                guard state.requestedMode == mode else { return (false, nil) }
                defer {
                    state.builtMode = mode
                    state.filter = filter
                }
                return (true, state.filter)
            }
            withExtendedLifetime(replaced) {}
            guard isStored else { return }
            os_log(
                .info,
                log: recordingLog,
                "voice isolation prepared: mode=%{public}@ ready=%{public}@ latency=%.1fms setup=%.0fms",
                mode.rawValue,
                String(filter != nil),
                filter.map { Double($0.latencyFrames) / VoiceIsolationFilter.sampleRate * 1000 } ?? 0,
                setupMilliseconds
            )
        }
    }

    /// `streamSampleRate` is the rate `onPCM16Samples` delivers; nil skips
    /// the stream conversion. `voiceIsolation` applies only when
    /// prepareVoiceIsolation has built the filter for that mode.
    /// `captureBackend` Apple voice processing is tried only when its gate
    /// passes and falls back to the capture session on its own; the
    /// `.standard` default keeps SetupView's mic test on the capture session.
    func startRecording(
        deviceUID: String? = nil,
        timingGeneration: UInt64? = nil,
        captureFormat: CaptureFormatPreference = .load(from: .standard),
        streamSampleRate: Int? = nil,
        voiceIsolation: VoiceIsolationPreference = .off,
        captureBackend: CaptureBackendPreference = .standard
    ) throws {
        let timingGeneration = timingGeneration ?? prepareRecordingTiming()
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        _bufferCount.withLock { $0 = 0 }
        failureReported = false
        liveLevelNormalizerLock.withLock { $0.reset() }
        speechActivityLock.withLock { $0.reset() }

        os_log(.info, log: recordingLog, "startRecording() entered")

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        do {
            try sessionQueue.sync {
                try self.makeSession(
                    deviceUID: deviceUID,
                    outputURL: outputURL,
                    captureFormat: captureFormat,
                    streamSampleRate: streamSampleRate,
                    voiceIsolation: voiceIsolation,
                    captureBackend: captureBackend
                )
                self.captureTiming.withLock { $0.start(at: .now, generation: timingGeneration) }
                self._recording.withLock { $0 = true }
                self.startBufferWatchdog()
            }
        } catch {
            if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
                tempFileURL = nil
            } else {
                sessionQueue.sync {
                    tempFileURL = nil
                }
            }
            throw error
        }

        DispatchQueue.main.async {
            self.isRecording = true
            self.audioLevel = 0.0
        }
        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// The speech-activity value is captured on the session queue after
    /// teardown has drained the sample-buffer queue, so it belongs to the
    /// recording whose URL it accompanies.
    func stopRecording(completion: @escaping (URL?, SpeechActivityTracker) -> Void) {
        captureTiming.withLock { $0.invalidate() }
        let count = _bufferCount.withLock { $0 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, count)

        sessionQueue.async {
            self.cancelWatchdog()
            self.teardownSessionLocked()
            let outputURL = self.finishAudioFileLocked(discard: false)
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            let speechActivity = self.speechActivityLock.withLock { tracker -> SpeechActivityTracker in
                let snapshot = tracker
                tracker.reset()
                return snapshot
            }
            os_log(
                .info,
                log: recordingLog,
                "level: peak %.1f dBFS, speech threshold %.1f dBFS, speech %.0f of %.0f ms",
                Double(AudioLevelMeter.dbfs(speechActivity.peakRMS)),
                Double(AudioLevelMeter.dbfs(speechActivity.speechThresholdRMS)),
                speechActivity.speechMilliseconds,
                speechActivity.totalMilliseconds
            )
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                completion(outputURL, speechActivity)
            }
        }
    }

    /// Read-only snapshot of the current recording's speech activity for callers
    /// polling on the main queue; the stop-time value still arrives through
    /// stopRecording's completion.
    var currentSpeechActivity: SpeechActivityTracker {
        speechActivityLock.withLock { $0 }
    }

    func cancelRecording() {
        captureTiming.withLock { $0.invalidate() }
        sessionQueue.async {
            self.cancelWatchdog()
            self.teardownSessionLocked()
            let discardURL = self.finishAudioFileLocked(discard: true)
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            self.speechActivityLock.withLock { $0.reset() }
            if let discardURL {
                try? FileManager.default.removeItem(at: discardURL)
            }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
            }
        }
    }

    func cleanup() {
        let cleanup = {
            if let url = self.tempFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempFileURL = nil
            }
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        consumeCaptureBuffer { try decodeCaptureBuffer(sampleBuffer) }
    }

    /// Both capture paths feed their buffers here on the sample-buffer queue:
    /// the capture session decodes its sample buffers, voice processing hands
    /// over copied tap buffers. `makeBuffer` returns nil for an empty buffer.
    private func consumeCaptureBuffer(_ makeBuffer: () throws -> AVAudioPCMBuffer?) {
        guard _recording.withLock({ $0 }) else { return }

        let buffer: AVAudioPCMBuffer?
        do {
            buffer = try makeBuffer()
            if let buffer {
                try processCaptureBuffer(buffer)
            }
        } catch {
            fileWriteErrorLock.withLock { _ in
                fileWriteError = error
            }
            os_log(.error, log: recordingLog, "audio file write failed: %{public}@", error.localizedDescription)
            reportRecordingFailure(error)
            return
        }

        let count = _bufferCount.withLock { value -> Int in
            value += 1
            return value
        }

        // The meter and readiness use the raw capture buffer, before voice
        // isolation; the speech tracker is fed the converted 16 kHz chunks
        // (isolated when it is on) in writeRecordingChunk.
        let rms = buffer.map { AudioLevelMeter.rms($0) } ?? 0
        if buffer != nil {
            let normalizedDisplayLevel = liveLevelNormalizerLock.withLock {
                $0.normalizedLevel(forRMS: rms)
            }
            DispatchQueue.main.async {
                self.audioLevel = normalizedDisplayLevel
            }
        }
        if count <= Self.sampleRateLogLimit {
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: recordingLog, "buffer #%d at %.3fms, rms=%.6f", count, elapsed, rms)
        }

        if let readyEvent = captureTiming.withLock({ $0.recordingStartIfReady(rms: rms) }) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
            DispatchQueue.main.async {
                guard self.captureTiming.withLock({ $0.isCurrent(readyEvent) }) else { return }
                self.onRecordingReady?(readyEvent.instant)
            }
        }
    }
}
