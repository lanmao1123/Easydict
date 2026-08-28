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
         Defaults.Keys, so nothing to write here — a write here would clobber
         keys the user customized later. Legacy repair runs every launch from
         `setupShortcut`, not just on first launch.
         */
    }

    /**
     The retired one-shot migration wrote wrong combos into storage — the F2
     clipboard slot got ⌘[ and the F3 pin slot got ⌥Z — which shadow the
     inline defaults and leave the bare function keys firing nothing. Exact
     keyCode + modifier fingerprint keeps any combo the user actually
     recorded untouched.
     */
    func repairLegacyBrokenHotkeys() {
        // Carbon modifier masks as Magnet persists them: cmd 256, option 2048.
        let brokenCombos: [(Defaults.Key<KeyCombo?>, keyCode: Int, modifiers: Int, fallback: String)] = [
            (.clipboardHistoryShortcut, 33, 256, "F2"), // stored ⌘[
            (.pinToScreenShortcut, 6, 2048, "F3"), // stored ⌥Z
        ]
        for (key, keyCode, modifiers, fallback) in brokenCombos {
            guard let combo = Defaults[key],
                  combo.currentKeyCode == keyCode,
                  combo.modifiers == modifiers
            else { continue }
            Defaults[key] = nil
            logWarn("repaired legacy broken hotkey, key=\(key.name), reset to default \(fallback)")
        }

        // Storage of retired features (old ⌥C screenshot OCR, ⌥F mini window)
        // that no code reads anymore.
        for staleKey in ["EZScreenshotOCRShortcutKey2_keyHolder", "EZShowMiniShortcutKey_keyHolder"] {
            guard UserDefaults.standard.object(forKey: staleKey) != nil else { continue }
            UserDefaults.standard.removeObject(forKey: staleKey)
            logInfo("removed stale hotkey storage, key=\(staleKey)")
        }
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

        if !keyCombo.doubledModifiers {
            /*
             Mirror the combo into the menu-safe channel: Carbon hotkeys are
             dead while any menu tracks, and pressing the very combo a menu
             item displays is the most natural gesture. claimEmission's
             cooldown keeps the two channels from double-firing one press.
             */
            MenuSafeHotKeyChannel.shared.enroll(
                identifier: action.rawValue,
                keyCode: Int(keyCombo.currentKeyCode),
                modifiers: keyCombo.keyEquivalentModifierMask
            ) { _ in
                action.executeAction()
            }
        }
    }
}
