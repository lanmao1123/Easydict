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
/// the original pixels untouched on screen, dock a floating result panel beside
/// it and fill the panel asynchronously with OCR text and its translation.
///
/// Triggered by a dedicated global shortcut; existing screenshot actions are
/// untouched. The panel closes itself on an outside click or the ESC key.
@MainActor
final class ScreenshotDockManager: NSObject {
    // MARK: Internal

    static let shared = ScreenshotDockManager()

    /// Starts a fresh dock translate session.
    func start() {
        // Close other floating query windows first so they do not cover the area.
        EZWindowManager.shared().closeFloatingWindowIfNotPinnedOrMain()

        Screenshot.shared.startCapture { [weak self] image in
            guard let self, let image else { return }
            handleCapturedImage(image)
        }
    }

    /// Closes the panel, cancels pending work and removes all listeners.
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
        guard let screen = Screenshot.shared.lastScreen else {
            logWarn("Cannot place dock panel without a known screen")
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

        let model = QueryModel()
        model.ocrImage = image
        let ocrManager = DetectManager(model: model)
        detectManager = ocrManager
        ocrManager.ocrAndDetectText { [weak self] model, error in
            self?.handleOCRResult(model: model, error: error)
        }
    }

    private func handleOCRResult(model: QueryModel, error: Error?) {
        detectManager = nil

        let sourceText = model.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if error != nil || sourceText.isEmpty {
            if let error {
                logError("Screenshot dock OCR failed: \(error.localizedDescription)")
            }
            showToast(key: "screenshot_dock_no_text_detected")
            dismiss()
            return
        }

        state.sourceText = sourceText
        state.phase = .translating
        refreshLayout()

        guard let service = pickTranslationService() else {
            failureDetail(NSLocalizedString("screenshot_dock_no_translation_service", comment: ""))
            return
        }

        let sourceLanguage = model.detectedLanguage
        let targetLanguage = EZLanguageManager.shared().userTargetLanguage(
            withSourceLanguage: sourceLanguage
        )
        let text = model.inputText

        translateTask = Task { [weak self] in
            do {
                let result = try await service.translate(text, from: sourceLanguage, to: targetLanguage)
                guard let self else { return }

                if let resultError = result.error {
                    finishFailure(resultError.localizedDescription)
                    return
                }
                let translated = result.translatedResults?.joined(separator: "\n")
                finishTranslation(translated ?? result.translatedText ?? "")
            } catch {
                guard let self else { return }
                finishFailure(error.localizedDescription)
            }
        }
    }

    /// First enabled text-translation service, following the user configured order.
    private func pickTranslationService() -> QueryService? {
        LocalStorage.shared().enabledServices(.main).first { service in
            service.enabledQuery
                && service.enabledAutoQuery
                && service.supportedQueryType().contains(.translation)
        }
    }

    // MARK: Panel Lifecycle

    private func showPanel() {
        teardownPanelOnly()
        let newPanel = ScreenshotDockPanel(state: state)
        panel = newPanel
        refreshLayout()
        newPanel.orderFrontRegardless()
        installEventMonitors()
    }

    /// Recomputes panel content size and docked origin for the current phase.
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
        let screenFrame = dockScreen?.frame ?? NSScreen.main?.frame
        guard let screenFrame, let screen = dockScreen ?? NSScreen.main else { return }

        let preferredSize = preferredContentSize(of: targetPanel, limitFrame: screen.visibleFrame)
        targetPanel.setContentSize(preferredSize)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: preferredSize,
            selectionGlobalRect: selectionRect,
            visibleFrame: screen.visibleFrame
        )
        targetPanel.setFrameOrigin(origin)
    }

    private func preferredContentSize(of targetPanel: ScreenshotDockPanel, limitFrame: NSRect) -> NSSize {
        var size = (targetPanel.contentView as? NSHostingView<ScreenshotDockView>)?.fittingSize ?? .zero
        size.width = ScreenshotDockLayout.panelWidth
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
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: Outcome Helpers

    private func finishTranslation(_ translatedText: String) {
        if translatedText.isEmpty {
            finishFailure(NSLocalizedString("screenshot_dock_translation_failed", comment: ""))
            return
        }
        state.translatedText = translatedText
        state.phase = .result
        refreshLayout()
    }

    /// Shows the failure card inside the panel instead of closing it, so the
    /// user can read why nothing was translated.
    private func finishFailure(_ detail: String) {
        failureDetail(detail)
    }

    private func failureDetail(_ detail: String) {
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
        // must be outside the panel.
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
                dismiss()
            }
            return
        }
        dismiss()
    }

    private func handleLocalEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == kVK_Escape {
                dismiss()
            }
            return
        }
        // Clicks within our own process count as inside only when they hit the panel.
        if event.windowNumber != panel?.windowNumber {
            dismiss()
        }
    }
}
