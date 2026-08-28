//
//  ShortcutAction.swift
//  Easydict
//
//  Created by tisfeng on 2025/8/25.
//  Copyright © 2025 izual. All rights reserved.
//

import Defaults
import Foundation
import Magnet
import SFSafeSymbols

// MARK: - ShortcutAction

/// Enum representing the global shortcut actions of the app
public enum ShortcutAction: String, Identifiable, CaseIterable {
    // Global shortcuts (kept: dock translate, SnipTools, clipboard history, OCR)
    case screenshotDockTranslate

    // SnipTools global shortcuts
    case snipToolsEditScreen
    case pinToScreen
    case copyImagePath

    // Clipboard history
    case clipboardHistory

    // OCR specific shortcuts (silent-only per product decision)
    case silentScreenshotOCR

    // MARK: Public

    public var id: String { rawValue }
}

extension ShortcutAction {
    /// All global shortcut actions (system-wide hotkeys)
    static let globalActions: [ShortcutAction] = [
        .screenshotDockTranslate,
        .snipToolsEditScreen,
        .pinToScreen,
        .copyImagePath,
        .clipboardHistory,
        .silentScreenshotOCR,
    ]

    /// Every remaining action registers as a system-wide hotkey; the
    /// in-app-only shortcut tier was removed with the translation windows.
    var isGlobal: Bool { true }

    /// Get configuration for the shortcut type
    var configuration: ActionConfiguration {
        Self.configurations[self]
            ?? .init(
                titleKey: "unknown",
                icon: .questionmark,
                defaultsKey: nil,
                action: {}
            )
    }

    func localizedStringKey() -> String {
        configuration.titleKey
    }

    var icon: SFSymbol {
        configuration.icon
    }

    @MainActor
    func executeAction() {
        Task {
            await configuration.action()
        }
    }

    /// Get the Defaults.Key for this shortcut action
    var defaultsKey: Defaults.Key<KeyCombo?>? {
        configuration.defaultsKey
    }
}

// MARK: - ShortcutAction Configurations

extension ShortcutAction {
    /// Static configurations for all shortcut types
    fileprivate static let configurations: [ShortcutAction: ActionConfiguration] = {
        let windowManager = EZWindowManager.shared()

        return [
            // Global shortcuts
            .screenshotDockTranslate: .init(
                titleKey: "menu_screenshot_dock_translate",
                icon: .cameraViewfinder,
                defaultsKey: .screenshotDockTranslateShortcut,
                action: { await ScreenshotDockManager.shared.start() }
            ),
            .snipToolsEditScreen: .init(
                titleKey: "menu_edit_screenshot",
                icon: .cameraOnRectangleFill,
                defaultsKey: .snipToolsEditShortcut,
                action: { await SnipToolsManager.shared.startScreenshotEdit() }
            ),
            .pinToScreen: .init(
                titleKey: "menu_pin_to_screen",
                icon: .pin,
                defaultsKey: .pinToScreenShortcut,
                action: { await SnipToolsManager.shared.pinToScreen() }
            ),
            .copyImagePath: .init(
                titleKey: "menu_copy_image_path",
                icon: .docOnDoc,
                defaultsKey: .copyImagePathShortcut,
                action: { await SnipToolsManager.shared.copyImagePath() }
            ),
            .clipboardHistory: .init(
                titleKey: "menu_clipboard_history",
                icon: .clipboard,
                defaultsKey: .clipboardHistoryShortcut,
                action: { await ClipboardManager.shared.togglePanel() }
            ),

            // OCR specific shortcuts
            .silentScreenshotOCR: .init(
                titleKey: "menu_silent_screenshot_OCR",
                icon: .cameraMeteringSpot,
                defaultsKey: .silentScreenshotOCRShortcut,
                action: { windowManager.silentScreenshotOCR() }
            ),
        ]
    }()
}
