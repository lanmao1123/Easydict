//
//  PinImageManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon
import os.log

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
         editor's local key monitor can see it, so this is the ONLY path that
         runs for F3 during editing: route it to the editor, which pins the
         annotated result directly.
         */
        if Screenshot.shared.editModeEnabled,
           let editor = Screenshot.shared.activeAnnotationEditor {
            Self.log.info("[SnipTools] F3 routed to annotation editor pin")
            editor.pinAndFinish()
            return
        }

        guard let image = NSPasteboard.general.image else {
            EZToast.showText(NSLocalizedString("snip_pasteboard_no_image", comment: ""))
            Self.log.warning("[SnipTools] Pin skipped, no image in pasteboard")
            return
        }

        pin(image: image)
        Self.log.info("[SnipTools] Pinned pasteboard image")
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

        installESCHotKeyIfNeeded()
        installMagnifyMonitorIfNeeded()
    }

    /// Closes one pinned panel and releases it fully.
    func remove(_ panel: PinImagePanel) {
        pins.removeAll { $0 === panel }
        panel.orderOut(nil)
        panel.close()

        if pins.isEmpty {
            removeESCHotKey()
            removeMagnifyMonitor()
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
        removeESCHotKey()
        removeMagnifyMonitor()
    }

    // MARK: ESC close

    /// ESC closes the pin under the cursor, falling back to the newest one.
    func closePinOnESC() {
        let mouse = NSEvent.mouseLocation
        if let target = pins.last(where: { NSPointInRect(mouse, $0.frame) }) {
            remove(target)
        } else if let newest = pins.last {
            remove(newest)
        }
    }

    // MARK: Private

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Easydict", category: "SnipTools")

    private static let escHotKeyIdentifier = "com.izual.Easydict.pinESC"

    private var pins: [PinImagePanel] = []

    private var escHotKeyActive = false

    /// Local monitor feeding trackpad pinch zooms, alive while pins exist.
    private var magnifyMonitor: Any?

    /// Registers a Carbon ESC hotkey while pins exist. Pins never become key
    /// windows, and NSEvent global key monitors require accessibility
    /// permission — Carbon hotkeys need none.
    private func installESCHotKeyIfNeeded() {
        guard !escHotKeyActive else { return }

        FunctionKeyHotKeyCenter.register(
            identifier: Self.escHotKeyIdentifier,
            keyCode: kVK_Escape
        ) { [weak self] in
            self?.handleESC()
        }
        escHotKeyActive = true
    }

    private func removeESCHotKey() {
        guard escHotKeyActive else { return }

        FunctionKeyHotKeyCenter.unregister(identifier: Self.escHotKeyIdentifier)
        escHotKeyActive = false
    }

    // MARK: Trackpad pinch zoom

    /*
     SwiftUI internals swallow `magnify` events inside the hosting view, so
     subclass overrides never see them. This local monitor sits upstream of
     view dispatch and zooms the pin under the cursor directly.
     */
    private func installMagnifyMonitorIfNeeded() {
        guard magnifyMonitor == nil else { return }

        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.handleMagnify(event)
            }
            return event
        }
        Self.log.info("[SnipTools] Pin magnify monitor installed")
    }

    private func removeMagnifyMonitor() {
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
            self.magnifyMonitor = nil
        }
    }

    /// Zooms the pin under the cursor by the pinch's incremental factor.
    private func handleMagnify(_ event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        guard let target = pins.last(where: { NSPointInRect(mouse, $0.frame) }),
              abs(event.magnification) > 0.0001 else { return }

        if event.phase == .began {
            Self.log.info("[SnipTools] Pinch zoom began over pin")
        }
        target.zoom(by: 1 + event.magnification)
    }

    /// ESC routing: the hotkey consumed the key system-wide, so when a
    /// capture session is running reproduce its ESC behavior (discard text
    /// draft / cancel capture); otherwise close the pin under the cursor.
    private func handleESC() {
        if Screenshot.shared.isTakingScreenshot {
            if let editor = Screenshot.shared.activeAnnotationEditor,
               editor.textDraftPoint != nil {
                editor.commitText("")
            } else {
                Screenshot.shared.finishCapture(nil)
            }
            return
        }
        closePinOnESC()
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
