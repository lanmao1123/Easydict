//
//  ScreenshotDockView.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import SwiftUI

// MARK: - ScreenshotDockState

/// Observable state driving the phases of the dock overlay UI.
///
/// Mirrors the Youdao "对照" experience: the original pixels stay untouched on
/// screen while translated blocks, one per recognized source segment, fill the
/// overlay in source order.
final class ScreenshotDockState: NSObject, ObservableObject {
    /// UI phases of the overlay, from capture feedback to final outcome.
    enum Phase: Equatable {
        case recognizing
        case translating
        case result
        case failed
    }

    @Published var phase: Phase = .recognizing
    /// Translated blocks in source segment order, appended as each finishes.
    @Published var translatedBlocks: [String] = []
    /// Number of source segments still waiting for their translation.
    @Published var pendingCount = 0
    @Published var failureDetail = ""
    /// Overlay width tracks the selection width, set by the manager per capture.
    @Published var overlayWidth: CGFloat = ScreenshotDockLayout.defaultOverlayWidth

    /// Resets every field so the overlay can be reused for the next capture.
    func reset() {
        phase = .recognizing
        translatedBlocks = []
        pendingCount = 0
        failureDetail = ""
        overlayWidth = ScreenshotDockLayout.defaultOverlayWidth
    }
}

// MARK: - ScreenshotDockView

/// Content view of the floating overlay: translated paragraph blocks stacked in
/// source order, plus inline loading and failure feedback.
struct ScreenshotDockView: View {
    // MARK: Internal

    @ObservedObject var state: ScreenshotDockState

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                switch state.phase {
                case .recognizing:
                    LoadingRow(textKey: "screenshot_dock_recognizing")
                case .failed, .result, .translating:
                    // Each block mirrors one source bullet (the checkmarks in
                    // the screenshot), so the translation reads "one segment
                    // per original item" instead of a wall of text.
                    ForEach(Array(state.translatedBlocks.enumerated()), id: \.offset) { _, block in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                                .padding(.top, 2)
                            Text(block)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if state.pendingCount > 0 {
                        LoadingRow(textKey: "screenshot_dock_translating")
                    }
                    if state.phase == .failed {
                        failureCard
                    }
                }
            }
            .padding(12)
            .frame(width: state.overlayWidth, alignment: .leading)
        }
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
