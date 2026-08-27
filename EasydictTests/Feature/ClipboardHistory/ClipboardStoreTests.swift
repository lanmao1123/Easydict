//
//  ClipboardStoreTests.swift
//  EasydictTests
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation
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

    private func writePayload(_ context: StoreContext, name: String) -> Data {
        let url = context.store.imagesDirectory.appendingPathComponent(name)
        let data = Data("png-\(name)".utf8)
        try? data.write(to: url)
        return data
    }
}
