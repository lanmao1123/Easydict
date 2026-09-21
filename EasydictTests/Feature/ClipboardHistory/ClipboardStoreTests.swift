//
//  ClipboardStoreTests.swift
//  EasydictTests
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation
import SQLite3
import Testing

@testable import Easydict

// MARK: - ClipboardStoreTests

/// Unit tests for the SQLite clipboard store: round-trips, time/keyword/kind
/// queries, hash dedup, file lifecycle and capacity bookkeeping. Every test
/// uses its own temp directory so rows and files never leak between cases.
@Suite("Clipboard History Store", .tags(.clipboard, .unit))
struct ClipboardStoreTests {
    // MARK: Internal

    // MARK: Text round-trip

    @Test("Inserted text round-trips with derived preview and hash", .tags(.clipboard, .unit))
    func testInsertAndReadBackText() throws {
        let context = try makeStore()

        try context.store.insertText("hello clipboard", sourceApp: "Notes", sourceBundleID: "com.apple.Notes")

        let entries = try context.store.entries(since: nil)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.kind == .text)
        #expect(entry.text == "hello clipboard")
        #expect(entry.preview == "hello clipboard")
        #expect(entry.byteCount == "hello clipboard".utf8.count)
        #expect(entry.sourceApp == "Notes")
        #expect(entry.sourceBundleID == "com.apple.Notes")
        #expect(entry.contentHash == ClipboardStore.sha256(Data("hello clipboard".utf8)))
    }

    // MARK: Time window

    @Test("entries(since:) keeps only rows inside the window", .tags(.clipboard, .unit))
    func testRecentSinceFilter() throws {
        let context = try makeStore()
        let now = Date()
        let old = now.addingTimeInterval(-30 * 24 * 3600)

        try context.store.insertText("fresh", sourceApp: nil, sourceBundleID: nil, at: now)
        try context.store.insertText("ancient", sourceApp: nil, sourceBundleID: nil, at: old)

        let week = try context.store.entries(since: now.addingTimeInterval(-7 * 24 * 3600))
        #expect(week.map(\.text) == ["fresh"])

        let all = try context.store.entries(since: nil)
        #expect(all.count == 2)
        #expect(all.map(\.text) == ["fresh", "ancient"])
    }

    // MARK: Keyword search

    @Test("Keyword search matches text content only, never image rows", .tags(.clipboard, .unit))
    func testKeywordSearchOnlyMatchesText() throws {
        let context = try makeStore()

        try context.store.insertText("invoice number 42", sourceApp: nil, sourceBundleID: nil)
        try context.store.insertImage(
            imageFile: "img.png",
            thumbFile: nil,
            pixelWidth: 10,
            pixelHeight: 10,
            byteCount: 8,
            contentHash: "img-hash",
            sourceApp: nil,
            sourceBundleID: nil
        )

        let hits = try context.store.entries(since: nil, keyword: "invoice")
        #expect(hits.count == 1)
        #expect(hits.first?.text == "invoice number 42")

        let none = try context.store.entries(since: nil, keyword: "img-hash")
        #expect(none.isEmpty)
    }

    /// FTS5's unicode61 tokenizer never segments CJK runs — an indexed
    /// Chinese query used to match nothing. CJK keywords now take the LIKE
    /// path, for both text entries and image OCR text.
    @Test("CJK keyword search matches text and image OCR text", .tags(.clipboard, .unit))
    func testCJKKeywordSearch() throws {
        let context = try makeStore()

        try context.store.insertText("微信昵称：宁静致远", sourceApp: nil, sourceBundleID: nil)
        let imageID = try context.store.insertImage(
            imageFile: "member.png",
            thumbFile: nil,
            pixelWidth: 756,
            pixelHeight: 491,
            byteCount: 8,
            contentHash: "member-hash",
            sourceApp: nil,
            sourceBundleID: nil
        )
        try context.store.updateImageOCRText(
            "全部会员 微信昵称：宁静致远 编号：ANecOOVO", forEntryID: imageID
        )

        // Text scope: only the text entry matches.
        let textOnly = try context.store.entries(
            since: nil, keyword: "宁静", includesImageText: false
        )
        #expect(textOnly.count == 1)
        #expect(textOnly.first?.text == "微信昵称：宁静致远")

        // Text + image scope: both entries match via their CJK content.
        let withImages = try context.store.entries(
            since: nil, keyword: "宁静", includesImageText: true
        )
        #expect(withImages.count == 2)

        // An unrelated keyword still matches nothing.
        let none = try context.store.entries(
            since: nil, keyword: "不存在词", includesImageText: true
        )
        #expect(none.isEmpty)
    }

    // MARK: Kind filter

    @Test("Kind filter narrows to text or image rows", .tags(.clipboard, .unit))
    func testKindFilter() throws {
        let context = try makeStore()

        try context.store.insertText("note", sourceApp: nil, sourceBundleID: nil)
        try context.store.insertImage(
            imageFile: "pic.png",
            thumbFile: nil,
            pixelWidth: 4,
            pixelHeight: 4,
            byteCount: 6,
            contentHash: "pic-hash",
            sourceApp: nil,
            sourceBundleID: nil
        )

        #expect(try context.store.entries(since: nil, kind: .all).count == 2)
        #expect(try context.store.entries(since: nil, kind: .text).first?.kind == .text)
        #expect(try context.store.entries(since: nil, kind: .image).first?.kind == .image)
    }

    // MARK: Dedup

    @Test("Re-inserting the same text bumps it to top instead of duplicating", .tags(.clipboard, .unit))
    func testTextDedupBumpsToTop() throws {
        let context = try makeStore()
        let original = Date().addingTimeInterval(-3600)

        try context.store.insertText("repeat me", sourceApp: nil, sourceBundleID: nil, at: original)
        try context.store.insertText("other", sourceApp: nil, sourceBundleID: nil)
        let freshDate = Date()

        try context.store.insertText("repeat me", sourceApp: nil, sourceBundleID: nil, at: freshDate)

        let entries = try context.store.entries(since: nil)
        #expect(entries.count == 2)
        #expect(entries.first?.text == "repeat me")
        #expect(abs(entries[0].createdAt.timeIntervalSince(freshDate)) < 1)
    }

    @Test("Re-inserting the same image deletes the older row and its files", .tags(.clipboard, .unit))
    func testImageDedupDeletesOldFiles() throws {
        let context = try makeStore()

        let first = writePayload(context, name: "a.png")
        let hash = ClipboardStore.sha256(first)
        let fileName = context.store.makeImageFileName(hash: hash)
        try first.write(to: context.store.imagesDirectory.appendingPathComponent(fileName))
        try context.store.insertImage(
            imageFile: fileName,
            thumbFile: nil,
            pixelWidth: 2,
            pixelHeight: 2,
            byteCount: first.count,
            contentHash: hash,
            sourceApp: nil,
            sourceBundleID: nil
        )

        // Same payload copied again: the store hands out a fresh unique name
        // (same-second collision gets a -N suffix).
        let secondName = context.store.makeImageFileName(hash: hash)
        #expect(secondName != fileName)
        try first.write(to: context.store.imagesDirectory.appendingPathComponent(secondName))
        try context.store.insertImage(
            imageFile: secondName,
            thumbFile: nil,
            pixelWidth: 2,
            pixelHeight: 2,
            byteCount: first.count,
            contentHash: hash,
            sourceApp: nil,
            sourceBundleID: nil
        )

        let entries = try context.store.entries(since: nil, kind: .image)
        #expect(entries.count == 1)
        #expect(entries.first?.imageFile == secondName)
        #expect(!FileManager.default
            .fileExists(atPath: context.store.imagesDirectory.appendingPathComponent(fileName).path))
        #expect(FileManager.default
            .fileExists(atPath: context.store.imagesDirectory.appendingPathComponent(secondName).path))
    }

    // MARK: Delete

    @Test("Deleting an entry removes its row and disk files", .tags(.clipboard, .unit))
    func testDeleteRemovesRowAndFiles() throws {
        let context = try makeStore()

        let payload = writePayload(context, name: "gone.png")
        let fileName = "2026-08-27-120000-deadbeef.png"
        try payload.write(to: context.store.imagesDirectory.appendingPathComponent(fileName))
        let id = try context.store.insertImage(
            imageFile: fileName,
            thumbFile: "thumb-\(fileName)",
            pixelWidth: 8,
            pixelHeight: 8,
            byteCount: payload.count,
            contentHash: "gone-hash",
            sourceApp: nil,
            sourceBundleID: nil
        )

        try context.store.delete(id: id)

        #expect(try context.store.entries(since: nil).isEmpty)
        #expect(!FileManager.default
            .fileExists(atPath: context.store.imagesDirectory.appendingPathComponent(fileName).path))
    }

    // MARK: Capacity

    @Test("deleteImages(olderThan:) clears old images and keeps text", .tags(.clipboard, .unit))
    func testDeleteImagesOlderThanCutoff() throws {
        let context = try makeStore()
        let now = Date()

        try context.store.insertImage(
            imageFile: "old1.png", thumbFile: nil, pixelWidth: 1, pixelHeight: 1,
            byteCount: 100, contentHash: "old-1", sourceApp: nil, sourceBundleID: nil,
            at: now.addingTimeInterval(-10 * 24 * 3600)
        )
        try context.store.insertImage(
            imageFile: "old2.png", thumbFile: nil, pixelWidth: 1, pixelHeight: 1,
            byteCount: 200, contentHash: "old-2", sourceApp: nil, sourceBundleID: nil,
            at: now.addingTimeInterval(-9 * 24 * 3600)
        )
        try context.store.insertImage(
            imageFile: "new.png", thumbFile: nil, pixelWidth: 1, pixelHeight: 1,
            byteCount: 50, contentHash: "new", sourceApp: nil, sourceBundleID: nil,
            at: now
        )
        try context.store.insertText("keeper", sourceApp: nil, sourceBundleID: nil)

        let removed = try context.store.deleteImages(olderThan: now.addingTimeInterval(-7 * 24 * 3600))

        #expect(removed == 2)
        let remaining = try context.store.entries(since: nil)
        #expect(remaining.count == 2)
        #expect(remaining.map(\.preview).sorted() == ["Image (1×1)", "keeper"])
        #expect(try context.store.totalImageBytes() == 50)
    }

    @Test("Capacity stats sum image bytes and order oldest first", .tags(.clipboard, .unit))
    func testTotalImageBytesAndOldestOrder() throws {
        let context = try makeStore()

        try context.store.insertImage(
            imageFile: "i1.png", thumbFile: nil, pixelWidth: 1, pixelHeight: 1,
            byteCount: 300, contentHash: "h1", sourceApp: nil, sourceBundleID: nil,
            at: Date().addingTimeInterval(-100)
        )
        try context.store.insertImage(
            imageFile: "i2.png", thumbFile: nil, pixelWidth: 1, pixelHeight: 1,
            byteCount: 700, contentHash: "h2", sourceApp: nil, sourceBundleID: nil
        )
        try context.store.insertText("text", sourceApp: nil, sourceBundleID: nil)

        #expect(try context.store.totalImageBytes() == 1000)
        #expect(try context.store.oldestImages(limit: 10).map(\.imageFile) == ["i1.png", "i2.png"])
        #expect(try context.store.count() == 3)
    }

    // MARK: Failure recovery

    @Test("Whitespace-only searches preserve unfiltered image and text results", .tags(.clipboard, .unit))
    func testWhitespaceOnlySearch() throws {
        let context = try makeStore()
        try context.store.insertText("note", sourceApp: nil, sourceBundleID: nil)
        _ = try insertImagePayload(context, name: "search", hash: "search-hash")
        let expectedIDs = try context.store.entries(since: nil).map(\.id)

        for keyword in ["", "   ", "\n\t ", "　"] {
            #expect(try context.store.entries(since: nil, keyword: keyword).map(\.id) == expectedIDs)
            #expect(try context.store.entries(since: nil, keyword: keyword, kind: .image).count == 1)
        }
    }

    @Test("A failed duplicate text insert preserves the original row and search index", .tags(.clipboard, .unit))
    func testTextDedupRollsBackFailedInsert() throws {
        let context = try makeStore()
        let originalDate = Date(timeIntervalSince1970: 1000)
        try context.store.insertText("original note", sourceApp: "Notes", sourceBundleID: nil, at: originalDate)
        let original = try #require(context.store.entries(since: nil).first)
        try executeSQL(context, sql: """
        CREATE TRIGGER reject_insert BEFORE INSERT ON entries
        BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END;
        """)

        #expect(throws: ClipboardStoreError.self) {
            try context.store.insertText("original note", sourceApp: "Other", sourceBundleID: nil)
        }

        let restored = try #require(context.store.entries(since: nil).first)
        #expect(try context.store.count() == 1)
        #expect(restored.id == original.id)
        #expect(restored.createdAt == originalDate)
        #expect(restored.sourceApp == "Notes")
        #expect(try context.store.entries(since: nil, keyword: "original").map(\.id) == [original.id])
        try executeSQL(context, sql: "DROP TRIGGER reject_insert")
        try context.store.insertText("recovered", sourceApp: nil, sourceBundleID: nil)
        #expect(try context.store.count() == 2)
    }

    @Test("A failed duplicate image insert preserves the original row and both files", .tags(.clipboard, .unit))
    func testImageDedupRollsBackFailedInsert() throws {
        let context = try makeStore()
        let originalID = try insertImagePayload(context, name: "original", hash: "duplicate")
        try executeSQL(context, sql: """
        CREATE TRIGGER reject_insert BEFORE INSERT ON entries
        BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END;
        """)

        #expect(throws: ClipboardStoreError.self) {
            try insertImagePayload(context, name: "replacement", hash: "duplicate")
        }

        let restored = try #require(context.store.entries(since: nil).first)
        #expect(try context.store.count() == 1)
        #expect(restored.id == originalID)
        #expect(restored.imageFile == "original.png")
        #expect(restored.thumbFile == "original-thumb.png")
        try expectImagePayload(context, name: "original")
    }

    @Test("Duplicate images can reuse their image and thumbnail files", .tags(.clipboard, .unit))
    func testImageDedupPreservesReusedFiles() throws {
        let context = try makeStore()
        _ = try insertImagePayload(context, name: "shared", hash: "duplicate")
        let replacementID = try context.store.insertImage(
            imageFile: "shared.png", thumbFile: "shared-thumb.png",
            pixelWidth: 2, pixelHeight: 2, byteCount: 7,
            contentHash: "duplicate", sourceApp: "Updated", sourceBundleID: nil
        )

        let entries = try context.store.entries(since: nil)
        #expect(entries.map(\.id) == [replacementID])
        #expect(entries.first?.sourceApp == "Updated")
        try expectImagePayload(context, name: "shared")
    }

    @Test(
        "Failed deletions preserve all rows, images and thumbnails",
        .tags(.clipboard, .unit),
        arguments: ["entry", "oldImages", "allEntries"]
    )
    func testFailedDeletePreservesFiles(operation: String) throws {
        let context = try makeStore()
        let firstID = try insertImagePayload(context, name: "first", hash: "first")
        let secondID = try insertImagePayload(context, name: "second", hash: "second")
        try context.store.insertText("keep text", sourceApp: nil, sourceBundleID: nil)
        let originalIDs = try context.store.entries(since: nil).map(\.id)
        // Reject the second image so a bulk deletion must also restore earlier rows.
        try executeSQL(context, sql: """
        CREATE TRIGGER reject_delete BEFORE DELETE ON entries WHEN OLD.id = \(secondID)
        BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END;
        """)

        #expect(throws: ClipboardStoreError.self) {
            switch operation {
            case "entry":
                try context.store.delete(id: secondID)
            case "oldImages":
                _ = try context.store.deleteImages(olderThan: Date.distantFuture)
            default:
                _ = try context.store.deleteAllEntries()
            }
        }

        #expect(try context.store.entries(since: nil).map(\.id) == originalIDs)
        try expectImagePayload(context, name: "first")
        try expectImagePayload(context, name: "second")
        try executeSQL(context, sql: "DROP TRIGGER reject_delete")
        try context.store.delete(id: firstID)
        #expect(try context.store.count() == 2)
        #expect(!FileManager.default.fileExists(
            atPath: context.store.imagesDirectory.appendingPathComponent("first.png").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: context.store.imagesDirectory.appendingPathComponent("first-thumb.png").path
        ))
    }

    // MARK: Preview building

    @Test("Preview takes the first line and caps its length", .tags(.clipboard, .unit))
    func testPreviewTakesFirstLineAndCapsLength() {
        #expect("first\nsecond".clipboardPreview() == "first")
        let long = String(repeating: "x", count: 300)
        let preview = long.clipboardPreview()
        #expect(preview.count == 121)
        #expect(preview.hasSuffix("…"))
    }

    // MARK: Private

    // MARK: Helpers

    private struct StoreContext {
        let store: ClipboardStore
    }

    private func makeStore() throws -> StoreContext {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezd-clip-tests-\(UUID().uuidString)", isDirectory: true)
        return StoreContext(store: try ClipboardStore(directory: dir))
    }

    /// Uses a separate connection to inject SQLite failures without production hooks.
    private func executeSQL(_ context: StoreContext, sql: String) throws {
        var database: OpaquePointer?
        let path = context.store.directory.appendingPathComponent("history.db").path
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(database) }
        try #require(status == SQLITE_OK)
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        let message = String(cString: sqlite3_errmsg(database))
        try #require(result == SQLITE_OK, "SQLite fixture failed: \(message)")
    }

    private func insertImagePayload(_ context: StoreContext, name: String, hash: String) throws -> Int64 {
        for filename in ["\(name).png", "\(name)-thumb.png"] {
            try Data(filename.utf8).write(to: context.store.imagesDirectory.appendingPathComponent(filename))
        }
        return try context.store.insertImage(
            imageFile: "\(name).png", thumbFile: "\(name)-thumb.png",
            pixelWidth: 2, pixelHeight: 2, byteCount: 7,
            contentHash: hash, sourceApp: nil, sourceBundleID: nil
        )
    }

    private func expectImagePayload(_ context: StoreContext, name: String) throws {
        for filename in ["\(name).png", "\(name)-thumb.png"] {
            let contents = try Data(contentsOf: context.store.imagesDirectory.appendingPathComponent(filename))
            #expect(contents == Data(filename.utf8))
        }
    }

    private func writePayload(_ context: StoreContext, name: String) -> Data {
        let url = context.store.imagesDirectory.appendingPathComponent(name)
        let data = Data("png-\(name)".utf8)
        try? data.write(to: url)
        return data
    }
}
