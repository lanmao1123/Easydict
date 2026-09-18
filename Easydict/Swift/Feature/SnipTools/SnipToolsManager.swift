//
//  SnipToolsManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// Entry manager for the SnipTools feature set.
///
/// Coordinates the global actions: annotated screenshot capture (F1),
/// pasteboard pin-to-screen (F3) and pasteboard-image-to-file-path
/// copying (F4).

@MainActor
final class SnipToolsManager: NSObject {
    // MARK: Lifecycle

    private override init() {
        super.init()
    }

    // MARK: Internal

    static let shared = SnipToolsManager()

    // MARK: Actions (bound from ShortcutAction)

    /// Takes a screenshot and enters annotation editing right after selection;
    /// the composed image is copied to the pasteboard on confirm. When the
    /// menu-safe channel triggers this while a status-bar menu is open,
    /// `presetFrozenImages` carries frames captured with the menu still on
    /// screen so the menu content survives into the shot.
    func startScreenshotEdit(presetFrozenImages: [NSScreen: NSImage] = [:]) async {
        guard !Screenshot.shared.isTakingScreenshot else {
            logWarn("startScreenshotEdit skipped, capture already in progress")
            return
        }
        /*
         F1 reaches this async entry through Carbon and the menu-safe channel.
         Their shared claim normally deduplicates one press, but a task queued
         as the editor closes can run after the capture flag clears. Suppress
         only that short tail so confirming a copy cannot reopen the overlay.
         */
        guard Date().timeIntervalSince(lastCaptureEndedAt) >= Self.restartGuardInterval else {
            logWarn("startScreenshotEdit skipped, capture just ended")
            return
        }

        Screenshot.shared.shouldRestorePreviousApp = false
        Screenshot.shared.editModeEnabled = true
        logInfo("startScreenshotEdit began, presetScreens=\(presetFrozenImages.count)")
        await withCheckedContinuation { continuation in
            /*
              The capture engine copies the composited image itself (PNG+TIFF+
              backing file), so the completion only releases the continuation —
              writing the pasteboard here again would downgrade that payload.
             */
            Screenshot.shared.startCapture(presetFrozenImages: presetFrozenImages) { _ in
                self.lastCaptureEndedAt = Date()
                continuation.resume()
            }
        }
    }

    /// Pins the pasteboard image as a floating always-on-top window.
    func pinToScreen() async {
        PinImageManager.shared.pinFromPasteboard()
    }

    /// Saves the pasteboard image to disk and copies its absolute path.
    func copyImagePath() async {
        PasteboardPathService.saveFromPasteboardAndCopyPath()
    }

    // MARK: Private

    private static let restartGuardInterval: TimeInterval = 0.35

    private var lastCaptureEndedAt = Date.distantPast
}
