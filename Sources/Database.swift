import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: LocalizedError {
    case open(String)
    case prepare(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): "无法打开数据库：\(m)"
        case .prepare(let m): "SQL 编译失败：\(m)"
        case .step(let m): "SQL 执行失败：\(m)"
        }
    }
}

/// Tiny synchronous SQLite wrapper. All work is serialised on a private queue,
/// so the type is safe to hand across concurrency domains.
final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "com.hexyans.unseen.database")

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw DatabaseError.open(message)
        }
        self.handle = handle
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA busy_timeout = 3000;")
        try migrate()
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - Low level

    private func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(error)
                throw DatabaseError.step(message)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS items (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            hash        TEXT    NOT NULL UNIQUE,
            kind        TEXT    NOT NULL,
            text        TEXT,
            fileURLs    TEXT,
            image       BLOB,
            thumb       BLOB,
            hasImage    INTEGER NOT NULL DEFAULT 0,
            byteCount   INTEGER NOT NULL DEFAULT 0,
            createdAt   REAL    NOT NULL,
            updatedAt   REAL    NOT NULL,
            sourceApp   TEXT,
            bundleID    TEXT,
            pinned      INTEGER NOT NULL DEFAULT 0,
            copyCount   INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_items_updatedAt ON items(updatedAt DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(pinned);")
    }

    // MARK: - Binding helpers

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Data?) {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        value.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func data(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    // MARK: - Writes

    /// Insert, or bump an existing row with the same content hash.
    @discardableResult
    func upsert(hash: String, payload: ClipPayload, at date: Date = Date()) throws -> Int64 {
        try queue.sync {
            let sql = """
            INSERT INTO items
                (hash, kind, text, fileURLs, image, thumb, hasImage, byteCount,
                 createdAt, updatedAt, sourceApp, bundleID, pinned, copyCount)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
            ON CONFLICT(hash) DO UPDATE SET
                updatedAt = excluded.updatedAt,
                kind      = excluded.kind,
                text      = COALESCE(excluded.text, items.text),
                fileURLs  = COALESCE(excluded.fileURLs, items.fileURLs),
                image     = COALESCE(excluded.image, items.image),
                thumb     = COALESCE(excluded.thumb, items.thumb),
                hasImage  = MAX(excluded.hasImage, items.hasImage),
                byteCount = excluded.byteCount,
                sourceApp = COALESCE(excluded.sourceApp, items.sourceApp),
                bundleID  = COALESCE(excluded.bundleID, items.bundleID),
                copyCount = items.copyCount + 1;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            let encodedFiles = payload.fileURLs.isEmpty
                ? nil
                : String(data: try JSONEncoder().encode(payload.fileURLs), encoding: .utf8)

            bind(statement, 1, hash)
            bind(statement, 2, payload.kind.rawValue)
            bind(statement, 3, payload.text)
            bind(statement, 4, encodedFiles)
            bind(statement, 5, payload.imagePNG)
            bind(statement, 6, payload.thumbnailPNG)
            bind(statement, 7, Int64(payload.imagePNG == nil ? 0 : 1))
            bind(statement, 8, Int64(payload.byteCount))
            bind(statement, 9, date.timeIntervalSince1970)
            bind(statement, 10, date.timeIntervalSince1970)
            bind(statement, 11, payload.sourceApp)
            bind(statement, 12, payload.bundleID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }

            let lookup = try prepare("SELECT id FROM items WHERE hash = ? LIMIT 1;")
            defer { sqlite3_finalize(lookup) }
            bind(lookup, 1, hash)
            guard sqlite3_step(lookup) == SQLITE_ROW else {
                throw DatabaseError.step("无法回读刚写入的记录")
            }
            return sqlite3_column_int64(lookup, 0)
        }
    }

    func setPinned(id: Int64, pinned: Bool) throws {
        try queue.sync {
            let statement = try prepare("UPDATE items SET pinned = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, Int64(pinned ? 1 : 0))
            bind(statement, 2, id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func bumpCopyCount(id: Int64) throws {
        try queue.sync {
            let statement = try prepare("UPDATE items SET copyCount = copyCount + 1 WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, id)
            _ = sqlite3_step(statement)
        }
    }

    func delete(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let statement = try prepare("DELETE FROM items WHERE id IN (\(placeholders));")
            defer { sqlite3_finalize(statement) }
            for (offset, id) in ids.enumerated() {
                bind(statement, Int32(offset + 1), id)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func clearAll(keepingPinned: Bool) throws {
        try execute(keepingPinned ? "DELETE FROM items WHERE pinned = 0;" : "DELETE FROM items;")
    }

    /// Delete the oldest unpinned rows beyond `maxItems`.
    func trim(maxItems: Int) throws {
        try queue.sync {
            let statement = try prepare("""
            DELETE FROM items WHERE pinned = 0 AND id NOT IN (
                SELECT id FROM items WHERE pinned = 0 ORDER BY updatedAt DESC LIMIT ?
            );
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, Int64(max(0, maxItems)))
            _ = sqlite3_step(statement)
        }
    }

    /// Delete unpinned rows older than `days`. `days <= 0` disables pruning.
    func prune(olderThanDays days: Int, now: Date = Date()) throws {
        guard days > 0 else { return }
        try queue.sync {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            let statement = try prepare("DELETE FROM items WHERE pinned = 0 AND updatedAt < ?;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, cutoff)
            _ = sqlite3_step(statement)
        }
    }

    // MARK: - Reads

    func fetch(limit: Int = 500, retentionDays: Int = 0, now: Date = Date()) throws -> [ClipItem] {
        try queue.sync {
            let cutoff = retentionDays > 0
                ? now.addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
                : 0
            let sql = """
            SELECT id, kind, text, fileURLs, hasImage, byteCount,
                   createdAt, updatedAt, sourceApp, bundleID, pinned, copyCount
            FROM items
            WHERE pinned = 1 OR updatedAt >= ?
            ORDER BY pinned DESC, updatedAt DESC
            LIMIT ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, cutoff)
            bind(statement, 2, Int64(limit))

            var results: [ClipItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let fileURLs: [String]
                if let encoded = string(statement, 3), let data = encoded.data(using: .utf8) {
                    fileURLs = (try? JSONDecoder().decode([String].self, from: data)) ?? []
                } else {
                    fileURLs = []
                }
                results.append(ClipItem(
                    id: sqlite3_column_int64(statement, 0),
                    kind: ClipKind(rawValue: string(statement, 1) ?? "") ?? .text,
                    text: string(statement, 2),
                    fileURLs: fileURLs,
                    hasImage: sqlite3_column_int64(statement, 4) != 0,
                    byteCount: Int(sqlite3_column_int64(statement, 5)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    sourceApp: string(statement, 8),
                    bundleID: string(statement, 9),
                    pinned: sqlite3_column_int64(statement, 10) != 0,
                    copyCount: Int(sqlite3_column_int64(statement, 11))
                ))
            }
            return results
        }
    }

    func loadImage(id: Int64, thumbnail: Bool = false) throws -> Data? {
        try queue.sync {
            let column = thumbnail ? "thumb" : "image"
            let statement = try prepare("SELECT \(column) FROM items WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return data(statement, 0)
        }
    }

    /// Captures per calendar day, for the usage heat-map.
    func dailyCounts(days: Int, now: Date = Date()) throws -> [Date: Int] {
        try queue.sync {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            let statement = try prepare("""
            SELECT date(updatedAt, 'unixepoch', 'localtime') AS day, COUNT(*)
            FROM items WHERE updatedAt >= ?
            GROUP BY day;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, cutoff)

            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd"
            parser.timeZone = .current

            var result: [Date: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = string(statement, 0), let date = parser.date(from: raw) else { continue }
                result[Calendar.current.startOfDay(for: date)] = Int(sqlite3_column_int64(statement, 1))
            }
            return result
        }
    }

    func count() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM items;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
