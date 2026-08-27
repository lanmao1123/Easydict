//
//  ScreenshotDockLayoutTests.swift
//  EasydictTests
//
//  Created by agent on 2026/8/26.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation
import Testing

@testable import Easydict

// MARK: - ScreenshotDockLayoutTests

/// Unit tests for the pure layout math in `ScreenshotDockLayout`.
///
/// All coordinates are constructed as integer-valued rects so every expectation
/// is exact and free of floating point drift.
@Suite("Screenshot Dock Layout", .tags(.screenshot, .unit))
struct ScreenshotDockLayoutTests {
    // MARK: Internal

    // MARK: globalRect(fromLocalRect:screenFrame:)

    @Test("Primary screen selection converts with a Y-axis flip", .tags(.screenshot, .unit))
    func testGlobalRectFlipsYAxisOnPrimaryScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let localRect = CGRect(x: 100, y: 200, width: 300, height: 150)

        let result = ScreenshotDockLayout.globalRect(fromLocalRect: localRect, screenFrame: screenFrame)

        // Local top edge sits 200pt below the screen top with a 150pt height,
        // so the global rect spans y = 730...880 (bottom-left origin).
        let expected = CGRect(x: 100, y: 730, width: 300, height: 150)
        #expect(result == expected)
        #expect(result.width == 300)
        #expect(result.height == 150)
    }

    @Test("Secondary screen offset shifts both axes", .tags(.screenshot, .unit))
    func testGlobalRectOffsetsBySecondaryScreenFrame() {
        // A display arranged to the left of and above the primary display,
        // so both screenFrame.minX and screenFrame.minY are non-zero.
        let screenFrame = CGRect(x: -1920, y: 1080, width: 1920, height: 1080)
        let localRect = CGRect(x: 50, y: 40, width: 120, height: 80)

        let result = ScreenshotDockLayout.globalRect(fromLocalRect: localRect, screenFrame: screenFrame)

        // x follows screenFrame.minX directly; y flips against screenFrame.maxY (2160).
        let expected = CGRect(x: -1870, y: 2040, width: 120, height: 80)
        #expect(result == expected)
    }

    @Test("Local top edge maps onto screenFrame.maxY - localRect.minY", .tags(.screenshot, .unit))
    func testGlobalRectTopEdgeMatchesScreenMaxYRelation() {
        let screenFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let localRect = CGRect(x: 400, y: 90, width: 260, height: 60)

        let result = ScreenshotDockLayout.globalRect(fromLocalRect: localRect, screenFrame: screenFrame)

        // The converted global top edge must equal the screen top minus the local
        // top inset, and the converted bottom edge must equal it minus the height.
        #expect(result.maxY == screenFrame.maxY - localRect.minY)
        #expect(result.minY == screenFrame.maxY - localRect.maxY)
        #expect(result.minX == screenFrame.minX + localRect.minX)
    }

    @Test("Empty local rect returns .zero", .tags(.screenshot, .unit))
    func testGlobalRectReturnsZeroForEmptyLocalRect() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        #expect(ScreenshotDockLayout.globalRect(fromLocalRect: .zero, screenFrame: screenFrame) == .zero)

        // Zero width makes a rect empty even with non-zero origin.
        let degenerateRect = CGRect(x: 10, y: 20, width: 0, height: 40)
        #expect(ScreenshotDockLayout.globalRect(fromLocalRect: degenerateRect, screenFrame: screenFrame) == .zero)
    }

    // MARK: overlayWidth(forSelectionWidth:)

    @Test("Narrow selection widens to the minimum readable width", .tags(.screenshot, .unit))
    func testOverlayWidthClampsNarrowSelectionToMinimum() {
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 100) == ScreenshotDockLayout.minOverlayWidth)
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 100) == 240)
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 0) == 240)
    }

    @Test("Normal selection width mirrors through untouched", .tags(.screenshot, .unit))
    func testOverlayWidthMirrorsNormalSelectionWidth() {
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 500) == 500)
        // Exact boundary values pass through unchanged too.
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 240) == 240)
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 900) == 900)
    }

    @Test("Full-screen selection narrows to the maximum readable width", .tags(.screenshot, .unit))
    func testOverlayWidthClampsWideSelectionToMaximum() {
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 1200) == ScreenshotDockLayout.maxOverlayWidth)
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 1200) == 900)
        #expect(ScreenshotDockLayout.overlayWidth(forSelectionWidth: 1000) == 900)
    }

    @Test(
        "Ample room below docks the overlay 8pt under the selection",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginDocksDirectlyBelowWithRoomBelow() {
        let frame = Self.typicalVisibleFrame
        let selection = CGRect(x: 400, y: 600, width: 200, height: 60)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 300, height: 100),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        // The 100pt box fits into the 584pt space below, so its top edge rests
        // exactly one overlayGap under the selection's bottom edge.
        #expect(origin.x == 400)
        #expect(origin.y == 492)
        #expect(origin.x == selection.minX)
        #expect(origin.y + 100 == selection.minY - ScreenshotDockLayout.overlayGap)
    }

    @Test(
        "Horizontal placement only follows the selection minX, even for wider content",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginXIgnoresContentWiderThanSelection() {
        let frame = Self.typicalVisibleFrame
        let selection = CGRect(x: 300, y: 600, width: 120, height: 50)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 500, height: 80),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        // Nothing else constrains x horizontally: the overlay stays left-aligned
        // with the selection as long as the whole box clears the inner right bound.
        #expect(origin.x == 300)
        #expect(origin.x == selection.minX)
        #expect(origin.y == 512)
    }

    @Test(
        "No room below but plenty above flips the overlay over the selection",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginFlipsAboveWhenOnlyUpperSideFits() {
        let frame = Self.typicalVisibleFrame
        // Inner bounds span y = 8...892, so this near-bottom selection leaves a
        // 24pt strip below versus 814pt above; the 200pt box must flip upward.
        let selection = CGRect(x: 400, y: 40, width: 300, height: 30)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 280, height: 200),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        // Its bottom edge parks exactly one overlayGap above the selection top.
        #expect(origin.x == 400)
        #expect(origin.y == 78)
        #expect(origin.y == selection.maxY + ScreenshotDockLayout.overlayGap)
    }

    @Test(
        "Below-side majority pins the overlay onto the inner floor when neither side fits",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginPinsToFloorWhenBelowWinsButNeitherFits() {
        // Inner bounds span y = 8...392. The tall box (300pt) exceeds both the
        // 184pt below strip and the 124pt above strip, but the below side has
        // more room, so the below formula runs and bottoms out at the floor.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 400)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 60)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 360, height: 300),
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        // The naive below origin (-108) clamps up to the inner bottom bound.
        #expect(origin.x == 100)
        #expect(origin.y == 8)
        #expect(origin.y == visibleFrame.minY + ScreenshotDockLayout.screenMargin)
    }

    @Test(
        "Above-side win still clamps onto the inner floor when the flipped origin sinks past it",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginClampsFlippedAbovePositionIntoInnerFloor() {
        // The selection lies entirely beneath the visible frame (negative global
        // y), so there is no room below at all while almost everything is above;
        // the flipped candidate (-2) still sits under the inner floor of 8 and is
        // raised back inside.
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let selection = CGRect(x: 100, y: -20, width: 400, height: 10)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 360, height: 100),
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        #expect(origin.x == 100)
        #expect(origin.y == 8)
        #expect(origin.y == visibleFrame.minY + ScreenshotDockLayout.screenMargin)
    }

    @Test(
        "Selection poking past the left margin pushes the overlay onto the inner left bound",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginClampsToLeftInnerBoundForLeftEdgeSelection() {
        let frame = Self.typicalVisibleFrame
        // selection.minX = 2 sits inside the 8pt screenMargin band at the left,
        // so the aligned x is clamped up to the inner left bound.
        let selection = CGRect(x: 2, y: 600, width: 300, height: 60)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 360, height: 100),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        #expect(origin.x == 8)
        #expect(origin.x == frame.minX + ScreenshotDockLayout.screenMargin)
        #expect(origin.y == 492)
    }

    @Test(
        "Right-edge selection pulls wide content fully inside",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginPullsWideContentInsideAtRightEdge() {
        let frame = Self.typicalVisibleFrame
        // Aligning at 1300 would push the 420pt box's right edge to 1720, well
        // past the inner right bound (1432), so x drops back to keep it flush.
        let selection = CGRect(x: 1300, y: 600, width: 140, height: 60)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 420, height: 100),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        #expect(origin.x == 1012)
        #expect(origin.x == frame.maxX - ScreenshotDockLayout.screenMargin - 420)
        #expect(origin.y == 492)
    }

    @Test(
        "Selection cresting past the visible top keeps the whole overlay on screen",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginKeepsWholeOverlayOnScreenForSelectionAboveVisibleTop() {
        let frame = Self.typicalVisibleFrame
        // This selection tops out at y = 1030, beyond both the visible frame
        // (900) and the inner upper bound (892). The below formula naively yields
        // 772, which would push the box top to 972; clamping brings the top edge
        // exactly flush with the inner upper bound instead.
        let selection = CGRect(x: 400, y: 980, width: 300, height: 50)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 360, height: 200),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        #expect(origin.x == 400)
        #expect(origin.y == 692)
        // The overlay's top edge rests exactly on the inner upper bound (892).
        #expect(origin.y + 200 == 892)
        #expect(origin.y + 200 == frame.maxY - ScreenshotDockLayout.screenMargin)
    }

    @Test(
        "Exact-fit boundaries keep the below placement without flipping",
        .tags(.screenshot, .unit)
    )
    func testOverlayOriginKeepsBelowPlacementAtExactFitBoundaries() {
        let frame = Self.typicalVisibleFrame
        // Height equals the 160pt strip below the selection exactly; the strict
        // `>` fit check therefore never flips upward even though the above strip
        // (658pt) is larger. Horizontally the 420pt box ending at 1432 matches
        // the inner right bound exactly, so x also passes through untouched.
        let selection = CGRect(x: 1012, y: 176, width: 300, height: 50)

        let origin = ScreenshotDockLayout.overlayOrigin(
            contentSize: CGSize(width: 420, height: 160),
            selectionGlobalRect: selection,
            visibleFrame: frame
        )

        #expect(origin.x == 1012)
        #expect(origin.x + 420 == 1432)
        #expect(origin.y == 8)
        #expect(origin.y == selection.minY - ScreenshotDockLayout.overlayGap - 160)
    }

    // MARK: Private

    // MARK: overlayOrigin(contentSize:selectionGlobalRect:visibleFrame:)

    /// Visible frame used by most cases: an inset of 8pt on every side gives
    /// inner bounds x = 8...1432, y = 8...892.
    private static let typicalVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
}
