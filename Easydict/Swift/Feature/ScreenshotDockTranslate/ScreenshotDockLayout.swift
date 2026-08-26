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
/// keep the conversion and dock placement logic in one testable place, free of
/// AppKit dependencies.
enum ScreenshotDockLayout {
    // MARK: Constants

    /// Fixed panel width in points.
    static let panelWidth: CGFloat = 360

    /// Horizontal gap between the panel edge and the selection edge.
    static let panelGap: CGFloat = 12

    /// Extra inset kept inside the screen visible frame when clamping.
    static let screenMargin: CGFloat = 8

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

    /// Computes the docked panel origin point beside the selection rect.
    ///
    /// Prefers the right side of the selection and falls back to the left side
    /// when there is not enough room. The panel is then top-aligned with the
    /// selection and clamped into the visible frame so it always stays fully
    /// reachable on screen.
    /// - Parameters:
    ///   - panelSize: Desired size of the panel.
    ///   - selectionGlobalRect: Global bottom-left-origin selection rect.
    ///   - visibleFrame: Visible frame (excluding menu bar and dock) to clamp into.
    /// - Returns: The clamped window origin (bottom-left corner of the panel in
    ///   AppKit global coordinates), ready for `setFrameOrigin`.
    static func dockedPanelOrigin(
        panelSize: CGSize,
        selectionGlobalRect: CGRect,
        visibleFrame: NSRect
    )
        -> CGPoint {
        let innerBounds = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)

        // Prefer the right side of the selection, fall back to the left side.
        var x = selectionGlobalRect.maxX + panelGap
        if x + panelSize.width > innerBounds.maxX {
            x = selectionGlobalRect.minX - panelGap - panelSize.width
        }

        // Top-align with the selection, then keep the whole panel inside by
        // capping the origin against both vertical edges.
        var y = selectionGlobalRect.maxY - panelSize.height
        y = min(y, max(innerBounds.minY, innerBounds.maxY - panelSize.height))
        y = max(y, innerBounds.minY)

        // When neither side fits, keep the panel visible instead of overlapping deeper.
        x = max(x, innerBounds.minX)

        return CGPoint(x: x, y: y)
    }
}
