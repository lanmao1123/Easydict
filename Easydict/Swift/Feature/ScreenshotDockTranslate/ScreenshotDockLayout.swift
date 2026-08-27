//
//  ScreenshotDockLayout.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

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

    /// Widest overlay width so a full-width selection stays readable.
    static let maxOverlayWidth: CGFloat = 900

    /// Overlay width before geometry is known.
    static let defaultOverlayWidth: CGFloat = 360

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
}
