//
//  NSScreen+Extention.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/20.
//  Copyright © 2025 izual. All rights reserved.
//

import Foundation
import ScreenCaptureKit

extension NSScreen {
    /// Take screenshot of the specified area in the screen.
    /// - Parameter rect: The rect in the screen to capture. The rect is `top-left` origin. If nil, capture the entire screen.
    /// - Returns: NSImage of captured screenshot or nil if failed
    func takeScreenshot(rect: CGRect? = nil) -> NSImage? {
        let rect = rect ?? bounds
        logInfo("takeScreenshot begin, screen=\(localizedName), rect=\(rect)")

        /*
         ScreenCaptureKit first: a customized Accessibility pointer is a
         Window Server overlay that leaks into window-list captures, and a
         snipping tool must never show the pointer. SCK can exclude those
         windows and the cursor itself; menus and every other layer stay in.
         */
        if #available(macOS 14.0, *) {
            let started = Date()
            if let image = Self.sckCaptureSync(screen: self, rect: rect) {
                logInfo(
                    "takeScreenshot SCK ok, screen=\(localizedName), size=\(image.size), cost=\(Int(Date().timeIntervalSince(started) * 1000))ms"
                )
                return image
            }
            logWarn("takeScreenshot SCK failed after retry, falling back to window list, screen=\(localizedName)")
        }

        /*
         CGWindowListCreateImage instead of CGDisplayCreateImage: the latter
         silently omits open status-bar menus (and other high-layer popups).
         `rect` arrives in top-left screen-local space; the list API wants
         global bottom-left space.
         */
        let globalRect = CGRect(
            x: frame.minX + rect.origin.x,
            y: frame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
        guard let capturedImage = CGWindowListCreateImage(
            globalRect,
            [.optionOnScreenOnly],
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            logError("window-list fallback failed too, globalRect=\(globalRect), screen=\(localizedName)")
            return nil
        }

        logInfo("takeScreenshot window-list fallback ok, screen=\(localizedName), globalRect=\(globalRect)")
        return NSImage(cgImage: capturedImage, size: .zero)
    }

    /// ScreenCaptureKit capture that excludes cursor overlays. Synchronous
    /// wrapper: the frame must exist before the overlay window can appear.
    @available(macOS 14.0, *)
    private static func sckCaptureSync(screen: NSScreen, rect: CGRect) -> NSImage? {
        var result: NSImage?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            result = await sckCapture(screen: screen, rect: rect)
            if result == nil {
                /*
                 One immediate retry with a refreshed content snapshot: a
                 transiently failing or stale SCShareableContent is the usual
                 cause, and a nil here leaves the overlay without its frozen
                 background and dark mask entirely.
                 */
                invalidateShareableContentCache()
                result = await sckCapture(screen: screen, rect: rect)
            }
            semaphore.signal()
        }
        /*
         Bounded wait: ScreenCaptureKit can hang across display reconfigure or
         WindowServer stalls, and this runs on the main thread — an unbounded
         wait would freeze the whole app. On timeout the detached task keeps
         writing only its own captured variable; fall through to the
         window-list fallback instead.
         */
        if semaphore.wait(timeout: .now() + sckCaptureTimeout) == .timedOut {
            logError("SCK capture timed out after \(Int(sckCaptureTimeout))s, screen=\(screen.localizedName)")
            return nil
        }
        return result
    }

    private static let sckCaptureTimeout: TimeInterval = 4

    @available(macOS 14.0, *)
    private static func sckCapture(screen: NSScreen, rect: CGRect) async -> NSImage? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID
        else { return nil }

        do {
            let content = try await Self.cachedShareableContent()
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                logError("SCK display not found, displayID=\(displayID)")
                return nil
            }

            // The customized pointer renders as a Window Server window on a
            // huge layer (owningApplication nil). Drop those; everything else
            // — menus included — stays in the frame.
            let cursorOverlays = content.windows.filter {
                $0.owningApplication == nil && $0.windowLayer > 1_000_000
            }
            logInfo(
                "SCK filter ready, excludedCursorOverlays=\(cursorOverlays.count), totalWindows=\(content.windows.count)"
            )
            let filter = SCContentFilter(display: display, excludingWindows: cursorOverlays)
            /*
             Docs claim excluding-filters include the menu bar by default, but
             on recent macOS the top bar is missing unless asked for — set it
             explicitly so the status icons stay capturable.
             */
            if #available(macOS 14.2, *) {
                filter.includeMenuBar = true
            }

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            // SCK sourceRect uses the same top-left screen-local space as rect.
            config.sourceRect = rect
            config.width = max(Int(rect.width * scale), 1)
            config.height = max(Int(rect.height * scale), 1)
            config.showsCursor = false
            config.captureResolution = .best

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            logError("SCK capture error: \(error)")
            return nil
        }
    }

    /// The CG display backing this screen.
    private var screenID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            ?? CGMainDisplayID()
    }

    // MARK: - SCShareableContent cache

    @available(macOS 14.0, *) private static let shareableContentLock = NSLock()
    @available(macOS 14.0, *) private nonisolated(unsafe) static var shareableContentCache: (
        content: SCShareableContent, timestamp: Date
    )?

    /**
     Enumerating shareable content costs tens to hundreds of milliseconds and
     the capture flow needs it for every frame; a short-lived cache keeps
     repeat captures (freeze frame, edits, retakes) snappy. Stale by at most
     1.5 s, which only matters for cursor-overlay exclusion — a newly appeared
     overlay within that window would slip into one frame, a cosmetic risk
     worth the latency.
     */
    @available(macOS 14.0, *)
    private static func invalidateShareableContentCache() {
        shareableContentLock.lock()
        shareableContentCache = nil
        shareableContentLock.unlock()
    }

    @available(macOS 14.0, *)
    private static func cachedShareableContent() async throws -> SCShareableContent {
        shareableContentLock.lock()
        let cached = shareableContentCache
        shareableContentLock.unlock()
        if let cached, Date().timeIntervalSince(cached.timestamp) < 1.5 {
            return cached.content
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        shareableContentLock.lock()
        shareableContentCache = (fresh, Date())
        shareableContentLock.unlock()
        return fresh
    }

    /// Crops a previously captured full-screen image to `rect` (top-left
    /// origin), applying the same Retina scaling as `takeScreenshot(rect:)`.
    /// Lets every consumer reuse the frame frozen at capture start instead of
    /// re-shooting the display.
    func croppedScreenshot(from image: NSImage, rect: CGRect) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logError("frozen screenshot CGImage unreadable, screen=\(localizedName)")
            return nil
        }

        let scale = CGFloat(cgImage.width) / max(bounds.width, 1)
        let scaledCropRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        guard scaledCropRect.width >= 1, scaledCropRect.height >= 1,
              let cropped = cgImage.cropping(to: scaledCropRect) else {
            logError("frozen screenshot crop failed, rect=\(rect), cgImage=\(cgImage.width)x\(cgImage.height)")
            return nil
        }
        return NSImage(cgImage: cropped, size: .zero)
    }

    var bounds: CGRect {
        CGRect(origin: .zero, size: frame.size)
    }

    /// Adjust last screenshot rect to fit within the current screen bounds
    /// - Parameters: lastRect Last screenshot rect, `top-left` origin
    /// - Parameters: currentScreenFrame: Screen where the current screenshot is being taken, `bottom-left` origin
    /// - Returns: Adjusted rect that fits within the current screen, `top-left` origin
    /// - Note: If `currentScreen` contains `lastRect`, the adjusted rect will be the same as lastRect.
    ///        Otherwise, if `lastRect` size is larger than `currentScreen`, the adjusted rect will be scaled down to fit within the screen.
    ///        Else, the adjusted rect location to fit within the screen.
    func adjustedScreenshotRect(_ lastRect: CGRect) -> CGRect {
        logInfo("adjusting last screenshot rect, lastRect=\(lastRect)")

        let screenFrame = frame
        logInfo("current screen frame=\(screenFrame)")

        if lastRect.isEmpty {
            logWarn("rect adjustment aborted, lastRect empty")
            return .zero
        }

        // Convert lastRect from top-left to bottom-left origin for comparison with screen frames
        let lastRectScreenCoordinate = CGRect(
            x: lastRect.origin.x,
            y: screenFrame.height - lastRect.origin.y - lastRect.height,
            width: lastRect.width,
            height: lastRect.height
        )

        // Check if the last rect is completely within current screen's bounds
        let currentScreenBounds = CGRect(origin: .zero, size: screenFrame.size)
        if currentScreenBounds.contains(lastRectScreenCoordinate) {
            logInfo("lastRect fits current screen, no adjustment")
            return lastRect
        }

        // If lastRect size is larger than current screen, scale down to fit within the screen
        if lastRect.width > screenFrame.width || lastRect.height > screenFrame.height {
            logInfo("lastRect larger than screen, scaling down")

            let widthRatio = screenFrame.width / lastRect.width
            let heightRatio = screenFrame.height / lastRect.height
            let scale = min(widthRatio, heightRatio) * 0.9 // Use 90% of screen to leave margin

            let newSize = CGSize(
                width: lastRect.width * scale,
                height: lastRect.height * scale
            )

            // Center in current screen (in top-left coordinates)
            let newX = (screenFrame.width - newSize.width) / 2
            let newY = (screenFrame.height - newSize.height) / 2

            return CGRect(
                x: newX,
                y: newY,
                width: newSize.width,
                height: newSize.height
            )
        }

        // Adjust position to fit within screen
        logInfo("adjusting lastRect position to fit screen")
        var adjustedRect = lastRect

        // Adjust X position
        if adjustedRect.minX < 0 {
            adjustedRect.origin.x = 0
        } else if adjustedRect.maxX > screenFrame.width {
            adjustedRect.origin.x = screenFrame.width - adjustedRect.width
        }

        // Adjust Y position
        if adjustedRect.minY < 0 {
            adjustedRect.origin.y = 0
        } else if adjustedRect.maxY > screenFrame.height {
            adjustedRect.origin.y = screenFrame.height - adjustedRect.height
        }

        logInfo("adjusted rect=\(adjustedRect)")
        return adjustedRect.integral
    }

    /// Get the current mouse screen
    class func currentMouseScreen() -> NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) }
    }
}

extension NSScreen {
    /// Device description string
    var deviceDescriptionString: String {
        // Sort keys to ensure consistent order
        let sortedKeys = deviceDescription.keys.sorted { $0.rawValue < $1.rawValue }

        var description = ""
        for key in sortedKeys {
            if let value = deviceDescription[key] {
                description += "\(key.rawValue): \(value)\n"
            }
        }
        return "{\n\(description)}"
    }

    func isSameScreen(_ other: NSScreen?) -> Bool {
        deviceDescriptionString == other?.deviceDescriptionString
    }
}
