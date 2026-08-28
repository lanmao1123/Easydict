//
//  ColorPickerPanel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

// MARK: - ColorPickerState

/// Observable state driving the magnifier HUD content.
@MainActor
final class ColorPickerState: ObservableObject {
    /// Magnified snapshot region around the cursor, pixelated on purpose.
    @Published var zoomedImage: NSImage?

    /// Picked color components at the cursor, display-ready.
    @Published var hexText = ""

    @Published var redText = ""
    @Published var greenText = ""
    @Published var blueText = ""

    /// Clears a finished session so the next launch shows no stale values.
    func reset() {
        zoomedImage = nil
        hexText = ""
        redText = ""
        greenText = ""
        blueText = ""
    }
}

// MARK: - ColorPickerView

/// SwiftUI content of the color picker HUD: a pixelated magnifier circle plus
/// an RGB / HEX readout row.
struct ColorPickerView: View {
    // MARK: Lifecycle

    init(state: ColorPickerState) {
        self.state = state
    }

    // MARK: Internal

    @ObservedObject var state: ColorPickerState

    var body: some View {
        VStack(spacing: 6) {
            magnifierView
            readoutRow
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
        )
    }

    // MARK: Private

    private let magnifierSide: CGFloat = 132

    private var magnifierView: some View {
        Group {
            if let image = state.zoomedImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: magnifierSide, height: magnifierSide)
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: magnifierSide, height: magnifierSide)
            }
        }
        .frame(width: magnifierSide, height: magnifierSide)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 2))
        .overlay(crosshair)
        .shadow(radius: 4)
    }

    /// Fixed crosshair over the magnifier center; drawn separately so the
    /// zoomed image can move freely underneath it.
    private var crosshair: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            Path { path in
                path.move(to: CGPoint(x: mid - 10, y: mid))
                path.addLine(to: CGPoint(x: mid + 10, y: mid))
                path.move(to: CGPoint(x: mid, y: mid - 10))
                path.addLine(to: CGPoint(x: mid, y: mid + 10))
            }
            .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
    }

    private var readoutRow: some View {
        HStack(spacing: 12) {
            componentLabel("R", state.redText)
            componentLabel("G", state.greenText)
            componentLabel("B", state.blueText)
            Text(state.hexText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 6)
    }

    private func componentLabel(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.white)
        }
    }
}

// MARK: - ColorPickerPanel

/// Magnifier HUD that samples colors around the cursor and copies the picked
/// HEX value on click; dismissed by ESC or after picking.
///
/// The screen under the cursor is snapshotted once when the picker starts (and
/// again only when the cursor crosses to another screen); sampling reads from
/// that cached frame instead of recapturing on every mouse move.
@MainActor
enum ColorPickerPanel {
    // MARK: Internal

    /// Presents the magnifier HUD over the screen under the cursor.
    static func start() {
        guard panel == nil else {
            logWarn("[SnipTools] Color picker already active")
            return
        }

        refreshSnapshot(for: NSScreen.currentMouseScreen())

        let hudPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.level = .statusBar
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudPanel.isReleasedWhenClosed = false
        hudPanel.contentViewController = NSHostingController(rootView: ColorPickerView(state: state))

        panel = hudPanel
        setupMonitors()
        updateHUD()
        hudPanel.orderFrontRegardless()

        logInfo("[SnipTools] Color picker started")
    }

    // MARK: Private

    /// Zoom factor of the magnifier HUD.
    private static let magnification: CGFloat = 16

    private static var panel: NSPanel?
    private static var state = ColorPickerState()
    private static var monitors: [Any] = []
    private static var snapshotImage: CGImage?
    private static var lastHUDRefresh: CFAbsoluteTime = 0
    private static var snapshotScreen: NSScreen?

    /// Tears everything down; safe to call repeatedly.
    private static func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()

        FunctionKeyHotKeyCenter.unregister(identifier: "com.izual.Easydict.colorPickerESC")

        if let panel {
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        snapshotImage = nil
        snapshotScreen = nil
        state.reset()

        logInfo("[SnipTools] Color picker stopped")
    }

    private static func setupMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moveMask) { _ in updateHUD() })
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: moveMask) { event in
                updateHUD()
                return event
            }
        )

        // Global leftMouseDown cannot swallow the click, which is fine: the
        // intent is "pick this color" and one pass-through click is harmless.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in pickColor() })
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                pickColor()
                return nil
            }
        )

        // A Carbon ESC for the picker's short lifetime: global key monitors
        // are deaf without Input Monitoring, which left the HUD uncancellable
        // on un-permitted machines.
        FunctionKeyHotKeyCenter.register(
            identifier: "com.izual.Easydict.colorPickerESC",
            keyCode: kVK_Escape
        ) {
            stop()
        }
    }

    /// Re-captures the whole screen frame when the cursor switches screens.
    private static func refreshSnapshot(for screen: NSScreen?) {
        guard let screen, screen != snapshotScreen || snapshotImage == nil else { return }

        guard let cgImage = screen.takeScreenshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logError("[SnipTools] Failed to capture screen for color picker")
            return
        }
        snapshotImage = cgImage
        snapshotScreen = screen
    }

    /// Refreshes the snapshot if needed and repositions the HUD around the cursor.
    private static func updateHUD() {
        guard let panel else { return }
        // Mouse-move storms fire far faster than the eye needs; cap ~30fps.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHUDRefresh < 0.033 { return }
        lastHUDRefresh = now

        let mouseLocation = NSEvent.mouseLocation
        refreshSnapshot(for: NSScreen.currentMouseScreen())
        guard let screen = snapshotScreen else { return }

        // Place the HUD above-right of the cursor, clamped into the screen.
        let size = panel.frame.size
        let offset: CGFloat = 24
        var origin = CGPoint(x: mouseLocation.x + offset, y: mouseLocation.y - size.height - offset)
        origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - size.width)
        origin.y = max(origin.y, screen.frame.minY + offset)
        panel.setFrameOrigin(origin)

        let picked = pickPixel(at: mouseLocation, on: screen)
        state.zoomedImage = magnifiedRegion(at: mouseLocation, on: screen)

        guard let picked else { return }
        state.redText = String(picked.r)
        state.greenText = String(picked.g)
        state.blueText = String(picked.b)
        state.hexText = String(format: "#%02X%02X%02X", picked.r, picked.g, picked.b)
    }

    /// Reads the cached snapshot's pixel under the cursor as sRGB bytes.
    private static func pickPixel(at location: CGPoint, on screen: NSScreen) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let image = snapshotImage else { return nil }

        let scale = screen.backingScaleFactor
        // Convert global bottom-left points to snapshot top-left pixels.
        let localX = (location.x - screen.frame.minX) * scale
        let localY = (screen.frame.maxY - location.y) * scale
        let px = Int(localX.rounded())
        let py = Int(localY.rounded())
        guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }

        guard let tile = image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        return tile.sRGBBytes().map { (r: $0[0], g: $0[1], b: $0[2]) }
    }

    /// Builds the magnified region shown inside the HUD circle.
    private static func magnifiedRegion(at location: CGPoint, on screen: NSScreen) -> NSImage? {
        guard let image = snapshotImage else { return nil }

        let scale = screen.backingScaleFactor
        let halfSide = Int((66 * scale).rounded()) // source radius in pixels
        let center = CGPoint(
            x: (location.x - screen.frame.minX) * scale,
            y: (screen.frame.maxY - location.y) * scale
        )
        let cropRect = CGRect(
            x: center.x - CGFloat(halfSide),
            y: center.y - CGFloat(halfSide),
            width: CGFloat(halfSide * 2),
            height: CGFloat(halfSide * 2)
        ).intersection(CGRect(origin: .zero, size: CGSize(width: image.width, height: image.height)))

        guard !cropRect.isNull, let region = image.cropping(to: cropRect) else { return nil }
        return NSImage(cgImage: region, size: CGSize(width: magnification * 66, height: magnification * 66))
    }

    /// Copies the currently sampled HEX value and closes the picker.
    private static func pickColor() {
        let hex = state.hexText
        stop()
        guard !hex.isEmpty else {
            EZToast.showText(NSLocalizedString("snip_color_pick_failed", comment: ""))
            return
        }

        NSPasteboard.general.setString(hex)
        EZToast.showText(hex)
        logInfo("[SnipTools] Color picked, hex=\(hex)")
    }
}

// MARK: - CGImage + Pixel Reading

extension CGImage {
    /// Redraws a pixel-exact tile into a canonical sRGB RGBA8 buffer.
    fileprivate func sRGBBytes() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: 1,
                      height: 1,
                      bitsPerComponent: 8,
                      bytesPerRow: 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                  ) else { return false }

            context.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drew ? buffer : nil
    }
}
