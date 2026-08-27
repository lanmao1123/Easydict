//
//  MenuSafeHotKeyChannel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import CoreGraphics

/// Hotkey fallback that keeps working while an NSMenu is tracking.
///
/// When a status-bar (or any) menu is open, WindowServer stops matching
/// Carbon hotkeys and no app receives normal keyboard events, so pressing F1
/// looks dead until the menu closes — the exact gap Microsoft's Snipping Tool
/// does not have on Windows. Two verified escape hatches exist:
///
/// 1. A listen-only `CGEventTap` installed on a dedicated background thread
///    still receives key events during menu tracking (the tap lives outside
///    any app run loop mode).
/// 2. `CGEventSource.keyState` mirrors real hardware key state regardless of
///    the modal loop, polled from a queue that never blocks.
///
/// Both routes funnel into one edge-detected dispatcher with a per-key cooldown
/// so the regular Carbon hotkey path (`FunctionKeyHotKeyCenter`) never fires the
/// same physical key press twice. When a popup menu is actually on screen, the
/// dispatcher first freezes a clean full-screen frame (so the menu content is
/// captured), posts synthetic ESC to dismiss the menu — freeing the main thread
/// if it is our own menu — and only then hands over to the main-actor action.
final class MenuSafeHotKeyChannel {
    // MARK: Lifecycle

    private init() {}

    // MARK: Internal

    static let shared = MenuSafeHotKeyChannel()

    /// Registers a menu-safe fallback for a bare function-key hotkey.
    /// `fire` receives preset frozen frames keyed by screen when menus were
    /// detected at trigger time; actions that don't capture screens ignore it.
    func enroll(
        identifier: String,
        keyCode: Int,
        capturesFrozenFrame: Bool = false,
        fire: @escaping @MainActor ([NSScreen: NSImage]) -> ()
    ) {
        lock.lock()
        enrollments[identifier] = Enrollment(
            keyCode: keyCode,
            capturesFrozenFrame: capturesFrozenFrame,
            fire: fire
        )
        keyCodes.insert(keyCode)
        pressedKeys.remove(keyCode)
        lock.unlock()

        installIfNeeded()
    }

    /// Drops the enrollment for `identifier` (hotkey rebind or removal).
    func unenroll(identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let removed = enrollments.removeValue(forKey: identifier) else { return }
        // Keep other identifiers bound to the same key code alive.
        if !enrollments.values.contains(where: { $0.keyCode == removed.keyCode }) {
            keyCodes.remove(removed.keyCode)
            pressedKeys.remove(removed.keyCode)
            lastFireByKeyCode.removeValue(forKey: removed.keyCode)
        }
    }

    /**
     Arbitrates between this channel and the Carbon hotkey path for one key.

     Returns true when the caller may dispatch. Keys we never enrolled pass
     through untouched; enrolled keys honor a short cooldown so whichever
     channel sees the physical press first wins and the other stays silent.
     */
    func claimEmission(keyCode: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enrollments.values.contains(where: { $0.keyCode == keyCode }) else {
            return true
        }
        let now = Date()
        if let last = lastFireByKeyCode[keyCode], now.timeIntervalSince(last) < Self.cooldown {
            return false
        }
        lastFireByKeyCode[keyCode] = now
        return true
    }

    #if DEBUG
    /// Headless-verification entry: runs the same dispatch path a real key
    /// press would take (menu detect -> frozen frame -> dismiss -> action).
    func debugFire(forKeyCode keyCode: Int) {
        dispatch(forKeyCode: keyCode)
    }
    #endif

    // MARK: Private

    private struct Enrollment {
        let keyCode: Int
        let capturesFrozenFrame: Bool
        let fire: @MainActor ([NSScreen: NSImage]) -> ()
    }

    private static let pollInterval: TimeInterval = 0.06
    private static let cooldown: TimeInterval = 0.6

    private let lock = NSLock()
    private var enrollments: [String: Enrollment] = [:]
    private var keyCodes: Set<Int> = []
    private var pressedKeys: Set<Int> = []
    private var lastFireByKeyCode: [Int: Date] = [:]

    private var installed = false
    private var eventTap: CFMachPort?
    private var pollTimer: DispatchSourceTimer?

    private func installIfNeeded() {
        lock.lock()
        guard !installed else {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()

        startPolling()
        startEventTapIfAuthorized()
    }

    /// Route 1: hardware state polling. Needs no TCC grant at all.
    private func startPolling() {
        lock.lock()
        let enrolledKeys = Array(keyCodes).sorted()
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock()
            let codes = Array(keyCodes)
            lock.unlock()
            for keyCode in codes {
                let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
                    || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
                updatePress(isDown: down, forKeyCode: keyCode, source: "poll")
            }
        }
        timer.resume()
        pollTimer = timer
        NSLog("[MenuSafeHotKey] Polling channel started, keys=%@", enrolledKeys)
    }

    /// Route 2: session event tap on its own run loop thread. Reads every key
    /// even during menu tracking; silently skipped without Input Monitoring.
    private func startEventTapIfAuthorized() {
        guard CGPreflightListenEventAccess() else {
            NSLog("[MenuSafeHotKey] Listen-event access not granted, polling-only mode")
            return
        }

        let thread = Thread { [weak self] in
            guard let self else { return }
            let mask = CGEventMask(
                (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            )
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return nil }
                    let channel = Unmanaged<MenuSafeHotKeyChannel>
                        .fromOpaque(userInfo).takeUnretainedValue()
                    channel.handleTapEvent(type: type, event: event)
                    return nil
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            guard let tap else {
                NSLog("[MenuSafeHotKey] Event tap creation failed, polling-only mode")
                return
            }
            lock.lock()
            eventTap = tap
            lock.unlock()

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, CFRunLoopMode.defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[MenuSafeHotKey] Event tap installed on background thread")
            RunLoop.current.run()
        }
        thread.name = "com.izual.Easydict.MenuSafeHotKeyTap"
        thread.start()
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown, .keyUp:
            break
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        default:
            return
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        updatePress(
            isDown: type == .keyDown,
            forKeyCode: keyCode,
            source: "tap"
        )
    }

    /// Edge detector shared by both channels: fire once per physical press.
    private func updatePress(isDown: Bool, forKeyCode keyCode: Int, source: String) {
        var freshPress = false
        lock.lock()
        if isDown {
            freshPress = !pressedKeys.contains(keyCode)
            pressedKeys.insert(keyCode)
        } else {
            pressedKeys.remove(keyCode)
        }
        lock.unlock()
        guard freshPress else { return }

        let claimed = claimEmission(keyCode: keyCode)
        NSLog(
            "[MenuSafeHotKey] %@ keyDown keyCode=%d claimed=%d",
            source, keyCode, claimed ? 1 : 0
        )
        guard claimed else { return }

        dispatch(forKeyCode: keyCode)
    }

    private func dispatch(forKeyCode keyCode: Int) {
        lock.lock()
        let match = enrollments.values.first { $0.keyCode == keyCode }
        lock.unlock()
        guard let match else { return }

        // Freeze the frame BEFORE dismissing anything: the popup is exactly
        // what the user wants to see in the shot.
        let menusOnScreen = popupMenuWindows()
        NSLog(
            "[MenuSafeHotKey] Dispatching action, keyCode=%d, identifier=%@, openMenus=%d",
            keyCode, enrollments.first { $1.keyCode == keyCode }?.key ?? "?", menusOnScreen.count
        )
        var presets: [NSScreen: NSImage] = [:]
        if match.capturesFrozenFrame {
            /*
             Capture here on this background thread even with no menu open:
             the main thread then only creates windows and the crosshair
             appears without waiting for a ScreenCaptureKit round trip.
             */
            for screen in NSScreen.screens {
                if let image = screen.takeScreenshot() {
                    presets[screen] = image
                }
            }
        }

        if !menusOnScreen.isEmpty {
            dismissOpenMenus(menusOnScreen)
        }

        Task { @MainActor in
            match.fire(presets)
        }
    }

    /// Bounds + owner PID of on-screen popup-menu-level windows (status-bar
    /// menus, etc.). The PID lets the dismissal target only the menu owner.
    private func popupMenuWindows() -> [(bounds: CGRect, pid: pid_t)] {
        // kCGPopUpMenuWindowLevel — every NSMenu popup lives on this layer,
        // verified live; ordinary windows and floating HUDs never do.
        let menuLevel: Int32 = 101
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return list.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int32 == menuLevel else { return nil }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            let bounds = CGRect(
                x: boundsDict["X"] as? Double ?? 0,
                y: boundsDict["Y"] as? Double ?? 0,
                width: boundsDict["Width"] as? Double ?? 0,
                height: boundsDict["Height"] as? Double ?? 0
            )
            let pid = window[kCGWindowOwnerPID as String] as? Int32 ?? 0
            return (bounds, pid)
        }
    }

    /// Dismisses the tracking menu without moving the pointer and without
    /// leaking keys into the capture session that starts right after.
    ///
    /// - Own menu: a synthetic click at the pointer's current spot. The menu
    ///   tracking loop consumes it normally (toggle-close) and nothing stays
    ///   queued. An ESC posted to our own PID was tried instead, but the
    ///   tracking loop never consumes PID-posted events — the key sat in the
    ///   queue until the capture session's monitors were live and then
    ///   canceled the fresh session.
    /// - Another app's menu: ESC to that PID only. A broadcast click was
    ///   tried before, but a synthesized mouse event teleports the real
    ///   pointer to the click spot — the "pointer jumps mid-screen" bug.
    private func dismissOpenMenus(_ menus: [(bounds: CGRect, pid: pid_t)]) {
        guard let menu = menus.first, menu.pid > 0 else { return }

        if menu.pid == getpid() {
            let here = CGEvent(source: nil)?.location ?? .zero
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: here,
                    mouseButton: .left
                )
                event?.post(tap: .cghidEventTap)
            }
            NSLog(
                "[MenuSafeHotKey] Posted in-place click to dismiss own menu at (%.0f, %.0f)",
                here.x, here.y
            )
        } else {
            let escapeKeyCode = CGKeyCode(53)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: true)
            down?.postToPid(menu.pid)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: escapeKeyCode, keyDown: false)
            up?.postToPid(menu.pid)
            NSLog("[MenuSafeHotKey] Posted ESC to menu owner, pid=%d", menu.pid)
        }
    }
}
