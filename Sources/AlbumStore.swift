import AppKit
import Foundation

/// Local record of screenshots that were saved into **Apple Photos**.
///
/// The pictures themselves live in 照片 — this store is only an index so the
/// 相册 page can show what was imported, when, and from which folder, without
/// asking Photos to enumerate the user's library (which would need read access
/// the app deliberately does not request).
///
/// Every entry also points at a normal history row, so 复制 / 钉图 keep working
/// from the grid. The local PNG copy exists only for the thumbnails on that page.
///
/// Images live in `…/Application Support/Unseen/Album/` as
/// `<uuid>.png`. Deleting an album entry deletes its file; the JSON index is
/// rewritten on every change and is small enough to rewrite wholesale.
@MainActor
enum AlbumStore {
    /// One album entry.
    struct AlbumRecord: Codable, Identifiable, Hashable, Sendable {
        var id: UUID = UUID()
        /// The history row this entry mirrors. `-1` for an import that could
        /// not be registered in history (should not happen, kept for safety).
        var itemID: Int64
        /// When it entered the album.
        var addedAt: Date
        /// Where it came from: file name and containing folder. Both `nil` for
        /// screenshots taken by the app itself.
        var sourceName: String?
        var sourceFolder: String?
        /// `PHAsset` local identifier returned by Photos, when it gave us one.
        /// Useful for diagnostics; the UI does not depend on it.
        var photoAssetID: String?

        /// Provenance line for the UI, e.g. "来自 桌面/截图".
        var originText: String? {
            if let sourceName {
                let folder = sourceFolder.map { ($0 as NSString).lastPathComponent } ?? ""
                return folder.isEmpty ? "来自 \(sourceName)" : "来自 \(folder)/\(sourceName)"
            }
            return nil
        }
    }

    // MARK: - Locations

    static var albumDirectory: URL {
        AppModel.resolveStorageDirectory().appendingPathComponent("Album", isDirectory: true)
    }

    static var indexURL: URL {
        albumDirectory.appendingPathComponent("album.json")
    }

    // MARK: - Read

    /// Every album record, newest first. Missing/corrupt index reads as empty
    /// rather than throwing: the album must never block the app from starting.
    ///
    /// The decoder is built here rather than read from a shared instance because
    /// `save` writes ISO-8601 dates; a plain `JSONDecoder()` would then fail to
    /// read back its own output and the album would look empty on next launch.
    static func load() -> [AlbumRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([AlbumRecord].self, from: data) else {
            DebugLog.log("album: index is unreadable; treating as empty")
            return []
        }
        return records.sorted { $0.addedAt > $1.addedAt }
    }

    static func load(for itemID: Int64) -> AlbumRecord? {
        load().first { $0.itemID == itemID }
    }

    // MARK: - Write

    /// Store one PNG in the album and record the pointer. Returns the record on
    /// success; `nil` means the copy failed and nothing changed.
    @discardableResult
    static func save(
        pngData: Data,
        itemID: Int64 = -1,
        sourceName: String? = nil,
        sourceFolder: String? = nil,
        photoAssetID: String? = nil
    ) -> AlbumRecord? {
        let fm = FileManager.default
        // The record id is chosen *before* the file so the PNG can be named
        // after it. `fileURL(for:)` is the only way anything reads the bytes
        // back, so the two must agree — naming the file with a fresh UUID and
        // the record with another made every album tile unreadable.
        let record = AlbumRecord(
            itemID: itemID,
            addedAt: Date(),
            sourceName: sourceName,
            sourceFolder: sourceFolder,
            photoAssetID: photoAssetID
        )
        do {
            try fm.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL(for: record.id))
        } catch {
            DebugLog.log("album: cannot write image: \(error.localizedDescription)")
            return nil
        }
        var records = load()
        records.insert(record, at: 0)
        persist(records)
        return record
    }

    /// Remove one entry and its image file.
    static func delete(_ record: AlbumRecord) {
        var records = load()
        records.removeAll { $0.id == record.id }
        persist(records)
        removeFile(for: record.id)
    }

    /// Make sure every album entry still has a file; drop the ones that do not.
    /// Called once at launch so a half-deleted folder cannot leave ghost rows.
    @discardableResult
    static func pruneMissingFiles() -> Int {
        let records = load()
        let kept = records.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
        let dropped = records.count - kept.count
        if dropped > 0 { persist(kept) }
        return dropped
    }

    static func fileURL(for recordID: UUID) -> URL {
        albumDirectory.appendingPathComponent("\(recordID.uuidString).png")
    }

    /// Image bytes for an album entry.
    static func imageData(for record: AlbumRecord) -> Data? {
        try? Data(contentsOf: fileURL(for: record.id))
    }

    // MARK: - Index

    private static func persist(_ records: [AlbumRecord]) {
        do {
            try FileManager.default.createDirectory(at: albumDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            // `.atomic` so a crash mid-write cannot truncate the index.
            try data.write(to: indexURL, options: .atomic)
        } catch {
            DebugLog.log("album: cannot write index: \(error.localizedDescription)")
        }
    }

    private static func removeFile(for recordID: UUID) {
        let url = albumDirectory.appendingPathComponent("\(recordID.uuidString).png")
        try? FileManager.default.removeItem(at: url)
    }
}
