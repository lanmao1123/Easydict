//
//  ClipboardMonitor.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import os.log

// MARK: - ClipboardMonitor

/// Polls the pasteboard's change count and captures text/image changes into
/// the store. macOS has no pasteboard-change notification, so a 0.5 s poll is
/// the industry-standard approach (Raycast/Maccy alike) and is nearly free.
@MainActor
final class ClipboardMonitor: NSObject {
    // MARK: Lifecycle

    override private init() {
        super.init()
    }

    // MARK: Internal

    static let shared = ClipboardMonitor()

    /// Poll interval; Raycast and Maccy use the same order of magnitude.
    static let pollInterval: TimeInterval = 0.5

    private(set) var store: ClipboardStore?

    /// Starts polling; safe to call repeatedly. Store failures disable
    /// capture but never crash the app.
    func start() {
        guard timer == nil else { return }

        do {
            let opened = try ClipboardStore(directory: Self.defaultDirectory())
            store = opened
            Self.log.info("[Clipboard] Store opened at \(opened.directory.path, privacy: .public)")
        } catch {
            Self.log.error("[Clipboard] Store init failed: \(String(describing: error), privacy: .public)")
            store = nil
        }

        lastChangeCount = NSPasteboard.general.changeCount
        let pollTimer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(pollTimer, forMode: .common)
        timer = pollTimer
        Self.log.info("[Clipboard] Monitor started, interval=\(Self.pollInterval, privacy: .public)s")
    }

    /*
     Writing a selection back to the pasteboard (Enter on a history entry)
     would be captured as a "new" copy. The manager registers the write here
     first so the very next change count is ignored once.
     */
    func suppressNextChange() {
        suppressedChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: Private

    // MARK: Payload reading

    private struct ImagePayload {
        let pngData: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Easydict", category: "ClipboardHistory")

    /// Concealed = password managers (1Password et al.); transient = the
    /// clipboard managers' own chatter. Both must never be recorded.
    private static let skippedTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("com.apple.isConcealed"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var suppressedChangeCount: Int?
    private let workQueue = DispatchQueue(label: "com.izual.Easydict.clipboard.store", qos: .utility)

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Easydict", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    private func poll() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let suppressed = suppressedChangeCount {
            suppressedChangeCount = nil
            if changeCount == suppressed {
                Self.log.debug("[Clipboard] Skipped suppressed self-write")
                return
            }
        }

        capture()
    }

    /// Reads the pasteboard on the main thread (an AppKit requirement), then
    /// hands heavy encoding/writing work to the utility queue.
    private func capture() {
        let types = NSPasteboard.general.types ?? []
        guard !types.isEmpty else { return }
        for skipped in Self.skippedTypes where types.contains(skipped) {
            Self.log.info("[Clipboard] Skipped concealed/transient pasteboard")
            return
        }

        guard let store else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceName = sourceApp?.localizedName
        let sourceBundle = sourceApp?.bundleIdentifier

        if let imagePayload = readImagePayload() {
            workQueue.async { [weak self] in
                self?.storeImage(imagePayload, sourceName: sourceName, sourceBundle: sourceBundle)
            }
            return
        }

        if let text = NSPasteboard.general.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            workQueue.async { [weak self] in
                self?.storeText(text, sourceName: sourceName, sourceBundle: sourceBundle)
            }
        }
    }

    /// TIFF-first extraction keeps the original pixels lossless through the
    /// PNG re-encode; nil when the pasteboard holds no usable image.
    private func readImagePayload() -> ImagePayload? {
        guard let tiff = NSPasteboard.general.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ImagePayload(
            pngData: png,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh
        )
    }

    // MARK: Store writing (utility queue)

    private func storeText(_ text: String, sourceName: String?, sourceBundle: String?) {
        guard let store else { return }
        do {
            try store.insertText(text, sourceApp: sourceName, sourceBundleID: sourceBundle)
            Self.log.info("[Clipboard] Captured text, bytes=\(text.utf8.count)")
        } catch {
            Self.log.error("[Clipboard] Text insert failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func storeImage(_ payload: ImagePayload, sourceName: String?, sourceBundle: String?) {
        guard let store else { return }
        do {
            let hash = ClipboardStore.sha256(payload.pngData)
            let fileName = store.makeImageFileName(hash: hash)
            let imageURL = store.imagesDirectory.appendingPathComponent(fileName)
            try payload.pngData.write(to: imageURL)

            let thumbName = makeThumbnail(for: imageURL, maxPixel: 96)

            try store.insertImage(
                imageFile: fileName,
                thumbFile: thumbName,
                pixelWidth: payload.pixelWidth,
                pixelHeight: payload.pixelHeight,
                byteCount: payload.pngData.count,
                contentHash: hash,
                sourceApp: sourceName,
                sourceBundleID: sourceBundle
            )
            Self.log.info("[Clipboard] Captured image \(payload.pixelWidth)x\(payload.pixelHeight)")
        } catch {
            Self.log.error("[Clipboard] Image insert failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes a height-capped thumbnail next to the payload; nil when the
    /// image is already small enough or encoding fails.
    private func makeThumbnail(for imageURL: URL, maxPixel: Int) -> String? {
        guard let source = NSImage(contentsOf: imageURL),
              let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }

        let longest = max(rep.pixelsWide, rep.pixelsHigh)
        guard longest > maxPixel * 2 else { return nil }

        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        let target = NSSize(
            width: CGFloat(rep.pixelsWide) * ratio,
            height: CGFloat(rep.pixelsHigh) * ratio
        )
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()

        guard let smallTiff = scaled.tiffRepresentation,
              let smallRep = NSBitmapImageRep(data: smallTiff),
              let smallPNG = smallRep.representation(using: .png, properties: [:]) else { return nil }

        let thumbName = "thumb-" + imageURL.lastPathComponent
        let thumbURL = imageURL.deletingLastPathComponent().appendingPathComponent(thumbName)
        do {
            try smallPNG.write(to: thumbURL)
            return thumbName
        } catch {
            return nil
        }
    }
}
