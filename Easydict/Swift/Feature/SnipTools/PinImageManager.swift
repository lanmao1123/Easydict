//
//  PinImageManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon

/// Tracks all pinned image panels so they can be closed individually or all
/// at once.
@MainActor
final class PinImageManager: NSObject {
    // MARK: Lifecycle

    private override init() {
        super.init()
    }

    // MARK: Internal

    static let shared = PinImageManager()

    /// Pins the current pasteboard image; shows a toast when none exists.
    func pinFromPasteboard() {
        /*
         The global Carbon hotkey consumes F3 at the system level before the
         capture overlay's key handler can see it, so this is the ONLY path
         that runs for F3 during a capture session: route it to the engine,
         which pins the annotated result directly.
         */
        if Screenshot.shared.isTakingScreenshot {
            logInfo("[SnipTools] F3 routed to capture session pin")
            Screenshot.shared.finishCaptureAndPin()
            return
        }

        guard let image = NSPasteboard.general.image else {
            EZToast.showText(NSLocalizedString("snip_pasteboard_no_image", comment: ""))
            logWarn("[SnipTools] Pin skipped, no image in pasteboard")
            return
        }

        pin(image: image)
        logInfo("[SnipTools] Pinned pasteboard image")
    }

    /// Creates a pinned panel: exactly over `globalRect` when given (e.g.
    /// pinning a fresh capture back where it was taken), otherwise near the
    /// cursor with a cascade so stacked pins stay identifiable.
    func pin(image: NSImage, atGlobalRect globalRect: CGRect? = nil) {
        let panel = PinImagePanel(image: image)

        pins.append(panel)
        panel.state.onCloseRequest = { [weak self, weak panel] in
            guard let panel else { return }
            self?.remove(panel)
        }

        place(panel: panel, index: pins.count - 1, atGlobalRect: globalRect)
        panel.orderFrontRegardless()

        installEventMonitorsIfNeeded()
    }

    /// Closes one pinned panel and releases it fully.
    func remove(_ panel: PinImagePanel) {
        pins.removeAll { $0 === panel }
        panel.orderOut(nil)
        panel.close()

        if pins.isEmpty {
            removeEventMonitors()
        }
    }

    /// Closes every pinned panel.
    func closeAll() {
        let allPins = pins
        pins.removeAll()
        for panel in allPins {
            panel.orderOut(nil)
            panel.close()
        }
        removeEventMonitors()
    }

    // MARK: ESC close

    /// ESC closes the focused pin first, then the one under the cursor, and
    /// finally falls back to the newest one.
    func closePinOnESC() {
        if let focused = pins.first(where: { $0.isKeyWindow }) {
            remove(focused)
            return
        }

        let mouse = NSEvent.mouseLocation
        if let target = pins.last(where: { NSPointInRect(mouse, $0.frame) }) {
            remove(target)
        } else if let newest = pins.last {
            remove(newest)
        }
    }

    // MARK: Private

    /// Observer box handed to the C tap callback through its user-info pointer.
    private final class PinchTapBox {
        // MARK: Lifecycle

        init(onMagnify: @escaping (CGFloat) -> ()) {
            self.onMagnify = onMagnify
        }

        // MARK: Internal

        let onMagnify: (CGFloat) -> ()

        /// Observes one gesture event. The NSEvent conversion expands the raw
        /// CG gesture event into typed magnify/rotate/swipe events; only the
        /// magnify kind drives pin zoom.
        func deliver(_ event: NSEvent) {
            if event.type == .magnify, abs(event.magnification) > 0.0001 {
                onMagnify(event.magnification)
            }
            if Date().timeIntervalSince(lastGestureLogAt) > 1.5 {
                lastGestureLogAt = Date()
                let magnification = event.type == .magnify ? event.magnification : 0
                logInfo(
                    "[SnipTools] Gesture tap event, type=\(event.type.rawValue), subtype=\(event.subtype.rawValue), magnification=\(magnification)"
                )
            }
        }

        // MARK: Private

        /// Throttles gesture diagnostics to one line per 1.5s.
        private var lastGestureLogAt = Date.distantPast
    }

    private var pins: [PinImagePanel] = []

    /// Session-level event tap observing system-wide pinch gestures. This is
    /// the PRIMARY pinch channel: on current macOS, gesture events are only
    /// dispatched to the active app, so NSEvent monitors (local sees nothing
    /// while another app is active; the global one no longer sees gestures)
    /// miss the "pin over someone else's app" case entirely.
    private var pinchTap: CFMachPort?
    private var pinchTapSource: CFRunLoopSource?
    private var pinchTapBox: PinchTapBox?

    /// Last gesture diagnostics line timestamp, throttling tap logs.
    private var lastGestureLogAt = Date.distantPast

    /// Local monitor feeding trackpad pinch zooms. FALLBACK only — used when
    /// the session tap cannot be created (missing permission).
    private var magnifyMonitor: Any?

    /// Global twin of the magnify monitor (same fallback story).
    private var globalMagnifyMonitor: Any?

    /// Local monitor copying the focused pin on ⌘C, alive while pins exist.
    private var keyDownMonitor: Any?

    // MARK: Event monitors

    private func installEventMonitorsIfNeeded() {
        installPinchTapIfNeeded()
        installKeyDownMonitorIfNeeded()
    }

    private func removeEventMonitors() {
        removePinchTap()
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
            self.magnifyMonitor = nil
        }
        if let globalMagnifyMonitor {
            NSEvent.removeMonitor(globalMagnifyMonitor)
            self.globalMagnifyMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    /// Installs a listen-only session event tap for gesture events. Listen-only
    /// taps never modify or swallow events; they only observe, so this cannot
    /// interfere with the frontmost app's own gesture handling.
    private func installPinchTapIfNeeded() {
        guard pinchTap == nil else { return }

        let box = PinchTapBox { [weak self] magnification in
            MainActor.assumeIsolated {
                self?.handleSystemPinch(magnification: magnification)
            }
        }
        pinchTapBox = box
        let boxed = Unmanaged.passRetained(box)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // kCGEventGesture: the Swift CGEventType enum has no gesture case,
            // so compare raw values (29 = system gesture, magnify included).
            guard type.rawValue == 29, let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let unboxed = Unmanaged<PinchTapBox>.fromOpaque(userInfo).takeUnretainedValue()
            if let nsEvent = NSEvent(cgEvent: event) {
                unboxed.deliver(nsEvent)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << 29),
            callback: callback,
            userInfo: boxed.toOpaque()
        ) else {
            logWarn("[SnipTools] System pinch tap unavailable, falling back to NSEvent monitors")
            boxed.release()
            pinchTapBox = nil
            installMagnifyMonitorIfNeeded()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        pinchTap = tap
        pinchTapSource = source
        logInfo("[SnipTools] System pinch tap installed (session-level, listen-only)")
    }

    private func removePinchTap() {
        if let pinchTap {
            CGEvent.tapEnable(tap: pinchTap, enable: false)
            if let pinchTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), pinchTapSource, .commonModes)
            }
            CFMachPortInvalidate(pinchTap)
            self.pinchTap = nil
            pinchTapSource = nil
            pinchTapBox = nil
            logInfo("[SnipTools] System pinch tap removed")
        }
    }

    private func installMagnifyMonitorIfNeeded() {
        guard magnifyMonitor == nil else { return }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated {
                self.handleMagnify(event)
            }
            // Swallow handled gestures so the hosting view never zooms twice;
            // pass the rest through to the view-level backup path.
            return handled ? nil : event
        }
        globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.handleMagnify(event, source: "global")
            }
        }
        logInfo("[SnipTools] Pin magnify monitors installed (local + global)")
    }

    /*
     A focused pin's ⌘C must not fall through to the frontmost app's menu bar
     copy action, which would copy whatever that app has selected instead. A
     local keyDown monitor sits upstream of menu dispatch and sees keys only
     while a pin is the key window, so this stays scoped to pins.
     */
    private func installKeyDownMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }
        logInfo("[SnipTools] Pin keyDown monitor installed")
    }

    /// Zooms through the system tap channel: same target resolution as the
    /// NSEvent fallback, but sees gestures regardless of which app is active.
    private func handleSystemPinch(magnification: CGFloat) {
        guard !pins.isEmpty else { return }

        let mouse = NSEvent.mouseLocation
        let target = pins.last(where: { NSPointInRect(mouse, $0.frame) })
            ?? pins.first(where: { $0.isKeyWindow })
        guard let target else { return }

        target.zoom(by: 1 + magnification)
    }

    /// Handles ⌘C (copy) and ESC (close) over a focused pin; every other key
    /// passes through untouched. Only a focused pin is affected, so other apps
    /// keep their ESC — no more system-wide key hijack.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel = event.window as? PinImagePanel else { return event }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == kVK_Escape, flags.isEmpty {
            logInfo("[SnipTools] Pin closed via ESC")
            remove(panel)
            return nil
        }

        guard flags == .command, event.keyCode == kVK_ANSI_C else { return event }

        panel.state.image.writeToPasteboard()
        logInfo("[SnipTools] Pin image copied via ⌘C")
        return nil
    }

    /// Zooms the pin under the cursor by the pinch's incremental factor; when
    /// the cursor is elsewhere, the focused (key) pin is zoomed instead so a
    /// selected pin can be resized hands-off. Exactly one of the two monitors
    /// fires per gesture: the local one while our app is active, the global
    /// one while another app holds focus. Returns whether the pinch was used,
    /// so the local monitor can swallow handled events.
    @discardableResult
    private func handleMagnify(_ event: NSEvent, source: String = "local") -> Bool {
        guard abs(event.magnification) > 0.0001 else { return false }

        let mouse = NSEvent.mouseLocation
        let target = pins.last(where: { NSPointInRect(mouse, $0.frame) })
            ?? pins.first(where: { $0.isKeyWindow })

        guard let target else {
            if event.phase == .began {
                logInfo(
                    "[SnipTools] Pinch ignored, no pin under cursor or focused, pins=\(pins.count), source=\(source)"
                )
            }
            return false
        }

        if event.phase == .began {
            logInfo("[SnipTools] Pinch zoom began over pin, source=\(source)")
        }
        target.zoom(by: 1 + event.magnification)
        return true
    }

    private func place(panel: PinImagePanel, index: Int, atGlobalRect globalRect: CGRect?) {
        if let globalRect {
            panel.setFrameOrigin(globalRect.origin)
            return
        }

        // Cascade by half tile steps so stacked pins stay identifiable.
        let offset = CGFloat(index % 8) * 24
        let center = NSEvent.mouseLocation
        let origin = CGPoint(
            x: center.x - panel.frame.width / 2 + offset,
            y: center.y - panel.frame.height / 2 - offset
        )
        panel.setFrameOrigin(origin)
    }
}
