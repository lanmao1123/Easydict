//
//  ScreenshotOverlayView.swift
//  Easydict
//
//  Created by tisfeng on 2025/3/11.
//  Copyright © 2025 izual. All rights reserved.
//

import SwiftUI

// MARK: - ScreenshotOverlayView

struct ScreenshotOverlayView: View {
    // MARK: Lifecycle

    init(state: ScreenshotState) {
        self.state = state
        /*
         The frame was frozen once in createOverlayWindow. Re-shooting here
         would fire a full CGDisplayCreateImage on every SwiftUI re-init of
         this struct — i.e. every frame of the selection drag.
         */
        self._backgroundImage = State(initialValue: state.frozenDisplayImage)
    }

    // MARK: Internal

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backgroundLayer

            if state.isEditing {
                editingDimLayer
                editingLayer
            } else {
                selectionLayer

                if state.isAdjustingSelection {
                    SelectionAdjustBar(screen: state.screen, rect: state.selectedRect)
                } else if state.isTipVisible {
                    tipLayer
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Private

    // MARK: Resize Handles

    private enum SelectionHandle: CaseIterable {
        case topLeft, top, topRight, leading, trailing, bottomLeft, bottom, bottomRight
    }

    @State private var backgroundImage: NSImage?
    @ObservedObject private var state: ScreenshotState

    /// Drag inside the selection moves the whole rect during adjusting.
    @State private var moveStartRect: CGRect?

    @State private var resizeStartRect: CGRect?

    // MARK: Gestures

    /// Drag gesture for selection
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged(handleDragChange)
            .onEnded(handleDragEnd)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if moveStartRect == nil { moveStartRect = state.selectedRect }
                guard let start = moveStartRect else { return }
                let origin = CGPoint(
                    x: start.minX + value.translation.width,
                    y: start.minY + value.translation.height
                )
                state.selectedRect = CGRect(origin: origin, size: start.size).integral
            }
            .onEnded { _ in
                moveStartRect = nil
                logInfo("selection moved to \(state.selectedRect)")
            }
    }

    // MARK: View Components

    /// Background screenshot with dimming: a full veil marks capture mode,
    /// and once a selection exists it punches a bright hole over the selection
    /// (Snipping Tool style).
    private var backgroundLayer: some View {
        Group {
            if let image = backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                if state.shouldHideDarkOverlay {
                    Rectangle()
                        .fill(Color.black.opacity(0))
                        .animation(.easeInOut, value: state.shouldHideDarkOverlay)
                } else if !state.selectedRect.isEmpty {
                    GeometryReader { geometry in
                        Path { path in
                            path.addRect(CGRect(origin: .zero, size: geometry.size))
                            path.addRect(state.selectedRect)
                        }
                        .fill(Color.black.opacity(0.3), style: FillStyle(eoFill: true))
                    }
                } else {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                }
            }
        }
    }

    /// Selection area and drag gesture handling
    private var selectionLayer: some View {
        GeometryReader { geometry in
            ZStack {
                if !state.selectedRect.isEmpty {
                    selectionRectangleView
                }

                resizeHandles

                crosshairView
            }

            // Gesture recognition layer
            Rectangle()
                .fill(Color.clear)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(drag)
        }
    }

    /// Self-drawn crosshair following the pointer, Microsoft Snipping Tool
    /// style. Drawn by the overlay because the system cursor cannot be
    /// reliably restyled while Accessibility pointer customization is on —
    /// NSCursor.set() is ignored by the customized pointer layer.
    ///
    /// The displayed center is nudged fully inside the screen: a pointer
    /// hugging the menu bar would otherwise clip half the crosshair off the
    /// window edge, where a thin line on the light menu bar reads as gone.
    /// Selection math still uses the real pointer position.
    private var crosshairView: some View {
        GeometryReader { geometry in
            Group {
                if let pos = state.cursorPosition {
                    let halfArm = 16.0
                    let displayX = min(max(pos.x, halfArm), geometry.size.width - halfArm)
                    let displayY = min(max(pos.y, halfArm), geometry.size.height - halfArm)

                    CrosshairShape()
                        .stroke(Color.black.opacity(0.85), lineWidth: 4)
                        .frame(width: 32, height: 32)
                        .position(x: displayX, y: displayY)

                    CrosshairShape()
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 32, height: 32)
                        .position(x: displayX, y: displayY)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Visual representation of the selection area. During the adjusting
    /// phase it grows resize handles and a move gesture, Snipping Tool style.
    private var selectionRectangleView: some View {
        ZStack {
            // Dark underlay keeps the white border readable on light content.
            Rectangle()
                .strokeBorder(Color.black.opacity(0.6), lineWidth: 4)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
        }
        .background(Color.black.opacity(0.1)) // Add a darker overlay for selection area
        .frame(width: state.selectedRect.width, height: state.selectedRect.height)
        .position(
            x: state.selectedRect.midX,
            y: state.selectedRect.midY
        )
        .gesture(state.isAdjustingSelection ? moveGesture : nil)
    }

    /// White square handles on the border during adjusting; dragging one
    /// resizes the rect from that side or corner.
    @ViewBuilder
    private var resizeHandles: some View {
        if state.isAdjustingSelection, !state.selectedRect.isEmpty {
            ForEach(SelectionHandle.allCases, id: \.hashValue) { handle in
                resizeHandleView(handle)
            }
        }
    }

    /// Snipaste-style editing mask: everything outside the selection stays
    /// dimmed with a hole punched over it plus a high-contrast border, so the
    /// editing boundary stays obvious while annotating.
    private var editingDimLayer: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRect(state.editingRect)
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))

                Rectangle()
                    .strokeBorder(Color.black.opacity(0.6), lineWidth: 4)
                    .frame(width: state.editingRect.width, height: state.editingRect.height)
                    .offset(x: state.editingRect.minX, y: state.editingRect.minY)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: state.editingRect.width, height: state.editingRect.height)
                    .offset(x: state.editingRect.minX, y: state.editingRect.minY)
            }
        }
        .allowsHitTesting(false)
    }

    /// Annotation editing UI over the selection: canvas plus floating toolbar,
    /// both positioned in the same top-left screen space as `editingRect`.
    @ViewBuilder
    private var editingLayer: some View {
        if let editor = state.annotationEditor {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    // The canvas spans exactly the selection so its item
                    // coordinates line up with what gets exported.
                    AnnotationCanvasView(editor: editor)
                        .frame(
                            width: editor.selectionRect.width,
                            height: editor.selectionRect.height
                        )
                        .offset(x: editor.selectionRect.minX, y: editor.selectionRect.minY)

                    EditToolbarView(
                        editor: editor,
                        model: editor.model,
                        containerSize: geometry.size
                    )
                }
            }
        }
    }

    /// Tip layer at bottom-left corner
    private var tipLayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("screenshot.tip.capture_last_area_desc")
                .foregroundStyle(.white)

            Divider()

            Text("screenshot.tip.cancel_capture_desc")
                .foregroundStyle(.white)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    }
                    // Get the tip frame
                    .onAppear {
                        state.tipFrame = CGRect(
                            x: state.screen.frame.minX,
                            y: state.screen.frame.minY,
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                    }
            }
        }
    }

    private func resizeHandleView(_ handle: SelectionHandle) -> some View {
        let anchor = handleAnchor(handle)
        let isCorner = handle != .top && handle != .bottom && handle != .leading && handle != .trailing
        return ZStack {
            Rectangle().fill(Color.clear)
        }
        .frame(width: 28, height: 28)
        .overlay(
            Rectangle()
                .fill(Color.white)
                .frame(width: isCorner ? 12 : 20, height: isCorner ? 12 : 8)
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.7), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.4), radius: 1)
        )
        .position(anchor)
        .contentShape(Rectangle())
        .gesture(resizeGesture(handle))
    }

    private func handleAnchor(_ handle: SelectionHandle) -> CGPoint {
        let r = state.selectedRect
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .leading: return CGPoint(x: r.minX, y: r.midY)
        case .trailing: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func resizeGesture(_ handle: SelectionHandle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if resizeStartRect == nil { resizeStartRect = state.selectedRect }
                guard let start = resizeStartRect else { return }

                var minX = start.minX
                var minY = start.minY
                var maxX = start.maxX
                var maxY = start.maxY

                switch handle {
                case .topLeft: minX = value.location.x; minY = value.location.y
                case .top: minY = value.location.y
                case .topRight: maxX = value.location.x; minY = value.location.y
                case .leading: minX = value.location.x
                case .trailing: maxX = value.location.x
                case .bottomLeft: minX = value.location.x; maxY = value.location.y
                case .bottom: maxY = value.location.y
                case .bottomRight: maxX = value.location.x; maxY = value.location.y
                }

                let rect = CGRect(
                    x: min(minX, maxX), y: min(minY, maxY),
                    width: max(abs(maxX - minX), 10),
                    height: max(abs(maxY - minY), 10)
                ).integral
                state.selectedRect = rect
            }
            .onEnded { _ in
                resizeStartRect = nil
                logInfo("selection resized to \(state.selectedRect)")
            }
    }

    // MARK: Event Handlers

    /// Handle drag gesture change
    private func handleDragChange(_ value: DragGesture.Value) {
        // Cancel any pending preview screenshot if user starts dragging
        Screenshot.shared.cancelPreviewScreenshotTimer()

        let adjustedStartLocation = CGPoint(
            x: value.startLocation.x,
            y: value.startLocation.y
        )
        let adjustedLocation = CGPoint(
            x: value.location.x,
            y: value.location.y
        )

        // Calculate selection rectangle
        let origin = CGPoint(
            x: min(adjustedStartLocation.x, adjustedLocation.x),
            y: min(adjustedStartLocation.y, adjustedLocation.y)
        )
        let size = CGSize(
            width: abs(adjustedLocation.x - adjustedStartLocation.x),
            height: abs(adjustedLocation.y - adjustedStartLocation.y)
        )

        state.selectedRect = CGRect(origin: origin, size: size).integral
        state.isTipVisible = false
    }

    /// Handle drag gesture end
    private func handleDragEnd(_ value: DragGesture.Value? = nil) {
        // Cancel any pending preview screenshot (might be redundant here but safe)
        Screenshot.shared.cancelPreviewScreenshotTimer()

        state.isTipVisible = false

        let selectedRect = state.selectedRect
        logInfo("drag ended, selectedRect=\(selectedRect)")

        // Check if selection meets minimum size requirements
        if selectedRect.width > 10, selectedRect.height > 10 {
            // F1's edit path first enters the resize/move phase; picking any
            // tool (or ✓/Enter) locks the rect. Plain capture paths keep the
            // old fire-on-release behavior.
            if Screenshot.shared.editModeEnabled {
                if !state.isAdjustingSelection {
                    state.isAdjustingSelection = true
                    logInfo("entering selection adjusting mode, rect=\(selectedRect)")
                } else {
                    logInfo("re-selected while adjusting, rect=\(selectedRect)")
                }
            } else {
                // Call the centralized screenshot method
                Screenshot.shared.performScreenshot(screen: state.screen, rect: selectedRect)
            }
        } else {
            logInfo("selection cancelled, too small (minimum 10x10), rect=\(selectedRect)")
            // Cancel the screenshot process directly
            Screenshot.shared.finishCapture(nil)
        }
    }
}

// MARK: - SelectionAdjustBar

/// Toolbar of the adjusting phase, docked under the selection (or above it
/// when the space below is tight). Picking a tool locks the rect and starts
/// annotating with that tool; ✓ confirms the crop as-is; ✕ cancels.
private struct SelectionAdjustBar: View {
    // MARK: Internal

    let screen: NSScreen
    let rect: CGRect

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases, id: \.rawValue) { tool in
                toolButton(tool)
            }
            Divider()
                .frame(height: 12)
                .overlay(Color.white.opacity(0.35))
            exitButton(symbol: "checkmark", prominent: true) {
                Screenshot.shared.confirmAdjustedSelection()
            }
            exitButton(symbol: "xmark", prominent: false) {
                Screenshot.shared.finishCapture(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        )
        .foregroundStyle(.white)
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { measuredSize = geometry.size }
                    .onChange(of: geometry.size) { measuredSize = $0 }
            }
        )
        .position(clampedPosition)
    }

    // MARK: Private

    @State private var measuredSize: CGSize = .init(width: 340, height: 34)

    private var clampedPosition: CGPoint {
        let margin: CGFloat = 8
        let gap: CGFloat = 8
        let halfW = measuredSize.width / 2
        let halfH = measuredSize.height / 2

        let x = max(halfW + margin, min(rect.midX, screen.frame.width - halfW - margin))
        let preferredY = rect.maxY + gap + halfH
        let maxY = screen.frame.height - halfH - margin
        let y = min(preferredY <= maxY ? preferredY : max(rect.minY - gap - halfH, halfH + margin), maxY)
        return CGPoint(x: x, y: y)
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            Screenshot.shared.lockSelectionAndBeginEditing(tool: tool)
        } label: {
            iconView(for: tool)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(tool.tooltipKey)))
    }

    @ViewBuilder
    private func iconView(for tool: AnnotationTool) -> some View {
        if tool == .text {
            Text("T")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        } else if let custom = tool.customToolbarImage {
            Image(nsImage: custom)
                .interpolation(.high)
                .foregroundStyle(.white)
        } else {
            Image(systemName: tool.systemSymbolName)
                .font(.system(size: 12, weight: .medium))
        }
    }

    private func exitButton(symbol: String, prominent: Bool, action: @escaping () -> ()) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(prominent ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.white.opacity(0.22)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CrosshairShape

/// Plus-shaped path centered in the proposed rect, for the selection crosshair.
struct CrosshairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.minX, y: center.y))
        path.addLine(to: CGPoint(x: rect.maxX, y: center.y))
        path.move(to: CGPoint(x: center.x, y: rect.minY))
        path.addLine(to: CGPoint(x: center.x, y: rect.maxY))
        return path
    }
}

// MARK: - ScreenshotOverlayHostingView

/// Registers the overlay cursor: crosshair while selecting, the active
/// annotation tool's cursor while editing.
final class ScreenshotOverlayHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        discardCursorRects()
        if let editor = Screenshot.shared.activeAnnotationEditor {
            let brushSide = AnnotationEditorState.brushSides[editor.widthIndex % AnnotationEditorState.brushSides.count]
            addCursorRect(bounds, cursor: AnnotationCursors.cursor(for: editor.selectedTool, brushSide: brushSide))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }
}
