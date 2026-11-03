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
    /// (B12). The recorder writes a 16 kHz mono PCM16 WAV file independently.
    var onPCM16Samples: ((Data) -> Void)? {
        get { pcm16SamplesHandler.withLock { $0 } }
        set { pcm16SamplesHandler.withLock { $0 = newValue } }
    }
    private let pcm16SamplesHandler = OSAllocatedUnfairLock<((Data) -> Void)?>(initialState: nil)
    private let recordingTargetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }()
    /// Capture pipeline state. Set in makeSession before capture starts,
    /// otherwise touched only on the sample-buffer queue, then flushed and
    /// cleared in finishAudioFileLocked.
    private var requestedCaptureFormat: CaptureFormatPreference = .native
    private var streamSampleRate: Int?
    private var pipelineSourceFormat: AVAudioFormat?
    private var wavResampler: PCMStreamResampler?
    private var streamResampler: PCMStreamResampler?
    private var pipelineBuildCount = 0
    private let streamFailed = OSAllocatedUnfairLock(initialState: false)
    private let captureTiming = OSAllocatedUnfairLock(initialState: RecordingCaptureTiming())
    private var failureReported = false
    private static let watchdogTimeout: TimeInterval = 2.0
    private static let sampleRateLogLimit = 40

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

    /// Converts one capture buffer into the 16 kHz WAV (which also feeds the
    /// speech tracker and a 16 kHz stream) and, for another stream rate, into
    /// the stream. WAV errors throw; stream errors only stop the stream.
    private func processCaptureBuffer(_ buffer: AVAudioPCMBuffer) throws {
        if let fileWriteError = fileWriteErrorLock.withLock({ _ in
            self.fileWriteError
        }) {
            throw fileWriteError
        }

        if pipelineSourceFormat != buffer.format {
            try rebuildCapturePipeline(for: buffer.format)
        }
        try wavResampler?.process(buffer) { try self.writeRecordingChunk($0) }
        if let streamResampler {
            do {
                try streamResampler.process(buffer) { self.emitStreamChunk($0) }
            } catch {
                markStreamFailed(error)
            }
        }
    }

    /// Flushes the converters built for the previous source format, then builds
    /// new ones for `sourceFormat`.
    private func rebuildCapturePipeline(for sourceFormat: AVAudioFormat) throws {
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

    /// Writes and streams the converters' held-back tails at stop.
    private func flushCapturePipeline() {
        do {
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
        streamSampleRate: Int?
    ) throws {
        teardownSessionLocked()

        let device = try preferredCaptureDevice(for: deviceUID, reason: "initial start")

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
        activeAudioFile = nil
        activeAudioFormat = nil
        requestedCaptureFormat = captureFormat
        self.streamSampleRate = streamSampleRate
        pipelineSourceFormat = nil
        wavResampler = nil
        streamResampler = nil
        pipelineBuildCount = 0
        streamFailed.withLock { $0 = false }
        recordedFrameCount = 0
        fileWriteErrorLock.withLock { _ in
            fileWriteError = nil
        }
        installSessionObservers(for: session)

        os_log(.info, log: recordingLog, "configured capture session with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.failedToStartCaptureSession("Session failed to enter running state.")
        }

        os_log(.info, log: recordingLog, "capture session running with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)
        tempFileURL = outputURL
    }

    /// Called before scheduling capture setup so cancellation also invalidates pending starts.
    func prepareRecordingTiming() -> UInt64 {
        captureTiming.withLock { $0.prepare() }
    }

    /// `streamSampleRate` is the rate `onPCM16Samples` delivers; nil skips
    /// the stream conversion.
    func startRecording(
        deviceUID: String? = nil,
        timingGeneration: UInt64? = nil,
        captureFormat: CaptureFormatPreference = .load(from: .standard),
        streamSampleRate: Int? = nil
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
                    streamSampleRate: streamSampleRate
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
        guard _recording.withLock({ $0 }) else { return }

        let buffer: AVAudioPCMBuffer?
        do {
            buffer = try decodeCaptureBuffer(sampleBuffer)
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

        // The meter and readiness use the raw capture buffer; the speech
        // tracker is fed the 16 kHz chunks in writeRecordingChunk.
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
