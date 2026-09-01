//
//  ScreenshotDockLayout.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - DockSegment

/// One aligned source paragraph of the dock translate overlay: recognized
/// text plus its on-screen position, paired with its translation once ready.
struct DockSegment: Identifiable, Equatable {
    /// 1-based, matches the numbering used in the single-shot translation prompt.
    let id: Int
    let source: String
    /// Highlight rect in the highlight window's local space (selection-sized,
    /// top-left origin, as SwiftUI expects), linking a translated card back to
    /// the original pixels. Nil when geometry is unavailable.
    let highlightRect: CGRect?
    var translation: String?
    /// Short non-Chinese source (<10 words): the card shows a pronunciation
    /// toggle; long sentences never need one. Set after language detection.
    var pronunciationEligible: Bool = false
    /// Chinese-character phonetic rendering of the English source ("克劳德"),
    /// lazily fetched from the AI fallback chain on first reveal.
    var pronunciation: String?
    var pronunciationLoading: Bool = false
    var showPronunciation: Bool = false
}

// MARK: - ScreenshotDockLayout

/// Pure layout math for the screenshot dock translate feature.
///
/// Screenshot selections are stored in screen-local coordinates with a top-left
/// origin, while AppKit windows use global bottom-left coordinates. These helpers
/// keep the conversion and per-block overlay placement logic in one testable
/// place, free of AppKit dependencies.
enum ScreenshotDockLayout {
    // MARK: Constants

    /// Extra inset kept inside the screen visible frame when clamping.
    static let screenMargin: CGFloat = 8

    /// Vertical gap between a source block edge and its translation overlay.
    static let overlayGap: CGFloat = 8

    /// Smallest readable overlay width when the selection is very narrow.
    static let minOverlayWidth: CGFloat = 240

    /// Widest overlay width — beyond this the 15-16pt text reads small.
    static let maxOverlayWidth: CGFloat = 900

    /// Overlay width before geometry is known.
    static let defaultOverlayWidth: CGFloat = 420

    // MARK: Conversion

    /// Converts a screen-local top-left-origin rect into an AppKit global
    /// bottom-left-origin rect.
    ///
    /// The overlay window covers exactly `screen.frame`, so the local rect maps
    /// onto the screen frame with a Y-axis flip.
    /// - Parameters:
    ///   - localRect: Selection rect relative to the overlay window of `screen`.
    ///   - screenFrame: Global frame of the screen the rect belongs to.
    /// - Returns: The equivalent global rect, or `.zero` for an empty input.
    static func globalRect(fromLocalRect localRect: CGRect, screenFrame: CGRect) -> CGRect {
        guard !localRect.isEmpty else { return .zero }
        return CGRect(
            x: screenFrame.minX + localRect.minX,
            y: screenFrame.maxY - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )
    }

    // MARK: Placement

    /// Overlay width mirroring the selection width, clamped to readable bounds.
    static func overlayWidth(forSelectionWidth selectionWidth: CGFloat) -> CGFloat {
        min(max(selectionWidth, minOverlayWidth), maxOverlayWidth)
    }

    /// Computes the overlay origin docked against the selection, Youdao
    /// "对照"-style: the overlay sits directly below the selection when there is
    /// room, otherwise directly above it; when neither side fully fits, the side
    /// with more room wins and the origin is clamped into the visible frame.
    /// - Parameters:
    ///   - contentSize: Desired size of the overlay.
    ///   - selectionGlobalRect: Global bottom-left-origin selection rect.
    ///   - visibleFrame: Visible frame (excluding menu bar and dock) to clamp into.
    /// - Returns: The clamped window origin (bottom-left corner of the overlay in
    ///   AppKit global coordinates), ready for `setFrameOrigin`.
    static func overlayOrigin(
        contentSize: CGSize,
        selectionGlobalRect: CGRect,
        visibleFrame: NSRect
    )
        -> CGPoint {
        let innerBounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)

        // Align the overlay's left edge with the selection, clamped inside.
        var x = selectionGlobalRect.minX
        x = min(
            max(x, innerBounds.minX),
            max(innerBounds.minX, innerBounds.maxX - contentSize.width)
        )

        // Prefer directly below the selection; flip above when the content
        // cannot fit below and there is more room above.
        let spaceBelow = selectionGlobalRect.minY - overlayGap - innerBounds.minY
        let spaceAbove = innerBounds.maxY - overlayGap - selectionGlobalRect.maxY
        var y = selectionGlobalRect.minY - overlayGap - contentSize.height
        if contentSize.height > spaceBelow, spaceAbove > spaceBelow {
            y = selectionGlobalRect.maxY + overlayGap
        }

        // Keep the whole overlay inside the visible frame when neither side fits.
        let lowest = innerBounds.minY
        let highest = max(lowest, innerBounds.maxY - contentSize.height)
        y = min(max(y, lowest), highest)

        return CGPoint(x: x, y: y)
    }

    // MARK: Paragraph Grouping

    /// Clusters Vision text lines into visual paragraphs, in reading order.
    ///
    /// - Parameter lines: Recognized lines with normalized Vision bounding
    ///   boxes (0-1 coordinates, bottom-left origin, y grows upward).
    /// - Returns: Paragraphs ordered top-to-bottom on screen; each paragraph
    ///   keeps its lines' text (joined with newlines) and its bounding rect
    ///   in the same normalized Vision coordinates.
    static func paragraphs(fromLines lines: [DockOCRLine]) -> [(text: String, rect: CGRect)] {
        guard !lines.isEmpty else { return [] }

        // Reading order: top first (Vision y grows upward), left first in a row.
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > min(lhs.rect.height, rhs.rect.height) * 0.5 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }

        // Cluster lines that sit on the same visual row.
        var rows: [[DockOCRLine]] = []
        var currentRow: [DockOCRLine] = [sorted[0]]
        for line in sorted.dropFirst() {
            let rowMidY = currentRow.reduce(0) { $0 + $1.rect.midY } / CGFloat(currentRow.count)
            let referenceHeight = max(currentRow.last!.rect.height, line.rect.height)
            if abs(line.rect.midY - rowMidY) < referenceHeight * 0.6 {
                currentRow.append(line)
            } else {
                rows.append(currentRow)
                currentRow = [line]
            }
        }
        rows.append(currentRow)

        struct RowInfo {
            let text: String
            let rect: CGRect
            let height: CGFloat
        }
        let rowInfos: [RowInfo] = rows.map { row in
            let items = row.sorted { $0.rect.minX < $1.rect.minX }
            let text = items.map(\.text).joined(separator: " ")
            var rect = items[0].rect
            for item in items.dropFirst() {
                rect = rect.union(item.rect)
            }
            return RowInfo(text: text, rect: rect, height: rect.height)
        }

        // Merge adjacent rows into one paragraph while the vertical gap stays
        // tighter than a line height; a bigger gap starts a new paragraph.
        var paragraphs: [(text: String, rect: CGRect)] = []
        var group: [RowInfo] = [rowInfos[0]]
        func flushGroup() {
            let text = group.map(\.text).joined(separator: "\n")
            var rect = group[0].rect
            for row in group.dropFirst() {
                rect = rect.union(row.rect)
            }
            paragraphs.append((text, rect))
        }
        for row in rowInfos.dropFirst() {
            let previous = group.last!
            let gap = previous.rect.minY - row.rect.maxY
            let referenceHeight = max(previous.height, row.height)
            if gap > referenceHeight * 0.8 {
                flushGroup()
                group = [row]
            } else {
                group.append(row)
            }
        }
        flushGroup()
        return paragraphs
    }

    /// Converts a normalized Vision paragraph rect into an AppKit global
    /// (bottom-left) rect within the captured selection.
    static func segmentScreenRect(_ visionRect: CGRect, in selection: CGRect) -> CGRect {
        CGRect(
            x: selection.minX + visionRect.minX * selection.width,
            y: selection.minY + (1 - visionRect.maxY) * selection.height,
            width: visionRect.width * selection.width,
            height: visionRect.height * selection.height
        )
    }
}
