//
//  ClipboardManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

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
            logInfo("panel toggle ignored during screenshot session")
            return
        }

        if panel?.isVisible == true {
            hidePanel()
            return
        }

        previousApp = Self.currentPasteTarget()
        showPanel()
    }

    /// URL entries (Raycast Quicklink etc.) arrive after the system has
    /// already activated this app, so the frontmost at showPanel time is
    /// ourselves and the activation moment is impossible to observe from
    /// inside. The paste target is instead read off the window stack: the
    /// app the user just worked in owns the topmost foreign windows, right
    /// beneath ours. Only .regular apps qualify — launchers like Raycast
    /// (.accessory) and helpers never become the paste destination.
    func openPanelFromURL() {
        previousApp = Self.captureRegularAppUnderOurs()
        if let previousApp {
            logInfo(
                "[Clipboard] URL source app captured, bundle=\(previousApp.bundleIdentifier ?? "?")"
            )
        } else {
            logWarn("[Clipboard] URL source app not captured, auto-paste target unresolved")
        }
        showPanel()
    }

    func showPanel() {
        // Polling may not be running yet on very old sessions — be safe.
        ClipboardMonitor.shared.start()

        if panel == nil {
            panel = ClipboardPanel()
        }

        observeDeactivation()
        panel?.present()
        NSApp.activate(ignoringOtherApps: true)
        logInfo("panel shown, visible=\(panel?.isVisible == true), frame=\(NSStringFromRect(panel?.frame ?? .zero))")
    }

    func hidePanel() {
        removeDeactivationObserver()
        if panel?.isVisible == true {
            logInfo("panel hidden")
        }
        panel?.orderOut(nil)
    }

    /// Enter on an entry: write it back, close, reactivate the previous app,
    /// then auto-paste when the accessibility permission allows.
    func select(_ entry: ClipboardEntry) {
        logInfo(
            "select entry, id=\(entry.id), kind=\(entry.kind.rawValue), target=\(previousApp?.bundleIdentifier ?? "nil")"
        )
        writeBack(entry)
        ClipboardMonitor.shared.suppressNextChange()
        hidePanel()

        if let previousApp {
            previousApp.activate()
        } else {
            logWarn("[Clipboard] No captured source app, pasting into current frontmost")
        }
        // The paster verifies the frontmost handoff itself before typing;
        // this first activate() is just the fastest head start.
        ClipboardAutoPaster.paste(to: previousApp)
    }

    @discardableResult
    func delete(_ entry: ClipboardEntry) -> Bool {
        guard let store = ClipboardMonitor.shared.store else { return false }
        do {
            try store.delete(id: entry.id)
            panel?.reload()
            logInfo("[Clipboard] Deleted entry id=\(entry.id)")
            return true
        } catch {
            logError("[Clipboard] Delete failed: \(String(describing: error))")
            return false
        }
    }

    @discardableResult
    func clearAll() -> Bool {
        guard let store = ClipboardMonitor.shared.store else { return false }
        do {
            try store.deleteAllEntries()
            panel?.reload()
            return true
        } catch {
            logError("[Clipboard] Clear all failed: \(String(describing: error))")
            return false
        }
    }

    func openStorageFolder() {
        NSWorkspace.shared.open(ClipboardMonitor.shared.store?.directory ?? URL(fileURLWithPath: NSHomeDirectory()))
    }

    // MARK: Private

    private var panel: ClipboardPanel?

    /// Strong on purpose: a weak reference released the URL-path capture —
    /// NSRunningApplication(processIdentifier:) hands back a wrapper that is
    /// not strongly held, so the target silently became nil between panel
    /// open and select, and the paste took the no-target fast path.
    private var previousApp: NSRunningApplication?

    /// Hides the panel when Easydict loses focus — the "states stay in sync"
    /// contract: collapsing Raycast (or clicking anywhere else) collapses the
    /// clipboard panel with it. NSPanel.hidesOnDeactivate proved unreliable
    /// for this nonactivating panel, so the resignation is observed directly.
    private var deactivateObserver: (any NSObjectProtocol)?

    /// The frontmost app to paste into, unless that is this app itself —
    /// by the time a URL activation lands, the frontmost is already us.
    private static func currentPasteTarget() -> NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        guard front != NSRunningApplication.current else { return nil }
        return front
    }

    /// Topmost foreign on-screen window whose owner is a regular app — the
    /// user's current working app in the window stack right beneath ours.
    private static func captureRegularAppUnderOurs() -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
        else { return nil }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != selfPID,
                  // Resolve through the workspace's shared instance table —
                  // NSRunningApplication(processIdentifier:) wrappers are not
                  // strongly held and die before the panel is used.
                  let app = NSWorkspace.shared.runningApplications.first(where: {
                      $0.processIdentifier == pid
                  }),
                  app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    /// Last deliberate show, used to turn a quick re-trigger into a close.
    private func observeDeactivation() {
        guard deactivateObserver == nil else { return }
        deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, panel?.isVisible == true else { return }
            logInfo("app resigned active, syncing panel closed")
            hidePanel()
        }
    }

    private func removeDeactivationObserver() {
        if let deactivateObserver {
            NotificationCenter.default.removeObserver(deactivateObserver)
            self.deactivateObserver = nil
        }
    }

    private func writeBack(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general

        switch entry.kind {
        case .text:
            guard let text = entry.text else {
                logWarn("write-back skipped, text entry has nil text")
                return
            }
            // Validate before clearing: a failed write-back must not wipe the
            // user's current clipboard contents.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            logInfo("text written back, bytes=\(text.utf8.count)")
        case .image:
            guard let store = ClipboardMonitor.shared.store,
                  let url = store.imageURL(for: entry),
                  let image = NSImage(contentsOf: url) else {
                logError("write-back aborted, image file missing, id=\(entry.id)")
                return
            }
            pasteboard.clearContents()
            image.writeToPasteboard()
            logInfo("image written back")
        }
    }
}
