//
//  ClipboardMonitor.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

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

    /// UserDefaults key for the user-chosen store root (settings tab).
    static let storePathKey = "clipboardStorePath"

    private(set) var store: ClipboardStore?

    /// Switches the store to `url`: copies the existing history.db and images
    /// over (unless the destination already has its own database), swaps the
    /// live store on the main actor, then reports the outcome. Capture keeps
    /// writing through the old store until the swap lands.
    func changeStoreDirectory(to url: URL, completion: @escaping (Bool) -> ()) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let oldStore = store
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                let targetDB = url.appendingPathComponent("history.db")
                if let oldStore,
                   fm.fileExists(atPath: oldStore.directory.appendingPathComponent("history.db").path),
                   !fm.fileExists(atPath: targetDB.path) {
                    try fm.copyItem(
                        at: oldStore.directory.appendingPathComponent("history.db"), to: targetDB
                    )
                    let oldImages = oldStore.directory.appendingPathComponent("images", isDirectory: true)
                    let newImages = url.appendingPathComponent("images", isDirectory: true)
                    try fm.createDirectory(at: newImages, withIntermediateDirectories: true)
                    for file in (try? fm.contentsOfDirectory(atPath: oldImages.path)) ?? [] {
                        try? fm.copyItem(
                            at: oldImages.appendingPathComponent(file),
                            to: newImages.appendingPathComponent(file)
                        )
                    }
                }
                let newStore = try ClipboardStore(directory: url)
                DispatchQueue.main.async {
                    let previous = self.store
                    self.store = newStore
                    previous?.close()
                    logInfo("[Clipboard] Store switched to \(url.path)")
                    completion(true)
                }
            } catch {
                logError("[Clipboard] Store switch failed: \(String(describing: error))")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }
    }

    /// Starts polling; safe to call repeatedly. Store failures disable
    /// capture but never crash the app.
    func start() {
        guard timer == nil else { return }

        do {
            let opened = try ClipboardStore(directory: Self.defaultDirectory())
            store = opened
            logInfo("[Clipboard] Store opened at \(opened.directory.path)")
        } catch {
            logError("[Clipboard] Store init failed: \(String(describing: error))")
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
        logInfo("[Clipboard] Monitor started, interval=\(Self.pollInterval)s")
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
        if let configured = UserDefaults.standard.string(forKey: storePathKey)?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("Easydict", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    /// TIFF-first extraction keeps the original pixels lossless through the
    /// PNG re-encode; nil when the data holds no usable image. Runs off-main.
    private static func imagePayload(fromTIFF tiff: Data) -> ImagePayload? {
        guard let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return ImagePayload(
            pngData: png,
            pixelWidth: rep.pixelsWide,
            pixelHeight: rep.pixelsHigh
        )
    }

    private func poll() {
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let suppressed = suppressedChangeCount {
            suppressedChangeCount = nil
            if changeCount == suppressed {
                logInfo("[Clipboard] Skipped suppressed self-write")
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
            logInfo("[Clipboard] Skipped concealed/transient pasteboard")
            return
        }

        guard let store else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceName = sourceApp?.localizedName
        let sourceBundle = sourceApp?.bundleIdentifier

        // Only the raw TIFF bytes are grabbed on the main thread (AppKit
        // requirement); decode and PNG re-encode run on the utility queue —
        // a few-dozen-MB screenshot used to stall the UI here.
        if let tiff = NSPasteboard.general.data(forType: .tiff) {
            workQueue.async { [weak self] in
                guard let payload = Self.imagePayload(fromTIFF: tiff) else { return }
                self?.storeImage(payload, sourceName: sourceName, sourceBundle: sourceBundle)
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

    // MARK: Store writing (utility queue)

    private func storeText(_ text: String, sourceName: String?, sourceBundle: String?) {
        guard let store else { return }
        do {
            try store.insertText(text, sourceApp: sourceName, sourceBundleID: sourceBundle)
            try store.pruneTexts(
                maxCount: configuredMaxCount(),
                ageLimit: TimeInterval(configuredAgeDays() * 24 * 3600)
            )
            logInfo("[Clipboard] Captured text, bytes=\(text.utf8.count)")
        } catch {
            logError("[Clipboard] Text insert failed: \(String(describing: error))")
        }
    }

    /// Reads the clipboard settings tab's limits; falls back to the store's
    /// own defaults (500 entries / 90 days) when unset.
    private func configuredMaxCount() -> Int {
        let stored = UserDefaults.standard.object(forKey: "clipboardHistoryMaxCount") as? Int
        return stored ?? 500
    }

    private func configuredAgeDays() -> Int {
        let stored = UserDefaults.standard.object(forKey: "clipboardHistoryAgeDays") as? Int
        return stored ?? 90
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
            logInfo("[Clipboard] Captured image \(payload.pixelWidth)x\(payload.pixelHeight)")
            pruneImageStorageIfNeeded()
        } catch {
            logError("[Clipboard] Image insert failed: \(String(describing: error))")
        }
    }

    /// The capacity APIs existed but nothing called them, so the image folder
    /// grew forever. Keep it under ~500 MB / 60 days.
    private func pruneImageStorageIfNeeded() {
        guard let store else { return }
        do {
            let capBytes = 500 * 1024 * 1024
            if try store.totalImageBytes() > capBytes {
                let removed = try store.deleteImages(olderThan: Date().addingTimeInterval(-60 * 24 * 3600))
                logInfo("[Clipboard] Storage pruned, removedImages=\(removed)")
            }
        } catch {
            logWarn("[Clipboard] Storage prune failed: \(String(describing: error))")
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
