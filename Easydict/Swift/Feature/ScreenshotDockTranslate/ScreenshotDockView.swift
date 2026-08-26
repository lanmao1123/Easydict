//
//  ScreenshotDockView.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

// MARK: - ScreenshotDockState

/// Observable state driving the phases of the dock panel UI.
///
/// The manager transitions the phase from recognizing to translating, then to
/// either the final result or a failure; the view stays a plain function of it.
final class ScreenshotDockState: NSObject, ObservableObject {
    /// UI phases of the panel, from capture feedback to final outcome.
    enum Phase: Equatable {
        case recognizing
        case translating
        case result
        case failed
    }

    @Published var phase: Phase = .recognizing
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var failureDetail = ""
    @Published var isCopied = false

    /// Copies the translated text to the pasteboard and flashes the copy button.
    func copyTranslatedText() {
        guard !translatedText.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)

        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isCopied = false
        }
    }

    /// Resets every field so the panel can be reused for the next capture.
    func reset() {
        phase = .recognizing
        sourceText = ""
        translatedText = ""
        failureDetail = ""
        isCopied = false
    }
}

// MARK: - ScreenshotDockView

/// Content view of the floating panel: loading, source preview plus translated
/// text, or a failure card.
struct ScreenshotDockView: View {
    // MARK: Internal

    @ObservedObject var state: ScreenshotDockState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.phase {
            case .recognizing:
                LoadingRow(textKey: "screenshot_dock_recognizing")
            case .translating:
                sourcePreview
                Divider()
                LoadingRow(textKey: "screenshot_dock_translating")
            case .result:
                HStack(alignment: .top, spacing: 8) {
                    sourcePreview
                    Spacer(minLength: 0)
                }
                Divider()
                HStack(spacing: 8) {
                    Text("screenshot_dock_translated")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    copyButton
                }
                Text(state.translatedText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .lineLimit(maxTranslatedLines)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed:
                failureCard
            }
        }
        .padding(14)
        .frame(width: ScreenshotDockLayout.panelWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: Private

    private let maxSourceLines = 3
    private let maxTranslatedLines = 24

    /// Short quote of the recognized text; the original stays fully readable
    /// on screen right beside the panel, so only a preview lives here.
    private var sourcePreview: some View {
        Text(state.sourceText)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(maxSourceLines)
            .truncationMode(.tail)
    }

    private var copyButton: some View {
        Button {
            state.copyTranslatedText()
        } label: {
            Label(
                state.isCopied ? "screenshot_dock_copied" : "screenshot_dock_copy",
                systemSymbol: state.isCopied ? .checkmark : .docOnDoc
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11))
            .foregroundStyle(state.isCopied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(Text("screenshot_dock_copy"))
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("screenshot_dock_translation_failed", systemSymbol: .exclamationmarkTriangleFill)
                .font(.system(size: 13))
                .foregroundStyle(.red)
            if !state.failureDetail.isEmpty {
                Text(state.failureDetail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
        }
    }
}

// MARK: - LoadingRow

/// Inline progress row showing what the pipeline is currently doing.
private struct LoadingRow: View {
    let textKey: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(textKey)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
