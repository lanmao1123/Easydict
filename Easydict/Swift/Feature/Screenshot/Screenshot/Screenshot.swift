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

    @objc
    public func startCapture(completion: @escaping (NSImage?) -> ()) {
        if isTakingScreenshot {
            completion(nil)
            return
        }

        let hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
        if !hasScreenCapturePermission {
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
        pushCrosshairCursor()
        setupEventMonitor()
        showOverlayWindow(completion: completion)
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
        popCrosshairCursor()

        // Restore focus to previous application only if shouldRestorePreviousApp is true
        if shouldRestorePreviousApp, let previousApp = previousActiveApp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previousApp.activate()
            }
        }

        previousActiveApp = nil

        // Call the original completion handler
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
        NSLog("Performing screenshot, screen frame: \(screen.frame), rect: \(rect)")

        // Save last screenshot rect and screen
        lastScreenshotRect = rect
        lastScreen = screen

        /*
         Editing mode parks this capture session on the overlay instead of
         finishing it: the dark overlay stays hidden, ESC keeps its fallback,
         and annotation editing ends through `completeEditing`.
         */
        if editModeEnabled {
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
        finishCapture(image)
    }

    /// Completes annotation editing: hides overlays and fires the completion
    /// handler exactly like a regular capture, with `image` or nil to cancel.
    func completeEditing(with image: NSImage?) {
        if let screen = lastScreen {
            overlayViewStates[screen]?.endEditing()
        }
        finishCapture(image)
    }

    /// The clean, un-annotated screenshot covering the editing rect.
    func captureEditedBaseImage() -> NSImage? {
        guard let screen = lastScreen,
              let rect = overlayViewStates[screen]?.editingRect,
              !rect.isEmpty else { return nil }
        // Crop the frame frozen at capture start — instant, versus a fresh
        // full-display CGDisplayCreateImage on every ⌘C / mosaic stroke.
        if let frozen = overlayViewStates[screen]?.frozenDisplayImage,
           let cropped = screen.croppedScreenshot(from: frozen, rect: rect) {
            return cropped
        }
        return screen.takeScreenshot(rect: rect)
    }

    // MARK: Private

    /// The completion handler passed from startCapture.
    private var captureCompletionHandler: ((NSImage?) -> ())?

    private var previousActiveApp: NSRunningApplication?

    /// Tracks whether the crosshair cursor is currently pushed onto the cursor stack.
    private var hasPushedCrosshairCursor = false

    /// Applies the crosshair cursor immediately.
    private func updateCrosshairCursor() {
        NSCursor.crosshair.set()
    }

    private func pushCrosshairCursor() {
        guard !hasPushedCrosshairCursor else { return }
        NSCursor.crosshair.push()
        updateCrosshairCursor()
        hasPushedCrosshairCursor = true
    }

    /// Pops the crosshair cursor from the cursor stack after capture finishes.
    private func popCrosshairCursor() {
        guard hasPushedCrosshairCursor else { return }
        NSCursor.pop()
        hasPushedCrosshairCursor = false
    }

    private func showOverlayWindow(completion: @escaping (NSImage?) -> ()) {
        // Store the completion handler
        captureCompletionHandler = completion

        // Save the currently active application
        previousActiveApp = NSWorkspace.shared.frontmostApplication

        tearDownOverlayStates()
        hideAllOverlayWindows()

        // Show overlay window on each screen
        for screen in NSScreen.screens {
            createOverlayWindow(for: screen)
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
    }

    /// Removes transient screenshot state and releases any local event monitors it owns.
    private func tearDownOverlayStates() {
        for state in overlayViewStates.values {
            state.cleanup()
        }
        overlayViewStates.removeAll()
    }

    private func createOverlayWindow(for screen: NSScreen) {
        let state = ScreenshotState(screen: screen)
        // Freeze the clean display before our own window can appear in it.
        state.frozenDisplayImage = screen.takeScreenshot()

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
