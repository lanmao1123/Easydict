//
//  AnnotationComposer.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// Rasterizes annotation items onto the clean screenshot for export or copy.
///
/// Compositing runs in two passes because the two halves disagree about
/// coordinate orientation: annotation math is top-left (flipped) like the
/// on-screen canvas, while base image drawing is only guaranteed upright in a
/// standard unflipped context. Mixing them in one flipped focus produced a
/// 180°-flipped export, so each pass gets the context it can trust.
enum AnnotationComposer {
    /// - Parameters:
    ///   - base: Clean screenshot covering the editing rect; its size is in
    ///     pixels because screenshots are captured without DPI metadata.
    ///   - selectionSize: The editing rect's point size, deriving the scale.
    ///   - items: Annotations in z-order, last on top.
    /// - Returns: A new image with annotations baked in, or `base` unchanged
    ///   when the inputs are degenerate.
    static func compose(base: NSImage, selectionSize: CGSize, items: [AnnotationItem]) -> NSImage {
        let imageSize = base.size
        guard imageSize.width > 0, imageSize.height > 0,
              selectionSize.width > 0, selectionSize.height > 0 else { return base }

        let scale = imageSize.width / selectionSize.width

        // Pass 1: annotations alone on a transparent flipped canvas, exactly
        // mirroring the SwiftUI display coordinates.
        let overlay = NSImage(size: imageSize)
        overlay.lockFocusFlipped(true)
        NSColor.clear.set()
        NSBezierPath(rect: NSRect(origin: .zero, size: imageSize)).fill()
        for item in items {
            item.render(scale: scale)
        }
        overlay.unlockFocus()

        // Pass 2: unflipped context, where NSImage drawing is unambiguously
        // upright; stack base and annotation overlay.
        let composed = NSImage(size: imageSize)
        composed.lockFocus()
        base.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        overlay.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        composed.unlockFocus()
        return composed
    }
}
