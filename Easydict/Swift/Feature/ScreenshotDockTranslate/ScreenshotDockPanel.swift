//
//  ScreenshotDockPanel.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

/// Non-activating floating panel that docks beside the screenshot selection.
///
/// The panel never becomes key or main, so showing it does not steal focus from
/// the app the user was working with. It supports background dragging and its
/// SwiftUI content is driven by the shared `ScreenshotDockState`.
final class ScreenshotDockPanel: NSPanel {
    // MARK: Lifecycle

    /// Creates the panel and binds it to the given observable state.
    init(state: ScreenshotDockState) {
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

        contentViewController = NSHostingController(rootView: ScreenshotDockView(state: state))
    }

    // MARK: Internal

    // MARK: Override

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}
