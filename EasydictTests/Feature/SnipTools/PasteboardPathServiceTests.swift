//
//  PasteboardPathServiceTests.swift
//  EasydictTests
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation
import Testing

@testable import Easydict

// MARK: - PasteboardPathServiceTests

/// Unit tests for the deterministic save-path derivation in
/// `PasteboardPathService`.
///
/// Each case works inside its own unique subdirectory of the system temporary
/// directory, so parallel tests never collide, and removes that subtree when
/// it finishes.
@Suite("Snip Tools Pasteboard Path Service", .tags(.screenshot, .unit))
struct PasteboardPathServiceTests {
    // MARK: Internal

    // MARK: dateFolderURL(at:in:)

    @Test("Date folder nests a yyyy-MM-dd folder under EasydictCaptures", .tags(.screenshot, .unit))
    func testDateFolderURLNestsDayFolderUnderCaptureRoot() throws {
        let base = try Self.makeTemporaryBaseDirectory()
        defer { Self.removeTemporaryBaseDirectory(base) }

        let date = try Self.makeSampleDate()

        let url = PasteboardPathService.dateFolderURL(at: date, in: base)
        let captureRoot = url.deletingLastPathComponent()

        #expect(url.lastPathComponent == "2026-08-27")
        #expect(captureRoot.lastPathComponent == "EasydictCaptures")
        #expect(captureRoot.deletingLastPathComponent().standardizedFileURL == base.standardizedFileURL)
    }

    // MARK: saveFileURL(at:sequence:in:)

    @Test("First sequence names the file with the bare timestamp", .tags(.screenshot, .unit))
    func testSaveFileURLFirstSequenceHasNoSuffix() throws {
        let base = try Self.makeTemporaryBaseDirectory()
        defer { Self.removeTemporaryBaseDirectory(base) }

        let date = try Self.makeSampleDate()

        let url = PasteboardPathService.saveFileURL(at: date, sequence: 1, in: base)

        #expect(url.lastPathComponent == "14-30-15-123.png")
        #expect(
            url.deletingLastPathComponent().standardizedFileURL
                == PasteboardPathService.dateFolderURL(at: date, in: base).standardizedFileURL
        )
    }

    @Test("Higher sequences append an increasing numeric suffix", .tags(.screenshot, .unit))
    func testSaveFileURLHigherSequencesAppendNumericSuffix() throws {
        let base = try Self.makeTemporaryBaseDirectory()
        defer { Self.removeTemporaryBaseDirectory(base) }

        let date = try Self.makeSampleDate()

        let twoDigits = PasteboardPathService.saveFileURL(at: date, sequence: 2, in: base)
        let doubleDigit = PasteboardPathService.saveFileURL(at: date, sequence: 10, in: base)

        #expect(twoDigits.lastPathComponent == "14-30-15-123-2.png")
        #expect(doubleDigit.lastPathComponent == "14-30-15-123-10.png")
    }

    // MARK: deriveSaveURL(at:in:createDirectories:)

    @Test("deriveSaveURL creates the nested folders only when asked", .tags(.screenshot, .unit))
    func testDeriveSaveURLCreatesNestedFoldersOnlyWhenRequested() throws {
        let base = try Self.makeTemporaryBaseDirectory()
        defer { Self.removeTemporaryBaseDirectory(base) }

        let date = try Self.makeSampleDate()
        let folderPath = PasteboardPathService.dateFolderURL(at: date, in: base).path

        // Without the flag nothing is written to disk yet.
        _ = PasteboardPathService.deriveSaveURL(at: date, in: base)
        #expect(!FileManager.default.fileExists(atPath: folderPath))

        // With the flag both EasydictCaptures and the day folder materialize.
        _ = PasteboardPathService.deriveSaveURL(at: date, in: base, createDirectories: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDirectory)
        #expect(exists)
        #expect(isDirectory.boolValue)
    }

    @Test("deriveSaveURL keeps probing suffixes until an unused name shows up", .tags(.screenshot, .unit))
    func testDeriveSaveURLAppendsSuffixAroundExistingFiles() throws {
        let base = try Self.makeTemporaryBaseDirectory()
        defer { Self.removeTemporaryBaseDirectory(base) }

        let date = try Self.makeSampleDate()
        let fileManager = FileManager.default

        // Seed the collisions: pre-create the plain name plus the -2 variant.
        let firstCandidate = PasteboardPathService.saveFileURL(at: date, sequence: 1, in: base)
        try fileManager.createDirectory(
            at: firstCandidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: firstCandidate)
        try Data().write(to: PasteboardPathService.saveFileURL(at: date, sequence: 2, in: base))

        let derived = PasteboardPathService.deriveSaveURL(at: date, in: base)

        #expect(derived.lastPathComponent == "14-30-15-123-3.png")
        // The returned slot must not collide with anything on disk either.
        #expect(!fileManager.fileExists(atPath: derived.path))
    }

    // MARK: Private

    // MARK: Helpers

    /// Local-time components shared by every case: 2026-08-27 14:30:15.123,
    /// chosen far away from any DST transition edge.
    private static func makeSampleDate() throws -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 27
        components.hour = 14
        components.minute = 30
        components.second = 15
        components.nanosecond = 123_000_000
        return try #require(Calendar.current.date(from: components))
    }

    private static func makeTemporaryBaseDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteboardPathServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeTemporaryBaseDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
