//
//  ScreenshotState.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/18.
//  Copyright © 2025 izual. All rights reserved.
//

import Carbon
import SwiftUI

/// Manages the state for screenshot capture UI
class ScreenshotState: ObservableObject {
    // MARK: Lifecycle

    init(screen: NSScreen) {
        self.screen = screen
        self.isTipVisible = !MyConfiguration.shared.isScreenshotTipLayerHidden
            && !Screenshot.shared.lastScreenshotRect.isEmpty

        updateHideDarkOverlay()
        setupMouseMovedMonitor()
    }

    deinit {
        cleanup()
    }

    // MARK: Internal

    /// The screen where the screenshot state is attached.
    /// Screen frame is `bottom-left` origin.
    var screen: NSScreen

    /// Full-screen frame captured once before the overlay window appears.
    /// Every consumer (mask background, ⌘C compose, mosaic base, plain
    /// capture) crops this instead of re-shooting the display.
    var frozenDisplayImage: NSImage?

    /// Controls whether the dark overlay is shown during screenshot selection for this specific screen state. Defaults to false.
    var enableDarkOverlay = false

    // MARK: - Published Properties

    /// Whether the mouse has moved since capture started
    @Published var isMouseMoved = false

    /// The currently selected rectangle for screenshot
    @Published var selectedRect = CGRect.zero

    /// Whether the preview is being shown
    @Published var isShowingPreview = false

    /// Whether the dark overlay should be hidden
    @Published private(set) var shouldHideDarkOverlay = true

    @Published var isTipVisible = false

    var tipFrame: CGRect = .zero

    /// Whether this overlay switched from selecting into annotation editing.
    @Published var isEditing = false

    /// Selection rect captured when editing began, top-left origin.
    private(set) var editingRect = CGRect.zero

    /// Annotation editor created together with the editing session.
    var annotationEditor: AnnotationEditorState?

    /// Reset all state variables
    func reset() {
        isMouseMoved = false
        selectedRect = .zero
        isShowingPreview = false
        shouldHideDarkOverlay = true
        isEditing = false

        cleanup()
    }

    /// Switches this screen's overlay from selecting into annotation editing:
    /// selection gestures stop, the frozen background stays fully visible.
    func beginEditing(inRect rect: CGRect) {
        cleanup()
        shouldHideDarkOverlay = true
        isShowingPreview = false
        isTipVisible = false
        editingRect = rect
        // The call chain starts from AppKit input handling, always main-thread.
        annotationEditor = MainActor.assumeIsolated {
            AnnotationEditorState(selectionRect: rect)
        }
        isEditing = true
    }

    /// Leaves annotation editing mode.
    func endEditing() {
        isEditing = false
        editingRect = .zero
        annotationEditor = nil
    }

    /// Releases the local event monitor owned by this screenshot state.
    func cleanup() {
        if let mouseMovedMonitor {
            NSEvent.removeMonitor(mouseMovedMonitor)
            self.mouseMovedMonitor = nil
        }
    }

    // MARK: - State Management

    /// Update the state to hide the dark overlay, based on the local setting and current interaction state.
    func updateHideDarkOverlay() {
        // If dark overlay is disabled for this state, always hide it.
        guard enableDarkOverlay else {
            shouldHideDarkOverlay = true
            return
        }

        // Otherwise, hide based on interaction state (previewing or mouse moved onto the screen).
        shouldHideDarkOverlay =
            isShowingPreview || isMouseMoved && screen.isSameScreen(NSScreen.currentMouseScreen())
    }

    /// Show preview rect, update state
    func showPreview(rect: CGRect) {
        isShowingPreview = true
        selectedRect = rect
        isTipVisible = false
        updateHideDarkOverlay()
    }

    // MARK: Private

    private var mouseMovedMonitor: Any?

    // MARK: - Mouse moved event monitoring

    /// Setup local mouse monitor to track mouse movement
    /// Since SwiftUI `onHover` is not reliable, we need to track mouse movement manually
    private func setupMouseMovedMonitor() {
        /*
         Unlike keyDown events which are typically sent only to the active application,
         mouseMoved events can be captured by a local monitor even if the application
         isn't active, especially when an overlay window is present under the cursor.
         Therefore, explicit NSApplication.shared.activate() is not strictly required
         for this specific monitor to function, unlike the keyDown monitor for ESC.
         */
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }

            isMouseMoved = true
            updateHideDarkOverlay()

            guard !MyConfiguration.shared.isScreenshotTipLayerHidden else {
                return event
            }

            let expandedValue = 20.0
            let tipLayerExpandedFrame = CGRect(
                origin: tipFrame.origin,
                size: .init(
                    width: tipFrame.width + expandedValue,
                    height: tipFrame.height + expandedValue
                )
            )
            // Check if mouse is outside the expanded tip frame
            isTipVisible = !tipLayerExpandedFrame.contains(NSEvent.mouseLocation)

            // Pass the event to the next screen monitor
            return event
        }
    }
}
