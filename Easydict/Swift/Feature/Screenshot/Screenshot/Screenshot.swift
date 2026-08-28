//
//  Screenshot.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/12.
//  Copyright © 2025 izual. All rights reserved.
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Screenshot

@objc
class Screenshot: NSObject {
    // MARK: Public

    @objc public static let shared = Screenshot()

    @objc public private(set) var isTakingScreenshot = false
    @objc public var shouldRestorePreviousApp = false

    /// Legacy ObjC entry point; no preset frames involved.
    @objc
    public func startCapture(completion: @escaping (NSImage?) -> ()) {
        startCapture(presetFrozenImages: [:], completion: completion)
    }

    @objc
    public func startCapture(
        presetFrozenImages: [NSScreen: NSImage] = [:],
        completion: @escaping (NSImage?) -> ()
    ) {
        if isTakingScreenshot {
            logInfo("startCapture rejected, capture already in progress")
            completion(nil)
            return
        }

        let hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
        if !hasScreenCapturePermission {
            logInfo("startCapture rejected, screen capture permission missing")
            if !hasRequestedPermission {
                hasRequestedPermission = true
                /**
                 This method will prompt to get screen capture access if not already granted only once.

                 If you trigger the prompt and the user `denies` it, you cannot bring up the prompt again - the user must manually enable it in System Preferences.
                 */
                CGRequestScreenCaptureAccess()
            } else {
                showScreenCapturePermissionAlert()
            }
            completion(nil)
            return
        }

        isTakingScreenshot = true
        captureStartedAt = Date()
        logInfo("startCapture began, presetScreens=\(presetFrozenImages.count), editMode=\(editModeEnabled)")

        /*
         The overlay is app-modal: once another application takes focus, the
         session's ⌘C/Enter/ESC shortcuts would land in the frontmost app
         instead, so the user "copies" someone else's selection while the
         frozen overlay still covers the screen. End the session on resign.
         */
        observeResignActiveDuringCapture()

        /*
         A stray press on F2 right next to F1 can pop the clipboard panel at
         the last moment; it would then sit over the screenshot, since both
         live in this same app and hidesOnDeactivate never fires. Close it.
         */
        MainActor.assumeIsolated {
            ClipboardManager.shared.hidePanel()
        }

        pushCrosshairCursor()
        setupEventMonitor()
        showOverlayWindow(presetFrozenImages: presetFrozenImages, completion: completion)
    }

    // MARK: Internal

    /// When true, the next capture enters annotation editing after selection
    /// instead of returning the image immediately. Session-scoped: always reset
    /// in `finishCapture`, so unrelated shortcuts keep the classic behavior.
    var editModeEnabled = false

    var overlayWindows: [NSScreen: NSWindow] = [:]
    var overlayViewStates: [NSScreen: ScreenshotState] = [:]

    var eventMonitor: Any?

    /// Work item for the delayed screenshot capture after pressing 'D' for preview.
    var previewScreenshotWorkItem: DispatchWorkItem?

    /// The annotation editor of the ongoing editing session, if any.
    var activeAnnotationEditor: AnnotationEditorState? {
        guard editModeEnabled else { return nil }
        let screen = lastScreen ?? NSScreen.currentMouseScreen()
        guard let screen else { return nil }
        return overlayViewStates[screen]?.annotationEditor
    }

    /// The editing rect converted to AppKit global coordinates (bottom-left
    /// origin), so the annotated image can be pinned exactly over the spot
    /// it was captured from.
    var editingGlobalRect: CGRect? {
        guard let screen = lastScreen,
              let rect = overlayViewStates[screen]?.editingRect,
              !rect.isEmpty else { return nil }
        return CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Finish screenshot capture and call the completion handler
    @objc
    func finishCapture(_ image: NSImage?) {
        // Cancel any pending preview screenshot task first
        cancelPreviewScreenshotTimer()

        // The session flag lives for exactly one capture, success or not.
        editModeEnabled = false

        isTakingScreenshot = false
        captureStartedAt = nil
        removeResignActiveObserver()
        logInfo("finishCapture, image=\(image != nil ? "\(image!.size)" : "nil")")
        popCrosshairCursor()

        // Restore focus to previous application only if shouldRestorePreviousApp is true
        if shouldRestorePreviousApp, let previousApp = previousActiveApp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previousApp.activate()
            }
        }

        previousActiveApp = nil

        // Call the original completion handler
        logInfo("finishCapture invoking completion handler")
        captureCompletionHandler?(image)
        captureCompletionHandler = nil

        hideAllOverlayWindows()
        removeEventMonitor()
        tearDownOverlayStates()
    }

    /// Cancels the scheduled preview screenshot task, if any.
    func cancelPreviewScreenshotTimer() {
        previewScreenshotWorkItem?.cancel()
        previewScreenshotWorkItem = nil
    }

    /// Performs the actual screenshot operation asynchronously.
    /// - Parameters:
    ///   - screen: The screen to capture from.
    ///   - rect: The rectangle area to capture within the screen coordinates.
    func performScreenshot(screen: NSScreen, rect: CGRect) {
        logInfo("performing screenshot, screen=\(screen.localizedName), rect=\(rect)")

        // Save last screenshot rect and screen
        lastScreenshotRect = rect
        lastScreen = screen

        /*
         Editing mode parks this capture session on the overlay instead of
         finishing it: the dark overlay stays hidden, ESC keeps its fallback,
         and annotation editing ends through `completeEditing`.
         */
        if editModeEnabled {
            logInfo("performScreenshot entering edit mode, rect=\(rect)")
            overlayViewStates[screen]?.beginEditing(inRect: rect)
            return
        }

        // Reset the state for the specific screen to hide selection UI etc.
        overlayViewStates[screen]?.reset()

        /*
         The frame frozen before the overlay appeared is exactly the clean
         shot — cropping it finishes instantly and cannot contain any of our
         overlay UI, unlike the previous re-shoot after a 0.1 s wait.
         */
        let image = overlayViewStates[screen]?.frozenDisplayImage
            .flatMap { screen.croppedScreenshot(from: $0, rect: rect) }
            ?? screen.takeScreenshot(rect: rect)
        logInfo(
            "performScreenshot produced image, rect=\(rect), source=\(image != nil ? "ok" : "FAILED"), editMode=\(editModeEnabled)"
        )
        finishCapture(image)
    }

    /// Completes annotation editing: hides overlays and fires the completion
    /// handler exactly like a regular capture, with `image` or nil to cancel.
    func completeEditing(with image: NSImage?) {
        logInfo("completeEditing, image=\(image != nil ? "\(image!.size)" : "nil(cancel)")")
        if let screen = lastScreen {
            overlayViewStates[screen]?.endEditing()
        }
        finishCapture(image)
    }

    /// The clean, un-annotated screenshot covering the editing rect.
    func captureEditedBaseImage() -> NSImage? {
        guard let screen = lastScreen,
              let rect = overlayViewStates[screen]?.editingRect,
              !rect.isEmpty else {
            logWarn("captureEditedBaseImage aborted, no editing rect")
            return nil
        }
        // Crop the frame frozen at capture start — instant, versus a fresh
        // full-display CGDisplayCreateImage on every ⌘C / mosaic stroke.
        if let frozen = overlayViewStates[screen]?.frozenDisplayImage,
           let cropped = screen.croppedScreenshot(from: frozen, rect: rect) {
            return cropped
        }
        return screen.takeScreenshot(rect: rect)
    }

    /// Restores the real pointer during annotation editing: the crosshair
    /// overlay no longer draws there, and hide() alone left customized-pointer
    /// users with no visible cursor for toolbar clicks.
    func restorePointerForEditing() {
        popCrosshairCursor()
    }

    // MARK: Private

    /// Dismissing our own menu (the menu-safe hotkey path posts an in-place
    /// click) bounces focus right after the overlay appears; that bounce must
    /// not cancel the session the user just started.
    private static let resignActiveGracePeriod: TimeInterval = 1.0

    /// The completion handler passed from startCapture.
    private var captureCompletionHandler: ((NSImage?) -> ())?

    private var previousActiveApp: NSRunningApplication?

    /// Cancels the capture session when the app loses focus; see startCapture.
    private var resignActiveObserver: (any NSObjectProtocol)?

    /// When the session began; backs the resign-active grace period.
    private var captureStartedAt: Date?

    /// Tracks whether the crosshair cursor is currently pushed onto the cursor stack.
    private var hasPushedCrosshairCursor = false

    private func observeResignActiveDuringCapture() {
        guard resignActiveObserver == nil else { return }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, isTakingScreenshot else { return }
            if let started = captureStartedAt,
               Date().timeIntervalSince(started) < Self.resignActiveGracePeriod {
                logWarn("app resigned active within grace period, keeping session")
                return
            }
            logInfo("app resigned active during capture, canceling session")
            finishCapture(nil)
        }
    }

    private func removeResignActiveObserver() {
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
    }

    /// Applies the crosshair cursor immediately.
    private func updateCrosshairCursor() {
        NSCursor.crosshair.set()
    }

    private func pushCrosshairCursor() {
        guard !hasPushedCrosshairCursor else { return }
        NSCursor.crosshair.push()
        /*
         Also hide: with Accessibility pointer customization on, the rendered
         pointer ignores NSCursor images, so without hiding it the old arrow
         would sit next to the overlay's self-drawn crosshair.
         */
        NSCursor.hide()
        updateCrosshairCursor()
        hasPushedCrosshairCursor = true
    }

    /// Pops the crosshair cursor from the cursor stack after capture finishes.
    private func popCrosshairCursor() {
        guard hasPushedCrosshairCursor else { return }
        NSCursor.unhide()
        NSCursor.pop()
        hasPushedCrosshairCursor = false
    }

    private func showOverlayWindow(
        presetFrozenImages: [NSScreen: NSImage],
        completion: @escaping (NSImage?) -> ()
    ) {
        // Store the completion handler
        captureCompletionHandler = completion

        // Save the currently active application
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        // Show overlay window on each screen
        logInfo(
            "showOverlayWindow, screens=\(NSScreen.screens.count), previousApp=\(previousActiveApp?.localizedName ?? "nil"), presets=\(presetFrozenImages.count)"
        )
        tearDownOverlayStates()
        hideAllOverlayWindows()

        for screen in NSScreen.screens {
            createOverlayWindow(for: screen, presetFrozenImage: presetFrozenImages[screen])
        }

        /*
         Activate App after creating all screenshot windows, avoid losing focus application.

         Activate the application to ensure it receives key events.
         Local event monitors (`addLocalMonitorForEvents`) only capture events
         dispatched to the *active* application. Without activating,
         key down events (like ESC to cancel) might not be received
         if another application was active when the screenshot started.
         */
        NSApplication.shared.activateApp()

        /*
         Cursor rects only apply on the next mouse move, so without this the
         pointer keeps its old arrow until the user drags — the crosshair
         must appear the instant the overlay does.
         */
        NSCursor.crosshair.set()
    }

    /// Removes transient screenshot state and releases any local event monitors it owns.
    private func tearDownOverlayStates() {
        for state in overlayViewStates.values {
            state.cleanup()
        }
        overlayViewStates.removeAll()
    }

    private func createOverlayWindow(for screen: NSScreen, presetFrozenImage: NSImage?) {
        let state = ScreenshotState(screen: screen)
        /*
         The menu-safe channel hands us a frame captured while the target menu
         was still on screen; reuse it instead of re-shooting after the popup
         is gone. Normal path freezes the clean display before our own window
         can appear in it.
         */
        state.frozenDisplayImage = presetFrozenImage ?? screen.takeScreenshot()
        if state.frozenDisplayImage == nil {
            logError("frozen frame capture failed, edit background will be blank, screen=\(screen.localizedName)")
        } else {
            logInfo(
                "overlay window created, screen=\(screen.localizedName), frame=\(screen.frame), frozenFrame=\(presetFrozenImage != nil ? "preset" : "fresh")"
            )
        }

        let window = ScreenshotOverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.makeKeyAndOrderFront(nil)

        let contentView = ScreenshotOverlayView(state: state)
        window.contentView = ScreenshotOverlayHostingView(rootView: contentView)
        if let contentView = window.contentView {
            window.invalidateCursorRects(for: contentView)
        }

        overlayWindows[screen] = window
        overlayViewStates[screen] = state
    }

    private func hideAllOverlayWindows() {
        for (_, window) in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

// MARK: - ScreenshotOverlayWindow

/// A borderless overlay window that can become key and main for cursor updates.
final class ScreenshotOverlayWindow: NSWindow {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
