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
    // MARK: Internal

    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Pastes into `previousApp` — the app that was frontmost before the
    /// history panel opened. Activation handoff is asynchronous and can be
    /// silently refused under cooperative activation, so the keystroke is
    /// only posted once the target app is verified frontmost; a refused
    /// attempt is retried, with an AppleScript activation as last resort.
    static func paste(to previousApp: NSRunningApplication?) {
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

        guard let previousApp else {
            // Unknown origin: paste into whatever is frontmost right now.
            postPasteKeystroke()
            return
        }

        Task { @MainActor in
            previousApp.activate()
            if await waitUntilFrontmost(previousApp, timeout: 0.5) {
                await settleBeforePaste()
                postPasteKeystroke()
                return
            }

            previousApp.activate()
            if await waitUntilFrontmost(previousApp, timeout: 0.5) {
                await settleBeforePaste()
                postPasteKeystroke()
                return
            }

            activateViaAppleScript(previousApp)
            if await waitUntilFrontmost(previousApp, timeout: 0.8) {
                await settleBeforePaste()
                postPasteKeystroke()
                return
            }

            // Could not verify the handoff; paste anyway, best effort.
            logWarn("[Clipboard] Frontmost handoff unverified, posting paste anyway")
            await settleBeforePaste()
            postPasteKeystroke()
        }
    }

    // MARK: Private

    /// The frontmost flag flips before the target app has actually restored
    /// its key window and first responder — logs showed the keystroke landing
    /// 15ms after select, inside the window-switch animation, where Chrome
    /// simply dropped it. A short settle delay lets the focus come back.
    private static func settleBeforePaste() async {
        try? await Task.sleep(nanoseconds: 220_000_000)
    }

    /// Posts ⌘V down/up to the hid tap.
    private static func postPasteKeystroke() {
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

    private static func waitUntilFrontmost(
        _ app: NSRunningApplication, timeout: TimeInterval
    ) async
        -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication == app { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return NSWorkspace.shared.frontmostApplication == app
    }

    /// Cooperative activation can silently refuse the handoff; the Apple
    /// Events activation does not, at the cost of a one-time automation
    /// permission prompt for the target app.
    private static func activateViaAppleScript(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application id \"\(bundleID)\" to activate",
        ]
        do {
            try process.run()
            process.waitUntilExit()
            logInfo("[Clipboard] AppleScript activation exit=\(process.terminationStatus)")
        } catch {
            logWarn("[Clipboard] AppleScript activation failed: \(error.localizedDescription)")
        }
    }

    // MARK: Private
}
