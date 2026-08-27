//
//  ShortcutManager.swift
//  Easydict
//
//  Created by Sharker on 2024/1/20.
//  Copyright © 2024 izual. All rights reserved.

import Defaults
import Foundation
import Magnet

// MARK: - ShortcutManager

class ShortcutManager: NSObject {
    // MARK: Internal

    @objc static let shared = ShortcutManager()

    var confictShortcutTitle = ""

    @objc
    func setupShortcut() {
        // Set default shortcuts for first launch
        if Defaults[.firstLaunch] {
            Defaults[.firstLaunch] = false
            setDefaultShortcutKeys()
        }

        /*
         Older installs miss the SnipTools keys because they never see
         firstLaunch again; inject their defaults exactly once.
         */
        if !Defaults[.snipToolsDefaultsApplied] {
            setSnipToolsDefaultKeys()
            Defaults[.snipToolsDefaultsApplied] = true
        }

        // Same one-shot pattern for the clipboard history default key (F2).
        if !Defaults[.clipboardDefaultsApplied] {
            Defaults[.clipboardHistoryShortcut] = KeyCombo(key: .f2, cocoaModifiers: [])
            Defaults[.clipboardDefaultsApplied] = true
        }

        // Bind global shortcut actions
        setupGlobalShortcutActions()

        #if DEBUG
        installMenuSafeDebugHooks()
        #endif

        /*
         The clipboard history monitor must poll from app launch on; this is
         the Swift-side assembly point already invoked by
         applicationDidFinishLaunching.
         */
        MainActor.assumeIsolated {
            ClipboardMonitor.shared.start()
        }
    }

    // MARK: Private

    #if DEBUG
    /// Headless-verification hooks: a DistributedNotification from the
    /// terminal drives the exact menu-safe dispatch path without real keys.
    private func installMenuSafeDebugHooks() {
        let center = DistributedNotificationCenter.default()
        for (name, keyCode) in [
            ("com.izual.Easydict.debugMenuSafeFireF1", 122), // F1
            ("com.izual.Easydict.debugMenuSafeFireF2", 120), // F2
        ] {
            center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: nil
            ) { _ in
                NSLog("[MenuSafeHotKey] DEBUG fire via notification, keyCode=%d", keyCode)
                MenuSafeHotKeyChannel.shared.debugFire(forKeyCode: keyCode)
            }
        }
        NSLog("[MenuSafeHotKey] DEBUG notification hooks installed")
    }
    #endif
}

// MARK: - Update Menu action

extension ShortcutManager {
    /// Update shortcut menu
    func updateMenu(_ action: ShortcutAction) {
        let shortcutTitle = String(
            localized: LocalizedStringResource(stringLiteral: action.localizedStringKey())
        )
        let menuTitle = String(localized: LocalizedStringResource(stringLiteral: "shortcut"))
        let shortcutMenu = NSApp.mainMenu?.items.first(where: { $0.title == menuTitle })
        let clearInput = shortcutMenu?.submenu?.items.first(where: { $0.title == shortcutTitle })
        clearInput?.keyEquivalent = ""
    }
}
