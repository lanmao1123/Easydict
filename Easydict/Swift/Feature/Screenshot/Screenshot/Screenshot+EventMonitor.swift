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
        logInfo("local key/right-click monitor installing")
        // Monitor both key down and right mouse down events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .keyDown:
                return handleKeyDown(event)

            case .rightMouseDown:
                // Handle right mouse click
                logInfo("right click detected, canceling screenshot")
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
        // Flag names keep the log readable without leaking typed content.
        let flagNames = [
            flags.contains(.command) ? "cmd" : nil,
            flags.contains(.shift) ? "shift" : nil,
            flags.contains(.option) ? "opt" : nil,
            flags.contains(.control) ? "ctrl" : nil,
        ].compactMap { $0 }.joined(separator: "+")
        logInfo(
            "key down, keyCode=\(keyCode), flags=\(flagNames.isEmpty ? "none" : flagNames), editMode=\(editModeEnabled)"
        )

        if keyCode == kVK_Escape {
            // While typing, ESC only discards the text draft, restoring the
            // committed item when re-editing.
            if let editor = activeAnnotationEditor {
                let discardedDraft = MainActor.assumeIsolated { () -> Bool in
                    guard editor.textDraftPoint != nil else { return false }
                    logInfo("ESC discards text draft only")
                    editor.discardText()
                    return true
                }
                if discardedDraft { return nil }
            }
            logInfo("ESC cancels screenshot session")
            finishCapture(nil)
            return nil
        }

        if keyCode == kVK_ANSI_D, !editModeEnabled {
            logInfo("D key re-captures last screenshot rect")
            captureLastScreenshotRect()
            return nil
        }

        if let editor = activeAnnotationEditor {
            // Bare F3 while annotating pins the result directly, Snipaste-style.
            // The function modifier is ignored since fn-mode keyboards report it.
            if keyCode == kVK_F3,
               flags.intersection([.command, .control, .option, .shift]).isEmpty {
                logInfo("F3 pins editing result directly")
                MainActor.assumeIsolated {
                    editor.pinAndFinish()
                }
                return nil
            }

            let handled = MainActor.assumeIsolated { () -> Bool in
                guard editor.textDraftPoint == nil else {
                    logInfo("text draft active, editing shortcut skipped, keyCode=\(keyCode)")
                    return false
                }
                // ⌘Z/⇧⌘Z undo-redo, ⌘C copy-and-close, ⌘S save-path,
                // Enter confirms like the toolbar checkmark.
                if flags == .command, keyCode == kVK_ANSI_Z {
                    logInfo("⌘Z undo while annotating")
                    editor.model.undo()
                    return true
                }
                if flags == [.command, .shift], keyCode == kVK_ANSI_Z {
                    logInfo("⇧⌘Z redo while annotating")
                    editor.model.redo()
                    return true
                }
                if flags == .command, keyCode == kVK_ANSI_C {
                    logInfo("⌘C finishes editing by copying")
                    editor.finishByCopying()
                    return true
                }
                if flags == .command, keyCode == kVK_ANSI_S {
                    logInfo("⌘S finishes editing by saving path")
                    editor.finishBySavingPath()
                    return true
                }
                if flags.isEmpty, keyCode == kVK_Return {
                    logInfo("Enter finishes editing by copying")
                    editor.finishByCopying()
                    return true
                }
                return false
            }
            if handled { return nil }
            // Pass everything else to the editing UI (text input needs it).
            logInfo("key passed through to editing UI, keyCode=\(keyCode)")
            return event
        }

        return nil // Consume, avoid beep sound
    }

    func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
            logInfo("local key/right-click monitor removed")
        }
    }

    // MARK: - Screenshot Rect Preview

    /// Capture the last screenshot rect
    func captureLastScreenshotRect() {
        var lastRect = lastScreenshotRect

        if lastRect.isEmpty {
            logInfo("D preview aborted, no previous screenshot rect")
            return
        }

        // Find appropriate screen for capturing
        guard let targetScreen = lastScreen ?? NSScreen.currentMouseScreen() ?? NSScreen.main else {
            logWarn("D preview aborted, no valid screen")
            return
        }

        // Last screen may have gone offline, adjust rect to current screen
        if lastScreen == nil {
            lastRect = targetScreen.adjustedScreenshotRect(lastRect)
        }

        guard let state = overlayViewStates[targetScreen] else {
            logWarn("D preview aborted, no overlay state for target screen")
            return
        }

        // Cancel any previously scheduled preview screenshot task
        cancelPreviewScreenshotTimer()

        // Show the preview rectangle visually
        logInfo("D preview shows last rect \(lastRect)")
        state.showPreview(rect: lastRect)

        // Create a work item to perform the actual screenshot after a delay
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Ensure we are still in screenshot mode
            guard isTakingScreenshot else {
                logInfo("D preview cancelled, capture already finished")
                return
            }

            performScreenshot(screen: targetScreen, rect: lastRect)
        }

        // Store the work item so it can be cancelled
        previewScreenshotWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
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
