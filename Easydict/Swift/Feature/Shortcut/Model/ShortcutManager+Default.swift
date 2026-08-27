//
//  ShortcutManager+Default.swift
//  Easydict
//
//  Created by Sharker on 2024/2/5.
//  Copyright © 2024 izual. All rights reserved.
//

import Defaults
import Magnet

// MARK: - ShortcutManager + Defaults Settings

extension ShortcutManager {
    // Set defalut hotkeys for global and app
    func setDefaultShortcutKeys() {
        setDefaultGlobalShortcutKeys()
        setDefaultAppShortcutKeys()
    }

    private func setDefaultGlobalShortcutKeys() {
        Defaults[.inputShortcut] = KeyCombo(key: .a, cocoaModifiers: .option)
        Defaults[.snipShortcut] = KeyCombo(key: .s, cocoaModifiers: .option)
        Defaults[.selectionShortcut] = KeyCombo(key: .d, cocoaModifiers: .option)
        Defaults[.showMiniWindowShortcut] = KeyCombo(key: .f, cocoaModifiers: .option)
        Defaults[.silentScreenshotOCRShortcut] = KeyCombo(
            key: .s, cocoaModifiers: [.option, .shift]
        )
        Defaults[.screenshotDockTranslateShortcut] = KeyCombo(
            key: .x, cocoaModifiers: .option
        )
        setSnipToolsDefaultKeys()
    }

    /// Default keys for the SnipTools actions; shared by first launch and by
    /// the one-shot migration that back-fills older installs.
    func setSnipToolsDefaultKeys() {
        // Bare function keys, mirroring Snipaste's muscle memory.
        Defaults[.snipToolsEditShortcut] = KeyCombo(key: .f1, cocoaModifiers: [])
        Defaults[.pinToScreenShortcut] = KeyCombo(key: .f3, cocoaModifiers: [])
        Defaults[.copyImagePathShortcut] = KeyCombo(key: .f4, cocoaModifiers: [])
        Defaults[.colorPickerShortcut] = KeyCombo(key: .c, cocoaModifiers: .option)
    }

    private func setDefaultAppShortcutKeys() {
        Defaults[.clearInputShortcut] = KeyCombo(key: .k, cocoaModifiers: .command)
        Defaults[.clearAllShortcut] = KeyCombo(key: .k, cocoaModifiers: [.command, .shift])
        Defaults[.copyShortcut] = KeyCombo(key: .c, cocoaModifiers: [.command, .shift])
        Defaults[.copyFirstResultShortcut] = KeyCombo(key: .j, cocoaModifiers: [.command, .shift])
        Defaults[.focusShortcut] = KeyCombo(key: .i, cocoaModifiers: .command)
        Defaults[.playShortcut] = KeyCombo(key: .s, cocoaModifiers: .command)
        Defaults[.retryShortcut] = KeyCombo(key: .r, cocoaModifiers: .command)
        Defaults[.toggleShortcut] = KeyCombo(key: .t, cocoaModifiers: .command)
        Defaults[.pinShortcut] = KeyCombo(key: .p, cocoaModifiers: .command)
        Defaults[.hideShortcut] = KeyCombo(key: .y, cocoaModifiers: .command)
        Defaults[.increaseFontSize] = KeyCombo(key: .keypadPlus, cocoaModifiers: .command)
        Defaults[.decreaseFontSize] = KeyCombo(key: .keypadMinus, cocoaModifiers: .command)
        Defaults[.googleShortcut] = KeyCombo(key: .return, cocoaModifiers: .command)
        Defaults[.eudicShortcut] = KeyCombo(key: .return, cocoaModifiers: [.command, .shift])
        Defaults[.appleDictionaryShortcut] = KeyCombo(key: .d, cocoaModifiers: [.command, .shift])
    }
}

// MARK: - ShortcutManager + GlobalShortcut

extension ShortcutManager {
    /// Setup global shortcut actions
    func setupGlobalShortcutActions() {
        for action in ShortcutAction.globalActions {
            if let key = action.defaultsKey {
                let keyCombo = Defaults[key]
                bindingGlobalShortcutAction(keyCombo: keyCombo, action: action)
            }
        }
    }

    /// Bind global shortcut action (registers as system-wide hotkey)
    func bindingGlobalShortcutAction(keyCombo: KeyCombo?, action: ShortcutAction) {
        HotKeyCenter.shared.unregisterHotKey(with: action.rawValue)
        FunctionKeyHotKeyCenter.unregister(identifier: action.rawValue)
        MenuSafeHotKeyChannel.shared.unenroll(identifier: action.rawValue)

        // Ensure the action is a global action and keyCombo is valid
        guard let keyCombo, action.isGlobal else {
            return
        }

        /*
         Bare function keys: Magnet stores them with the fn modifier flag,
         which Carbon hotkey matching can never satisfy, so those hotkeys
         never fire. Route them through our own Carbon registration with no
         modifiers instead.
         */
        if !keyCombo.doubledModifiers,
           keyCombo.modifiers == Int(NSEvent.ModifierFlags.function.rawValue) {
            let keyCode = Int(keyCombo.currentKeyCode)

            /*
             Carbon hotkeys are dead while any menu is tracking (the press
             looks swallowed), so also enroll the key in the menu-safe
             channel. The screenshot action gets its menu-content frame
             captured before the channel dismisses the popup.
             */
            MenuSafeHotKeyChannel.shared.enroll(
                identifier: action.rawValue,
                keyCode: keyCode,
                capturesFrozenFrame: action == .snipToolsEditScreen
            ) { presets in
                if action == .snipToolsEditScreen {
                    Task { @MainActor in
                        await SnipToolsManager.shared.startScreenshotEdit(
                            presetFrozenImages: presets
                        )
                    }
                } else {
                    action.executeAction()
                }
            }

            FunctionKeyHotKeyCenter.register(
                identifier: action.rawValue,
                keyCode: keyCode
            ) {
                action.executeAction()
            }
            return
        }

        let hotKey = HotKey(
            identifier: action.rawValue,
            keyCombo: keyCombo
        ) { _ in
            Task { @MainActor in
                action.executeAction()
            }
        }

        hotKey.register()
    }
}
