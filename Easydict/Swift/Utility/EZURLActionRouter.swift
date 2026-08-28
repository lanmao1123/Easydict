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

 Recognized: snip, dock-translate, clipboard-history, ocr, pin, color-picker.
 */
@objcMembers
final class EZURLActionRouter: NSObject {
    // MARK: Internal

    /// Returns true when `action` names a supported feature and it was
    /// dispatched; callers fall back to legacy query routing otherwise.
    @discardableResult
    static func handle(_ action: String) -> Bool {
        let normalized = action.lowercased().trimmingCharacters(in: .whitespaces)
        guard actions.contains(normalized) else { return false }

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
        "snip", "dock-translate", "clipboard-history", "ocr", "pin", "color-picker",
    ]

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
            EZWindowManager.shared().screenshotOCR()

        case "pin":
            Task { await SnipToolsManager.shared.pinToScreen() }

        case "color-picker":
            Task { await SnipToolsManager.shared.startColorPicker() }

        default:
            break
        }
    }
}
