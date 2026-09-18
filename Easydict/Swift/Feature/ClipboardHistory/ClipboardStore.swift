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
    let ocrText: String?
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
        try addImageOCRTextColumnIfNeeded()
        self.fullTextSearchAvailable = configureFullTextSearch()
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
            ocrText: nil,
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
            ocrText: nil,
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
    ///
    /// Keywords route by script: latin keywords use the FTS5 index, while
    /// keywords containing CJK characters fall back to LIKE — FTS5's default
    /// tokenizer never segments Han/Kana runs, so an indexed Chinese query
    /// like 「宁静」 matches nothing (the whole sentence is one token). The
    /// LIKE scan is a two-column full sweep over a personal-size history
    /// (a few thousand rows), well under interactive latency.
    func entries(
        since: Date?,
        keyword: String? = nil,
        kind: ClipboardKindFilter = .all,
        includesImageText: Bool = false,
        limit: Int? = nil
    ) throws
        -> [ClipboardEntry] {
        let trimmedKeyword = keyword?.isEmpty == false ? keyword : nil
        let usesFullTextSearch = trimmedKeyword != nil
            && fullTextSearchAvailable
            && !trimmedKeyword!.containsCJK

        var sql: String
        var bindings: [String] = []

        if let keyword = trimmedKeyword {
            if usesFullTextSearch {
                sql = "SELECT \(Self.qualifiedColumns) FROM entries JOIN entries_fts ON entries_fts.rowid = entries.id WHERE entries_fts MATCH ?"
                bindings.append(Self.fullTextQuery(for: keyword))
                if !includesImageText {
                    sql += " AND entries.kind = 'text'"
                }
            } else {
                let pattern = "%\(Self.escapeLike(keyword))%"
                if includesImageText {
                    sql =
                        "SELECT \(Self.columns) FROM entries WHERE (IFNULL(text, '') LIKE ? ESCAPE '\\' OR IFNULL(ocr_text, '') LIKE ? ESCAPE '\\')"
                    bindings = [pattern, pattern]
                } else {
                    sql =
                        "SELECT \(Self.columns) FROM entries WHERE kind = 'text' AND text LIKE ? ESCAPE '\\'"
                    bindings = [pattern]
                }
            }
        } else {
            sql = "SELECT \(Self.columns) FROM entries WHERE 1=1"
        }

        if let since {
            sql += " AND created_at >= ?"
            bindings.append(String(since.timeIntervalSince1970))
        }
        switch kind {
        case .all:
            break
        case .text:
            sql += " AND kind = 'text'"
        case .image:
            sql += " AND kind = 'image'"
        }
        sql += " ORDER BY created_at DESC"
        if let limit, limit > 0 {
            sql += " LIMIT \(limit)"
        }

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

    /// Removes every row along with each entry's payload files — the store
    /// side of the panel's "Clear all" action. Returns the removed row count.
    @discardableResult
    func deleteAllEntries() throws -> Int {
        let victims = try query("SELECT \(Self.columns) FROM entries", bindings: [])
        for entry in victims {
            removeFiles(of: entry)
        }
        try exec("DELETE FROM entries")
        logInfo("[Clipboard] Cleared all entries, removed=\(victims.count)")
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

    /// Number of stored image rows — the count-driven eviction gauge.
    func imageCount() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT COUNT(*) FROM entries WHERE kind = 'image'", -1, &statement, nil
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

    /// Returns image entries that have not been OCR-indexed yet. Empty text is
    /// persisted after a completed no-text recognition, so it is not retried.
    func unindexedImages(limit: Int = 200) throws -> [ClipboardEntry] {
        try query(
            "SELECT \(Self.columns) FROM entries WHERE kind = 'image' AND ocr_text IS NULL ORDER BY created_at DESC LIMIT \(limit)",
            bindings: []
        )
    }

    /// Stores a completed background OCR result and lets the FTS trigger keep
    /// the text/image search index in sync.
    func updateImageOCRText(_ text: String, forEntryID id: Int64) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "UPDATE entries SET ocr_text = ? WHERE id = ? AND kind = 'image'",
            -1, &statement, nil
        ) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
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
    private static let qualifiedColumns = "entries.id, entries.kind, entries.text, entries.preview, entries.image_file, entries.thumb_file, entries.width, entries.height, entries.byte_count, entries.content_hash, entries.source_app, entries.source_bundle, entries.created_at"

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
    CREATE INDEX IF NOT EXISTS idx_entries_kind_created ON entries(kind, created_at DESC);
    CREATE INDEX IF NOT EXISTS idx_entries_hash ON entries(content_hash);
    """

    private static let fullTextSchemaSQL = """
    CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
        text,
        ocr_text,
        content='entries',
        content_rowid='id',
        tokenize='unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS entries_fts_insert AFTER INSERT ON entries BEGIN
        INSERT INTO entries_fts(rowid, text, ocr_text) VALUES (new.id, new.text, new.ocr_text);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_fts_delete AFTER DELETE ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, text, ocr_text) VALUES ('delete', old.id, old.text, old.ocr_text);
    END;
    CREATE TRIGGER IF NOT EXISTS entries_fts_update AFTER UPDATE OF text, ocr_text ON entries BEGIN
        INSERT INTO entries_fts(entries_fts, rowid, text, ocr_text) VALUES ('delete', old.id, old.text, old.ocr_text);
        INSERT INTO entries_fts(rowid, text, ocr_text) VALUES (new.id, new.text, new.ocr_text);
    END;
    """

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var db: OpaquePointer?
    private var fullTextSearchAvailable = false

    /// Escapes LIKE wildcards so a keyword like "50%" matches literally.
    private static func escapeLike(_ keyword: String) -> String {
        keyword
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func fullTextQuery(for keyword: String) -> String {
        keyword
            .split(whereSeparator: \.isWhitespace)
            .map { "\"\(String($0).replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    /// Installs an external-content FTS5 index once and rebuilds it for
    /// databases created before the index existed. If a platform SQLite build
    /// lacks FTS5, history remains usable through the compatible LIKE fallback.
    private func configureFullTextSearch() -> Bool {
        do {
            try exec(Self.fullTextSchemaSQL)
            let versionKey = "entries-fts-version"
            guard try metadataValue(for: versionKey) != "2" else { return true }
            try exec("DROP TRIGGER IF EXISTS entries_fts_insert")
            try exec("DROP TRIGGER IF EXISTS entries_fts_delete")
            try exec("DROP TRIGGER IF EXISTS entries_fts_update")
            try exec("DROP TABLE IF EXISTS entries_fts")
            try exec(Self.fullTextSchemaSQL)
            try exec("INSERT INTO entries_fts(entries_fts) VALUES ('rebuild')")
            try setMetadataValue("2", for: versionKey)
            return true
        } catch {
            logWarn("[Clipboard] Full-text index unavailable: \(error)")
            return false
        }
    }

    private func metadataValue(for key: String) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key = ?", -1, &statement, nil) == SQLITE_OK
        else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipboardStoreError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func addImageOCRTextColumnIfNeeded() throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(entries)", -1, &statement, nil) == SQLITE_OK else {
            throw ClipboardStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == "ocr_text" { return }
        }
        try exec("ALTER TABLE entries ADD COLUMN ocr_text TEXT")
    }

    @discardableResult
    private func insert(_ row: PendingRow) throws -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = """
        INSERT INTO entries
        (kind, text, ocr_text, preview, image_file, thumb_file, width, height, byte_count, content_hash, source_app, source_bundle, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        bindOptionalText(statement, 3, row.ocrText)
        sqlite3_bind_text(statement, 4, row.preview, -1, SQLITE_TRANSIENT)
        bindOptionalText(statement, 5, row.imageFile)
        bindOptionalText(statement, 6, row.thumbFile)
        bindOptionalInt(statement, 7, row.pixelWidth)
        bindOptionalInt(statement, 8, row.pixelHeight)
        sqlite3_bind_int64(statement, 9, Int64(row.byteCount))
        sqlite3_bind_text(statement, 10, row.contentHash, -1, SQLITE_TRANSIENT)
        bindOptionalText(statement, 11, row.sourceApp)
        bindOptionalText(statement, 12, row.sourceBundleID)
        sqlite3_bind_double(statement, 13, row.createdAt.timeIntervalSince1970)

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

// MARK: - CJK Detection

/// True when the string contains CJK characters (Han, Kana, Hangul) —
/// exactly the scripts FTS5's default unicode61 tokenizer cannot segment,
/// which is why CJK keywords take the LIKE search path instead.
extension String {
    fileprivate var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00 ... 0x9FFF).contains(v) // CJK Unified Ideographs
                || (0x3400 ... 0x4DBF).contains(v) // Extension A
                || (0xF900 ... 0xFAFF).contains(v) // Compatibility Ideographs
                || (0x3040 ... 0x30FF).contains(v) // Hiragana + Katakana
                || (0xAC00 ... 0xD7AF).contains(v) // Hangul syllables
        }
    }
}
