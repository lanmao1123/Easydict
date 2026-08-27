//
//  AnnotationModel.swift
//  Easydict
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import AppKit

// MARK: - AnnotationTool

/// Annotation tools offered by the screenshot editor toolbar.
enum AnnotationTool: String, CaseIterable {
    case rectangle
    case ellipse
    case line
    case arrow
    case pencil
    case marker
    case underline
    case text
    case mosaic
    case blur
    case eraser

    // MARK: Internal

    var systemSymbolName: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pencil: "pencil.tip"
        case .marker: "highlighter"
        case .underline: "underline"
        case .text: "textformat"
        case .mosaic: "squareshape.split.3x3"
        case .blur: "drop.halffull"
        case .eraser: "eraser"
        }
    }

    /// Localization key for the toolbar tooltip.
    var tooltipKey: String {
        "tool_\(rawValue)"
    }

    /// Custom toolbar glyph; nil falls back to `systemSymbolName`.
    /// Mosaic gets a hand-drawn pixel grid — Snipping-Tool style — because no
    /// SF Symbol reads as "pixelate" at toolbar size.
    var customToolbarImage: NSImage? {
        guard self == .mosaic else { return nil }
        return Self.mosaicToolbarIcon
    }

    // MARK: Private

    private static let mosaicToolbarIcon: NSImage = {
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocusFlipped(true)

        // 3x3 pixel grid with a few cells knocked out, reading as a coarse
        // low-resolution image; template-ready via a single dark tone.
        let cells = 3
        let gap: CGFloat = 1.5
        let cell = (side - gap * CGFloat(cells - 1)) / CGFloat(cells)
        let fillPattern: [[Bool]] = [
            [true, true, false],
            [true, true, true],
            [false, true, true],
        ]
        NSColor.black.setFill()
        for row in 0 ..< cells {
            for column in 0 ..< cells where fillPattern[row][column] {
                NSBezierPath(
                    roundedRect: CGRect(
                        x: CGFloat(column) * (cell + gap),
                        y: CGFloat(row) * (cell + gap),
                        width: cell,
                        height: cell
                    ),
                    xRadius: 1.5,
                    yRadius: 1.5
                ).fill()
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()
}

// MARK: - AnnotationStyle

/// Color and stroke width shared by vector annotations.
/// Components are stored as doubles so styles stay equatable and testable.
struct AnnotationStyle: Equatable {
    static let black = AnnotationStyle(red: 0.07, green: 0.09, blue: 0.16, lineWidth: 5)

    var red: Double
    var green: Double
    var blue: Double
    /// Stroke width in annotation points (the editing rect's point space).
    var lineWidth: CGFloat
    /// Stroke opacity; below 1 gives highlighter translucency.
    var alpha: Double = 1
}

// MARK: - AnnotationItemKind

enum AnnotationItemKind: Equatable {
    case rectangle(bounds: CGRect)
    case ellipse(bounds: CGRect)
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case pencil(points: [CGPoint])
    case marker(points: [CGPoint])
    /// A straight horizontal highlighter band; the user-visible underline tool.
    case underline(band: CGRect)
    case text(string: String, at: CGPoint, fontSize: CGFloat)
    /// A pre-rendered effect tile (mosaic or blur) covering `frame`.
    case region(image: CGImage, frame: CGRect)

    // MARK: Internal

    /// Default font size for new text annotations, in annotation points.
    static let defaultFontSize: CGFloat = 16
    /// Line-height multiplier applied to a text item's font size.
    static let textLineHeightFactor: CGFloat = 1.4

    /// Shared text metric used by rendering, hit tests and the eraser so all
    /// three agree on how much room a text annotation occupies.
    static func textSize(for string: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize)
        return (string as NSString).boundingRect(
            with: CGSize(width: 420, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        ).size
    }

    /// Bounding box in the selection's top-left point space, used for hit
    /// tests and eraser intersection.
    func bounds() -> CGRect {
        func inflated(_ points: [CGPoint], width: CGFloat) -> CGRect {
            guard let first = points.first else { return .zero }
            var bounds = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                bounds = bounds.union(CGRect(origin: point, size: .zero))
            }
            return bounds.insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
        }

        switch self {
        case let .ellipse(bounds), let .rectangle(bounds):
            return bounds.standardized
        case let .line(from, to):
            return inflated([from, to], width: 10)
        case let .arrow(from, to):
            return inflated([from, to], width: 14)
        case let .marker(points), let .pencil(points):
            return inflated(points, width: 12)
        case let .underline(band):
            return band.insetBy(dx: -2, dy: -2)
        case let .text(string, at, fontSize):
            return CGRect(origin: at, size: Self.textSize(for: string, fontSize: fontSize))
        case let .region(_, frame):
            return frame
        }
    }
}

// MARK: - AnnotationItem

/// One committed annotation drawn over the screenshot.
struct AnnotationItem: Equatable {
    // MARK: Internal

    let id = UUID()
    var kind: AnnotationItemKind
    var style: AnnotationStyle

    /// Renders with AppKit into the current flipped graphics context.
    /// `scale` converts annotation points to target pixels. The composer sets
    /// up a flipped focus so all math here matches the SwiftUI display side.
    func render(scale: CGFloat) {
        let color = NSColor(
            calibratedRed: style.red, green: style.green, blue: style.blue,
            alpha: style.alpha
        )
        color.setStroke()
        color.setFill()

        switch kind {
        case let .rectangle(bounds):
            let path = NSBezierPath(rect: scaled(bounds, by: scale))
            path.lineWidth = scaledWidth(scale)
            path.stroke()

        case let .ellipse(bounds):
            let path = NSBezierPath(ovalIn: scaled(bounds, by: scale))
            path.lineWidth = scaledWidth(scale)
            path.stroke()

        case let .line(from, to):
            let path = NSBezierPath()
            path.move(to: scaledPoint(from, by: scale))
            path.line(to: scaledPoint(to, by: scale))
            applyRoundCaps(path)
            path.lineWidth = scaledWidth(scale)
            path.stroke()

        case let .arrow(from, to):
            let start = scaledPoint(from, by: scale)
            let end = scaledPoint(to, by: scale)
            let shaft = NSBezierPath()
            shaft.move(to: start)
            shaft.line(to: end)
            shaft.lineWidth = scaledWidth(scale)
            applyRoundCaps(shaft)
            shaft.stroke()

            // Arrowhead wings at ±150° from the shaft direction.
            let headLength = max(scaledWidth(scale) * 3, 10)
            let angle = atan2(end.y - start.y, end.x - start.x)
            for offset in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                let wingAngle = angle + offset
                let wingStart = CGPoint(
                    x: end.x + cos(wingAngle) * headLength,
                    y: end.y + sin(wingAngle) * headLength
                )
                let head = NSBezierPath()
                head.move(to: wingStart)
                head.line(to: end)
                head.lineWidth = scaledWidth(scale)
                head.lineCapStyle = .round
                head.stroke()
            }

        case let .marker(points), let .pencil(points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: scaledPoint(first, by: scale))
            for point in points.dropFirst() {
                path.line(to: scaledPoint(point, by: scale))
            }
            applyRoundCaps(path)
            // Markers run three times thicker for a highlighter feel.
            path.lineWidth = scaledWidth(scale) * (style.alpha < 1 ? 3 : 1)
            path.stroke()

        case let .underline(band):
            let rect = scaled(band, by: scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            path.fill()

        case let .text(string, at, fontSize):
            let font = NSFont.systemFont(ofSize: fontSize * scale)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            // Multi-line text wraps at a generous max width; the string's own
            // newlines drive explicit breaks.
            let bounding = (string as NSString).boundingRect(
                with: CGSize(width: 420 * scale, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            )
            (string as NSString).draw(
                with: CGRect(origin: scaledPoint(at, by: scale), size: bounding.size),
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            )

        case let .region(image, frame):
            /*
             Flipped context (y grows downward) plus CGContext's habit of
             mapping the image top row to the rect's maxY would render the
             tile upside down; flip explicitly so the top row lands on the
             visual top instead.
             */
            if let context = NSGraphicsContext.current?.cgContext {
                let rect = scaled(frame, by: scale)
                context.saveGState()
                context.translateBy(x: 0, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
                context.restoreGState()
            }
        }
    }

    // MARK: Private

    private func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    private func scaledPoint(_ point: CGPoint, by scale: CGFloat) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }

    private func scaledWidth(_ scale: CGFloat) -> CGFloat {
        max(style.lineWidth * scale, 1)
    }

    private func applyRoundCaps(_ path: NSBezierPath) {
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }
}

// MARK: - AnnotationModel

/// Observable collection of annotations with snapshot-based undo/redo.
@MainActor
final class AnnotationModel: ObservableObject {
    // MARK: Internal

    /// Committed items in z-order; the last one draws on top.
    @Published private(set) var items: [AnnotationItem] = []

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Commits an item on top of the stack.
    func add(_ item: AnnotationItem) {
        mutate { $0.append(item) }
    }

    /// Opens a stroke group: one undo snapshot covering every `addSilent`
    /// commit until `endStrokeGroup()`, so a single ⌘Z removes the whole
    /// painted brush stroke.
    func beginStrokeGroup() {
        guard !strokeGroupOpen else { return }
        strokeGroupOpen = true
        undoStack.append(items)
        if undoStack.count > Self.maxHistoryDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
        syncFlags()
    }

    /// Closes the stroke group; drops the snapshot again when nothing was
    /// painted so empty strokes leave no dangling undo step.
    func endStrokeGroup() {
        defer { strokeGroupOpen = false }
        if let snapshot = undoStack.last, snapshot == items {
            undoStack.removeLast()
            syncFlags()
        }
    }

    /// Appends without touching undo history; only valid inside a stroke group.
    func addSilent(_ item: AnnotationItem) {
        items.append(item)
    }

    /// Removes the topmost annotation intersecting the drag segment, matching
    /// Snipaste's eraser feel. Returns true when something was erased.
    @discardableResult
    func erase(alongSegment from: CGPoint, to: CGPoint) -> Bool {
        let span = minInsetSegmentBounds(from: from, to: to)
        guard let index = items.lastIndex(where: { $0.kind.bounds().intersects(span) }) else {
            return false
        }
        mutate { $0.remove(at: index) }
        return true
    }

    /// Replaces an item in place — the re-edit path for committed text. The
    /// incoming item keeps its identity, so one undo step restores the old one.
    func update(_ updated: AnnotationItem) {
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
        mutate { $0[index] = updated }
    }

    /// Deletes one identified item (e.g. a text annotation cleared during
    /// re-edit); a single undo step brings it back.
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate { $0.remove(at: index) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        syncFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        syncFlags()
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        mutate { $0.removeAll() }
    }

    // MARK: Private

    private static let maxHistoryDepth = 50

    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []

    /// True between `beginStrokeGroup()` and `endStrokeGroup()`.
    private var strokeGroupOpen = false

    /// Applies a structural change while pushing an undo snapshot.
    private func mutate(_ change: (inout [AnnotationItem]) -> ()) {
        undoStack.append(items)
        if undoStack.count > Self.maxHistoryDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()

        change(&items)
        syncFlags()
    }

    private func syncFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func minInsetSegmentBounds(from: CGPoint, to: CGPoint) -> CGRect {
        let bounds = CGRect(origin: from, size: .zero).union(CGRect(origin: to, size: .zero))
        return bounds.insetBy(dx: -8, dy: -8)
    }
}
