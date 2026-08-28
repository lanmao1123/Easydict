//
//  EditToolbarView.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

/// Floating toolbar of the screenshot editor: tools, color and width pickers,
/// undo/redo, and the confirm / save-with-path / cancel exits. Docked under
/// the selection (or above it when the space below is too tight).
struct EditToolbarView: View {
    // MARK: Lifecycle

    init(editor: AnnotationEditorState, model: AnnotationModel, containerSize: CGSize) {
        self.editor = editor
        self.model = model
        self.containerSize = containerSize
    }

    // MARK: Internal

    @ObservedObject var editor: AnnotationEditorState
    @ObservedObject var model: AnnotationModel

    /// Size of the overlay hosting view, used to keep the bar on screen.
    let containerSize: CGSize

    var body: some View {
        HStack(spacing: 12) {
            toolGroup
            separator
            paletteGroup
            separator
            widthButton
            separator
            historyGroup
            separator
            exitGroup
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(capsuleBackground)
        .foregroundStyle(.white)
        .background(toolbarGeometryReader)
        .position(clampedPosition)
    }

    // MARK: Private

    private static let edgeMargin: CGFloat = 8
    private static let dockGap: CGFloat = 10

    @State private var measuredSize: CGSize = .init(width: 560, height: 46)

    // MARK: Placement

    private var clampedPosition: CGPoint {
        let rect = editor.selectionRect
        let margin = Self.edgeMargin
        let gap = Self.dockGap

        let halfW = measuredSize.width / 2
        var x = max(halfW + margin, min(rect.midX, containerSize.width - halfW - margin))

        let halfH = measuredSize.height / 2
        let preferredY = rect.maxY + gap + halfH
        let maxY = containerSize.height - halfH - margin
        var y = preferredY <= maxY ? preferredY : max(rect.minY - gap - halfH, halfH + margin)

        y = min(y, maxY)
        return CGPoint(x: x, y: y)
    }

    private var fontSizeBadge: String {
        switch editor.textFontSize {
        case ..<15: "S"
        case ..<19: "M"
        default: "L"
        }
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .overlay(Color.white.opacity(0.35))
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(Color.black.opacity(0.85))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    private var toolbarGeometryReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { measuredSize = geometry.size }
                .onChange(of: geometry.size) { newSize in
                    measuredSize = newSize
                }
        }
    }

    // MARK: Groups

    private var toolGroup: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases.filter { $0 != .eraser }, id: \.rawValue) { tool in
                toolButton(tool)
            }
            Divider()
                .frame(height: 16)
                .overlay(Color.white.opacity(0.3))
            toolButton(.eraser)
        }
    }

    private var paletteGroup: some View {
        HStack(spacing: 6) {
            ForEach(Array(AnnotationEditorState.palette.enumerated()), id: \.offset) { index, color in
                Button {
                    editor.colorIndex = index
                } label: {
                    Circle()
                        .fill(Color(red: color.red, green: color.green, blue: color.blue))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    Color.white.opacity(editor.colorIndex == index ? 1 : 0.35),
                                    lineWidth: 1.5
                                )
                        )
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Line-weight cycler for shape/brush tools; swaps to a font-size cycler
    /// while the text tool is active so both share one toolbar slot.
    @ViewBuilder
    private var widthButton: some View {
        if editor.selectedTool == .text {
            fontSizeButton
        } else {
            lineWidthButton
        }
    }

    /// Cycles thin → medium → thick, previewing the active line weight.
    private var lineWidthButton: some View {
        Button {
            editor.widthIndex = (editor.widthIndex + 1) % AnnotationEditorState.widths.count
        } label: {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 32)
                Rectangle()
                    .fill(Color.white)
                    .frame(
                        width: 22,
                        height: min(
                            AnnotationEditorState.widths[editor.widthIndex % AnnotationEditorState.widths.count],
                            8
                        )
                    )
                    .cornerRadius(1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("line_width", bundle: .main))
    }

    /// Cycles S/M/L; a live draft picks the change up on its next glyph.
    private var fontSizeButton: some View {
        Button {
            editor.textFontSizeIndex = (editor.textFontSizeIndex + 1) % AnnotationEditorState.textFontSizes.count
        } label: {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 32)
                Text(fontSizeBadge)
                    .font(.system(size: 13, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("text_font_size", bundle: .main))
    }

    private var historyGroup: some View {
        HStack(spacing: 4) {
            historyButton(symbol: "arrow.uturn.backward", enabled: model.canUndo) {
                model.undo()
            }
            historyButton(symbol: "arrow.uturn.forward", enabled: model.canRedo) {
                model.redo()
            }
        }
    }

    /// Confirm composes annotations into the clipboard image; folder saves to
    /// disk and copies the absolute path; cross cancels editing entirely.
    private var exitGroup: some View {
        HStack(spacing: 6) {
            exitButton(symbol: "checkmark", prominent: true) {
                editor.finishByCopying()
            }

            exitButton(symbol: "doc.on.doc", prominent: false) {
                editor.finishBySavingPath()
            }

            exitButton(symbol: "xmark", prominent: false) {
                Screenshot.shared.completeEditing(with: nil)
            }
        }
    }

    /// 32×32 full-frame hit target so a quick click never misses; the
    /// selected tool's highlight block covers the whole target, making the
    /// active tool obvious at a glance.
    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            logInfo("toolbar tool selected, tool=\(tool.rawValue)")
            editor.selectedTool = tool
        } label: {
            iconView(for: tool)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(editor.selectedTool == tool ? Color.white.opacity(0.25) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(tool.tooltipKey)))
    }

    @ViewBuilder
    private func iconView(for tool: AnnotationTool) -> some View {
        if tool == .text {
            // A bare T is the universal "add text" glyph; SF Symbols like
            // textformat read as gibberish at toolbar size.
            Text("T")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        } else if let custom = tool.customToolbarImage {
            Image(nsImage: custom)
                .interpolation(.high)
                .foregroundStyle(.white)
        } else {
            Image(systemName: tool.systemSymbolName)
                .font(.system(size: 15, weight: .medium))
        }
    }

    private func historyButton(symbol: String, enabled: Bool, action: @escaping () -> ()) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func exitButton(symbol: String, prominent: Bool, action: @escaping () -> ()) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(prominent ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.white.opacity(0.22)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
