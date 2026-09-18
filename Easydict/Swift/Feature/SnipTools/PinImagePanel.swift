//
//  PinImagePanel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

/// Borderless floating panel that pins an image on screen, Snipaste-style.
///
/// `.nonactivatingPanel` keeps the frontmost app running, yet the pin can
/// still become key on click — that "selected" state is what routes ⌘C to
/// the pin's own copy handler. Supports background dragging, wheel zooming
/// through `PinImageHostingView` and double-click close through
/// `PinImageView`.
final class PinImagePanel: NSPanel {
    // MARK: Lifecycle

    init(image: NSImage) {
        self.state = PinImageState(image: image)

        /*
         .nonactivatingPanel is deliberately NOT in the style mask: macOS
         routes trackpad pinch data only to the active app, and since macOS
         14 a background app's programmatic NSApp.activate is throttled.
         With a plain borderless panel, WindowServer itself brings the app
         forward on click (the one path no API policy can block), which is
         what makes select-then-pinch zoom work after re-selecting a pin.
         */
        super.init(
            contentRect: NSRect(origin: .zero, size: image.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        level = .floating
        // Stay visible across Spaces and above fullscreen apps like Snipaste.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hostingView = PinImageHostingView(rootView: PinImageView(state: state))
        hostingView.onZoom = { [weak self] factor in
            self?.zoom(by: factor)
        }
        hostingView.onOpacity = { [weak self] delta in
            self?.state.adjustOpacity(by: delta)
        }
        /*
         Gesture events (magnify) are routed to the key window, unlike
         scrollWheel which follows the cursor. A pin that lost key state
         (user clicked elsewhere) would therefore never see a pinch again.
         A hover tracking area re-keys the panel whenever the cursor enters,
         so the gesture route stays alive without activating the app.
         */
        hostingView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
        contentView = hostingView
        initialFirstResponder = hostingView
    }

    // MARK: Internal

    // MARK: Override

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { false }

    let state: PinImageState

    override func becomeKey() {
        super.becomeKey()
        state.isFocused = true
    }

    override func resignKey() {
        super.resignKey()
        state.isFocused = false
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Hover = re-key. Keeps the gesture route alive after the user
        // clicked away; nonactivating panels take key without activating.
        if !isKeyWindow {
            makeKey()
            PinImageManager.shared.notePanelHoverKey(on: self)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            logInfo("[SnipTools] Pin mouseDown, appActive=\(NSApp.isActive)")
            dragStartMouse = NSEvent.mouseLocation
            dragStartOrigin = frame.origin
        case .leftMouseDragged:
            if let start = dragStartMouse, let origin = dragStartOrigin {
                let now = NSEvent.mouseLocation
                setFrameOrigin(
                    NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y)
                )
            }
        case .leftMouseUp:
            dragStartMouse = nil
            dragStartOrigin = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Resizes the frame while keeping the point under the cursor fixed, so
    /// both wheel zoom and trackpad pinch feel anchored where you point.
    func zoom(by factor: CGFloat) {
        let anchor = NSEvent.mouseLocation
        let oldFrame = frame
        // Fractional position of the anchor inside the current frame.
        let anchorFractionX = (anchor.x - oldFrame.minX) / oldFrame.width
        let anchorFractionY = (anchor.y - oldFrame.minY) / oldFrame.height

        state.zoom(by: factor)

        let newSize = state.displaySize
        let newOrigin = CGPoint(
            x: anchor.x - anchorFractionX * newSize.width,
            y: anchor.y - anchorFractionY * newSize.height
        )
        setFrame(CGRect(origin: newOrigin, size: newSize), display: true)
    }

    /// Primary pinch path: a gesture AppKit routed straight to this window
    /// because the cursor is over the pin — the same reliable routing as
    /// scrollWheel. The manager dedupes its tap fallback accordingly.
    func handleDirectPinch(magnification: CGFloat) {
        PinImageManager.shared.noteViewPinchHandled(on: self)
        zoom(by: 1 + magnification)
    }

    // MARK: Private

    /*
     Manual window dragging at the event-pump level. The system's
     isMovableByWindowBackground cannot work here: the double-tap close
     gesture makes the SwiftUI hit-test view report "interactive", and the
     window then never starts a background drag (verified: clicks arrived,
     the frame never moved). sendEvent is the one hook that sees every mouse
     event reaching this window regardless of hit-testing, so dragging is
     implemented here; forwarding to super keeps the double tap, wheel zoom
     and pinch working untouched.
     */
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
}
