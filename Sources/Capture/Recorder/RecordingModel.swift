import AVFoundation
import CoreGraphics
import Foundation

/// Where a recording session is in its lifecycle.
///
/// The enum is deliberately tiny: it is the value the status bar, the floating
/// indicator, the menu and the self test all switch on. Anything that needs to
/// know "is a session running" asks `isActive` instead of comparing cases.
enum RecordingState: String, Sendable, Equatable, CaseIterable {
    case idle
    case recording
    case paused
    /// A session has ended (or failed). A recorder object can be reused: a new
    /// `start` moves `finished` back to `recording`.
    case finished

    var isActive: Bool { self == .recording || self == .paused }

    var title: String {
        switch self {
        case .idle: "未录制"
        case .recording: "录制中"
        case .paused: "已暂停"
        case .finished: "已结束"
        }
    }
}

/// Container/codec choice for the recording. Both options are H.264; only the
/// container changes, which is why the settings picker is a format choice
/// rather than a codec choice.
enum RecordingFormat: String, Sendable, Equatable, CaseIterable, Identifiable {
    case mp4
    case mov

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .mp4: "MP4（H.264）"
        case .mov: "MOV（H.264）"
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .mov: .mov
        case .mp4: .mp4
        }
    }
}

/// Everything the recorder needs besides the screen and destination folder.
///
/// The stored values are not trusted: the settings UI accepts free text for the
/// bitrate, so `effective*` clamps them at the point of use.
struct RecordingConfiguration: Equatable, Sendable {
    var format: RecordingFormat = .mp4
    var frameRate: Int = 30
    var bitrate: Int = 12_000_000
    var capturesMicrophone: Bool = false

    static let frameRateOptions = [24, 30, 60]
    /// 4 / 8 / 12 / 20 Mbps. The default is 12 Mbps, enough for a Retina
    /// full-screen capture at 30 fps without making a 10-second clip enormous.
    static let bitrateOptions = [4_000_000, 8_000_000, 12_000_000, 20_000_000]
    static let minimumFrameRate = 10
    static let maximumFrameRate = 60
    static let minimumBitrate = 1_000_000
    static let maximumBitrate = 100_000_000

    var effectiveFrameRate: Int {
        min(max(frameRate, Self.minimumFrameRate), Self.maximumFrameRate)
    }

    var effectiveBitrate: Int {
        min(max(bitrate, Self.minimumBitrate), Self.maximumBitrate)
    }

    static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        let millions = Double(bitsPerSecond) / 1_000_000
        if millions == millions.rounded() {
            return "\(Int(millions)) Mbps"
        }
        return String(format: "%.1f Mbps", millions)
    }
}

/// Active-time accounting with pause support.
///
/// Pure value type driven by caller-supplied timestamps, so the self test can
/// prove "a 1.2 s pause contributes 0 s" without sleeping for real seconds.
/// A paused timeline reports the elapsed value frozen at the pause instant.
struct RecordingTimeline: Equatable, Sendable {
    private(set) var beganAt: TimeInterval?
    private(set) var pausedTotal: TimeInterval = 0
    private(set) var pauseStartedAt: TimeInterval?

    var isPaused: Bool { pauseStartedAt != nil }

    mutating func begin(at time: TimeInterval) {
        beganAt = time
        pausedTotal = 0
        pauseStartedAt = nil
    }

    /// Returns `false` when the timeline is not running or already paused, so
    /// duplicate pause calls are visible to the caller instead of silently
    /// double-counting.
    @discardableResult
    mutating func pause(at time: TimeInterval) -> Bool {
        guard beganAt != nil, pauseStartedAt == nil else { return false }
        pauseStartedAt = time
        return true
    }

    @discardableResult
    mutating func resume(at time: TimeInterval) -> Bool {
        guard let pauseStartedAt, beganAt != nil else { return false }
        pausedTotal += max(0, time - pauseStartedAt)
        self.pauseStartedAt = nil
        return true
    }

    func elapsed(at time: TimeInterval) -> TimeInterval {
        guard let beganAt else { return 0 }
        // While paused the clock is frozen at the pause instant; the paused
        // segment is not part of `pausedTotal` until resume, so subtracting it
        // here would double-count.
        let end = pauseStartedAt ?? time
        return max(0, end - beganAt - pausedTotal)
    }

    /// Freeze the final value and report it.
    @discardableResult
    mutating func end(at time: TimeInterval) -> TimeInterval {
        let value = elapsed(at: time)
        pauseStartedAt = nil
        return value
    }
}

/// The legal `idle → recording → paused → recording → finished` transitions,
/// plus the active-time clock.
///
/// Kept free of AVFoundation and AppKit so every illegal call (stop before
/// start, pause twice, resume when running) is assertable in the self test.
struct RecordingStateMachine: Equatable, Sendable {
    private(set) var state: RecordingState = .idle
    private(set) var timeline = RecordingTimeline()
    /// Duration of the last finished session, excluding paused time.
    private(set) var lastElapsed: TimeInterval = 0

    /// A recorder can start again after `finished`; starting while active is
    /// rejected so a second hotkey press cannot stack sessions.
    @discardableResult
    mutating func start(at time: TimeInterval) -> Bool {
        switch state {
        case .recording, .paused:
            return false
        case .idle, .finished:
            state = .recording
            timeline = RecordingTimeline()
            timeline.begin(at: time)
            lastElapsed = 0
            return true
        }
    }

    @discardableResult
    mutating func pause(at time: TimeInterval) -> Bool {
        guard state == .recording, timeline.pause(at: time) else { return false }
        state = .paused
        return true
    }

    @discardableResult
    mutating func resume(at time: TimeInterval) -> Bool {
        guard state == .paused, timeline.resume(at: time) else { return false }
        state = .recording
        return true
    }

    /// `false` for `idle`/`finished`, i.e. repeated stops are no-ops rather
    /// than crashes or negative durations.
    @discardableResult
    mutating func stop(at time: TimeInterval) -> Bool {
        guard state.isActive else { return false }
        lastElapsed = timeline.end(at: time)
        state = .finished
        return true
    }

    /// Back to `idle`, used when a start attempt fails before any frame lands.
    mutating func reset() {
        state = .idle
        timeline = RecordingTimeline()
        lastElapsed = 0
    }

    func elapsed(at time: TimeInterval) -> TimeInterval {
        timeline.elapsed(at: time)
    }
}

/// What one finished recording actually produced.
struct RecordingResult: Equatable, Sendable {
    let url: URL
    /// Active recording time measured before the writer finalized. The file's
    /// own duration is read back by the caller / self test with `AVURLAsset`.
    let elapsed: TimeInterval
    let pixelSize: CGSize
    let framesWritten: Int
    let framesDropped: Int
    let microphone: Bool
}

/// Errors with user-facing text, in the same style as `CaptureError`.
enum RecordingError: LocalizedError, Equatable {
    case screenRecordingDenied
    case noDisplay
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case writerUnavailable(String)
    case encoderFailed(String)
    case noFramesCaptured

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "还没有屏幕录制权限。请到 系统设置 → 隐私与安全性 → 屏幕录制 中勾选「Unseen」，然后重新启动本 App。"
        case .noDisplay:
            return "找不到要录制的显示器。"
        case .alreadyRecording:
            return "已经在录制了。"
        case .notRecording:
            return "当前没有正在进行的录制。"
        case .microphoneUnavailable:
            return "麦克风不可用或未授权，本次录制不包含麦克风。"
        case .writerUnavailable(let detail):
            return "无法创建录像文件：\(detail)"
        case .encoderFailed(let detail):
            return "视频编码失败：\(detail)"
        case .noFramesCaptured:
            return "没有捕获到任何画面，未生成录像文件。"
        }
    }
}

/// The status-bar label while a recording is live.
///
/// Pure so the self test can assert the red-dot/timer rendering without
/// running the app's menu bar.
enum RecordingStatusBadge {
    /// `● 00:12` while recording, `⏸ 00:12` while paused, `nil` otherwise.
    static func text(state: RecordingState, elapsedText: String) -> String? {
        switch state {
        case .recording: "● \(elapsedText)"
        case .paused: "⏸ \(elapsedText)"
        case .idle, .finished: nil
        }
    }

    static func isPaused(_ state: RecordingState) -> Bool { state == .paused }
}

/// File naming for recordings. Mirrors the screenshot rule
/// (`截图-yyyyMMdd-HHmmss.png`) so screenshots and recordings sort together in
/// the same folder.
enum RecordingNaming {
    static let prefix = "录屏"

    /// `录屏-20261022-190500.mp4`
    static func fileName(date: Date = Date(), format: RecordingFormat) -> String {
        "\(prefix)-\(timestamp(date)).\(format.fileExtension)"
    }

    /// A URL in `directory` that does not exist yet. Two recordings started in
    /// the same second get `-2`, `-3`, … rather than overwriting each other.
    static func url(
        in directory: URL,
        date: Date = Date(),
        format: RecordingFormat,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = "\(prefix)-\(timestamp(date))"
        var candidate = directory.appendingPathComponent("\(base).\(format.fileExtension)")
        var suffix = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(format.fileExtension)")
            suffix += 1
        }
        return candidate
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
