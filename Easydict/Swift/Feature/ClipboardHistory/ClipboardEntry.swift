//
//  ClipboardEntry.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - ClipboardEntry

/// One captured clipboard item: either plain text or an image backed by a
/// file on disk. All fields map 1:1 to the `entries` table.
struct ClipboardEntry: Identifiable, Equatable {
    // MARK: Lifecycle

    init(
        id: Int64,
        kind: ClipboardEntryKind,
        text: String?,
        preview: String,
        imageFile: String?,
        thumbFile: String?,
        pixelWidth: Int?,
        pixelHeight: Int?,
        byteCount: Int,
        contentHash: String,
        sourceApp: String?,
        sourceBundleID: String?,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.preview = preview
        self.imageFile = imageFile
        self.thumbFile = thumbFile
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
    }

    // MARK: Internal

    let id: Int64
    let kind: ClipboardEntryKind

    /// Full text for `.text` entries; nil for images.
    let text: String?

    /// Single-line list preview (first line, length-capped at capture time).
    let preview: String

    /// Image file name inside the store's images folder; nil for text.
    let imageFile: String?
    let thumbFile: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let byteCount: Int

    /// sha256 of the payload; the dedup key that makes repeats bump to top.
    let contentHash: String

    let sourceApp: String?
    let sourceBundleID: String?
    let createdAt: Date
}

// MARK: - ClipboardEntryKind

enum ClipboardEntryKind: String {
    case text
    case image
}

// MARK: - ClipboardKindFilter

enum ClipboardKindFilter: String, CaseIterable {
    case all
    case text
    case image
}

// MARK: - ClipboardEntry + Preview Building

extension String {
    /// Builds the single-line list preview: first non-empty line, capped so a
    /// huge paste never balloons the row.
    func clipboardPreview(maxLength: Int = 120) -> String {
        let firstLine = split(whereSeparator: \.isNewline).first.map(String.init) ?? self
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}
