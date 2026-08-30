//
//  ScreenshotDockManager.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon.HIToolbox
import Defaults
import SwiftUI

/// Orchestrates the screenshot dock translate flow: capture a selection,
/// keep the original pixels untouched on screen and dock a translation
/// overlay against the selection — below it when there is room, otherwise
/// above. Recognized paragraphs stay aligned with their original pixels
/// (hovering a translated card highlights them) and one batched streaming
/// request translates every paragraph in a single round trip.
///
/// The overlay closes itself on an outside click or the ESC key.
@MainActor
final class ScreenshotDockManager: NSObject {
    // MARK: Internal

    static let shared = ScreenshotDockManager()

    /// Starts a fresh dock translate session.
    func start() {
        logInfo("dock translate start requested")
        // Close other floating query windows first so they do not cover the area.
        EZWindowManager.shared().closeFloatingWindowIfNotPinnedOrMain()

        // The panel must survive the session, and restoring the previous app
        // would fire the resign-active cancellation right after the capture.
        Screenshot.shared.shouldRestorePreviousApp = false
        Screenshot.shared.startCapture { [weak self] image in
            guard let self else { return }
            guard let image else {
                logInfo("dock translate aborted, capture returned no image")
                // A nil capture (permission denied / user cancelled) must not
                // leave the recognizing panel hanging on screen.
                teardownPanelOnly()
                return
            }
            handleCapturedImage(image)
        }
    }

    /// Closes the overlay, cancels pending work and removes all listeners.
    func dismiss() {
        translateTask?.cancel()
        translateTask = nil
        detectManager = nil
        removeEventMonitors()
        teardownPanelOnly()
    }

    #if DEBUG
    /// Headless verification of the font-scale pipeline and persistence.
    func debugScaleFont() {
        let before = state.fontScale
        state.scaleFont(by: 1.3)
        let stored = UserDefaults.standard.object(forKey: "dockTranslateFontScale") as? CGFloat ?? -1
        logInfo(
            "[ScreenshotDock] debug-scale applied, \(before)->\(state.fontScale), stored=\(stored)"
        )
    }

    /// Headless regression: drives the real translation pipeline (service
    /// pick, batched numbered-line request, parsing, state backfill) with
    /// synthetic paragraphs — no screen capture permission required.
    func debugTranslate() {
        let sources = [
            "The quick brown fox jumps over the lazy dog near the river bank.",
            "Artificial intelligence has transformed how people work and learn.",
            "Sunset paints the sky in orange and purple while birds fly home.",
        ]
        state.reset()
        selectionRect = CGRect(x: 400, y: 300, width: 800, height: 300)
        state.overlayWidth = 480
        state.segments = sources.enumerated().map { index, source in
            DockSegment(id: index + 1, source: source, highlightRect: nil, translation: nil)
        }
        state.phase = .translating
        showPanel()
        translateTask = Task {
            let services = pickTranslationServices()
            guard !services.isEmpty else {
                finishFailure("no service")
                return
            }
            try? await translateSegments(sources, services: services, sourceLanguage: .english)
            logInfo("debug-dock-translate finished, translated=\(state.segments.compactMap { $0.translation }.count)/3")
        }
    }
    #endif

    // MARK: Private

    private var panel: ScreenshotDockPanel?
    private var highlightPanel: ScreenshotDockHighlightPanel?
    private let state = ScreenshotDockState()

    /// Keeps the OCR helper alive until its async completion fires.
    private var detectManager: DetectManager?
    private var translateTask: Task<(), Never>?

    private var eventMonitors: [Any] = []
    private var selectionRect = CGRect.zero
    private weak var dockScreen: NSScreen?

    /// While translating, an outside click or ESC cancels the run; once a
    /// result (or failure) is pinned, the panel stays on screen like an image
    /// pin — only its close button, ESC (panel selected) or a fresh session
    /// remove it.
    private var isWorkInProgress: Bool {
        state.phase == .recognizing || state.phase == .translating
    }

    private func handleCapturedImage(_ image: NSImage) {
        logInfo("dock captured image, size=\(image.size)")
        guard let screen = Screenshot.shared.lastScreen else {
            logWarn("Cannot place dock overlay without a known screen")
            return
        }
        let localRect = Screenshot.shared.lastScreenshotRect
        let capturedRect = ScreenshotDockLayout.globalRect(
            fromLocalRect: localRect,
            screenFrame: screen.frame
        )
        guard capturedRect != .zero else {
            logWarn("Skip dock translate because selection rect is empty")
            return
        }
        selectionRect = capturedRect
        dockScreen = screen

        state.reset()
        state.overlayWidth = ScreenshotDockLayout.overlayWidth(
            forSelectionWidth: selectionRect.width
        )
        state.phase = .recognizing
        showPanel()

        logInfo("dock OCR starts, selection=\(capturedRect)")
        translateTask = Task {
            do {
                // Position-aware OCR: lines keep their normalized Vision
                // bounding boxes so paragraphs stay aligned with the pixels.
                let lines = try await AppleOCREngine().recognizeSegments(image: image)
                let paragraphs = ScreenshotDockLayout.paragraphs(fromLines: lines)
                logInfo("dock OCR done, lines=\(lines.count), paragraphs=\(paragraphs.count)")
                guard !paragraphs.isEmpty else {
                    showToast(key: "screenshot_dock_no_text_detected")
                    dismiss()
                    return
                }

                let segments = paragraphs.enumerated().map { index, paragraph in
                    let screenRect = ScreenshotDockLayout.segmentScreenRect(
                        paragraph.rect, in: selectionRect
                    )
                    return DockSegment(
                        id: index + 1,
                        source: paragraph.text,
                        highlightRect: highlightLocalRect(screenRect),
                        translation: nil
                    )
                }
                state.segments = segments
                state.phase = .translating
                refreshLayout()

                let services = pickTranslationServices()
                guard !services.isEmpty else {
                    finishFailure(
                        NSLocalizedString("screenshot_dock_no_translation_service", comment: "")
                    )
                    return
                }

                // Resolve the source language once for the whole batch.
                let mergedText = segments.map { $0.source }.joined(separator: "\n")
                var sourceLanguage = Language.auto
                do {
                    let detectedModel = try await DetectManager().detectText(mergedText)
                    sourceLanguage = detectedModel.detectedLanguage
                } catch {
                    finishFailure(error.localizedDescription)
                    return
                }

                try await translateSegments(
                    segments.map { $0.source },
                    services: services,
                    sourceLanguage: sourceLanguage
                )
            } catch is CancellationError {
                logInfo("dock flow cancelled")
            } catch {
                finishFailure(error.localizedDescription)
            }
        }
    }

    // MARK: Translation

    /// Translates every paragraph with a service fallback chain: each enabled
    /// service gets a concurrent per-segment pass (every segment is its own
    /// request, so results never cross-contaminate); a rate-limited or
    /// failing service automatically hands off to the next one.
    private func translateSegments(
        _ sources: [String],
        services: [QueryService],
        sourceLanguage: Language
    ) async throws {
        guard !Task.isCancelled else { return }

        // Source == target means there is nothing to translate; echoing the
        // source paragraphs avoids a wasted round trip and a confusing result.
        let targetLanguage = Defaults[.firstLanguage]
        if sourceLanguage == targetLanguage {
            for (index, source) in sources.enumerated() {
                updateSegment(index: index, translation: source)
            }
            completeFlow()
            logInfo("dock translation skipped, source equals target")
            return
        }

        var lastError = ""
        for service in services {
            let serviceName = service.serviceType().rawValue
            guard !Task.isCancelled else { return }
            do {
                try await translateSegmentsWithService(
                    sources, service: service, sourceLanguage: sourceLanguage
                )
                logInfo("dock translation succeeded via \(serviceName)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
                logWarn("dock service \(serviceName) failed: \(lastError), trying next")
                // Reset any partial translations before the next attempt.
                for index in state.segments.indices {
                    state.segments[index].translation = nil
                }
                refreshLayout()
            }
        }
        finishFailure("\(serviceName(of: services.last)): \(lastError)")
    }

    private func serviceName(of service: QueryService?) -> String {
        service?.name() ?? "translation"
    }

    /// One service attempt: every segment is translated by its own request
    /// (all segments in parallel) so a malformed reply can only affect its
    /// own paragraph. Throws when any segment fails, letting the caller fall
    /// through to the next service.
    private func translateSegmentsWithService(
        _ sources: [String],
        service: QueryService,
        sourceLanguage: Language
    ) async throws {
        // contentStreamTranslate-style paths write into service.result, an
        // implicitly unwrapped optional only initialized by startQuery —
        // prime it here or the first access crashes.
        if service.result == nil {
            service.result = QueryResult()
        }

        var perSegmentErrors: [String] = []
        await withTaskGroup(of: (Int, String, String?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let queryModel = QueryModel()
                    queryModel.inputText = source
                    queryModel.detectedLanguage = sourceLanguage
                    do {
                        // Route through startQuery so the service prepares its
                        // result lifecycle; bare translate crashes services
                        // like Youdao (result stays nil).
                        let result = try await service.startQuery(queryModel)
                        if let resultError = result.error {
                            return (index, "", resultError.localizedDescription)
                        }
                        let translated = result.translatedResults?.joined(separator: "\n")
                            ?? result.translatedText
                            ?? ""
                        return (index, translated, nil)
                    } catch {
                        return (index, "", error.localizedDescription)
                    }
                }
            }
            for await (index, translation, errorText) in group {
                if let errorText {
                    perSegmentErrors.append(errorText)
                } else if !translation.isEmpty {
                    updateSegment(index: index, translation: translation)
                }
            }
        }
        if !perSegmentErrors.isEmpty {
            throw QueryError(type: .api, message: perSegmentErrors.first!)
        }
        let done = state.segments.filter { $0.translation?.isEmpty == false }.count
        if done < sources.count {
            throw QueryError(type: .api, message: "translated \(done)/\(sources.count) segments")
        }
    }

    private func updateSegment(index: Int, translation: String) {
        guard state.segments.indices.contains(index) else { return }
        state.segments[index].translation = translation
        refreshLayout()
    }

    /// Converts a paragraph's global rect into the highlight window's local
    /// space (selection-covering, top-left origin, as SwiftUI expects).
    private func highlightLocalRect(_ screenRect: CGRect) -> CGRect {
        CGRect(
            x: screenRect.minX - selectionRect.minX,
            y: selectionRect.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    /// All enabled text-translation services in user configured order; the
    /// translate pass walks this list so a rate-limited service falls through
    /// to the next one automatically.
    private func pickTranslationServices() -> [QueryService] {
        let candidates = LocalStorage.shared().enabledServices(.main)
        logInfo(
            "dock service picking, candidates=\(candidates.map { "\($0.serviceType().rawValue)(enabled=\($0.enabledQuery),auto=\($0.enabledAutoQuery),types=\($0.supportedQueryType().rawValue))" })"
        )
        let picked = candidates.filter { service in
            service.enabledQuery
                && service.enabledAutoQuery
                && service.supportedQueryType().contains(.translation)
        }
        logInfo("dock services ordered, names=\(picked.map { $0.serviceType().rawValue })")
        return picked
    }

    // MARK: Panel Lifecycle

    private func showPanel() {
        teardownPanelOnly()
        state.onCloseRequest = { [weak self] in
            self?.dismiss()
        }
        let newPanel = ScreenshotDockPanel(state: state)
        panel = newPanel
        let newHighlight = ScreenshotDockHighlightPanel(frame: selectionRect, state: state)
        highlightPanel = newHighlight
        refreshLayout()
        newPanel.orderFrontRegardless()
        newHighlight.orderFrontRegardless()
        installEventMonitors()
        logInfo("dock panel shown")
    }

    /// Recomputes overlay content size and docked origin for the current phase.
    ///
    /// Called asynchronously so SwiftUI publishes pending state changes before
    /// the fitting size is measured.
    private func refreshLayout() {
        guard let panel else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.panel, current === panel else { return }
            layoutPanel(current)
        }
    }

    private func layoutPanel(_ targetPanel: ScreenshotDockPanel) {
        guard let screen = dockScreen ?? NSScreen.main else { return }

        let contentSize = preferredContentSize(limitFrame: screen.visibleFrame)
        targetPanel.setContentSize(contentSize)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: contentSize,
            selectionGlobalRect: selectionRect,
            visibleFrame: screen.visibleFrame
        )
        targetPanel.setFrameOrigin(origin)
    }

    private func preferredContentSize(limitFrame: NSRect) -> NSSize {
        var size = (panel?.contentView as? NSHostingView<ScreenshotDockView>)?.fittingSize ?? .zero
        size.width = state.overlayWidth
        size.height = max(size.height, 44)

        let maxHeight = limitFrame.insetBy(
            dx: ScreenshotDockLayout.screenMargin,
            dy: ScreenshotDockLayout.screenMargin
        ).height
        if size.height > maxHeight {
            size.height = maxHeight
        }
        return size
    }

    private func teardownPanelOnly() {
        // orderOut takes the window off screen and close releases it from the
        // app window list; dropping the reference alone leaves it visible.
        if panel != nil || highlightPanel != nil {
            logInfo("dock panel torn down")
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        highlightPanel?.orderOut(nil)
        highlightPanel?.close()
        highlightPanel = nil
    }

    // MARK: Outcome Helpers

    /// Marks the flow finished once the translation pass has run.
    private func completeFlow() {
        state.phase = .result
        refreshLayout()
    }

    /// Shows the failure card inside the overlay instead of closing it, so the
    /// user can read why nothing was translated; already translated blocks stay.
    private func finishFailure(_ detail: String) {
        state.failureDetail = detail
        state.phase = .failed
        refreshLayout()
    }

    private func showToast(key: String) {
        EZToast.showText(NSLocalizedString(key, comment: ""))
    }

    // MARK: Event Monitoring

    private func installEventMonitors() {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .keyDown]

        // Global events only arrive while another app is active; any click there
        // must be outside the overlay.
        eventMonitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleOutsideEvent(event)
            }
        )

        eventMonitors.append(
            NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleLocalEvent(event)
                return event
            }
        )
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    private func handleOutsideEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == kVK_Escape, isWorkInProgress {
                logInfo("dock dismissed via global ESC")
                dismiss()
            }
            return
        }
        if isWorkInProgress {
            logInfo("dock dismissed via global outside click")
            dismiss()
        }
    }

    @discardableResult
    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘C on a focused panel copies the whole translation.
            if flags == .command, event.keyCode == kVK_ANSI_C,
               state.panelFocused, event.window === panel {
                copyTranslation()
                return nil
            }
            if event.keyCode == kVK_Escape {
                if isWorkInProgress {
                    dismiss()
                    return nil
                }
                if state.panelFocused, event.window === panel {
                    logInfo("dock pinned panel closed via ESC")
                    dismiss()
                    return nil
                }
            }
            return nil
        }
        // While working, a click inside our process but outside the overlay
        // cancels; a pinned result ignores outside clicks entirely.
        if isWorkInProgress, event.windowNumber != panel?.windowNumber {
            logInfo("dock dismissed via local outside click")
            dismiss()
        }
        return nil
    }

    private func copyTranslation() {
        let text = state.segments.compactMap { segment -> String? in
            guard let translation = segment.translation, !translation.isEmpty else { return nil }
            return translation
        }
        .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        EZToast.showText(NSLocalizedString("screenshot_dock_copied", comment: ""))
        logInfo("dock translation copied, chars=\(text.count)")
    }
}
