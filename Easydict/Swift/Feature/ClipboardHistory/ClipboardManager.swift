//
//  ClipboardManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import os.log

// MARK: - ClipboardManager

/// Orchestrates the clipboard history feature: toggles the panel, writes a
/// selected entry back to the pasteboard, restores the previously active app
/// and triggers the auto-paste keystroke.
@MainActor
final class ClipboardManager: NSObject {
    // MARK: Lifecycle

    override private init() {
        super.init()
    }

    // MARK: Internal

    static let shared = ClipboardManager()

    func togglePanel() {
        /*
         During a capture session a keypress aimed at F3 (pin) can land on
         the adjacent F2; a clipboard panel popping over the screenshot is
         pure interference, so the hotkey stays dead until capture finishes.
         */
        if Screenshot.shared.isTakingScreenshot {
            NSLog("[Clipboard] Panel toggle ignored during screenshot session")
            return
        }

        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        // Polling may not be running yet on very old sessions — be safe.
        ClipboardMonitor.shared.start()

        if panel == nil {
            panel = ClipboardPanel()
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        panel?.present()
        NSApp.activate(ignoringOtherApps: true)
        NSLog(
            "[Clipboard] Panel shown, visible=%d, frame=%@",
            panel?.isVisible == true ? 1 : 0,
            NSStringFromRect(panel?.frame ?? .zero)
        )
    }

    func hidePanel() {
        panel?.orderOut(nil)
    }

    /// Enter on an entry: write it back, close, reactivate the previous app,
    /// then auto-paste when the accessibility permission allows.
    func select(_ entry: ClipboardEntry) {
        NSLog("[Clipboard] Select entry id=%lld kind=%@", entry.id, entry.kind.rawValue)
        writeBack(entry)
        ClipboardMonitor.shared.suppressNextChange()
        hidePanel()

        if let previousApp {
            previousApp.activate()
        }
        ClipboardAutoPaster.pasteToActiveApp()
    }

    @discardableResult
    func delete(_ entry: ClipboardEntry) -> Bool {
        guard let store = ClipboardMonitor.shared.store else { return false }
        do {
            try store.delete(id: entry.id)
            panel?.reload()
            Self.log.info("[Clipboard] Deleted entry id=\(entry.id)")
            return true
        } catch {
            Self.log.error("[Clipboard] Delete failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func openStorageFolder() {
        NSWorkspace.shared.open(ClipboardMonitor.shared.store?.directory ?? URL(fileURLWithPath: NSHomeDirectory()))
    }

    // MARK: Private

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Easydict", category: "ClipboardHistory")

    private var panel: ClipboardPanel?

    private weak var previousApp: NSRunningApplication?

    private func writeBack(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch entry.kind {
        case .text:
            guard let text = entry.text else {
                NSLog("[Clipboard] Write-back skipped, text entry has nil text")
                return
            }
            pasteboard.setString(text, forType: .string)
            NSLog("[Clipboard] Text written back, bytes=%lu", text.utf8.count)
        case .image:
            guard let store = ClipboardMonitor.shared.store,
                  let url = store.imageURL(for: entry),
                  let image = NSImage(contentsOf: url) else {
                NSLog("[Clipboard] Image file missing for entry id=%lld", entry.id)
                return
            }
            image.writeToPasteboard()
            NSLog("[Clipboard] Image written back")
        }
    }
}
