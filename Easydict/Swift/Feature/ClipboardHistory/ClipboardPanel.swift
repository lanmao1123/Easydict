//
//  ClipboardPanel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon
import SwiftUI

// MARK: - ClipboardPanel

/// Spotlight-style borderless panel for browsing clipboard history. Unlike
/// the pin panel it takes keyboard focus (search typing), so presenting it
/// activates the app; `hidesOnDeactivate` closes it when the user clicks
/// elsewhere.
final class ClipboardPanel: NSPanel {
    // MARK: Lifecycle

    init() {
        let viewModel = ClipboardHistoryViewModel()
        self.viewModel = viewModel

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.preferredSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = true
        isReleasedWhenClosed = false

        contentView = NSHostingView(rootView: ClipboardHistoryView(viewModel: viewModel))
    }

    // MARK: Internal

    // MARK: Override

    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }

    let viewModel: ClipboardHistoryViewModel

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        removeKeyMonitor()
    }

    /// Generous Spotlight-like footprint, clamped to the visible frame so
    /// small displays never get an oversized panel.
    static func preferredSize() -> NSSize {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSSize(
            width: min(920, visible.width * 0.72),
            height: min(640, visible.height * 0.76)
        )
    }

    /// Centers the panel in the upper third of the main screen, Spotlight
    /// style, then takes key focus.
    func present() {
        positionOnScreen()
        viewModel.load()
        viewModel.selectNewest()
        makeKeyAndOrderFront(nil)
        installKeyMonitorIfNeeded()
        logInfo("panel presented, visible=\(isVisible), occlusion=\(occlusionState.rawValue)")
    }

    func reload() {
        viewModel.load()
    }

    // MARK: Private

    private var keyMonitor: Any?

    private static func digitIndex(of keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        default: return nil
        }
    }

    private func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = Self.preferredSize()
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - visible.height * 0.18 - size.height
        )
        setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /*
     Arrows, Enter, Esc, ⌘1-9 and ⌘⌫ are intercepted here instead of via
     SwiftUI gestures: the search field owns first responder and would eat
     them, and a local monitor sees every key before AppKit dispatch — typing
     letters still flows through to the field untouched.
     */
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isVisible, isKeyWindow else { return event }
            return MainActor.assumeIsolated {
                self.handleKey(event)
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if keyCode == kVK_Escape {
            ClipboardManager.shared.hidePanel()
            return nil
        }

        if flags == .command, keyCode == kVK_Delete {
            viewModel.deleteSelected()
            return nil
        }

        if flags == .command {
            // ⌘1-9 jump straight to the Nth row, Spotlight-style.
            if let digit = Self.digitIndex(of: keyCode) {
                viewModel.selectIndex(digit)
                return nil
            }
            return event
        }

        switch keyCode {
        case kVK_DownArrow:
            viewModel.moveSelection(ClipboardMoveDirection.down)
            return nil
        case kVK_UpArrow:
            viewModel.moveSelection(ClipboardMoveDirection.up)
            return nil
        case kVK_ANSI_KeypadEnter, kVK_Return:
            viewModel.confirmSelection()
            return nil
        default:
            return event
        }
    }
}
