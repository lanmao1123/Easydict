//
//  PinImagePanel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

/// Borderless floating panel that pins an image on screen, Snipaste-style.
///
/// `.nonactivatingPanel` keeps the frontmost app running, yet the pin can
/// still become key on click — that "selected" state is what routes ⌘C to
/// the pin's own copy handler. Supports background dragging, wheel zooming
/// through `PinImageHostingView` and double-click close through
/// `PinImageView`.
final class PinImagePanel: NSPanel {
    // MARK: Lifecycle

    init(image: NSImage) {
        self.state = PinImageState(image: image)

        super.init(
            contentRect: NSRect(origin: .zero, size: image.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        level = .floating
        // Stay visible across Spaces and above fullscreen apps like Snipaste.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hostingView = PinImageHostingView(rootView: PinImageView(state: state))
        hostingView.onZoom = { [weak self] factor in
            self?.zoom(by: factor)
        }
        hostingView.onOpacity = { [weak self] delta in
            self?.state.adjustOpacity(by: delta)
        }
        contentView = hostingView
    }

    // MARK: Internal

    // MARK: Override

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    let state: PinImageState

    override func becomeKey() {
        super.becomeKey()
        state.isFocused = true
    }

    override func resignKey() {
        super.resignKey()
        state.isFocused = false
    }

    /// Resizes the frame while keeping the point under the cursor fixed, so
    /// both wheel zoom and trackpad pinch feel anchored where you point.
    func zoom(by factor: CGFloat) {
        let anchor = NSEvent.mouseLocation
        let oldFrame = frame
        // Fractional position of the anchor inside the current frame.
        let anchorFractionX = (anchor.x - oldFrame.minX) / oldFrame.width
        let anchorFractionY = (anchor.y - oldFrame.minY) / oldFrame.height

        state.zoom(by: factor)

        let newSize = state.displaySize
        let newOrigin = CGPoint(
            x: anchor.x - anchorFractionX * newSize.width,
            y: anchor.y - anchorFractionY * newSize.height
        )
        setFrame(CGRect(origin: newOrigin, size: newSize), display: true)
    }
}
