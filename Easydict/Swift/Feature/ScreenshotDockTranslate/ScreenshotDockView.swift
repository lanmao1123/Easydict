//
//  ScreenshotDockView.swift
//  Easydict
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import SwiftUI

// MARK: - ScreenshotDockState

/// Observable state driving the phases of the dock overlay UI, shared by the
/// translate panel and the on-screen highlight window.
final class ScreenshotDockState: NSObject, ObservableObject {
    // MARK: Lifecycle

    override init() {
        let stored = UserDefaults.standard.object(forKey: "dockTranslateFontScale") as? CGFloat
        self.fontScale = min(max(stored ?? 1.0, 0.5), 3.0)
    }

    // MARK: Internal

    /// UI phases of the overlay, from capture feedback to final outcome.
    enum Phase: Equatable {
        case recognizing
        case translating
        case result
        case failed
    }

    @Published var phase: Phase = .recognizing
    /// Source paragraphs in reading order, filled with translations as the
    /// single batched request (or its fallback) completes each one.
    @Published var segments: [DockSegment] = []
    @Published var failureDetail = ""
    /// Overlay width tracks the selection width, set by the manager per capture.
    @Published var overlayWidth: CGFloat = ScreenshotDockLayout.defaultOverlayWidth
    /// Screen rect (global coordinates) of the paragraph currently hovered in
    /// the panel; the highlight window draws over the original pixels there.
    @Published var highlightedRect: CGRect?
    /// Text scale applied to every font in the panel; adjusted with wheel or
    /// pinch over the panel, persisted across sessions.
    @Published var fontScale: CGFloat

    /// Invoked when the user closes the pinned panel (close button or ESC).
    var onCloseRequest: (() -> ())?

    /// True while the panel is the key window (user clicked it), enabling
    /// ESC-to-close and ⌘C-to-copy like an image pin.
    @Published var panelFocused = false

    /// Visible while a scale change is settling: shows the current percentage
    /// so the user can see where the wheel is taking the size.
    @Published var scaleBadge: String?

    /// Applies a multiplicative scale, clamped to readable bounds, persisted.
    /// The floor guards against wheel inertia parking the text at an
    /// unreadably tiny size (a stray 0.5x used to persist forever).
    func scaleFont(by factor: CGFloat) {
        fontScale = min(max(fontScale * factor, 0.75), 3.0)
        UserDefaults.standard.set(fontScale, forKey: "dockTranslateFontScale")
        logInfo("[ScreenshotDock] font scaled, factor=\(factor), now=\(fontScale)")
        showScaleBadge()
    }

    /// Resets the text scale to 100%.
    func resetFontScale() {
        fontScale = 1.0
        UserDefaults.standard.set(fontScale, forKey: "dockTranslateFontScale")
        showScaleBadge()
    }

    /// Resets every field so the overlay can be reused for the next capture.
    /// The font scale intentionally survives sessions.
    func reset() {
        phase = .recognizing
        segments = []
        failureDetail = ""
        overlayWidth = ScreenshotDockLayout.defaultOverlayWidth
        highlightedRect = nil
        panelFocused = false
        scaleBadge = nil
    }

    // MARK: Private

    private var scaleBadgeTask: Task<(), Never>?

    private func showScaleBadge() {
        scaleBadge = "\(Int((fontScale * 100).rounded()))%"
        scaleBadgeTask?.cancel()
        scaleBadgeTask = Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                scaleBadge = nil
            }
        }
    }
}

// MARK: - ScreenshotDockView

/// Content view of the floating overlay: one aligned card per source
/// paragraph (numbered source line + translated text), plus inline loading
/// and failure feedback. Hovering a card highlights the matching original
/// pixels on screen through `state.highlightedRect`.
struct ScreenshotDockView: View {
    // MARK: Internal

    @ObservedObject var state: ScreenshotDockState

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                switch state.phase {
                case .recognizing:
                    LoadingRow(textKey: "screenshot_dock_recognizing", fontScale: state.fontScale)
                        .padding(12)
                case .failed, .result, .translating:
                    ForEach(state.segments) { segment in
                        SegmentCard(
                            segment: segment,
                            fontScale: state.fontScale,
                            isHovered: hoveredSegmentID == segment.id,
                            onHover: { hovering in
                                hoveredSegmentID = hovering ? segment.id : nil
                                state.highlightedRect = hovering ? segment.highlightRect : nil
                            }
                        )
                    }
                    if state.phase == .translating {
                        LoadingRow(textKey: "screenshot_dock_translating", fontScale: state.fontScale)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    if state.phase == .failed {
                        failureCard
                            .padding(12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: state.overlayWidth)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if state.phase == .result || state.phase == .failed {
                Button {
                    state.onCloseRequest?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16 * state.fontScale))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("close")
            }
        }
        .overlay(alignment: .top) {
            if let badge = state.scaleBadge {
                Text(badge)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
    }

    // MARK: Private

    @State private var hoveredSegmentID: Int?

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

// MARK: - SegmentCard

/// One aligned paragraph: numbered source snippet on top, translation below.
/// An accent bar on the leading edge makes the paragraph rhythm scannable.
private struct SegmentCard: View {
    let segment: DockSegment
    let fontScale: CGFloat
    let isHovered: Bool
    let onHover: (Bool) -> ()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(segment.id)")
                    .font(.system(size: 11 * fontScale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 17 * fontScale, height: 17 * fontScale)
                    .background(Circle().fill(Color.accentColor.opacity(0.75)))
                Text(segment.source)
                    .font(.system(size: 15 * fontScale))
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
            if let translation = segment.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 16.5 * fontScale))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(Color.accentColor.opacity(isHovered ? 0.10 : 0.04))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(isHovered ? 0.9 : 0.35))
                .frame(width: 2)
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

// MARK: - LoadingRow

/// Inline progress row showing what the pipeline is currently doing.
/// `textKey` arrives as a raw key string, so it must go through
/// LocalizedStringKey explicitly — Text(String) renders verbatim.
private struct LoadingRow: View {
    let textKey: String
    let fontScale: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizedStringKey(textKey))
                .font(.system(size: 14.5 * fontScale))
                .foregroundStyle(.secondary)
        }
    }
}
