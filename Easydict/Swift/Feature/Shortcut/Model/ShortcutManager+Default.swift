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
        /*
         SnipTools keys are covered by inline `default:` values on their
         Defaults.Keys (F1/F3/F4/⌥P), so nothing to write here — a write here
         would clobber keys the user customized later.
         */
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
        // One owner per key combo: a duplicate registration makes the hotkey
        // fire the wrong action (or both), the classic "shortcuts act up" bug.
        var claimedCombos: [String: ShortcutAction] = [:]

        for action in ShortcutAction.globalActions {
            guard let key = action.defaultsKey else {
                logWarn("global shortcut skipped, no defaults key, action=\(action.rawValue)")
                continue
            }
            let keyCombo = Defaults[key]
            if keyCombo == nil {
                logWarn("global shortcut has no key combo in defaults, action=\(action.rawValue), key=\(key.name)")
            }
            if let keyCombo {
                let fingerprint = "\(keyCombo.currentKeyCode)|\(keyCombo.modifiers)"
                if let winner = claimedCombos[fingerprint] {
                    logError(
                        "shortcut conflict, action=\(action.rawValue) wants the same key as action=\(winner.rawValue); keeping \(winner.rawValue), rebind one of them in Settings"
                    )
                    continue
                }
                claimedCombos[fingerprint] = action
            }
            bindingGlobalShortcutAction(keyCombo: keyCombo, action: action)
        }
    }

    /// Bind global shortcut action (registers as system-wide hotkey)
    func bindingGlobalShortcutAction(keyCombo: KeyCombo?, action: ShortcutAction) {
        HotKeyCenter.shared.unregisterHotKey(with: action.rawValue)
        FunctionKeyHotKeyCenter.unregister(identifier: action.rawValue)
        MenuSafeHotKeyChannel.shared.unenroll(identifier: action.rawValue)

        // Ensure the action is a global action and keyCombo is valid
        guard let keyCombo, action.isGlobal else {
            logWarn(
                "shortcut binding skipped, action=\(action.rawValue), keyCombo=\(keyCombo != nil ? "set" : "nil"), isGlobal=\(action.isGlobal)"
            )
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
            logInfo(
                "binding function-key hotkey, action=\(action.rawValue), keyCode=\(keyCode), capturesFrozenFrame=\(action == .snipToolsEditScreen)"
            )

            /*
             Carbon hotkeys are dead while any menu is tracking. Only the
             capture action needs that menu-open escape hatch (shooting the
             menu itself); polling key-state and the global tap also pick up
             synthetic events and bounces, which made F2 pop the clipboard
             panel by itself — so every other function-key action sticks to
             plain Carbon hotkeys.
             */
            guard action == .snipToolsEditScreen else {
                FunctionKeyHotKeyCenter.register(
                    identifier: action.rawValue,
                    keyCode: keyCode
                ) {
                    action.executeAction()
                }
                logInfo("binding function-key hotkey, carbon-only, action=\(action.rawValue), keyCode=\(keyCode)")
                return
            }
            MenuSafeHotKeyChannel.shared.enroll(
                identifier: action.rawValue,
                keyCode: keyCode,
                capturesFrozenFrame: true
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
        logInfo("binding modifier hotkey via Magnet, action=\(action.rawValue), keyCombo=\(keyCombo)")
    }
}
