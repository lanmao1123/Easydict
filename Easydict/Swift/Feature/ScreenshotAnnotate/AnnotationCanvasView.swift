//
//  AnnotationCanvasView.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit
import SwiftUI

// MARK: - AnnotationEditorState

/// Session state of one screenshot editing pass: selected tool/style plus any
/// shape currently being dragged or text being typed. Committed shapes live in
/// the shared `AnnotationModel`.
@MainActor
final class AnnotationEditorState: ObservableObject {
    // MARK: Lifecycle

    init(selectionRect: CGRect) {
        self.selectionRect = selectionRect
    }

    // MARK: Internal

    static let palette: [(red: Double, green: Double, blue: Double)] = [
        (0.93, 0.27, 0.24), // red
        (0.23, 0.51, 0.96), // blue
        (0.98, 0.75, 0.18), // yellow
        (0.22, 0.80, 0.35), // green
        (0.10, 0.10, 0.12), // black
    ]

    static let widths: [CGFloat] = [2, 5, 12]

    /// Brush side lengths in screen points, cycling with the width picker.
    static let brushSides: [CGFloat] = [18, 28, 42]

    static let textFontSizes: [CGFloat] = [13, 16, 22]

    /// Editing rect in screen top-left point coordinates; all item math uses
    /// its own top-left point space.
    let selectionRect: CGRect

    @Published var selectedTool: AnnotationTool = .rectangle
    @Published var colorIndex = 0
    @Published var widthIndex = 1

    /// Text tool font size, picked on the input card (S/M/L).
    @Published var textFontSizeIndex = 1

    /// Points of the shape being dragged right now; empty when idle.
    @Published var inProgressPoints: [CGPoint] = []

    /// Screen-local point of an active text draft, if any.
    @Published var textDraftPoint: CGPoint?

    /// While re-editing committed text: the item hidden behind the draft box.
    @Published var editingTextItemID: UUID?

    let model = AnnotationModel()

    /// Live stroke bitmap: effect tiles composite into one context during the
    /// drag, so the canvas refreshes once per tile-stamp instead of rebuilding
    /// one view per tile. Committed as a single region item on mouse-up.
    @Published private(set) var liveStrokeCanvas: CGImage?

    var textFontSize: CGFloat {
        Self.textFontSizes[textFontSizeIndex % Self.textFontSizes.count]
    }

    var canUndo: Bool { model.canUndo }
    var canRedo: Bool { model.canRedo }

    /// Render style derived from the picked color, width and tool semantics.
    var currentStyle: AnnotationStyle {
        let palette = Self.palette[colorIndex % Self.palette.count]
        var style = AnnotationStyle(
            red: palette.red,
            green: palette.green,
            blue: palette.blue,
            lineWidth: Self.widths[widthIndex % Self.widths.count]
        )
        if selectedTool == .marker || selectedTool == .underline {
            style.alpha = 0.45
        }
        // Markers run three times thicker for a highlighter feel.
        if selectedTool == .marker {
            style.lineWidth *= 3
        }
        return style
    }

    /// Read-only view of `brushStrokeActive` so the canvas can de-duplicate
    /// its per-stroke diagnostic log.
    var isPaintingStroke: Bool { brushStrokeActive }

    /// Committing whatever the drag produced and refreshing the live preview.
    func dragChanged(at localPoint: CGPoint) {
        guard textDraftPoint == nil else { return }

        switch selectedTool {
        case .arrow, .ellipse, .line, .rectangle:
            inProgressPoints = [inProgressPoints.first ?? localPoint, localPoint]

        case .marker, .pencil:
            if inProgressPoints.isEmpty {
                inProgressPoints = [localPoint]
            } else {
                inProgressPoints.append(localPoint)
            }

        case .underline:
            inProgressPoints = [inProgressPoints.first ?? localPoint, localPoint]

        case .blur, .mosaic:
            // Brush painting, Snipping-Tool style: tiles composite into a
            // live bitmap while dragging; mouse-up commits it as one item.
            if !brushStrokeActive {
                brushStrokeActive = true
                brushTileCount = 0
                NSLog(
                    "[SnipTools] Brush stroke started, tool=%@, selection=%@",
                    selectedTool.rawValue,
                    NSStringFromRect(selectionRect)
                )
            }
            paintBrushStroke(to: localPoint)

        case .eraser:
            if let last = lastEraserPoint {
                _ = model.erase(alongSegment: last, to: localPoint)
            }
            lastEraserPoint = localPoint

        case .text:
            break
        }
    }

    func dragEnded(at localPoint: CGPoint) {
        defer {
            inProgressPoints = []
            lastEraserPoint = nil
        }

        if selectedTool == .text {
            guard textDraftPoint == nil else { return }
            if let hit = hitTextItem(at: localPoint) {
                beginEditingText(hit)
            } else {
                textDraftPoint = localPoint
            }
            return
        }

        switch selectedTool {
        case .arrow, .ellipse, .line, .rectangle:
            let start = inProgressPoints.first ?? localPoint
            guard hypot(start.x - localPoint.x, start.y - localPoint.y) > 3 else { return }

            let bounds = start.rect(to: localPoint)
            switch selectedTool {
            case .rectangle:
                model.add(AnnotationItem(kind: .rectangle(bounds: bounds), style: currentStyle))
            case .ellipse:
                model.add(AnnotationItem(kind: .ellipse(bounds: bounds), style: currentStyle))
            case .line:
                model.add(AnnotationItem(kind: .line(from: start, to: localPoint), style: currentStyle))
            default:
                model.add(AnnotationItem(kind: .arrow(from: start, to: localPoint), style: currentStyle))
            }

        case .marker, .pencil:
            var points = inProgressPoints
            points.append(localPoint)
            guard points.count > 1 else { return }
            let kind: AnnotationItemKind = selectedTool == .pencil ? .pencil(points: points) : .marker(points: points)
            model.add(AnnotationItem(kind: kind, style: currentStyle))

        case .underline:
            let anchor = inProgressPoints.first ?? localPoint
            let thickness = max(currentStyle.lineWidth, 6)
            let band = CGRect(
                x: min(anchor.x, localPoint.x),
                y: anchor.y,
                width: abs(localPoint.x - anchor.x),
                height: thickness
            )
            guard band.width > 4 else { return }
            model.add(AnnotationItem(kind: .underline(band: band), style: currentStyle))

        case .blur, .mosaic:
            if brushStrokeActive {
                brushStrokeActive = false
                lastBrushPoint = nil
                commitLiveStroke()
                let toolName = selectedTool.rawValue
                let count = brushTileCount
                NSLog("[SnipTools] Brush stroke finished, tool=%@, tiles=%d", toolName, count)
            }

        case .eraser:
            if let last = lastEraserPoint {
                _ = model.erase(alongSegment: last, to: localPoint)
            }

        case .text:
            break
        }
    }

    /// Commits the active text draft: a re-edit replaces (or, when cleared,
    /// removes) its item; a fresh draft adds one. Empty input on a new draft
    /// just discards.
    func commitText(_ string: String) {
        guard let point = textDraftPoint else { return }
        defer {
            textDraftPoint = nil
            editingTextItemID = nil
        }

        if let id = editingTextItemID {
            if string.isEmpty {
                model.remove(id)
                return
            }
            guard let index = model.items.firstIndex(where: { $0.id == id }) else { return }
            var updated = model.items[index]
            updated.kind = .text(string: string, at: point, fontSize: textFontSize)
            updated.style = currentStyle
            model.update(updated)
            return
        }

        guard !string.isEmpty else { return }
        model.add(AnnotationItem(
            kind: .text(string: string, at: point, fontSize: textFontSize),
            style: currentStyle
        ))
    }

    /// Esc during a text draft: leaves the committed state untouched.
    func discardText() {
        textDraftPoint = nil
        editingTextItemID = nil
    }

    /// Composes the clean base with every annotation; nil when the base
    /// cannot be captured anymore.
    func composedImage() -> NSImage? {
        guard let base = Screenshot.shared.captureEditedBaseImage() else { return nil }

        let composed = AnnotationComposer.compose(
            base: base,
            selectionSize: selectionRect.size,
            items: model.items
        )

        /*
         Retina captures store 2x pixels with pixel-count-as-points size, so
         pinning would show the image doubled. Declare the on-screen point
         size of the original selection while keeping the sharp bitmap.
         */
        composed.size = NSSize(width: selectionRect.width, height: selectionRect.height)
        return composed
    }

    /// Checkmark / ⌘C / Enter: copy the composed image and end editing.
    func finishByCopying() {
        guard let image = composedImage() else {
            EZToast.showText(NSLocalizedString("snip_save_failed", comment: ""))
            return
        }
        Screenshot.shared.completeEditing(with: image)
    }

    /// Folder / ⌘S: save to disk, copy the absolute path and end editing.
    func finishBySavingPath() {
        guard let image = composedImage(),
              PasteboardPathService.saveAndCopyPath(for: image) != nil else {
            EZToast.showText(NSLocalizedString("snip_save_failed", comment: ""))
            return
        }
        Screenshot.shared.completeEditing(with: nil)
    }

    /// F3 while annotating: pin the composed image straight to the screen,
    /// Snipaste-style, without touching the clipboard.
    func pinAndFinish() {
        guard let image = composedImage() else {
            EZToast.showText(NSLocalizedString("snip_save_failed", comment: ""))
            return
        }
        // Pin back exactly over the original selection for a seamless
        // bright-selection-to-pin transition.
        PinImageManager.shared.pin(image: image, atGlobalRect: Screenshot.shared.editingGlobalRect)
        Screenshot.shared.completeEditing(with: nil)
    }

    // MARK: Private

    private var lastEraserPoint: CGPoint?

    /// True while a mosaic/blur brush stroke is being painted.
    private var brushStrokeActive = false

    /// Last point a brush tile was painted at, for stroke interpolation.
    private var lastBrushPoint: CGPoint?

    /// Tiles committed in the current stroke, for logging.
    private var brushTileCount = 0

    private var liveStrokeContext: CGContext?

    /// Lazy pixel tile of the clean selection, needed by mosaic/blur commits.
    private var baseTile: CGImage?

    /// Topmost committed text item whose measured bounds contain `point`.
    private func hitTextItem(at point: CGPoint) -> AnnotationItem? {
        for item in model.items.reversed() {
            if case .text = item.kind, item.kind.bounds().contains(point) {
                return item
            }
        }
        return nil
    }

    /// Opens the draft over an existing annotation so it edits in place.
    private func beginEditingText(_ item: AnnotationItem) {
        guard case let .text(string, at, fontSize) = item.kind else { return }
        editingTextItemID = item.id
        textDraftPoint = at
        textFontSizeIndex = Self.textFontSizes.firstIndex(of: fontSize) ?? textFontSizeIndex
    }

    /// Paints brush tiles from the last painted point up to `to`, spacing
    /// tiles at half the brush side so fast strokes stay gap-free.
    private func paintBrushStroke(to: CGPoint) {
        let side = Self.brushSides[widthIndex % Self.brushSides.count]
        let step = side * 0.5

        guard let from = lastBrushPoint else {
            paintOneTile(at: to, side: side)
            lastBrushPoint = to
            return
        }

        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance >= step else { return }

        let steps = max(1, Int(distance / step))
        for index in 1 ... steps {
            let t = CGFloat(index) / CGFloat(steps)
            paintOneTile(
                at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                side: side
            )
        }
        lastBrushPoint = to
    }

    /// Stamps one effect tile centered on `point`, clipped to the selection.
    private func paintOneTile(at point: CGPoint, side: CGFloat) {
        let tileRect = CGRect(
            x: point.x - side / 2,
            y: point.y - side / 2,
            width: side,
            height: side
        ).intersection(CGRect(origin: .zero, size: selectionRect.size))

        guard tileRect.width > 2, tileRect.height > 2,
              let tile = effectTile(for: tileRect, pixellated: selectedTool == .mosaic) else {
            NSLog(
                "[SnipTools] Brush tile skipped, rect=%@, selected=%@",
                NSStringFromRect(tileRect),
                selectedTool.rawValue
            )
            return
        }
        drawLiveTile(tile, in: tileRect)
        brushTileCount += 1
    }

    /// Composites a tile into the live stroke bitmap (top-left point space).
    private func drawLiveTile(_ tile: CGImage, in rect: CGRect) {
        guard let context = ensureLiveStrokeContext() else { return }
        let scale = CGFloat(context.width) / max(selectionRect.width, 1)

        context.saveGState()
        // Annotation space is top-left; CG space is bottom-left.
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            tile,
            in: CGRect(
                x: rect.minX * scale,
                y: rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        )
        context.restoreGState()

        liveStrokeCanvas = context.makeImage()
    }

    private func ensureLiveStrokeContext() -> CGContext? {
        if let liveStrokeContext { return liveStrokeContext }

        guard let base = ensureBaseTile() else { return nil }
        let scale = CGFloat(base.width) / max(selectionRect.width, 1)
        let context = CGContext(
            data: nil,
            width: Int(selectionRect.width * scale),
            height: Int(selectionRect.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        liveStrokeContext = context
        return context
    }

    /// Mouse-up: the whole live bitmap becomes one region item, so one undo
    /// step removes the entire stroke exactly like the previous grouped adds.
    private func commitLiveStroke() {
        defer {
            liveStrokeContext = nil
            liveStrokeCanvas = nil
        }
        guard let context = liveStrokeContext, let image = context.makeImage() else { return }
        let frame = CGRect(origin: .zero, size: selectionRect.size)
        model.add(AnnotationItem(kind: .region(image: image, frame: frame), style: currentStyle))
    }

    /// Renders a mosaic/blur tile covering `region` (top-left point space).
    private func effectTile(for region: CGRect, pixellated: Bool) -> CGImage? {
        guard let tile = ensureBaseTile() else { return nil }

        let scale = Double(tile.width) / max(selectionRect.width, 1)
        let cropPx = CGRect(
            x: region.minX * scale,
            y: region.minY * scale,
            width: region.width * scale,
            height: region.height * scale
        ).intersection(CGRect(origin: .zero, size: CGSize(width: tile.width, height: tile.height)))
        guard !cropPx.isNull, cropPx.width >= 1, cropPx.height >= 1,
              let cropped = tile.cropping(to: cropPx) else {
            NSLog(
                "[SnipTools] Mosaic crop failed, region=%@, tile=%dx%d, scale=%.2f",
                NSStringFromRect(region), tile.width, tile.height, scale
            )
            return nil
        }

        // Block size in screen points first, then converted to source pixels:
        // tiny 6%-of-shortside pixel blocks were invisible on Retina.
        let blockPoints = min(max(min(region.width, region.height) * 0.25, 10), 26)
        let blockPixels = CGFloat(blockPoints * scale)
        let result = pixellated
            ? MosaicRegionRenderer.pixelated(source: cropped, blockSide: blockPixels)
            : MosaicRegionRenderer.blurred(source: cropped, radius: blockPixels * 0.8)
        if result == nil {
            NSLog("[SnipTools] Mosaic CIFilter returned nil, pixellated=%@", pixellated ? "yes" : "no")
        }
        return result
    }

    /// Fetches (once per session) the clean base pixels of the whole selection.
    private func ensureBaseTile() -> CGImage? {
        if let baseTile { return baseTile }

        guard let image = Screenshot.shared.captureEditedBaseImage(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            NSLog("[SnipTools] Mosaic base capture failed")
            return nil
        }
        NSLog("[SnipTools] Mosaic base tile captured, %dx%d", cgImage.width, cgImage.height)
        baseTile = cgImage
        return cgImage
    }
}

extension CGPoint {
    fileprivate func rect(to other: CGPoint) -> CGRect {
        CGRect(
            x: min(x, other.x),
            y: min(y, other.y),
            width: abs(other.x - x),
            height: abs(other.y - y)
        )
    }
}

// MARK: - ArrowShape

/// Shaft plus two wing lines forming one arrow path.
struct ArrowShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)

        let angle = atan2(to.y - from.y, to.x - from.x)
        for offset in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
            let wingAngle = angle + offset
            path.move(
                to: CGPoint(x: to.x + cos(wingAngle) * 12, y: to.y + sin(wingAngle) * 12)
            )
            path.addLine(to: to)
        }
        return path
    }
}

// MARK: - AnnotationCanvasView

/// SwiftUI surface showing committed annotations, the shape being dragged, and
/// hosting the gestures that feed `AnnotationEditorState`.
struct AnnotationCanvasView: View {
    // MARK: Lifecycle

    init(editor: AnnotationEditorState) {
        self.editor = editor
        self.model = editor.model
    }

    // MARK: Internal

    @ObservedObject var editor: AnnotationEditorState

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // The item under re-edit is hidden — the live draft stands in.
                ForEach(model.items.filter { $0.id != editor.editingTextItemID }, id: \.id) { item in
                    itemView(for: item)
                        .allowsHitTesting(false)
                }

                // In-flight brush stroke: one bitmap replaces dozens of tile
                // views, keeping the drag at full frame rate.
                if let live = editor.liveStrokeCanvas {
                    Image(decorative: live, scale: 1)
                        .resizable()
                        .interpolation(editor.selectedTool == .mosaic ? .none : .medium)
                        .frame(width: editor.selectionRect.width, height: editor.selectionRect.height)
                        .allowsHitTesting(false)
                }

                progressPreview
                    .allowsHitTesting(false)

                if let draftPoint = editor.textDraftPoint {
                    textDraftField(at: draftPoint, in: geometry.size)
                }

                gestureLayer(size: geometry.size)
            }
            // Registered here, not on the draft field itself: the field is
            // inserted after the state flip and would miss its own onChange.
            .onChange(of: editor.editingTextItemID) { id in
                guard let id else { draftText = ""; return }
                if let item = model.items.first(where: { $0.id == id }),
                   case let .text(string, _, _) = item.kind {
                    draftText = string
                }
            }
        }
    }

    // MARK: Private

    /// Observed separately: undo/redo/erase mutate the model without touching
    /// `editor`, and without this the canvas would never re-render for them.
    @ObservedObject private var model: AnnotationModel

    @State private var draftText = ""

    /// Live preview of the shape currently being dragged.
    @ViewBuilder
    private var progressPreview: some View {
        let points = editor.inProgressPoints
        if points.count >= 2 {
            switch editor.selectedTool {
            case .rectangle:
                itemView(for: AnnotationItem(
                    kind: .rectangle(bounds: points[0].rect(to: points[1])),
                    style: editor.currentStyle
                ))
            case .ellipse:
                itemView(for: AnnotationItem(
                    kind: .ellipse(bounds: points[0].rect(to: points[1])),
                    style: editor.currentStyle
                ))
            case .line:
                itemView(for: AnnotationItem(kind: .line(from: points[0], to: points[1]), style: editor.currentStyle))
            case .arrow:
                itemView(for: AnnotationItem(kind: .arrow(from: points[0], to: points[1]), style: editor.currentStyle))
            case .underline:
                let anchor = points[0]
                let band = CGRect(
                    x: min(anchor.x, points[1].x),
                    y: anchor.y,
                    width: abs(points[1].x - anchor.x),
                    height: max(editor.currentStyle.lineWidth, 6)
                )
                itemView(for: AnnotationItem(kind: .underline(band: band), style: editor.currentStyle))
            case .marker, .pencil:
                itemView(for: AnnotationItem(kind: .pencil(points: points), style: editor.currentStyle))
            case .blur, .mosaic:
                // Painted tiles already provide live feedback.
                EmptyView()
            case .eraser, .text:
                EmptyView()
            }
        }
    }

    /// Converts one committed item into a SwiftUI view; mirrors
    /// `AnnotationItem.render` so display matches export.
    @ViewBuilder
    private func itemView(for item: AnnotationItem) -> some View {
        let color = Color(red: item.style.red, green: item.style.green, blue: item.style.blue)
            .opacity(item.style.alpha)

        switch item.kind {
        case let .rectangle(bounds):
            RoundedRectangle(cornerRadius: 1)
                .strokeBorder(color, lineWidth: max(item.style.lineWidth, 1))
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)

        case let .ellipse(bounds):
            Ellipse()
                .strokeBorder(color, lineWidth: max(item.style.lineWidth, 1))
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX, y: bounds.minY)

        case let .line(from, to):
            straightPath(from: from, to: to)
                .stroke(color, style: strokeStyle(item.style))

        case let .arrow(from, to):
            ArrowShape(from: from, to: to)
                .stroke(color, style: strokeStyle(item.style))

        case let .marker(points), let .pencil(points):
            jointedPath(points: points)
                .stroke(color, style: StrokeStyle(
                    lineWidth: pencilWidth(item.style),
                    lineCap: .round,
                    lineJoin: .round
                ))

        case let .underline(band):
            Capsule()
                .fill(color)
                .frame(width: max(band.width, 2), height: band.height)
                .offset(x: band.minX, y: band.minY)

        case let .text(string, at, fontSize):
            Text(string)
                .font(.system(size: fontSize))
                .foregroundStyle(Color(red: item.style.red, green: item.style.green, blue: item.style.blue))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420, alignment: .topLeading)
                .offset(x: at.x, y: at.y)

        case let .region(image, frame):
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
    }

    /// Whole-area gesture layer translating drags into editor calls.
    private func gestureLayer(size: CGSize) -> some View {
        Color.white.opacity(0.001)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // Per-stroke probe: without it a stroke swallowed
                        // before `dragChanged` would leave no trace at all.
                        if editor.selectedTool == .mosaic || editor.selectedTool == .blur,
                           !editor.isPaintingStroke {
                            NSLog("[SnipTools] Canvas gesture received, tool=%@", editor.selectedTool.rawValue)
                        }
                        // While typing, the first outside click commits the
                        // text so nothing silently dangles.
                        if editor.textDraftPoint != nil {
                            commitDraft()
                            return
                        }
                        editor.dragChanged(at: value.location.translate(intoSelectionOf: editor))
                    }
                    .onEnded { value in
                        guard editor.textDraftPoint == nil else { return }
                        editor.dragEnded(at: value.location.translate(intoSelectionOf: editor))
                    }
            )
            .onChange(of: editor.selectedTool) { _ in
                refreshOverlayCursorRects()
            }
            .onChange(of: editor.widthIndex) { _ in
                refreshOverlayCursorRects()
            }
    }

    /// Inline WYSIWYG draft: the glyphs being typed use the same size and
    /// color as the committed item and sit exactly where it will land, so
    /// finishing an edit never makes the text jump.
    @ViewBuilder
    private func textDraftField(at point: CGPoint, in size: CGSize) -> some View {
        let color = Color(
            red: editor.currentStyle.red,
            green: editor.currentStyle.green,
            blue: editor.currentStyle.blue
        )
        let nsColor = NSColor(
            red: editor.currentStyle.red,
            green: editor.currentStyle.green,
            blue: editor.currentStyle.blue,
            alpha: 1
        )
        let width = min(420, max(140, size.width - point.x - 16))
        let height = draftHeight(forWidth: width, fontSize: editor.textFontSize)
        InlineTextEditor(
            text: $draftText,
            fontSize: editor.textFontSize,
            color: nsColor,
            onCommit: { commitDraft() },
            onCancel: {
                editor.discardText()
                draftText = ""
            }
        )
        .frame(width: width, height: height)
        .foregroundStyle(color)
        .offset(
            x: max(min(point.x + 2, size.width - width - 8), 8),
            y: max(min(point.y - 2, size.height - height - 24), 8)
        )
    }

    /// Sizes the draft box to its wrapped line count so the caret area never
    /// scrolls internally; capped at eight lines of height.
    private func draftHeight(forWidth width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributed = NSAttributedString(
            string: draftText.isEmpty ? " " : draftText,
            attributes: [.font: font]
        )
        let bounds = attributed.boundingRect(
            with: NSSize(width: width - 4, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).size
        return min(bounds.height + 6, fontSize * AnnotationItemKind.textLineHeightFactor * 8)
    }

    /// Submits the draft and clears the local buffer.
    private func commitDraft() {
        editor.commitText(draftText)
        draftText = ""
    }

    /// Re-registers cursor rects so the pointer matches the active tool and
    /// brush size.
    private func refreshOverlayCursorRects() {
        for window in NSApp.windows where window is ScreenshotOverlayWindow {
            if let contentView = window.contentView {
                window.invalidateCursorRects(for: contentView)
            }
        }
    }

    private func straightPath(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }

    private func jointedPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func strokeStyle(_ style: AnnotationStyle) -> StrokeStyle {
        StrokeStyle(lineWidth: max(style.lineWidth, 1), lineCap: .round, lineJoin: .round)
    }

    private func pencilWidth(_ style: AnnotationStyle) -> CGFloat {
        max(style.lineWidth, 1)
    }
}

extension CGPoint {
    /// Converts a `.global` screen point into the editor's selection space.
    fileprivate func translate(intoSelectionOf editor: AnnotationEditorState) -> CGPoint {
        CGPoint(x: x - editor.selectionRect.origin.x, y: y - editor.selectionRect.origin.y)
    }
}

// MARK: - AnnotationCursors

/// Per-tool cursors for the annotation canvas, Snipping-Tool style: effect
/// tools show a circular brush outline sized to the actual brush, text uses
/// the I-beam, drawing tools keep the crosshair.
enum AnnotationCursors {
    // MARK: Internal

    /// Returns the cursor for `tool`; effect-tool circles follow `brushSide`.
    static func cursor(for tool: AnnotationTool, brushSide: CGFloat) -> NSCursor {
        switch tool {
        case .arrow, .ellipse, .line, .marker, .pencil, .rectangle, .underline:
            return .crosshair
        case .text:
            return .iBeam
        case .mosaic:
            return brushCursor(brushSide: brushSide, kind: .mosaic)
        case .blur:
            return brushCursor(brushSide: brushSide, kind: .blur)
        case .eraser:
            return eraserCursor
        }
    }

    // MARK: Private

    private enum BrushKind {
        case mosaic
        case blur
    }

    private static let eraserCursor = makeCursor(side: 22) { context, side in
        // Classic two-tone eraser block.
        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 1).cgColor)
        let inset = side * 0.18
        let body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        context.fill(body)
        context.setFillColor(NSColor(calibratedWhite: 0.9, alpha: 1).cgColor)
        context.fill(CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2))
    }

    private static var brushCursorCache: [String: NSCursor] = [:]

    /// Circular brush outline matching the paint size, with a tiny center
    /// glyph hinting at the effect (pixel block for mosaic, soft dot for blur).
    private static func brushCursor(brushSide: CGFloat, kind: BrushKind) -> NSCursor {
        let key = "\(kind)-\(Int(brushSide))"
        if let cached = brushCursorCache[key] { return cached }

        // Padding leaves room for the contrast rings around the brush circle.
        let canvas = brushSide + 16
        let cursor = makeCursor(side: canvas) { context, side in
            let center = side / 2
            let radius = brushSide / 2

            if kind == .mosaic {
                // Tiny 2x2 pixel blocks inside the circle.
                let block = max(brushSide / 5, 2)
                for row in 0 ..< 2 {
                    for column in 0 ..< 2 {
                        let light = (row + column) % 2 == 0
                        context.setFillColor(
                            NSColor(calibratedWhite: light ? 0.65 : 0.3, alpha: 0.9).cgColor
                        )
                        let origin = CGPoint(
                            x: center - block + CGFloat(column) * block,
                            y: center - block + CGFloat(row) * block
                        )
                        context.fill(CGRect(origin: origin, size: CGSize(width: block, height: block)))
                    }
                }
            } else {
                // Soft blue dot hinting at blur.
                context
                    .setFillColor(NSColor(calibratedHue: 0.58, saturation: 0.4, brightness: 0.7, alpha: 0.55).cgColor)
                let dotRadius = max(brushSide / 6, 2)
                context.fillEllipse(in: CGRect(
                    x: center - dotRadius,
                    y: center - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
            }

            // Brush boundary rings: white outer, black inner, visible anywhere.
            for (color, width, inset) in [(NSColor.white, 5.0, -2.5), (NSColor.black, 2.0, 0.0)] {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(width)
                context.strokeEllipse(in: CGRect(
                    x: center - radius - inset,
                    y: center - radius - inset,
                    width: (radius + inset) * 2,
                    height: (radius + inset) * 2
                ))
            }
        }

        brushCursorCache[key] = cursor
        return cursor
    }

    /// Renders a 2x bitmap cursor with centered hotspot.
    private static func makeCursor(side: CGFloat, _ draw: (CGContext, CGFloat) -> ()) -> NSCursor {
        let pixels = Int(side * 2)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { return .crosshair }

        draw(context, CGFloat(pixels))

        guard let cgImage = context.makeImage() else { return .crosshair }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

// MARK: - InlineTextEditor

/// AppKit-backed inline editor for the text draft. SwiftUI's multiline
/// TextField cannot reliably tell Enter and Shift+Enter apart on macOS, so a
/// plain `NSTextView` owns the key handling instead.
private struct InlineTextEditor: NSViewRepresentable {
    // MARK: Lifecycle

    init(
        text: Binding<String>,
        fontSize: CGFloat,
        color: NSColor,
        onCommit: @escaping () -> (),
        onCancel: @escaping () -> ()
    ) {
        _text = text
        self.fontSize = fontSize
        self.color = color
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    // MARK: Internal

    final class Coordinator: NSObject, NSTextViewDelegate {
        // MARK: Lifecycle

        init(_ parent: InlineTextEditor) {
            self.parent = parent
        }

        // MARK: Internal

        var parent: InlineTextEditor

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }

    @Binding var text: String

    let fontSize: CGFloat
    let color: NSColor
    let onCommit: () -> ()
    let onCancel: () -> ()

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DraftTextView {
        let view = DraftTextView()
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        applyTypingAttributes(to: view)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: DraftTextView, context: Context) {
        if view.string != text { view.string = text }
        view.onCommit = onCommit
        view.onCancel = onCancel
        applyTypingAttributes(to: view)
    }

    // MARK: Private

    private func applyTypingAttributes(to view: DraftTextView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        if view.font != font || view.textColor != color {
            view.font = font
            view.textColor = color
            view.insertionPointColor = color
            view.typingAttributes = [.font: font, .foregroundColor: color]
        }
    }
}

// MARK: - DraftTextView

/// Text view distinguishing Enter (commit), Shift+Enter (newline) and Esc
/// (discard) — the three ways the draft can end while typing.
final class DraftTextView: NSTextView {
    var onCommit: (() -> ())?
    var onCancel: (() -> ())?

    override func insertNewline(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
        } else {
            onCommit?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
