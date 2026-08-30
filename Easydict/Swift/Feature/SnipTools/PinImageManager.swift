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
        lastActivePanel = panel
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

    /// Marks that a pin's own view just handled a pinch, both for dedupe of
    /// the tap echo and to keep the "most recent" fallback fresh.
    func noteViewPinchHandled(on panel: PinImagePanel) {
        lastViewZoomAt = Date()
        lastActivePanel = panel
        throttlePinchLog("Pinch zoom over pin, source=view")
    }

    /// Records that the cursor re-keyed a pin on hover, refreshing the
    /// fallback target and leaving a breadcrumb for gesture diagnostics.
    func notePanelHoverKey(on panel: PinImagePanel) {
        lastActivePanel = panel
        throttlePinchLog("Pin re-keyed on hover")
    }

    /// Logs the click-to-activate gesture fix: a pin click brings the app
    /// forward so AppKit routes trackpad pinch frames to it.
    func notePanelActivation(wasActive: Bool) {
        logInfo("[SnipTools] Pin clicked, app activated, wasActive=\(wasActive), now=\(NSApp.isActive)")
    }

    #if DEBUG
    /// Headless verification, step 1: returns an existing pin, or pins a
    /// synthetic image and returns nil so the caller invokes again.
    func debugPinTarget() -> PinImagePanel? {
        if let existing = pins.last {
            return existing
        }
        let size = NSSize(width: 400, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8))
        border.lineWidth = 6
        border.stroke()
        image.unlockFocus()
        pin(image: image)
        logInfo("[SnipTools] debug-pinch pinned synthetic image")
        return nil
    }

    /// Headless verification, step 2: drives the production zoom path and
    /// logs before/after scale plus frame so scripts can assert the change.
    func applyDebugPinch(to panel: PinImagePanel, magnification: CGFloat) {
        let before = panel.state.scale
        let frameBefore = panel.frame
        panel.zoom(by: 1 + magnification)
        logInfo(
            "[SnipTools] debug-pinch applied, scale \(String(format: "%.3f", before))->\(String(format: "%.3f", panel.state.scale)), frame \(NSStringFromRect(frameBefore))->\(NSStringFromRect(panel.frame))"
        )
    }
    #endif

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
            dumpGestureFieldsOnce(event)
            if event.type == .magnify, abs(event.magnification) > 0.005 {
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

        /// One-shot probe: the first three gesture frames get every nonzero
        /// CGEvent field dumped. If macOS hides the real pinch delta in a raw
        /// field instead of exposing it through NSEvent, this finds it and
        /// the tap channel reads it directly; all zeros proves the system
        /// never hands gesture data to third-party taps.
        private var remainingFieldDumps = 3

        private func dumpGestureFieldsOnce(_ event: NSEvent) {
            guard remainingFieldDumps > 0 else { return }
            guard event.type.rawValue == 29 || event.type.rawValue == 30 else { return }
            guard let cg = event.cgEvent else { return }
            remainingFieldDumps -= 1

            var nonzero = ""
            for raw in 0 ... 160 {
                // C layer looks fields up by number; unknown numbers just
                // read 0. CGEventField is a 4-byte C enum, so the raw index
                // must be narrowed first or unsafeBitCast aborts the process.
                let field = unsafeBitCast(UInt32(raw), to: CGEventField.self)
                let value = cg.getDoubleValueField(field)
                if value != 0 {
                    nonzero += "f\(raw)=\(String(format: "%.4f", value)) "
                }
            }
            logInfo(
                "[SnipTools] Gesture frame probe, type=\(event.type.rawValue): \(nonzero.isEmpty ? "ALL ZERO" : nonzero)"
            )
        }
    }

    private var pins: [PinImagePanel] = []

    /// Listen-only event taps at every gesture observation point (session,
    /// annotated-session, HID). Gesture data frames proved unreliable on the
    /// session tap alone; whichever layer carries them wins and the echo
    /// window in handleSystemPinch dedupes the rest.
    private var pinchTaps: [CFMachPort] = []
    private var pinchTapSources: [CFRunLoopSource] = []
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

    /// Most recently pinned or zoomed pin. A pinch with no cursor hit and no
    /// focused pin falls back to it instead of doing nothing.
    private var lastActivePanel: PinImagePanel?

    /// Throttles pinch diagnostic logging to one line per second.
    private var lastPinchLogAt = Date.distantPast

    /// Dedupe window: when a pin's own view just zoomed a routed gesture,
    /// the tap echo of the same gesture is skipped for this long.
    private var lastViewZoomAt = Date.distantPast

    /// Echo window between parallel tap points observing one gesture.
    private var lastTapZoomAt = Date.distantPast

    /// Periodic health probe for the session tap; rebuilds it when the
    /// system has silently disabled or invalidated the Mach port.
    private var pinchHealthTimer: Timer?

    /// Rebuilds the session gesture tap after sleep/wake cycles — the system
    /// can stop delivering gesture events to a session tap across wake, which
    /// used to leave pinch dead until relaunch.
    private var wakeObserver: NSObjectProtocol?

    // MARK: Event monitors

    private func installEventMonitorsIfNeeded() {
        installPinchTapIfNeeded()
        installKeyDownMonitorIfNeeded()
        installWakeObserverIfNeeded()
        ensurePinchHealthTimer()
    }

    private func removeEventMonitors() {
        removePinchTap()
        pinchHealthTimer?.invalidate()
        pinchHealthTimer = nil
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

    /// Probes the session tap every 30s: the query form of tapEnable returns
    /// whether the system still considers the tap enabled. A dead tap is
    /// rebuilt immediately instead of staying silent until the next pin.
    private func ensurePinchHealthTimer() {
        guard pinchHealthTimer == nil else { return }
        pinchHealthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPinchTapHealth()
            }
        }
    }

    private func checkPinchTapHealth() {
        guard !pinchTaps.isEmpty else { return }
        let healthy = pinchTaps.contains { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) }
        if !healthy {
            logWarn("[SnipTools] Pinch taps unhealthy, rebuilding all")
            removePinchTap()
            installPinchTapIfNeeded()
        }
    }

    /// Watches wake notifications so a dead session tap is rebuilt on the
    /// next pin install instead of staying silent until relaunch.
    private func installWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.pins.isEmpty else { return }
                logInfo("[SnipTools] System woke, rebuilding pinch tap")
                self.removePinchTap()
                self.installPinchTapIfNeeded()
            }
        }
    }

    /// Installs listen-only event taps for gesture events at every available
    /// observation point. The session tap proved unreliable for gesture data
    /// frames (boundary notices arrive, per-frame magnify deltas often do
    /// not), so the annotated-session and HID points are armed as well —
    /// whichever layer actually carries the frames wins; the echo window in
    /// handleSystemPinch dedupes the rest. Listen-only taps never modify or
    /// swallow events.
    private func installPinchTapIfNeeded() {
        guard pinchTaps.isEmpty else { return }

        let box = PinchTapBox { [weak self] magnification in
            MainActor.assumeIsolated {
                self?.handleSystemPinch(magnification: magnification)
            }
        }
        pinchTapBox = box
        let boxed = Unmanaged.passRetained(box)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            /*
             Two distinct CG event types carry pinch data: 29 (.gesture) is a
             boundary notice with magnification always 0, and 30 (.magnify)
             carries the actual per-frame zoom delta. Listening to 29 alone
             was why the tap saw "a gesture happened" but never how much.
             The Swift CGEventType enum has no cases for either, so compare
             raw values.
             */
            guard type.rawValue == 29 || type.rawValue == 30, let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let unboxed = Unmanaged<PinchTapBox>.fromOpaque(userInfo).takeUnretainedValue()
            if let nsEvent = NSEvent(cgEvent: event) {
                unboxed.deliver(nsEvent)
            }
            return Unmanaged.passUnretained(event)
        }

        // Ordered from most to least likely to carry gesture frames.
        let tapPoints: [CGEventTapLocation] = [
            .cgSessionEventTap, .cgAnnotatedSessionEventTap, .cghidEventTap,
        ]
        var installed = 0
        for tapPoint in tapPoints {
            guard let tap = CGEvent.tapCreate(
                tap: tapPoint,
                place: .headInsertEventTap,
                options: .listenOnly,
                // 29 = gesture boundary notice, 30 = magnify data frames.
                eventsOfInterest: CGEventMask((1 << 29) | (1 << 30)),
                callback: callback,
                userInfo: boxed.toOpaque()
            ) else {
                logWarn("[SnipTools] Pinch tap unavailable at \(tapPoint.rawValue)")
                continue
            }

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            pinchTaps.append(tap)
            if let source {
                pinchTapSources.append(source)
            }
            installed += 1
        }

        if installed == 0 {
            logWarn("[SnipTools] All pinch taps unavailable, falling back to NSEvent monitors")
            boxed.release()
            pinchTapBox = nil
            installMagnifyMonitorIfNeeded()
            return
        }
        logInfo("[SnipTools] Pinch taps installed, points=\(installed)/\(tapPoints.count)")
    }

    private func removePinchTap() {
        for tap in pinchTaps {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        for source in pinchTapSources {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        pinchTaps.removeAll()
        pinchTapSources.removeAll()
        pinchTapBox = nil
        if !pinchTaps.isEmpty || !pinchTapSources.isEmpty { return }
        logInfo("[SnipTools] System pinch tap removed")
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

    /// Zooms through the tap channels: covers gestures the pin's own view
    /// never sees (cursor away from pins, app inactive).
    private func handleSystemPinch(magnification: CGFloat) {
        guard !pins.isEmpty else { return }
        // A gesture routed to a pin's own view already zoomed it; skip the
        // tap echo inside the dedupe window.
        guard Date().timeIntervalSince(lastViewZoomAt) > 0.25 else { return }
        // Parallel taps observe the same gesture; the first arrival wins.
        guard Date().timeIntervalSince(lastTapZoomAt) > 0.05 else { return }

        guard let target = resolvePinTarget() else {
            throttlePinchLog("Pinch ignored, no pin resolved, pins=\(pins.count), source=tap")
            return
        }

        lastTapZoomAt = Date()
        let before = target.state.scale
        target.zoom(by: 1 + magnification)
        throttlePinchLog(
            "Pinch zoom over pin, source=tap, scale \(String(format: "%.2f", before))->\(String(format: "%.2f", target.state.scale))"
        )
    }

    /// Picks which pin a pinch/zoom gesture drives: the pin under the cursor
    /// first, then the focused (key) pin, then the most recently active pin.
    /// The last fallback matters — after clicking away, no pin is key and the
    /// cursor is usually elsewhere, which users experienced as "pinch works
    /// only sometimes".
    private func resolvePinTarget() -> PinImagePanel? {
        let mouse = NSEvent.mouseLocation
        let target = pins.last(where: { NSPointInRect(mouse, $0.frame) })
            ?? pins.first(where: { $0.isKeyWindow })
        if let target {
            lastActivePanel = target
            return target
        }
        // The fallback must never resurrect a closed panel.
        if let last = lastActivePanel, pins.contains(last) {
            return last
        }
        lastActivePanel = nil
        return nil
    }

    /// One diagnostic line per pinch gesture at most, shared by both channels.
    private func throttlePinchLog(_ message: String) {
        guard Date().timeIntervalSince(lastPinchLogAt) > 1.0 else { return }
        lastPinchLogAt = Date()
        logInfo("[SnipTools] \(message)")
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

        guard let target = resolvePinTarget() else {
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
