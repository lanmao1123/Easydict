//
//  AnnotationModelTests.swift
//  EasydictTests
//
//  Created by agent on 2026/8/27.
//  Copyright © 2026 izual. All rights reserved.
//

import CoreGraphics
import Foundation
import Testing

@testable import Easydict

// MARK: - AnnotationModelTests

/// Unit tests for the annotation collection semantics: z-order append, eraser
/// hit testing and snapshot-based undo/redo.
///
/// `AnnotationModel` is `@MainActor` isolated, so the whole suite runs on the
/// main actor.
@MainActor
@Suite("Screenshot Annotation Model", .tags(.screenshot, .unit))
struct AnnotationModelTests {
    // MARK: Internal

    // MARK: Initial state

    @Test("Fresh model has no items and no history flags", .tags(.screenshot, .unit))
    func testInitialModelStateIsEmpty() {
        let model = AnnotationModel()

        #expect(model.items.isEmpty)
        #expect(!model.canUndo)
        #expect(!model.canRedo)
    }

    // MARK: add(_:)

    @Test("add appends onto the z-order top and enables undo", .tags(.screenshot, .unit))
    func testAddAppendsOntopOfZOrderAndEnablesUndo() {
        let model = AnnotationModel()
        let bottom = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        let top = Self.rectangle(CGRect(x: 10, y: 10, width: 40, height: 40))

        model.add(bottom)
        model.add(top)

        // The later item sits at the end of the array, i.e. drawn on top.
        #expect(model.items.map(\.id) == [bottom.id, top.id])
        #expect(model.canUndo)
        #expect(!model.canRedo)
    }

    // MARK: undo() / redo()

    @Test("undo peels only the newest item off, one step per call", .tags(.screenshot, .unit))
    func testUndoPeelsNewestItemOffStepByStep() {
        let model = AnnotationModel()
        let first = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Self.line(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 70))
        model.add(first)
        model.add(second)

        model.undo()

        #expect(model.items.map(\.id) == [first.id])
        #expect(model.canUndo)
        #expect(model.canRedo)

        model.undo()

        #expect(model.items.isEmpty)
        #expect(!model.canUndo)
        #expect(model.canRedo)
    }

    @Test("redo restores the undone item exactly once", .tags(.screenshot, .unit))
    func testRedoRestoresUndoneItemExactlyOnce() {
        let model = AnnotationModel()
        let item = Self.rectangle(CGRect(x: 5, y: 5, width: 40, height: 40))
        model.add(item)
        model.undo()
        #expect(model.items.isEmpty)

        model.redo()

        #expect(model.items.map(\.id) == [item.id])
        #expect(model.canUndo)
        #expect(!model.canRedo)

        // A second redo is a no-op because the redo stack drained.
        model.redo()
        #expect(model.items.map(\.id) == [item.id])
    }

    @Test("a fresh edit invalidates the stale redo branch", .tags(.screenshot, .unit))
    func testFreshEditInvalidatesStaleRedoBranch() {
        let model = AnnotationModel()
        let abandoned = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        let replacement = Self.rectangle(CGRect(x: 60, y: 60, width: 40, height: 40))

        model.add(abandoned)
        model.undo()
        model.add(replacement)

        #expect(model.items.map(\.id) == [replacement.id])
        #expect(model.canUndo)
        #expect(!model.canRedo)
    }

    // MARK: erase(alongSegment:to:)

    @Test("erase deletes only the topmost item intersecting the drag segment", .tags(.screenshot, .unit))
    func testEraseDeletesOnlyTopmostIntersectingItem() {
        let model = AnnotationModel()
        let bottom = Self.rectangle(CGRect(x: 0, y: 0, width: 50, height: 50))
        let top = Self.rectangle(CGRect(x: 10, y: 10, width: 50, height: 50))
        model.add(bottom)
        model.add(top)

        // This segment crosses the overlap of both rectangles, so the eraser
        // must pick the newer one only.
        let erased = model.erase(alongSegment: CGPoint(x: 15, y: 15), to: CGPoint(x: 25, y: 25))

        #expect(erased)
        #expect(model.items.map(\.id) == [bottom.id])
        #expect(model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("erase returns false and keeps items when nothing intersects", .tags(.screenshot, .unit))
    func testEraseReturnsFalseWhenNothingIntersects() {
        let model = AnnotationModel()
        let item = Self.rectangle(CGRect(x: 0, y: 0, width: 50, height: 50))
        model.add(item)

        let erased = model.erase(alongSegment: CGPoint(x: 200, y: 200), to: CGPoint(x: 220, y: 220))

        #expect(!erased)
        #expect(model.items.map(\.id) == [item.id])
        // A missed erase records no new history: the earlier add snapshot
        // survives, so undo stays available while redo remains empty.
        #expect(model.canUndo)
        #expect(!model.canRedo)
    }

    @Test("erase hits a text item through its measured text bounds", .tags(.screenshot, .unit))
    func testEraseHitsTextThroughEstimatedBounds() {
        let model = AnnotationModel()
        let text = Self.text("hello", at: CGPoint(x: 100, y: 100))
        model.add(text)

        // "hello" at the default size measures ~36x22 points from its anchor,
        // so this segment lands well inside those bounds.
        let erased = model.erase(alongSegment: CGPoint(x: 130, y: 110), to: CGPoint(x: 140, y: 115))

        #expect(erased)
        #expect(model.items.isEmpty)
    }

    // MARK: update(_:) / remove(_:)

    @Test("update replaces an item in place and one undo restores it", .tags(.screenshot, .unit))
    func testUpdateReplacesInPlaceWithSingleUndoStep() {
        let model = AnnotationModel()
        let original = Self.text("hello", at: CGPoint(x: 100, y: 100))
        model.add(original)

        var edited = original
        edited.kind = .text(
            string: "hello world",
            at: CGPoint(x: 100, y: 100),
            fontSize: AnnotationItemKind.defaultFontSize
        )
        model.update(edited)

        #expect(model.items.map(\.id) == [original.id])
        if case let .text(string, _, _) = model.items[0].kind {
            #expect(string == "hello world")
        } else {
            Issue.record("item kind changed")
        }

        model.undo()

        if case let .text(string, _, _) = model.items[0].kind {
            #expect(string == "hello")
        } else {
            Issue.record("undo did not restore a text item")
        }
    }

    @Test("update with an unknown id is a no-op", .tags(.screenshot, .unit))
    func testUpdateWithUnknownIdIsNoOp() {
        let model = AnnotationModel()
        let item = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        model.add(item)

        let stranger = Self.text("ghost", at: .zero)
        model.update(stranger)

        #expect(model.items.map(\.id) == [item.id])
        if case .text = model.items[0].kind {
            Issue.record("unknown update leaked into items")
        }
    }

    @Test("remove deletes the identified item and undo brings it back", .tags(.screenshot, .unit))
    func testRemoveDeletesIdentifiedItemAndUndoRestoresIt() {
        let model = AnnotationModel()
        let keep = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        let drop = Self.text("bye", at: CGPoint(x: 60, y: 60))
        model.add(keep)
        model.add(drop)

        model.remove(drop.id)

        #expect(model.items.map(\.id) == [keep.id])
        #expect(model.canUndo)

        model.undo()

        #expect(model.items.map(\.id) == [keep.id, drop.id])
    }

    @Test("remove with an unknown id records no history", .tags(.screenshot, .unit))
    func testRemoveWithUnknownIdIsNoOp() {
        let model = AnnotationModel()
        let item = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        model.add(item)

        model.remove(UUID())

        #expect(model.items.map(\.id) == [item.id])
        // Still exactly the one add snapshot on the undo stack.
        model.undo()
        #expect(model.items.isEmpty)
    }

    // MARK: removeAll()

    @Test("removeAll clears everything while undo brings the items back", .tags(.screenshot, .unit))
    func testRemoveAllClearsItemsAndUndoBringsThemBack() {
        let model = AnnotationModel()
        let first = Self.rectangle(CGRect(x: 0, y: 0, width: 40, height: 40))
        let second = Self.text("note", at: CGPoint(x: 120, y: 80))
        model.add(first)
        model.add(second)

        model.removeAll()

        #expect(model.items.isEmpty)
        #expect(model.canUndo)
        #expect(!model.canRedo)

        model.undo()

        #expect(model.items.map(\.id) == [first.id, second.id])
        #expect(model.canRedo)
    }

    @Test("removeAll on an empty model stays a no-op", .tags(.screenshot, .unit))
    func testRemoveAllOnEmptyModelStaysNoOp() {
        let model = AnnotationModel()

        model.removeAll()

        #expect(model.items.isEmpty)
        #expect(!model.canUndo)
        #expect(!model.canRedo)
    }

    // MARK: Style defaults

    @Test("Default style is opaque and text metrics constants stay stable", .tags(.screenshot, .unit))
    func testDefaultStyleAlphaAndTextMetricsConstants() {
        let style = AnnotationStyle(red: 0.2, green: 0.4, blue: 0.6, lineWidth: 4)

        #expect(style.alpha == 1)
        #expect(AnnotationItemKind.defaultFontSize == 16)
        #expect(AnnotationItemKind.textLineHeightFactor == 1.4)
    }

    // MARK: Private

    // MARK: Helpers

    private static func rectangle(_ bounds: CGRect) -> AnnotationItem {
        AnnotationItem(kind: .rectangle(bounds: bounds), style: .black)
    }

    private static func line(from from: CGPoint, to: CGPoint) -> AnnotationItem {
        AnnotationItem(kind: .line(from: from, to: to), style: .black)
    }

    private static func text(_ string: String, at point: CGPoint) -> AnnotationItem {
        AnnotationItem(
            kind: .text(string: string, at: point, fontSize: AnnotationItemKind.defaultFontSize),
            style: .black
        )
    }
}
