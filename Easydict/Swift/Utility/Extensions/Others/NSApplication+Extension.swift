//
//  NSApplication+Extension.swift
//  Easydict
//
//  Created by agent on 2026/8/28.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

// MARK: - NSApplication + Activate

extension NSApplication {
    /// Brings the app to the front.
    ///
    /// - Note: The newer `activate()` API on macOS 14.0 doesn't work as
    ///   expected — it doesn't bring the app to front — so use the old API.
    func activateApp() {
        logInfo("Activating application")
        activate(ignoringOtherApps: true)
    }
}
