import Foundation

/// Always-on, low-volume diagnostics for scrolling capture.
///
/// The session's decisions are otherwise only visible with `UNSEEN_TRACE=1`,
/// which nobody launches a normal app with. A long capture that "does nothing"
/// is impossible to tell apart from "the page never moved" without the numbers,
/// so this writes one line per sample to a plain file the user can just send:
///
///     ~/Library/Logs/Unseen-scroll.log
///
/// Bounded to one file, truncated at launch, and only active while a scrolling
/// session runs.
enum ScrollDiag {
    /// Only ever touched inside `queue`, so the state is serialised by hand —
    /// the compiler cannot see that through a `DispatchQueue`.
    private final class Sink: @unchecked Sendable {
        var handle: FileHandle?
    }

    private static let queue = DispatchQueue(label: "unseen.scroll.diag")
    private static let sink = Sink()

    static var fileURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return logs.appendingPathComponent("Unseen-scroll.log")
    }

    static func begin() {
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: nil)
            sink.handle = FileHandle(forWritingAtPath: url.path)
            write("=== scrolling capture \(ISO8601DateFormatter().string(from: Date())) ===")
        }
    }

    static func log(_ message: @autoclosure @escaping () -> String) {
        queue.async { write(message()) }
    }

    private static func write(_ message: String) {
        guard sink.handle != nil else { return }
        let line = Data("[\(Self.stamp())] \(message)\n".utf8)
        try? sink.handle?.write(contentsOf: line)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
