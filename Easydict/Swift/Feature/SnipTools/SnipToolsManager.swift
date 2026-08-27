//
//  SnipToolsManager.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

/// Entry manager for the SnipTools feature set.
///
/// Coordinates four global actions: annotated screenshot capture (F1),
/// pasteboard pin-to-screen (F3), pasteboard-image-to-file-path copying (F4)
/// and the color picker HUD.
@MainActor
final class SnipToolsManager: NSObject {
    // MARK: Lifecycle

    private override init() {
        super.init()
    }

    // MARK: Internal

    static let shared = SnipToolsManager()

    // MARK: Actions (bound from ShortcutAction)

    /// Takes a screenshot and enters annotation editing right after selection;
    /// the composed image is copied to the pasteboard on confirm. When the
    /// menu-safe channel triggers this while a status-bar menu is open,
    /// `presetFrozenImages` carries frames captured with the menu still on
    /// screen so the menu content survives into the shot.
    func startScreenshotEdit(presetFrozenImages: [NSScreen: NSImage] = [:]) async {
        guard !Screenshot.shared.isTakingScreenshot else { return }

        Screenshot.shared.editModeEnabled = true
        await withCheckedContinuation { continuation in
            Screenshot.shared.startCapture(presetFrozenImages: presetFrozenImages) { image in
                if let image {
                    image.writeToPasteboard()
                }
                continuation.resume()
            }
        }
    }

    /// Pins the pasteboard image as a floating always-on-top window.
    func pinToScreen() async {
        PinImageManager.shared.pinFromPasteboard()
    }

    /// Saves the pasteboard image to disk and copies its absolute path.
    func copyImagePath() async {
        PasteboardPathService.saveFromPasteboardAndCopyPath()
    }

    /// Presents the color picker magnifier HUD.
    func startColorPicker() async {
        ColorPickerPanel.start()
    }
}
