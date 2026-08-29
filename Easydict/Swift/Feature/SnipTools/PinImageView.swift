//
//  PinImageState.swift content combined in PinImageView.swift
//

import AppKit
import SwiftUI

// MARK: - PinImageState

/// Observable state backing one pinned image panel.
@MainActor
final class PinImageState: ObservableObject {
    // MARK: Lifecycle

    init(image: NSImage) {
        self.image = image
        self.baseSize = image.size
    }

    // MARK: Internal

    let image: NSImage

    /// Point size of the image at scale 1, i.e. its natural on-screen size.
    let baseSize: CGSize

    /// Current zoom factor, clamped to readable bounds.
    @Published private(set) var scale: CGFloat = 1

    /// Window opacity, adjustable with ⌥+scroll like Snipaste.
    @Published private(set) var opacity: Double = 1

    /// True while the pin's panel is the key window, i.e. "selected".
    @Published var isFocused = false

    /// Invoked by double-click from the view; wired to the owning panel.
    var onCloseRequest: (() -> ())?

    var displaySize: CGSize {
        CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    }

    /// Multiplies the current scale, clamped between 5% and 20x.
    func zoom(by factor: CGFloat) {
        scale = min(max(scale * factor, Self.minScale), Self.maxScale)
    }

    /// Adds a signed opacity delta, clamped so a pin never fully disappears.
    func adjustOpacity(by delta: Double) {
        opacity = min(max(opacity + delta, Self.minOpacity), 1)
    }

    // MARK: Private

    private static let minScale: CGFloat = 0.05
    private static let maxScale: CGFloat = 20
    private static let minOpacity = 0.15
}

// MARK: - PinImageView

/// SwiftUI content of a pinned image window.
struct PinImageView: View {
    // MARK: Lifecycle

    init(state: PinImageState) {
        self.state = state
    }

    // MARK: Internal

    @ObservedObject var state: PinImageState

    var body: some View {
        Image(nsImage: state.image)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: state.displaySize.width, height: state.displaySize.height)
            .opacity(state.opacity)
            // A focused pin shows an accent outline so "selected" is visible,
            // matching the click-to-select semantics ⌘C relies on.
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor.opacity(state.isFocused ? 0.9 : 0), lineWidth: 2)
            )
            .onTapGesture(count: 2) {
                state.onCloseRequest?()
            }
    }
}

// MARK: - PinImageHostingView

/// Hosting view that turns mouse wheel scrolling into zoom steps and
/// ⌥+scroll into opacity steps. Trackpad pinches are handled by
/// PinImageManager's system-level session tap, which observes gestures
/// regardless of which app is active; this view must NOT also zoom on
/// `magnify` or one gesture would zoom the pin twice.
final class PinImageHostingView<Content: View>: NSHostingView<Content> {
    /// Called with a multiplicative zoom factor derived from the input.
    var onZoom: ((CGFloat) -> ())?

    /// Called with a signed opacity delta for ⌥+scroll.
    var onOpacity: ((Double) -> ())?

    override func scrollWheel(with event: NSEvent) {
        // Direction deliberately follows the raw delta: after trying the
        // normalized mapping the user asked for the opposite feel, so wheel
        // scrolling down on natural-scroll setups enlarges the pin.
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        if event.modifierFlags.contains(.option) {
            // exp() at a gentler divisor gives ~8% steps per wheel notch —
            // fine control from opaque to near-invisible.
            onOpacity?(Double(exp(deltaY / 120) - 1))
            return
        }
        // exp() keeps precise trackpad deltas smooth; one wheel notch (±10)
        // gives ~18% zoom, close to Snipaste's step.
        onZoom?(exp(deltaY / 60))
    }
}
