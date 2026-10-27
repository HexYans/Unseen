import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Screen recording through `SCStream` → `AVAssetWriter` (H.264).
///
/// Design notes, because the pause semantics are the whole point:
///
/// * ScreenCaptureKit delivers frames with the system's presentation
///   timestamps. Writing them as-is means a pause shows up in the file as a
///   frozen frame, and the duration grows by the paused time.
/// * This recorder therefore **drops** every frame while paused and, on the
///   first frame after a resume, absorbs the gap (`resumePTS - lastWrittenPTS`)
///   into a running offset. Every sample is re-timed as
///   `source - firstSource - pausedOffset`, so the output timeline only
///   contains active recording time.
/// * `lastWrittenPTS` must be the **source** timestamp of the last written
///   frame, not the retimed output timestamp, otherwise the gap subtraction
///   mixes two different clock domains and the offset explodes.
/// * The audio path subtracts the same offset, so a microphone track keeps
///   sync after a pause.
///
/// Only this type talks to `SCStream`; `ScreenCapture` remains the single place
/// that maps AppKit screens to ScreenCaptureKit displays and one-shot pixels.
@MainActor
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Writer state touched from the stream queue. The queue is serial, so all
    /// mutations are ordered; main-actor reads go through `queue.sync`.
    private final class WriterBox: @unchecked Sendable {
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var frameRate = 30
        var accepting = true
        var isPaused = false
        var sessionStarted = false
        var baseSource: CMTime?
        var lastVideoSource: CMTime?
        var lastVideoOutput: CMTime?
        var lastAudioOutput: CMTime?
        var pausedOffset: CMTime = .zero
        /// Source timestamp of the last frame written before pausing.
        var pauseSource: CMTime?
        var framesIn = 0
        var framesOut = 0
        var audioFramesOut = 0
        var framesDropped = 0
    }

    private let box = WriterBox()
    private let queue = DispatchQueue(label: "com.hexyans.unseen.recorder")
    private var stream: SCStream?
    private var outputURL: URL?
    private var machine = RecordingStateMachine()
    private var activityToken: NSObjectProtocol?

    private(set) var configuration = RecordingConfiguration()
    /// Encoded pixels. Full-screen captures use points × backing scale, i.e.
    /// the same pixel convention as the screenshot pipeline.
    private(set) var pixelSize: CGSize = .zero
    private(set) var microphoneActive = false
    /// Non-fatal note, e.g. "mic requested but macOS < 15".
    private(set) var warning: String?
    /// Set when ScreenCaptureKit stops the stream unexpectedly.
    private(set) var streamError: String?

    /// Called on every state transition.
    @ObservationIgnored var onStateChange: ((RecordingState) -> Void)?

    var state: RecordingState { machine.state }
    var isActive: Bool { machine.state.isActive }
    /// Last finished session's active duration (excludes pauses).
    var lastElapsed: TimeInterval { machine.lastElapsed }
    var framesWritten: Int { queue.sync { box.framesOut } }

    // MARK: - Lifecycle

    /// Start capturing one screen (full screen, or `region` in global AppKit
    /// points). Returns the URL the writer will finalize on `stop()`.
    @discardableResult
    func start(
        screen: NSScreen,
        region: CGRect? = nil,
        configuration: RecordingConfiguration,
        directory: URL,
        date: Date = Date()
    ) async throws -> URL {
        guard !state.isActive else { throw RecordingError.alreadyRecording }
        guard ScreenCapture.hasScreenRecordingPermission else {
            throw RecordingError.screenRecordingDenied
        }

        // The camera picture-in-picture is a window owned by this process, but
        // it is *content* for a recording (not chrome like the HUD), so it is
        // deliberately kept out of the own-window exclusion list.
        let (display, ownWindows) = try await ScreenCapture.displayAndOwnWindows(
            matching: screen,
            keepingWindowNumbers: CameraOverlayRegistry.activeWindowNumbers
        )
        let scale = max(screen.backingScaleFactor, 1)
        let localRect = Self.localTopLeftRect(region: region, on: screen)
        let pointSize = localRect?.size ?? screen.frame.size
        let pixelSize = CGSize(
            width: max(2, (pointSize.width * scale).rounded()),
            height: max(2, (pointSize.height * scale).rounded())
        )
        guard pointSize.width >= 2, pointSize.height >= 2 else { throw RecordingError.noDisplay }

        // Microphone is opt-in and macOS 15+ on the ScreenCaptureKit side.
        var microphone = configuration.capturesMicrophone
        var warning: String?
        if microphone {
            if #available(macOS 15.0, *) {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    break
                case .notDetermined:
                    microphone = await AVCaptureDevice.requestAccess(for: .audio)
                default:
                    microphone = false
                }
                if !microphone {
                    warning = "麦克风未授权，本次录制只含画面。"
                }
            } else {
                microphone = false
                warning = "系统低于 macOS 15，麦克风录制不可用，本次录制只含画面。"
            }
        }

        let url = RecordingNaming.url(in: directory, date: date, format: configuration.format)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let writer: AVAssetWriter
        do {
            try? FileManager.default.removeItem(at: url)
            writer = try AVAssetWriter(outputURL: url, fileType: configuration.format.avFileType)
        } catch {
            throw RecordingError.writerUnavailable(error.localizedDescription)
        }

        let frameRate = configuration.effectiveFrameRate
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(pixelSize.width),
            AVVideoHeightKey: Int(pixelSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: configuration.effectiveBitrate,
                AVVideoMaxKeyFrameIntervalKey: max(1, frameRate * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.writerUnavailable("无法创建 H.264 视频轨")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if microphone {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 96_000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                warning = "无法创建音轨，本次录制只含画面。"
            }
        }

        guard writer.startWriting() else {
            writer.cancelWriting()
            throw RecordingError.writerUnavailable(
                writer.error?.localizedDescription ?? "AVAssetWriter.startWriting 失败"
            )
        }

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = Int(pixelSize.width)
        streamConfiguration.height = Int(pixelSize.height)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(frameRate)
        )
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = true
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.captureResolution = .best
        // Fill the requested buffer with exactly the selected rectangle.
        streamConfiguration.scalesToFit = true
        if let localRect {
            streamConfiguration.sourceRect = localRect
        }
        if microphone {
            if #available(macOS 15.0, *) {
                streamConfiguration.captureMicrophone = true
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)

        queue.sync {
            box.writer = writer
            box.videoInput = videoInput
            box.audioInput = audioInput
            box.frameRate = frameRate
            box.accepting = true
            box.isPaused = false
            box.sessionStarted = false
            box.baseSource = nil
            box.lastVideoSource = nil
            box.lastVideoOutput = nil
            box.lastAudioOutput = nil
            box.pausedOffset = .zero
            box.pauseSource = nil
            box.framesIn = 0
            box.framesOut = 0
            box.audioFramesOut = 0
            box.framesDropped = 0
        }

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if microphone, #available(macOS 15.0, *) {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            queue.sync {
                box.writer = nil
                box.videoInput = nil
                box.audioInput = nil
                box.accepting = false
            }
            throw RecordingError.writerUnavailable(error.localizedDescription)
        }

        self.stream = stream
        self.outputURL = url
        self.pixelSize = pixelSize
        self.microphoneActive = microphone && audioInput != nil
        self.warning = warning
        self.configuration = configuration
        self.streamError = nil
        machine.reset()
        _ = machine.start(at: Date().timeIntervalSinceReferenceDate)
        beginActivity()
        onStateChange?(state)

        DebugLog.log(
            "recorder: started \(url.lastPathComponent) "
            + "points=\(pointSize) pixels=\(pixelSize) fps=\(frameRate) "
            + "bitrate=\(configuration.effectiveBitrate) mic=\(microphoneActive)"
        )

        // Waiting for the first frame means an immediate stop still produces a
        // valid file instead of a zero-sample writer.
        let firstFrame = await waitForFirstFrame(timeout: 1.5)
        guard firstFrame else {
            await discardStartedSession()
            throw RecordingError.noFramesCaptured
        }
        return url
    }

    /// Freeze the timeline and stop accepting frames. Returns `false` when the
    /// session is not running (repeated pause is a no-op).
    @discardableResult
    func pause() -> Bool {
        guard machine.state == .recording else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        guard machine.pause(at: now) else { return false }
        queue.sync {
            box.isPaused = true
            box.pauseSource = box.lastVideoSource
        }
        onStateChange?(state)
        DebugLog.log("recorder: paused at \(String(format: "%.2f", machine.elapsed(at: now)))s")
        return true
    }

    /// Resume writing. The first frame after this call absorbs the gap, so the
    /// paused wall-clock time never lands in the file's timeline.
    @discardableResult
    func resume() -> Bool {
        guard machine.state == .paused else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        guard machine.resume(at: now) else { return false }
        queue.sync { box.isPaused = false }
        onStateChange?(state)
        DebugLog.log("recorder: resumed, elapsed \(String(format: "%.2f", machine.elapsed(at: now)))s")
        return true
    }

    /// Stop the stream, finalize the file and report what was written.
    func stop(date: Date = Date()) async throws -> RecordingResult {
        guard state.isActive else { throw RecordingError.notRecording }
        guard machine.stop(at: date.timeIntervalSinceReferenceDate) else {
            throw RecordingError.notRecording
        }
        let elapsed = machine.lastElapsed
        queue.sync {
            box.accepting = false
            box.isPaused = true
        }

        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        endActivity()

        let writer = box.writer
        let videoInput = box.videoInput
        let audioInput = box.audioInput
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        queue.sync {
            box.writer = nil
            box.videoInput = nil
            box.audioInput = nil
        }

        let counters = queue.sync {
            (written: box.framesOut, dropped: box.framesDropped, seen: box.framesIn)
        }
        let url = outputURL
        outputURL = nil

        guard let writer, let url else {
            throw RecordingError.writerUnavailable("录像写入器已释放")
        }

        await writer.finishWriting()
        let status = writer.status
        DebugLog.log(
            "recorder: finish status=\(status.rawValue) frames=\(counters.written)/\(counters.seen) "
            + "dropped=\(counters.dropped) error=\(writer.error?.localizedDescription ?? "none")"
        )

        onStateChange?(state)

        guard status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.encoderFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter 状态 \(status.rawValue)"
            )
        }
        guard counters.written > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw RecordingError.noFramesCaptured
        }

        return RecordingResult(
            url: url,
            elapsed: elapsed,
            pixelSize: pixelSize,
            framesWritten: counters.written,
            framesDropped: counters.dropped,
            microphone: microphoneActive
        )
    }

    /// Abandon a session: stop the stream, cancel the writer and delete the
    /// partial file. Safe to call when idle.
    func cancel() {
        guard state.isActive else { return }
        _ = machine.stop(at: Date().timeIntervalSinceReferenceDate)
        queue.sync {
            box.accepting = false
            box.isPaused = true
        }
        let url = outputURL
        outputURL = nil
        let stream = self.stream
        self.stream = nil
        let writer = box.writer
        queue.sync {
            box.writer = nil
            box.videoInput = nil
            box.audioInput = nil
        }
        Task { @MainActor in
            if let stream { try? await stream.stopCapture() }
            writer?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        endActivity()
        onStateChange?(state)
        DebugLog.log("recorder: cancelled")
    }

    // MARK: - Clock

    func elapsed(at date: Date = Date()) -> TimeInterval {
        machine.elapsed(at: date.timeIntervalSinceReferenceDate)
    }

    func elapsedText(at date: Date = Date()) -> String {
        Self.elapsedText(elapsed(at: date))
    }

    /// `MM:SS`, or `H:MM:SS` past an hour.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Stream output

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            Self.appendVideo(sampleBuffer, box: box)
        case .audio:
            Self.appendAudio(sampleBuffer, box: box)
        case .microphone:
            if #available(macOS 15.0, *) {
                Self.appendAudio(sampleBuffer, box: box)
            }
        @unknown default:
            break
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        DebugLog.log("recorder: stream stopped with error: \(message)")
        Task { @MainActor [weak self] in
            self?.streamError = message
        }
    }

    /// ScreenCaptureKit also emits idle/blank frames; only `.complete` carries
    /// real pixels.
    nonisolated private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let raw = attachments.first?[.status] as? Int,
        let status = SCFrameStatus(rawValue: raw) else {
            return true
        }
        return status == .complete
    }

    nonisolated private static func appendVideo(_ sampleBuffer: CMSampleBuffer, box: WriterBox) {
        box.framesIn += 1
        guard box.accepting,
              let input = box.videoInput,
              let writer = box.writer,
              writer.status == .writing else { return }
        if box.isPaused {
            box.framesDropped += 1
            return
        }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard source.isValid else { return }

        if !box.sessionStarted {
            writer.startSession(atSourceTime: .zero)
            box.sessionStarted = true
            box.baseSource = source
        }
        guard let base = box.baseSource else { return }

        // First frame after a resume: absorb the whole paused gap so the
        // output timeline continues where it stopped.
        if let pauseSource = box.pauseSource {
            let gap = CMTimeSubtract(source, pauseSource)
            if gap.isValid, CMTimeCompare(gap, .zero) > 0 {
                box.pausedOffset = CMTimeAdd(box.pausedOffset, gap)
            }
            box.pauseSource = nil
        }
        box.lastVideoSource = source

        var output = CMTimeSubtract(CMTimeSubtract(source, base), box.pausedOffset)
        if !output.isValid || output.seconds < 0 { output = .zero }
        if let last = box.lastVideoOutput, CMTimeCompare(output, last) <= 0 {
            output = CMTimeAdd(
                last,
                CMTime(value: 1, timescale: CMTimeScale(max(600, box.frameRate * 2)))
            )
        }
        guard input.isReadyForMoreMediaData,
              let retimed = retimed(sampleBuffer, to: output),
              input.append(retimed) else { return }
        box.lastVideoOutput = output
        box.framesOut += 1
    }

    nonisolated private static func appendAudio(_ sampleBuffer: CMSampleBuffer, box: WriterBox) {
        guard box.accepting,
              let input = box.audioInput,
              let writer = box.writer,
              writer.status == .writing else { return }
        if box.isPaused { return }
        // Audio may arrive before the first video frame; the writer session
        // only exists after that frame.
        guard let base = box.baseSource else { return }
        let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard source.isValid else { return }

        var output = CMTimeSubtract(CMTimeSubtract(source, base), box.pausedOffset)
        if !output.isValid || output.seconds < 0 { return }
        if let last = box.lastAudioOutput, CMTimeCompare(output, last) <= 0 {
            output = CMTimeAdd(last, CMTime(value: 1, timescale: 48_000))
        }
        guard input.isReadyForMoreMediaData,
              let retimed = retimed(sampleBuffer, to: output),
              input.append(retimed) else { return }
        box.lastAudioOutput = output
        box.audioFramesOut += 1
    }

    /// Copy one sample buffer with all timing shifted onto `pts`.
    nonisolated private static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        to pts: CMTime
    ) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &count
        ) == noErr, count > 0 else { return sampleBuffer }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: count,
            arrayToFill: &timing,
            entriesNeededOut: nil
        ) == noErr else { return sampleBuffer }

        let delta = CMTimeSubtract(pts, timing[0].presentationTimeStamp)
        for index in 0..<count {
            timing[index].decodeTimeStamp = .invalid
            timing[index].presentationTimeStamp = CMTimeAdd(
                timing[index].presentationTimeStamp,
                delta
            )
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }

    // MARK: - Helpers

    /// AppKit region (global, bottom-left) → ScreenCaptureKit `sourceRect`
    /// (display-local, top-left), clipped to the screen.
    static func localTopLeftRect(region: CGRect?, on screen: NSScreen) -> CGRect? {
        localTopLeftRect(region: region, screenFrame: screen.frame)
    }

    /// Pure version used by the self test: same conversion without needing an
    /// `NSScreen`.
    static func localTopLeftRect(region: CGRect?, screenFrame: CGRect) -> CGRect? {
        guard let region else { return nil }
        let clipped = region.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return CGRect(
            x: clipped.minX - screenFrame.minX,
            y: screenFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    private func waitForFirstFrame(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.sync(execute: { box.framesIn > 0 }) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return queue.sync { box.framesIn > 0 }
    }

    /// Tear down a session whose stream never produced a frame.
    private func discardStartedSession() async {
        queue.sync {
            box.accepting = false
            box.isPaused = true
        }
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        let writer = box.writer
        let url = outputURL
        outputURL = nil
        queue.sync {
            box.writer = nil
            box.videoInput = nil
            box.audioInput = nil
        }
        writer?.cancelWriting()
        if let url { try? FileManager.default.removeItem(at: url) }
        endActivity()
        machine.reset()
        onStateChange?(state)
        DebugLog.log("recorder: discarded session without frames")
    }

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "正在录制屏幕"
        )
    }

    private func endActivity() {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }
}
