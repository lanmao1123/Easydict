//
//  ScreenshotDockPanel.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

// MARK: - ScreenshotDockPanel

/// Non-activating floating panel that docks beside the screenshot selection.
///
/// The panel never becomes key or main, so showing it does not steal focus from
/// the app the user was working with. It supports background dragging and its
/// SwiftUI content is driven by the shared `ScreenshotDockState`.
final class ScreenshotDockPanel: NSPanel {
    // MARK: Lifecycle

    /// Creates the panel and binds it to the given observable state.
    init(state: ScreenshotDockState) {
        self.state = state
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Float above normal windows like query windows, below overlay levels.
        level = .floating
        collectionBehavior = [.transient, .ignoresCycle]

        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: ScreenshotDockView(state: state))
    }

    // MARK: Internal

    // MARK: Override

    // Key-capable so a click "selects" the panel: ESC closes it and ⌘C copies
    // the translation, mirroring image-pin semantics.
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    let state: ScreenshotDockState

    override func becomeKey() {
        super.becomeKey()
        state.panelFocused = true
    }

    override func resignKey() {
        super.resignKey()
        state.panelFocused = false
    }
}

// MARK: - ScreenshotDockHighlightPanel

/// Click-through transparent window covering the captured selection; draws a
/// rounded highlight over the paragraph currently hovered in the translate
/// panel so the user can see which original pixels a translated card maps to.
final class ScreenshotDockHighlightPanel: NSPanel {
    /// Creates the highlight window sized exactly over the selection rect.
    ///
    /// - Parameters:
    ///   - frame: Global (bottom-left) rect of the captured selection.
    ///   - state: Shared observable state; `highlightedRect` is stored in
    ///     selection-local coordinates.
    init(frame: CGRect, state: ScreenshotDockState) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Float above the translate panel so the highlight stays visible even
        // when the panel overlaps the selection edge.
        level = .floating + 1
        collectionBehavior = [.transient, .ignoresCycle]

        // The highlight never intercepts input: clicks pass through to the
        // original content underneath (an outside click still dismisses).
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        contentViewController = NSHostingController(
            rootView: ScreenshotDockHighlightView(state: state)
        )
    }
}

// MARK: - ScreenshotDockHighlightView

/// Draws the hovered paragraph highlight inside the selection-covering window.
private struct ScreenshotDockHighlightView: View {
    @ObservedObject var state: ScreenshotDockState

    var body: some View {
        ZStack {
            if let rect = state.highlightedRect {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        // The window covers exactly the selection; highlightedRect is already
        // stored in selection-local coordinates by the manager.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
