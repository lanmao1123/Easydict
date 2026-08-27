//
//  Screenshot+EventMonitor.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/20.
//  Copyright © 2025 izual. All rights reserved.
//

import Carbon
import Foundation

extension Screenshot {
    // MARK: - Event Monitor

    /// Setup key event monitors for ESC key and D key
    func setupEventMonitor() {
        // Monitor both key down and right mouse down events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .keyDown:
                return handleKeyDown(event)

            case .rightMouseDown:
                // Handle right mouse click
                NSLog("Right mouse click detected, canceling screenshot")
                finishCapture(nil)

            default:
                break
            }

            return nil // Consume the event, avoid beep sound
        }
    }

    // MARK: Private

    /// Routes one key event: editing shortcuts first, then capture keys.
    ///
    /// While annotating, unhandled keys pass through so the SwiftUI text
    /// field and toolbar buttons keep receiving input; during plain capture
    /// everything is consumed as before to avoid the beep.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if keyCode == kVK_Escape {
            // While typing, ESC only discards the text draft, restoring the
            // committed item when re-editing.
            if let editor = activeAnnotationEditor {
                let discardedDraft = MainActor.assumeIsolated { () -> Bool in
                    guard editor.textDraftPoint != nil else { return false }
                    editor.discardText()
                    return true
                }
                if discardedDraft { return nil }
            }
            NSLog("ESC key detected locally, canceling screenshot")
            finishCapture(nil)
            return nil
        }

        if keyCode == kVK_ANSI_D, !editModeEnabled {
            NSLog("D key detected locally, capturing last screenshot rect")
            captureLastScreenshotRect()
            return nil
        }

        if let editor = activeAnnotationEditor {
            // Bare F3 while annotating pins the result directly, Snipaste-style.
            // The function modifier is ignored since fn-mode keyboards report it.
            if keyCode == kVK_F3,
               flags.intersection([.command, .control, .option, .shift]).isEmpty {
                MainActor.assumeIsolated {
                    editor.pinAndFinish()
                }
                return nil
            }

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard editor.textDraftPoint == nil else { return false }
                // ⌘Z/⇧⌘Z undo-redo, ⌘C copy-and-close, ⌘S save-path,
                // Enter confirms like the toolbar checkmark.
                if flags == .command, keyCode == kVK_ANSI_Z {
                    editor.model.undo()
                    return true
                }
                if flags == [.command, .shift], keyCode == kVK_ANSI_Z {
                    editor.model.redo()
                    return true
                }
                if flags == .command, keyCode == kVK_ANSI_C {
                    editor.finishByCopying()
                    return true
                }
                if flags == .command, keyCode == kVK_ANSI_S {
                    editor.finishBySavingPath()
                    return true
                }
                if flags.isEmpty, keyCode == kVK_Return {
                    editor.finishByCopying()
                    return true
                }
                return false
            }
            if handled { return nil }
            // Pass everything else to the editing UI (text input needs it).
            return event
        }

        return nil // Consume, avoid beep sound
    }

    func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - Screenshot Rect Preview

    /// Capture the last screenshot rect
    func captureLastScreenshotRect() {
        var lastRect = lastScreenshotRect

        if lastRect.isEmpty {
            NSLog("No previous screenshot rect available")
            return
        }

        // Find appropriate screen for capturing
        guard let targetScreen = lastScreen ?? NSScreen.currentMouseScreen() ?? NSScreen.main else {
            NSLog("No valid screen found for capture")
            return
        }

        // Last screen may have gone offline, adjust rect to current screen
        if lastScreen == nil {
            lastRect = targetScreen.adjustedScreenshotRect(lastRect)
        }

        guard let state = overlayViewStates[targetScreen] else {
            NSLog("No state found for target screen")
            return
        }

        // Cancel any previously scheduled preview screenshot task
        cancelPreviewScreenshotTimer()

        // Show the preview rectangle visually
        state.showPreview(rect: lastRect)

        // Create a work item to perform the actual screenshot after a delay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Ensure we are still in screenshot mode
            guard isTakingScreenshot else {
                NSLog("Preview screenshot cancelled because capture finished.")
                return
            }

            NSLog("Executing delayed screenshot for preview rect: \(lastRect)")

            performScreenshot(screen: targetScreen, rect: lastRect)
        }

        // Store the work item so it can be cancelled
        previewScreenshotWorkItem = workItem

        // Schedule the work item to run after 1 second
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        NSLog("Scheduled screenshot capture in 1s for preview.")
    }
}

extension Screenshot {
    /// Show an alert to guide the user to enable screen capture permission
    func showScreenCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("need_screen_capture_permission", comment: "")
        alert.informativeText = NSLocalizedString(
            "request_screen_capture_access_description", comment: ""
        )
        alert.alertStyle = .warning

        alert.addButton(withTitle: NSLocalizedString("open_system_settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(
                string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
