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
///
/// Text sizes are fixed: the previous wheel/pinch scaling persisted stray
/// factors twice (0.5x then 1.52x) and kept breaking the calibrated layout,
/// so scaling was removed entirely.
final class ScreenshotDockState: NSObject, ObservableObject {
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
    /// Invoked when the user closes the pinned panel (close button or ESC).
    var onCloseRequest: (() -> ())?

    /// Invoked when the user toggles a card's pronunciation control; the
    /// payload is the segment's array index. The manager owns the AI request.
    var onPronunciationRequest: ((Int) -> ())?

    /// True while the panel is the key window (user clicked it), enabling
    /// ESC-to-close and ⌘C-to-copy like an image pin.
    @Published var panelFocused = false

    /// Resets every field so the overlay can be reused for the next capture.
    func reset() {
        phase = .recognizing
        segments = []
        failureDetail = ""
        overlayWidth = ScreenshotDockLayout.defaultOverlayWidth
        highlightedRect = nil
        panelFocused = false
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
                    LoadingRow(textKey: "screenshot_dock_recognizing")
                        .padding(12)
                case .failed, .result, .translating:
                    ForEach(state.segments) { segment in
                        SegmentCard(
                            segment: segment,
                            isHovered: hoveredSegmentID == segment.id,
                            onHover: { hovering in
                                hoveredSegmentID = hovering ? segment.id : nil
                                state.highlightedRect = hovering ? segment.highlightRect : nil
                            },
                            onPronunciationToggle: {
                                state.onPronunciationRequest?(segment.id - 1)
                            }
                        )
                    }
                    if state.phase == .translating {
                        LoadingRow(textKey: "screenshot_dock_translating")
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
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("close")
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
/// Short non-Chinese sources show a "读法" toggle that reveals the
/// Chinese-character phonetic rendering of the English text. Font sizes are
/// fixed constants — deliberately not user-scalable.
private struct SegmentCard: View {
    // MARK: Internal

    let segment: DockSegment
    let isHovered: Bool
    let onHover: (Bool) -> ()
    let onPronunciationToggle: () -> ()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(segment.id)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(Color.accentColor.opacity(0.75)))
                Text(segment.source)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
            }
            if let translation = segment.translation, !translation.isEmpty {
                HStack(alignment: .top) {
                    Text(translation)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if segment.pronunciationEligible {
                        Spacer(minLength: 8)
                        HStack(spacing: 5) {
                            speakButton
                            pronunciationButton
                        }
                    }
                }
                if segment.showPronunciation,
                   let pronunciation = segment.pronunciation, !pronunciation.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(localized: "screenshot_dock_pronunciation_button"))
                            .font(.system(size: 11, weight: .semibold))
                        Text(pronunciation)
                            .font(.system(size: 14, weight: .medium))
                            .textSelection(.enabled)
                        if let pinyin = pronunciation.chinesePinyin {
                            Text("(\(pinyin))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 2)
                }
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

    // MARK: Private

    /// Speaker capsule: reads the English source aloud with the local
    /// system voice — works without expanding the phonetic row.
    @ViewBuilder
    private var speakButton: some View {
        Button {
            PronunciationSpeaker.speak(segment.source)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help("speak")
    }

    /// Capsule toggle next to the translation: tap once to fetch + reveal the
    /// phonetic rendering, then tap again to hide/show the cached result.
    @ViewBuilder
    private var pronunciationButton: some View {
        Button(action: onPronunciationToggle) {
            if segment.pronunciationLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 34, height: 16)
            } else {
                Text(String(localized: "screenshot_dock_pronunciation_button"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            Color.accentColor.opacity(segment.showPronunciation ? 0.9 : 0.5)
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .help("pronunciation")
    }
}

// MARK: - Pinyin

/// Local pinyin support for the pronunciation row: the phonetic rendering
/// sometimes contains rare characters (呙、汀) the user cannot read either.
extension String {
    /// Mandarin pinyin with tone marks for the Chinese characters in the
    /// string ("呙入汀" → "guō rù tīng"); nil when there are none.
    fileprivate var chinesePinyin: String? {
        guard contains(where: { $0.isChineseCharacter }) else { return nil }
        let mutable = NSMutableString(string: self) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        return mutable as String
    }
}

extension Character {
    fileprivate var isChineseCharacter: Bool {
        unicodeScalars.allSatisfy { $0.properties.isIdeographic }
    }
}

// MARK: - LoadingRow

/// Inline progress row showing what the pipeline is currently doing.
/// `textKey` arrives as a raw key string, so it must go through
/// LocalizedStringKey explicitly — Text(String) renders verbatim.
private struct LoadingRow: View {
    let textKey: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizedStringKey(textKey))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
