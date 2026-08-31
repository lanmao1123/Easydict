//
//  ClipboardAutoPaster.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import ApplicationServices

// MARK: - ClipboardAutoPaster

/// Synthesizes a ⌘V keystroke into the frontmost app after a history entry
/// is written back, Raycast-style. Posting CGEvents requires the Accessibility
/// permission; without it the call degrades to "copy only" and logging says so.
enum ClipboardAutoPaster {
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Posts ⌘V down/up to the hid tap after `delay`, giving the previous app
    /// time to become active again once the history panel closes.
    static func pasteToActiveApp(after delay: TimeInterval = 0.12) {
        guard isAccessibilityGranted else {
            logInfo("[Clipboard] Auto-paste skipped, accessibility permission missing")
            // A silent skip reads as "the feature is broken" — surface the
            // real reason and raise the one-time system prompt so the app
            // appears in the Accessibility list with an enable shortcut.
            EZToast.showText(
                NSLocalizedString("clipboard_autopaste_needs_accessibility", comment: "")
            )
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }

            let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            logInfo("[Clipboard] Auto-paste keystroke posted")
        }
    }

    // MARK: Private
}
