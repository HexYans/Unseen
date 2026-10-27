import Foundation

/// What kind of payload a clipboard entry carries.
enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case image
    case files
    case mixed

    var displayName: String {
        switch self {
        case .text: "文本"
        case .richText: "富文本"
        case .image: "图片"
        case .files: "文件"
        case .mixed: "混合内容"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .files: "folder"
        case .mixed: "square.stack.3d.up"
        }
    }
}

/// A row of clipboard history, without the (potentially huge) image blob.
struct ClipItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var kind: ClipKind
    var text: String?
    var fileURLs: [String]
    var hasImage: Bool
    var byteCount: Int
    var createdAt: Date
    var updatedAt: Date
    var sourceApp: String?
    var bundleID: String?
    var pinned: Bool
    var copyCount: Int

    /// One-or-two-line summary shown in the history list.
    var preview: String {
        if !fileURLs.isEmpty {
            let names = fileURLs.map { URL(fileURLWithPath: $0).lastPathComponent }
            if names.count == 1 { return names[0] }
            return names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " 等 \(names.count) 项" : "")
        }
        if let text, !text.isEmpty {
            let collapsed = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "  ")
            return collapsed.isEmpty ? "(空白文本)" : collapsed
        }
        if hasImage { return "图片" }
        return "(空)"
    }

    var byteCountText: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

/// The actual bytes captured from / written to `NSPasteboard`.
struct ClipPayload: Sendable {
    var kind: ClipKind
    var text: String?
    var imagePNG: Data?
    var thumbnailPNG: Data?
    var fileURLs: [String]
    var sourceApp: String?
    var bundleID: String?

    var isEmpty: Bool {
        (text?.isEmpty ?? true) && imagePNG == nil && fileURLs.isEmpty
    }

    var byteCount: Int {
        (text?.utf8.count ?? 0) + (imagePNG?.count ?? 0) + fileURLs.reduce(0) { $0 + $1.utf8.count }
    }
}

/// Sidebar segments: which kinds of entry to show.
enum ClipFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .image: "图片"
        case .file: "文件"
        }
    }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text || item.kind == .richText
        case .image: item.hasImage
        case .file: !item.fileURLs.isEmpty
        }
    }
}
