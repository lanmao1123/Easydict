//
//  Screenshot.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/12.
//  Copyright © 2025 izual. All rights reserved.
//
//  Capture engine ported from the macshot project. The public surface keeps
//  the legacy ObjC contract (startCaptureWithCompletion / finishCapture /
//  isTakingScreenshot / shouldRestorePreviousApp / editModeEnabled) so the
//  existing OCR and dock-translate callers keep working unchanged.
//

import AppKit

// MARK: - Screenshot

@objc
@MainActor
final class Screenshot: NSObject {
    // MARK: Lifecycle

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    // MARK: Public

    @objc public static let shared = Screenshot()

    @objc public private(set) var isTakingScreenshot = false

    /// Legacy toggle. The ported engine never activates the app (nonactivating
    /// panels), so there is no focus to hand back; the value is still accepted
    /// from callers for API compatibility.
    @objc public var shouldRestorePreviousApp = false

    /// When true, the next capture parks on the overlay for annotation editing
    /// (F1 flow). When false, the composited image is handed to the completion
    /// right after selection (OCR / dock-translate flows).
    @objc public var editModeEnabled = false

    @objc public private(set) var hasRequestedPermission: Bool {
        get { UserDefaults.standard.bool(forKey: "easydict.screenshot.hasRequestedPermission") }
        set { UserDefaults.standard.set(newValue, forKey: "easydict.screenshot.hasRequestedPermission") }
    }

    /// Legacy ObjC entry point; no preset frames involved.
    @objc
    public func startCapture(completion: @escaping (NSImage?) -> ()) {
        startCapture(presetFrozenImages: [:], completion: completion)
    }

    /// Starts a capture session. `presetFrozenImages` carries frames captured
    /// while a menu was still on screen (menu-safe hotkey channel); screens
    /// with a preset use it instead of the fresh capture so menu content
    /// survives into the shot.
    public func startCapture(
        presetFrozenImages: [NSScreen: NSImage] = [:],
        completion: @escaping (NSImage?) -> ()
    ) {
        if isTakingScreenshot {
            logInfo("startCapture rejected, capture already in progress")
            completion(nil)
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            logInfo("startCapture rejected, screen capture permission missing")
            if !hasRequestedPermission {
                hasRequestedPermission = true
                // Prompts only once; if denied the user must enable it manually.
                CGRequestScreenCaptureAccess()
            } else {
                showScreenCapturePermissionAlert()
            }
            completion(nil)
            return
        }

        // Consume the edit flag up front — the session mode lives in
        // pendingMode from here on, so a cancelled start can't leak it.
        pendingMode = editModeEnabled ? .edit : .hostImage
        editModeEnabled = false
        let mode = pendingMode
        isTakingScreenshot = true
        logInfo("startCapture began, mode=\(mode), presetScreens=\(presetFrozenImages.count)")
        self.presetFrozenImages = presetFrozenImages
        captureCompletionHandler = completion

        /*
         A stray press on F2 right next to F1 can pop the clipboard panel at
         the last moment; it would then sit over the screenshot. Close it.
         */
        ClipboardManager.shared.hidePanel()

        // Clean up stale overlays from a previous session. This must NOT touch
        // isTakingScreenshot/captureSessionID — the session just went live.
        dismissStaleOverlays()

        // Hide our own titled windows (settings) so they stay out of the shot.
        stashBackgroundWindows()

        let screens = NSScreen.screens
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = screens.first { $0.frame.contains(mouseLocation) }
        let captureContext = ScreenCaptureManager.makeImmediateCaptureContext()
        let sessionID = captureSessionID

        // Pull (don't construct) overlay controllers from the persistent pool.
        var controllers: [OverlayWindowController] = []
        for screen in screens {
            let controller = pooledController(for: screen)
            controller.overlayDelegate = self
            controller.capturedWindowTitle = nil
            if case .hostImage = mode {
                controller.setAutoHostImageMode()
            }
            controllers.append(controller)
        }
        activeControllers = controllers

        // Freeze the screens in the background; CGWindowListCreateImage keeps
        // transient UI (menu extras, app menus) that SCK may drop. Window
        // setup above already ran in parallel on the main thread.
        logInfo("capture task dispatched, session=\(sessionID)")
        Task {
            var captures: [ScreenCapture]? = nil
            if #available(macOS 14.0, *) {
                captures = await ScreenCaptureManager.captureAllScreensImmediatelySCK()
            }
            let finalCaptures = captures ?? ScreenCaptureManager.captureAllScreensImmediately(context: captureContext)
            logInfo("background capture done, sck=\(captures != nil), count=\(finalCaptures.count)")
            await MainActor.run {
                guard self.isTakingScreenshot, self.captureSessionID == sessionID else {
                    logWarn("stale capture dropped, session=\(sessionID), current=\(self.captureSessionID)")
                    return
                }
                self.installAndShowOverlays(captures: finalCaptures, controllers: controllers, mouseScreen: mouseScreen)
            }
        }
    }

    /// Legacy ObjC cancel/finish hook: tears the session down with no image.
    @objc
    public func finishCapture(_ image: NSImage?) {
        logInfo("finishCapture, image=\(image.map { "\($0.size)" } ?? "nil")")
        // The mode flag lives for exactly one capture, success or not; a
        // stale `true` would flip the next OCR capture into edit mode.
        editModeEnabled = false
        dismissOverlays()
        restoreBackgroundWindowsNow()

        let handler = captureCompletionHandler
        captureCompletionHandler = nil
        presetFrozenImages = [:]
        pendingMode = nil
        handler?(image)
    }

    // MARK: Internal

    /// Selection rect in top-left screen-local coordinates, persisted like the
    /// legacy engine so ScreenshotDockManager can place its panel.
    var lastScreenshotRect: CGRect {
        get {
            guard let string = UserDefaults.standard.string(forKey: "easydict.screenshot.lastScreenshotRect") else {
                return .zero
            }
            return NSRectFromString(string)
        }
        set {
            UserDefaults.standard.set(NSStringFromRect(newValue), forKey: "easydict.screenshot.lastScreenshotRect")
        }
    }

    var lastScreen: NSScreen? {
        get {
            guard let description = UserDefaults.standard.string(forKey: "easydict.screenshot.lastScreen") else {
                return nil
            }
            return NSScreen.screens.first { $0.deviceDescriptionString == description }
        }
        set {
            UserDefaults.standard.set(newValue?.deviceDescriptionString, forKey: "easydict.screenshot.lastScreen")
        }
    }

    /// F3 during an editing session: pin the annotated result directly.
    /// Routes through the overlay's own pin exit so annotations are baked in.
    func finishCaptureAndPin() {
        guard isTakingScreenshot, let primary = primaryController() else {
            finishCapture(nil)
            return
        }
        primary.overlayViewDidRequestPin()
    }

    // MARK: Private

    private enum CaptureMode {
        case edit
        case hostImage
    }

    /// Persistent per-screen overlay pool: each panel's CGSWindow stays alive
    /// in WindowServer so the next capture appears instantly.
    private var overlayControllerPool: [ObjectIdentifier: OverlayWindowController] = [:]
    private var activeControllers: [OverlayWindowController] = []
    private var captureCompletionHandler: ((NSImage?) -> ())?
    private var pendingMode: CaptureMode?
    private var presetFrozenImages: [NSScreen: NSImage] = [:]
    private var captureSessionID: UInt = 0
    private var stashedBackgroundWindows: [NSWindow] = []

    private func pooledController(for screen: NSScreen) -> OverlayWindowController {
        if let existing = overlayControllerPool[ObjectIdentifier(screen)] {
            return existing
        }
        let controller = OverlayWindowController(screen: screen)
        overlayControllerPool[ObjectIdentifier(screen)] = controller
        controller.warmPanel()
        return controller
    }

    private func installAndShowOverlays(
        captures: [ScreenCapture],
        controllers: [OverlayWindowController],
        mouseScreen: NSScreen?
    ) {
        guard !captures.isEmpty else {
            logWarn("no captures returned, bailing out")
            finishCapture(nil)
            return
        }

        var capturesByScreen: [NSScreen: CGImage] = captures.reduce(into: [:]) { result, capture in
            result[capture.screen] = capture.image
        }
        // Menu-safe channel presets win: they contain the still-open menu.
        for (screen, preset) in presetFrozenImages {
            if let cgImage = preset.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                capturesByScreen[screen] = cgImage
            }
        }

        for controller in controllers {
            if let image = capturesByScreen[controller.screen] {
                controller.setScreenshot(image)
            }
            controller.showOverlay()
        }
    }

    private func primaryController() -> OverlayWindowController? {
        activeControllers.first { $0.selectionRect.width >= 1 && $0.selectionRect.height >= 1 }
            ?? activeControllers.first
    }

    /// Tears the session down: clears the live flag, invalidates in-flight
    /// capture tasks and returns overlay panels to the pool.
    private func dismissOverlays() {
        isTakingScreenshot = false
        captureSessionID &+= 1
        dismissStaleOverlays()
    }

    /// Returns overlay panels to the pool without touching session state —
    /// used both at teardown and when a new session reuses stale overlays.
    private func dismissStaleOverlays() {
        for controller in activeControllers {
            controller.dismiss()
        }
        activeControllers.removeAll()
    }

    private func stashBackgroundWindows() {
        stashedBackgroundWindows.removeAll()
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            stashedBackgroundWindows.append(window)
            window.orderOut(nil)
        }
    }

    private func restoreBackgroundWindowsNow() {
        for window in stashedBackgroundWindows {
            window.orderBack(nil)
        }
        stashedBackgroundWindows.removeAll()
    }

    @objc
    private func screenParametersDidChange() {
        guard !isTakingScreenshot else { return }
        for (_, controller) in overlayControllerPool {
            controller.tearDown()
        }
        overlayControllerPool.removeAll()
    }

    /// Records the finished selection for ScreenshotDockManager, converting
    /// the engine's bottom-left local rect into the legacy top-left form.
    private func recordSelection(from controller: OverlayWindowController) {
        let selection = controller.selectionRect
        guard selection.width > 1, selection.height > 1 else { return }
        lastScreen = controller.screen
        let screenHeight = controller.screen.frame.height
        lastScreenshotRect = CGRect(
            x: selection.minX,
            y: screenHeight - selection.maxY,
            width: selection.width,
            height: selection.height
        )
    }
}

// MARK: OverlayWindowControllerDelegate

extension Screenshot: OverlayWindowControllerDelegate {
    func overlayDidCancel(_ controller: OverlayWindowController) {
        finishCapture(nil)
    }

    /// Edit-mode exit: the engine already copied the composited image.
    func overlayDidConfirm(
        _ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?
    ) {
        recordSelection(from: controller)
        finishCapture(capturedImage)
    }

    /// Host-driven exit (OCR / dock-translate): deliver the image untouched —
    /// the host owns the pasteboard afterwards.
    func overlayDidRequestHostImage(_ controller: OverlayWindowController, image: NSImage) {
        recordSelection(from: controller)
        finishCapture(image)
    }

    /// F3 inside an editing session: pin through the host pin manager.
    func overlayDidRequestPin(
        _ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?
    ) {
        recordSelection(from: controller)
        PinImageManager.shared.pin(image: image)
        finishCapture(nil)
    }

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        let others = activeControllers.filter {
            $0 !== controller && $0.remoteSelectionRect.width >= 1 && $0.remoteSelectionRect.height >= 1
        }
        guard !others.isEmpty else { return nil }
        return stitchCrossScreenCapture(primary: controller, others: others)
    }

    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        for other in activeControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
    }

    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in activeControllers where other !== controller {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(
                x: globalRect.origin.x - otherOrigin.x,
                y: globalRect.origin.y - otherOrigin.y,
                width: globalRect.width, height: globalRect.height
            )
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        guard let primary = activeControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else {
            return
        }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(
            x: globalRect.origin.x - primaryOrigin.x,
            y: globalRect.origin.y - primaryOrigin.y,
            width: globalRect.width, height: globalRect.height
        )
        primary.applySelection(primaryLocal)

        for other in activeControllers where other !== controller && other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(
                x: globalRect.origin.x - otherOrigin.x,
                y: globalRect.origin.y - otherOrigin.y,
                width: globalRect.width, height: globalRect.height
            )
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {
        guard let primary = activeControllers.first(where: { $0 !== controller && $0.selectionRect.width >= 1 }) else {
            return
        }
        let primaryOrigin = primary.screen.frame.origin
        let primaryLocal = NSRect(
            x: globalRect.origin.x - primaryOrigin.x,
            y: globalRect.origin.y - primaryOrigin.y,
            width: globalRect.width, height: globalRect.height
        )
        primary.applySelection(primaryLocal)
        primary.makeKey()

        let primarySel = primary.selectionRect
        let primaryGlobal = NSRect(
            x: primarySel.origin.x + primaryOrigin.x,
            y: primarySel.origin.y + primaryOrigin.y,
            width: primarySel.width, height: primarySel.height
        )
        for other in activeControllers where other !== primary {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(
                x: primaryGlobal.origin.x - otherOrigin.x,
                y: primaryGlobal.origin.y - otherOrigin.y,
                width: primaryGlobal.width, height: primaryGlobal.height
            )
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }

    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController) {
        for other in activeControllers where other !== controller {
            other.triggerRedraw()
        }
    }

    // MARK: Exits and features not wired into this port.

    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {
        // The toolbar OCR exit is unused; the host flows deliver images
        // through overlayDidRequestHostImage instead.
        finishCapture(nil)
    }

    func overlayDidRequestUpload(
        _ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?
    ) {
        finishCapture(nil)
    }

    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}

    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {}

    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}

    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {}

    func overlayDidRequestCancelScrollCapture(_ controller: OverlayWindowController) {}

    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {}

    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {}

    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {}

    // MARK: Cross-screen stitching

    /// Stitches the selection across screens into one image (multi-monitor).
    private func stitchCrossScreenCapture(
        primary: OverlayWindowController, others: [OverlayWindowController]
    )
        -> NSImage? {
        let primaryOrigin = primary.screen.frame.origin
        let primarySelRect = primary.selectionRect
        let globalRect = NSRect(
            x: primarySelRect.origin.x + primaryOrigin.x,
            y: primarySelRect.origin.y + primaryOrigin.y,
            width: primarySelRect.width, height: primarySelRect.height
        )

        let scale: CGFloat
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = primary.screen.backingScaleFactor
        }

        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        let cs: CGColorSpace
        if let screenshot = primary.screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        guard pixelW > 0, pixelH > 0,
              let cgCtx = CGContext(
                  data: nil, width: pixelW, height: pixelH,
                  bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        cgCtx.scaleBy(x: scale, y: scale)

        for controller in [primary] + others {
            guard let screenshot = controller.screenshotImage else { continue }
            let screenFrame = controller.screen.frame
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)

            cgCtx.saveGState()
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }
}

// MARK: - Permission Alert

extension Screenshot {
    /// Alerts the user when screen capture permission is missing after a
    /// previous prompt was denied.
    func showScreenCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("need_screen_capture_permission", comment: "")
        alert.informativeText = NSLocalizedString(
            "request_screen_capture_access_description", comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("open_system_settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
