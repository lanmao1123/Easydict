//
//  PasteboardPathService.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// Saves images to disk under `~/Downloads/EasydictCaptures/<yyyy-MM-dd>/`
/// and copies the resulting absolute POSIX path to the pasteboard, so the
/// clipboard can hold either the image itself or its file path on demand.
enum PasteboardPathService {
    // MARK: Internal

    /// Reads the pasteboard image and runs the save-and-copy flow.
    ///
    /// Always surfaces the outcome via toast so the action gives feedback even
    /// when there is nothing to save.
    static func saveFromPasteboardAndCopyPath() {
        guard let image = NSPasteboard.general.image else {
            EZToast.showText(NSLocalizedString("snip_pasteboard_no_image", comment: ""))
            logWarn("[SnipTools] Copy image path skipped, no image in pasteboard")
            return
        }

        if saveAndCopyPath(for: image) != nil {
            logInfo("[SnipTools] Saved pasteboard image and copied path")
        } else {
            EZToast.showText(NSLocalizedString("snip_save_failed", comment: ""))
            logError("[SnipTools] Failed to save pasteboard image")
        }
    }

    /// Saves `image` as PNG and copies the file's absolute path to the
    /// pasteboard.
    /// - Returns: The saved file URL, or nil when saving failed.
    @discardableResult
    static func saveAndCopyPath(for image: NSImage) -> URL? {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            logError("[SnipTools] Downloads directory unavailable")
            return nil
        }

        guard let data = image.pngData() else {
            logError("[SnipTools] Failed to encode image as PNG")
            return nil
        }

        let url = deriveSaveURL(at: Date(), in: downloadsURL, createDirectories: true)

        do {
            try data.write(to: url)
        } catch {
            logError("[SnipTools] Writing PNG failed, error=\(error.localizedDescription)")
            return nil
        }

        NSPasteboard.general.setString(url.path)
        return url
    }

    /// Builds a unique save URL `<baseDirectory>/<yyyy-MM-dd>/<HH-mm-ss-SSS>.png`,
    /// appending `-2`, `-3`, ... suffixes when the timestamp collides. Purely
    /// deterministic apart from optional directory creation, which makes it
    /// unit-testable.
    /// - Parameters:
    ///   - date: Timestamp naming the date folder and the file name.
    ///   - baseDirectory: Root directory, typically the user's Downloads folder.
    ///   - createDirectories: When true, intermediate directories are created.
    static func deriveSaveURL(
        at date: Date,
        in baseDirectory: URL,
        createDirectories: Bool = false
    )
        -> URL {
        if createDirectories {
            try? FileManager.default.createDirectory(
                at: dateFolderURL(at: date, in: baseDirectory),
                withIntermediateDirectories: true
            )
        }

        var counter = 1
        while true {
            let url = saveFileURL(at: date, sequence: counter, in: baseDirectory)
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            counter += 1
        }
    }

    /// The per-day folder for `date`, e.g. `<base>/2026-08-27/`.
    static func dateFolderURL(at date: Date, in baseDirectory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFolderFormat
        return baseDirectory
            .appendingPathComponent(rootFolderName, isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    /// A candidate file URL for `date`; `sequence > 1` adds a numeric suffix.
    static func saveFileURL(at date: Date, sequence: Int, in baseDirectory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timeStampFormat

        let stamp = formatter.string(from: date)
        let fileName = sequence == 1 ? "\(stamp).\(fileExtension)" : "\(stamp)-\(sequence).\(fileExtension)"
        return dateFolderURL(at: date, in: baseDirectory).appendingPathComponent(fileName)
    }

    // MARK: Private

    private static let rootFolderName = "EasydictCaptures"
    private static let fileExtension = "png"
    private static let dateFolderFormat = "yyyy-MM-dd"
    private static let timeStampFormat = "HH-mm-ss-SSS"
}
