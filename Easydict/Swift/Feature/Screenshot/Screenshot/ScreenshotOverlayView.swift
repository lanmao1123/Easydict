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

                if state.isTipVisible {
                    tipLayer
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Private

    @State private var backgroundImage: NSImage?
    @ObservedObject private var state: ScreenshotState

    // MARK: Gestures

    /// Drag gesture for selection
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged(handleDragChange)
            .onEnded(handleDragEnd)
    }

    // MARK: View Components

    /// Background screenshot with dark overlay
    private var backgroundLayer: some View {
        Group {
            if let image = backgroundImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)

                Rectangle()
                    .fill(Color.black.opacity(state.shouldHideDarkOverlay ? 0 : 0.3))
                    .animation(.easeInOut, value: state.shouldHideDarkOverlay)
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
                    let halfArm = 11.0
                    let displayX = min(max(pos.x, halfArm), geometry.size.width - halfArm)
                    let displayY = min(max(pos.y, halfArm), geometry.size.height - halfArm)

                    CrosshairShape()
                        .stroke(Color.black.opacity(0.85), lineWidth: 3)
                        .frame(width: 22, height: 22)
                        .position(x: displayX, y: displayY)

                    CrosshairShape()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                        .position(x: displayX, y: displayY)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// Visual representation of the selection area
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
            // Call the centralized screenshot method
            Screenshot.shared.performScreenshot(screen: state.screen, rect: selectedRect)
        } else {
            logInfo("selection cancelled, too small (minimum 10x10), rect=\(selectedRect)")
            // Cancel the screenshot process directly
            Screenshot.shared.finishCapture(nil)
        }
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
