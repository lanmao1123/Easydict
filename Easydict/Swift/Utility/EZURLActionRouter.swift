//
//  EZURLActionRouter.swift
//  Easydict
//
//  Created by agent on 2026/8/28.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Foundation

/**
 Bridges `easydict://<action>` URLs to the kept feature set, so external
 launchers (Raycast Quicklinks, Alfred, scripts) can trigger them without
 touching Carbon hotkeys. Actions mirror the menu items one-to-one.

 Recognized: snip, dock-translate, clipboard-history, ocr, pin.
 */
@objcMembers
final class EZURLActionRouter: NSObject {
    // MARK: Internal

    /// Returns true when `action` names a supported feature and it was
    /// dispatched; callers fall back to legacy query routing otherwise.
    @discardableResult
    static func handle(_ action: String) -> Bool {
        let normalized = action.lowercased().trimmingCharacters(in: .whitespaces)
        #if DEBUG
        let supported = actions.union(debugActions)
        #else
        let supported = actions
        #endif
        guard supported.contains(normalized) else { return false }

        logInfo("URL action dispatched, action=\(normalized)")

        // The Apple-event URL handler calls us on the main thread; hop
        // explicitly so MainActor singletons are always touched safely.
        Task { @MainActor in
            dispatch(normalized)
        }
        return true
    }

    // MARK: Private

    private static let actions: Set<String> = [
        "snip", "dock-translate", "clipboard-history", "ocr", "pin",
    ]

    #if DEBUG
    /// Debug-only actions used by headless verification scripts.
    private static let debugActions: Set<String> = [
        "debug-pinch", "debug-dock-translate", "debug-scale",
    ]
    #endif

    @MainActor
    private static func dispatch(_ action: String) {
        switch action {
        case "snip":
            Task { await SnipToolsManager.shared.startScreenshotEdit() }

        case "dock-translate":
            ScreenshotDockManager.shared.start()

        case "clipboard-history":
            ClipboardManager.shared.togglePanel()

        case "ocr":
            // Silent OCR: recognize in the background and copy the text
            // per the auto-copy setting, without any result window.
            EZWindowManager.shared().silentScreenshotOCR()

        case "pin":
            Task { await SnipToolsManager.shared.pinToScreen() }

        default:
            #if DEBUG
            if debugActions.contains(action) {
                handleDebugAction(action)
            }
            #endif
        }
    }

    #if DEBUG
    /// easydictd://debug-pinch drives the pinch pipeline without a trackpad:
    /// pins a synthetic image when none exists, then zooms through the exact
    /// production path so headless scripts can assert real frame changes.
    @MainActor
    private static func handleDebugAction(_ action: String) {
        if action == "debug-dock-translate" {
            ScreenshotDockManager.shared.debugTranslate()
            return
        }
        if action == "debug-scale" {
            ScreenshotDockManager.shared.debugScaleFont()
            return
        }
        guard action == "debug-pinch" else { return }
        let target = PinImageManager.shared.debugPinTarget()
        guard let target else {
            logInfo("debug-pinch: no pin available, pinned synthetic one; call again")
            return
        }
        PinImageManager.shared.applyDebugPinch(to: target, magnification: 0.3)
    }
    #endif
}
