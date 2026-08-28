//
//  ScreenshotDockManager.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Orchestrates the screenshot dock translate flow: capture a selection, keep
/// the original pixels untouched on screen and dock a single translation
/// overlay against the selection — below it when there is room, otherwise
/// above — filling the overlay with per-segment translations in source order.
///
/// Triggered by a dedicated global shortcut; existing screenshot actions are
/// untouched. The overlay closes itself on an outside click or the ESC key.
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

    // MARK: Private

    private var panel: ScreenshotDockPanel?
    private let state = ScreenshotDockState()

    /// Keeps the OCR helper alive until its async completion fires.
    private var detectManager: DetectManager?
    private var translateTask: Task<(), Never>?

    private var eventMonitors: [Any] = []
    private var selectionRect = CGRect.zero
    private weak var dockScreen: NSScreen?

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
        showPanel()

        logInfo("dock OCR starts, selection=\(capturedRect)")
        let model = QueryModel()
        model.ocrImage = image
        let ocrManager = DetectManager(model: model)
        detectManager = ocrManager
        ocrManager.ocr { [weak self] ocrResult, error in
            self?.handleOCRResult(ocrResult, error)
        }
    }

    private func handleOCRResult(_ ocrResult: EZOCRResult?, _ error: Error?) {
        detectManager = nil
        logInfo(
            "dock OCR done, segments=\(ocrResult?.ocrTextArray.count ?? 0), mergedChars=\(ocrResult?.mergedText.count ?? 0), error=\(error?.localizedDescription ?? "nil")"
        )

        let segmentTexts = (ocrResult?.ocrTextArray as? [EZOCRText] ?? [])
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mergedText = ocrResult?.mergedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let sourceBlocks = normalizedSourceBlocks(segments: segmentTexts, mergedText: mergedText)
        if error != nil || sourceBlocks.isEmpty {
            if let error {
                logError("Screenshot dock OCR failed: \(error.localizedDescription)")
            }
            showToast(key: "screenshot_dock_no_text_detected")
            dismiss()
            return
        }

        guard let service = pickTranslationService() else {
            finishFailure(NSLocalizedString("screenshot_dock_no_translation_service", comment: ""))
            return
        }

        // Mirror the selection width, then translate segment by segment so each
        // translated block lands in source order like the Youdao compare mode.
        state.overlayWidth = ScreenshotDockLayout.overlayWidth(
            forSelectionWidth: selectionRect.width
        )
        state.pendingCount = sourceBlocks.count
        state.phase = .translating
        refreshLayout()

        translateTask = Task {
            logInfo("dock translation begins, blocks=\(sourceBlocks.count)")
            // Resolve the source language once for all blocks: OCR usually
            // carries it; otherwise fall back to text detection. Services
            // reject an .auto source, which the window flow detects upstream.
            var sourceLanguage = ocrResult?.from ?? .auto
            if sourceLanguage == .auto {
                do {
                    let detectedModel = try await DetectManager().detectText(mergedText)
                    sourceLanguage = detectedModel.detectedLanguage
                } catch {
                    finishFailure(error.localizedDescription)
                    return
                }
            }

            var blockIndex = 0
            for block in sourceBlocks {
                blockIndex += 1
                if Task.isCancelled {
                    logInfo("dock translation cancelled at block \(blockIndex)")
                    return
                }

                do {
                    // Route through the official startQuery entry so the service
                    // prepares its result lifecycle; bare translate leaves the
                    // internal `result` nil and crashes services like Youdao.
                    let queryModel = QueryModel()
                    queryModel.inputText = block
                    queryModel.detectedLanguage = sourceLanguage
                    let result = try await service.startQuery(queryModel)

                    if let resultError = result.error {
                        finishFailure(resultError.localizedDescription)
                        return
                    }
                    let translated = result.translatedResults?.joined(separator: "\n")
                        ?? result.translatedText
                        ?? ""
                    logInfo("dock block translated, index=\(blockIndex), chars=\(translated.count)")
                    appendTranslationBlock(translated)
                } catch {
                    finishFailure(error.localizedDescription)
                    return
                }
            }
            completeFlow()
        }
    }

    /// Groups OCR segments into translation blocks, keeping source order; long
    /// segment lists are merged so the overlay never issues a long request chain.
    private func normalizedSourceBlocks(segments: [String], mergedText: String) -> [String] {
        var blocks = segments
        if blocks.isEmpty {
            blocks = mergedText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if blocks.isEmpty, !mergedText.isEmpty {
            blocks = [mergedText]
        }

        let maxBlocks = 8
        if blocks.count > maxBlocks {
            let groupSize = Int((Double(blocks.count) / Double(maxBlocks)).rounded(.up))
            var merged: [String] = []
            for start in stride(from: 0, to: blocks.count, by: groupSize) {
                let end = min(start + groupSize, blocks.count)
                merged.append(blocks[start ..< end].joined(separator: "\n"))
            }
            blocks = merged
        }
        return blocks
    }

    /// First enabled text-translation service, following the user configured order.
    private func pickTranslationService() -> QueryService? {
        let candidates = LocalStorage.shared().enabledServices(.main)
        logInfo(
            "dock service picking, candidates=\(candidates.map { "\($0.serviceType().rawValue)(enabled=\($0.enabledQuery),auto=\($0.enabledAutoQuery),types=\($0.supportedQueryType().rawValue))" })"
        )
        let picked = candidates.first { service in
            service.enabledQuery
                && service.enabledAutoQuery
                && service.supportedQueryType().contains(.translation)
        }
        if let picked {
            logInfo("dock service picked, service=\(picked.serviceType().rawValue)")
        } else {
            logWarn("dock service picking found none")
        }
        return picked
    }

    // MARK: Panel Lifecycle

    private func showPanel() {
        teardownPanelOnly()
        let newPanel = ScreenshotDockPanel(state: state)
        panel = newPanel
        refreshLayout()
        newPanel.orderFrontRegardless()
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
        if panel != nil {
            logInfo("dock panel torn down")
        }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: Outcome Helpers

    private func appendTranslationBlock(_ translated: String) {
        state.pendingCount = max(0, state.pendingCount - 1)
        guard !translated.isEmpty else { return }
        state.translatedBlocks.append(translated)
        refreshLayout()
    }

    /// Marks the flow finished once every source segment has been translated.
    private func completeFlow() {
        state.pendingCount = 0
        if state.translatedBlocks.isEmpty {
            finishFailure(NSLocalizedString("screenshot_dock_translation_failed", comment: ""))
        } else {
            state.phase = .result
            refreshLayout()
        }
    }

    /// Shows the failure card inside the overlay instead of closing it, so the
    /// user can read why nothing was translated; already translated blocks stay.
    private func finishFailure(_ detail: String) {
        state.failureDetail = detail
        state.phase = .failed
        state.pendingCount = 0
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
            if event.keyCode == kVK_Escape {
                logInfo("dock dismissed via global ESC")
                dismiss()
            }
            return
        }
        logInfo("dock dismissed via global outside click")
        dismiss()
    }

    private func handleLocalEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == kVK_Escape {
                dismiss()
            }
            return
        }
        // Clicks within our own process count as inside only when they hit the overlay.
        if event.windowNumber != panel?.windowNumber {
            logInfo("dock dismissed via local outside click")
            dismiss()
        }
    }
}
