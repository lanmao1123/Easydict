//
//  FunctionKeyHotKeyCenter.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon

/// Carbon-level registrar for no-modifier hotkeys.
///
/// Magnet always augments function keys with the fn modifier flag before
/// storing a `KeyCombo`, and passes that flag straight to
/// `RegisterEventHotKey`. Carbon hotkey matching never satisfies that
/// modifier combination, so bare F1/F3/F4 global hotkeys registered through
/// Magnet silently never fire. This registrar registers the bare key code
/// with no modifiers instead, which is the standard way apps grab F-keys.
///
/// All entry points are called on the main thread; the Carbon callback also
/// arrives on the main run loop, so plain dictionaries are sufficient.
enum FunctionKeyHotKeyCenter {
    // MARK: Internal

    /// Registers a no-modifier hotkey routed to an arbitrary handler.
    static func register(
        identifier: String,
        keyCode: Int,
        handler: @escaping @MainActor () -> ()
    ) {
        unregister(identifier: identifier)
        installDispatcherIfNeeded()

        let id = nextId
        nextId += 1

        var ref: EventHotKeyRef?
        let hotKeyId = EventHotKeyID(signature: signature, id: id)
        let error = RegisterEventHotKey(
            UInt32(keyCode),
            0,
            hotKeyId,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard error == noErr, let ref else {
            NSLog(
                "[Shortcut] Function-key hotkey registration failed, identifier=%@, keyCode=%d, error=%d",
                identifier, keyCode, Int(error)
            )
            return
        }

        hotKeyRefs[identifier] = ref
        identifiersById[id] = identifier
        handlersById[id] = handler
        NSLog("[Shortcut] Registered function-key hotkey, identifier=%@, keyCode=%d", identifier, keyCode)
    }

    /// Removes the hotkey bound to `identifier`, if any.
    static func unregister(identifier: String) {
        if let ref = hotKeyRefs.removeValue(forKey: identifier), let ref {
            UnregisterEventHotKey(ref)
        }
        let staleIds = identifiersById.filter { $0.value == identifier }.map(\.key)
        for staleId in staleIds {
            identifiersById.removeValue(forKey: staleId)
            handlersById.removeValue(forKey: staleId)
        }
    }

    // MARK: Private

    private static let signature = OSType(0x45_5A_44_46) // 'EZDF'

    private static var hotKeyRefs: [String: EventHotKeyRef?] = [:]
    private static var identifiersById: [UInt32: String] = [:]
    private static var handlersById: [UInt32: @MainActor () -> ()] = [:]
    private static var nextId: UInt32 = 1
    private static var dispatcherRef: EventHandlerRef?

    /// Installs the shared kEventHotKeyPressed dispatcher exactly once.
    private static func installDispatcherIfNeeded() {
        guard dispatcherRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                FunctionKeyHotKeyCenter.handleHotKeyEvent(event)
            },
            1,
            &spec,
            nil,
            &dispatcherRef
        )
    }

    /// Dispatches one fired hotkey to its handler; static so the Carbon
    /// callback closure needs no captured context.
    private static func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        var id = EventHotKeyID()
        GetEventParameter(
            event,
            OSType(kEventParamDirectObject),
            OSType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &id
        )
        let handler = MainActor.assumeIsolated {
            handlersById[id.id]
        }
        if let handler {
            Task { @MainActor in
                handler()
            }
        }
        return noErr
    }
}
