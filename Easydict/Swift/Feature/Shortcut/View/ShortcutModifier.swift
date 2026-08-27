//
//  AppShortcutModifier.swift
//  Easydict
//
//  Created by tisfeng on 2025/8/25.
//  Copyright © 2025 izual. All rights reserved.
//

import Defaults
import Foundation
import Magnet
import SwiftUI

// MARK: - ShortcutModifier

struct ShortcutModifier: ViewModifier {
    let action: ShortcutAction

    func body(content: Content) -> some View {
        if let defaultsKey = action.defaultsKey {
            ShortcutModifierWithKey(content: content, defaultsKey: defaultsKey)
        } else {
            content
        }
    }
}

// MARK: - ShortcutModifierWithKey

struct ShortcutModifierWithKey<Content: View>: View {
    // MARK: Lifecycle

    init(content: Content, defaultsKey: Defaults.Key<KeyCombo?>) {
        self.content = content
        _shortcutKey = .init(defaultsKey)
    }

    // MARK: Internal

    let content: Content
    @Default var shortcutKey: KeyCombo?

    var body: some View {
        if let shortcutKey, let keyEquivalent = fetchShortcutKeyEquivalent(shortcutKey) {
            content
                .keyboardShortcut(
                    keyEquivalent,
                    modifiers: fetchShortcutKeyEventModifiers(shortcutKey)
                )
        } else {
            content
        }
    }

    // MARK: Private

    /// Converts a stored combo into a single-grapheme `KeyEquivalent`.
    ///
    /// Function keys such as F1 map to private-use glyphs and some layouts
    /// report multi-cluster strings for them; constructing a `Character` from
    /// those crashes at runtime. Any combo that does not reduce to exactly one
    /// cluster simply gets no visible menu shortcut — the global hotkey still
    /// works, because it is registered separately by Magnet.
    private func fetchShortcutKeyEquivalent(_ keyCombo: KeyCombo) -> KeyEquivalent? {
        let string = keyCombo.doubledModifiers
            ? keyCombo.keyEquivalentModifierMaskString
            : keyCombo.keyEquivalent

        guard string.count == 1, let character = string.first else {
            return nil
        }
        return KeyEquivalent(character)
    }

    private func fetchShortcutKeyEventModifiers(_ keyCombo: KeyCombo) -> SwiftUI.EventModifiers {
        let modifierMappings: [(NSEvent.ModifierFlags, SwiftUI.EventModifiers)] = [
            (.command, .command),
            (.control, .control),
            (.option, .option),
            (.shift, .shift),
        ]

        return modifierMappings.reduce(into: SwiftUI.EventModifiers()) { result, mapping in
            if keyCombo.keyEquivalentModifierMask.contains(mapping.0) {
                result.update(with: mapping.1)
            }
        }
    }
}

/// can't using keyEquivalent and EventModifiers in SwiftUI MenuItemView direct, because item
/// keyboardShortcut not support double modifier key but can use ⌥ as character
extension View {
    @ViewBuilder
    public func keyboardShortcut(_ action: ShortcutAction) -> some View {
        modifier(ShortcutModifier(action: action))
    }
}
