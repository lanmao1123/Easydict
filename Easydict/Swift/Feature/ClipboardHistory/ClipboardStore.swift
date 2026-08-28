//
//  ClipboardStore.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import CryptoKit
import Foundation
import SQLite3

// MARK: - PendingRow

/// One row awaiting insertion; bundles the insert parameters so the SQLite
/// binding code stays under the parameter-count lint limit.
struct PendingRow {
    let kind: ClipboardEntryKind
    let text: String?
    let preview: String
    let imageFile: String?
    let thumbFile: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: Int
    let contentHash: String
    let sourceApp: String?
    let sourceBundleID: String?
    let createdAt: Date
}

// MARK: - ClipboardStoreError

enum ClipboardStoreError: Error {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
}

// MARK: - ClipboardStore

/// SQLite-backed permanent clipboard history under one folder: an `entries`
/// table plus an `images/` folder holding the image payloads.
///
/// All APIs are synchronous and serialized by the caller (ClipboardMonitor's
/// store queue); the connection is opened with SQLite's full mutex so a stray
/// cross-thread call cannot corrupt state.
final class ClipboardStore {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - directory: store root; created on demand. Tests inject a temp dir.
    init(directory: URL) throws {
        self.directory = directory
        let imagesDir = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        self.imagesDirectory = imagesDir

        let dbPath = directory.appendingPathComponent("history.db").path
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) ==
            SQLITE_OK else {
            throw ClipboardStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try exec(Self.schemaSQL)
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: Internal

    let directory: URL
    let imagesDirectory: URL

    static func imagePreviewTitle(width: Int?, height: Int?) -> String {
        guard let width, let height else { return "Image" }
        return "Image (\(width)×\(height))"
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Closes the SQLite connection. Only used when switching the store to a
    /// new directory; further calls on a closed store fail gracefully.
    func close() {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    /// High-level text insert: dedups by content hash by removing the older
    /// twin, so repeats land back on top with a fresh timestamp.
    @discardableResult
    func insertText(
        _ text: String,
        sourceApp: String?,
        sourceBundleID: String?,
        at date: Date = Date()
    ) throws
        -> Int64 {
        let hash = Self.sha256(Data(text.utf8))
        try removeEntries(matchingHash: hash)

        return try insert(PendingRow(
            kind: .text,
            text: text,
            preview: text.clipboardPreview(),
            imageFile: nil,
            thumbFile: nil,
            pixelWidth: nil,
            pixelHeight: nil,
            byteCount: text.utf8.count,
            contentHash: hash,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            createdAt: date
        ))
    }

    /// High-level image insert; the payload is already on disk by the time
    /// the monitor calls this. Dedup mirrors text: older twin is removed.
    @discardableResult
    func insertImage(
        imageFile: String,
        thumbFile: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        byteCount: Int,
        contentHash: String,
        sourceApp: String?,
        sourceBundleID: String?,
        at date: Date = Date()
    ) throws
        -> Int64 {
        try removeEntries(matchingHash: contentHash, alsoDeletingFiles: true)

        return try insert(PendingRow(
            kind: .image,
            text: nil,
            preview: Self.imagePreviewTitle(width: pixelWidth, height: pixelHeight),
            imageFile: imageFile,
            thumbFile: thumbFile,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: byteCount,
            contentHash: contentHash,
            sourceApp: sourceApp,
            sourceBundleID: sourceBundleID,
            createdAt: date
        ))
    }

    /// Keeps the text history bounded: drops text rows beyond the newest
    /// `maxCount` and rows older than `ageLimit`. Text rows carry no files, so
    /// a plain row delete is enough. Image rows are governed separately by
    /// the byte-cap prune in ClipboardMonitor.
    @discardableResult
    func pruneTexts(
        maxCount: Int = 500,
        ageLimit: TimeInterval = 90 * 24 * 3600
    ) throws
        -> Int {
        let cutoff = Date().addingTimeInterval(-ageLimit).timeIntervalSince1970
        let sql = """
        DELETE FROM entries
        WHERE kind = 'text'
          AND (created_at < ? OR id NOT IN (
              SELECT id FROM entries WHERE kind = 'text'
              ORDER BY created_at DESC LIMIT ?
          ))
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_double(statement, 1, cutoff)
        sqlite3_bind_int(statement, 2, Int32(maxCount))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        let removed = Int(sqlite3_changes(db))
        if removed > 0 {
            logInfo("[Clipboard] Text history pruned, removed=\(removed), maxCount=\(maxCount)")
        }
        return removed
    }

    /// Newest-first listing; `since == nil` means the whole history.
    func entries(
        since: Date?,
        keyword: String? = nil,
        kind: ClipboardKindFilter = .all,
        limit: Int = 500
    ) throws
        -> [ClipboardEntry] {
        var sql = "SELECT \(Self.columns) FROM entries WHERE 1=1"
        var bindings: [String] = []

        if let since {
            sql += " AND created_at >= ?"
            bindings.append(String(since.timeIntervalSince1970))
        }
        if let keyword, !keyword.isEmpty {
            sql += " AND kind = 'text' AND text LIKE '%' || ? || '%'"
            bindings.append(keyword)
        }
        switch kind {
        case .all:
            break
        case .text:
            sql += " AND kind = 'text'"
        case .image:
            sql += " AND kind = 'image'"
        }
        sql += " ORDER BY created_at DESC LIMIT \(limit)"

        return try query(sql, bindings: bindings)
    }

    func delete(id: Int64) throws {
        for entry in entries(withIDs: [id]) {
            removeFiles(of: entry)
        }
        try exec("DELETE FROM entries WHERE id = \(id)")
    }

    /// Clears image payloads and their rows older than the cutoff without
    /// touching text entries. Returns the removed row count.
    @discardableResult
    func deleteImages(olderThan cutoff: Date) throws -> Int {
        let victims = try query(
            "SELECT \(Self.columns) FROM entries WHERE kind = 'image' AND created_at < \(cutoff.timeIntervalSince1970)",
            bindings: []
        )
        for entry in victims {
            removeFiles(of: entry)
        }
        try exec("DELETE FROM entries WHERE kind = 'image' AND created_at < \(cutoff.timeIntervalSince1970)")
        return victims.count
    }

    /// SUM of image payload sizes — the number a capacity guard acts on.
    func totalImageBytes() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT COALESCE(SUM(byte_count), 0) FROM entries WHERE kind = 'image'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Image rows oldest-first, for capacity-driven eviction.
    func oldestImages(limit: Int) throws -> [ClipboardEntry] {
        try query(
            "SELECT \(Self.columns) FROM entries WHERE kind = 'image' ORDER BY created_at ASC LIMIT \(limit)",
            bindings: []
        )
    }

    func count() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries", -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Absolute URL of an entry's stored image, if it still exists.
    func imageURL(for entry: ClipboardEntry) -> URL? {
        guard let file = entry.imageFile else { return nil }
        let url = imagesDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbImageURL(for entry: ClipboardEntry) -> URL? {
        guard let file = entry.thumbFile else { return nil }
        let url = imagesDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Unique file name for a new image payload, e.g.
    /// `2026-08-27-161530-a1b2c3d4.png`. A `-N` suffix keeps same-second
    /// duplicates of identical content from colliding, which would let the
    /// dedup step delete the freshly written file.
    func makeImageFileName(date: Date = Date(), hash: String) -> String {
        let stamp = Self.fileNameFormatter.string(from: date)
        let digest = String(hash.prefix(8))
        var name = "\(stamp)-\(digest).png"
        var sequence = 2
        while FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent(name).path) {
            name = "\(stamp)-\(digest)-\(sequence).png"
            sequence += 1
        }
        return name
    }

    // MARK: Private

    private static let columns = "id, kind, text, preview, image_file, thumb_file, width, height, byte_count, content_hash, source_app, source_bundle, created_at"

    private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        text TEXT,
        preview TEXT NOT NULL DEFAULT '',
        image_file TEXT,
        thumb_file TEXT,
        width INTEGER,
        height INTEGER,
        byte_count INTEGER NOT NULL DEFAULT 0,
        content_hash TEXT NOT NULL,
        source_app TEXT,
        source_bundle TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_entries_created ON entries(created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(content_hash);
    """

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var db: OpaquePointer?

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    @discardableResult
    private func insert(_ row: PendingRow) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = """
        INSERT INTO entries
        (kind, text, preview, image_file, thumb_file, width, height, byte_count, content_hash, source_app, source_bundle, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }

        sqlite3_bind_text(statement, 1, row.kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text = row.text {
            sqlite3_bind_text(statement, 2, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_text(statement, 3, row.preview, -1, SQLITE_TRANSIENT)
        bindOptionalText(statement, 4, row.imageFile)
        bindOptionalText(statement, 5, row.thumbFile)
        bindOptionalInt(statement, 6, row.pixelWidth)
        bindOptionalInt(statement, 7, row.pixelHeight)
        sqlite3_bind_int64(statement, 8, Int64(row.byteCount))
        sqlite3_bind_text(statement, 9, row.contentHash, -1, SQLITE_TRANSIENT)
        bindOptionalText(statement, 10, row.sourceApp)
        bindOptionalText(statement, 11, row.sourceBundleID)
        sqlite3_bind_double(statement, 12, row.createdAt.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func removeEntries(matchingHash hash: String, alsoDeletingFiles: Bool = false) throws {
        let twins = try query(
            "SELECT \(Self.columns) FROM entries WHERE content_hash = ?",
            bindings: [hash]
        )
        if alsoDeletingFiles {
            for entry in twins {
                removeFiles(of: entry)
            }
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM entries WHERE content_hash = ?", -1, &statement, nil) == SQLITE_OK
        else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, hash, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func entries(withIDs ids: [Int64]) -> [ClipboardEntry] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        return (try? query("SELECT \(Self.columns) FROM entries WHERE id IN (\(list))", bindings: [])) ?? []
    }

    private func query(_ sql: String, bindings: [String]) throws -> [ClipboardEntry] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        for (index, binding) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), binding, -1, SQLITE_TRANSIENT)
        }

        var result: [ClipboardEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(readRow(statement))
        }
        return result
    }

    private func readRow(_ statement: OpaquePointer?) -> ClipboardEntry {
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return String(cString: sqlite3_column_text(statement, index))
        }
        func int(_ index: Int32) -> Int? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, index))
        }

        let kind = text(1) == "image" ? ClipboardEntryKind.image : .text
        return ClipboardEntry(
            id: sqlite3_column_int64(statement, 0),
            kind: kind,
            text: text(2),
            preview: text(3) ?? "",
            imageFile: text(4),
            thumbFile: text(5),
            pixelWidth: int(6),
            pixelHeight: int(7),
            byteCount: Int(sqlite3_column_int64(statement, 8)),
            contentHash: text(9) ?? "",
            sourceApp: text(10),
            sourceBundleID: text(11),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
        )
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func removeFiles(of entry: ClipboardEntry) {
        for file in [entry.imageFile, entry.thumbFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
