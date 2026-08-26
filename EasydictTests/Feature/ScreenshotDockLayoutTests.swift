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

    // MARK: dockedPanelOrigin(panelSize:selectionGlobalRect:visibleFrame:)

    @Test("Right-side placement wins when space allows and top-aligns", .tags(.screenshot, .unit))
    func testDockedPanelOriginPrefersRightSideAndTopAligns() {
        // Inner bounds after an 8pt screenMargin span x = 8...1432 and y = 8...892.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 400, width: 200, height: 60)
        let panelSize = CGSize(width: 360, height: 300)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        // Right side: 312 + 360 = 672 fits inside the inner bound of 1432.
        #expect(origin.x == selection.maxX + 12) // panelGap = 12
        // Top-aligned: unclamped y leaves the panel top at selection.maxY.
        #expect(origin.y + panelSize.height == selection.maxY)
        #expect(origin == CGPoint(x: 312, y: 160))
    }

    @Test("Falls back to the left side when the right side overflows", .tags(.screenshot, .unit))
    func testDockedPanelOriginFallsBackToLeftSideWhenRightSideOverflows() {
        // Inner right bound is 992; the right-side candidate would end at 1322.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let selection = CGRect(x: 700, y: 300, width: 250, height: 60)
        let panelSize = CGSize(width: 360, height: 240)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        // Left placement keeps the same 12pt gap; vertical stays unclamped.
        let expected = CGPoint(x: selection.minX - 12 - panelSize.width, y: selection.maxY - panelSize.height)
        #expect(origin == expected)
        #expect(origin == CGPoint(x: 328, y: 120))
    }

    @Test("Neither side fitting clamps x to the inner left edge", .tags(.screenshot, .unit))
    func testDockedPanelOriginClampsToInnerLeftEdgeWhenNeitherSideFits() {
        // Inner bounds: minX = 8, maxX = 792. The centered selection puts the
        // right candidate at x = 592, ending at 592 + 360 = 952 (overflows right),
        // and the left candidate at 220 - 12 - 360 = -152 (overflows left).
        let visibleFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let selection = CGRect(x: 220, y: 100, width: 360, height: 50)
        let panelSize = CGSize(width: 360, height: 100)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        #expect(origin.x == visibleFrame.minX + 8) // screenMargin = 8
        #expect(origin.y == selection.maxY - panelSize.height) // still unclamped
        #expect(origin == CGPoint(x: 8, y: 50))
    }

    @Test("Tall panel clamps above the visible bottom edge", .tags(.screenshot, .unit))
    func testDockedPanelOriginClampsTallPanelInsideVisibleBottomEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let selection = CGRect(x: 400, y: 100, width: 300, height: 50)
        let panelSize = CGSize(width: 360, height: 500)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        // Right side still fits (712 + 360 = 1072 <= 1184).
        #expect(origin.x == 712)
        // y = selection.maxY - height = -350 gets lifted to the inner lower bound.
        #expect(origin.y == visibleFrame.minY + 8) // screenMargin = 8
        #expect(origin == CGPoint(x: 712, y: 8))
    }

    @Test(
        "Selection poking above the visible frame keeps the panel fully inside",
        .tags(.screenshot, .unit)
    )
    func testDockedPanelOriginKeepsPanelInsideForHighSelection() {
        // Pure math scenario: the selection top (840) extends past the inner upper
        // bound (792), e.g. a screenshot reaching into the menu bar region. The
        // top-aligned candidate would poke out, so its origin is lowered until the
        // whole panel fits under the inner upper bound.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let selection = CGRect(x: 400, y: 780, width: 300, height: 60)
        let panelSize = CGSize(width: 360, height: 40)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        // Right side still fits; the origin drops to innerBounds.maxY - height so
        // the panel top edge lands exactly on the inner upper bound.
        #expect(origin.x == 712)
        #expect(origin.y == visibleFrame.maxY - 8 - panelSize.height) // margin + cap
        #expect(origin.y >= visibleFrame.minY)
        #expect(origin == CGPoint(x: 712, y: 752))
    }

    @Test("Exactly fitting right side stays on the right", .tags(.screenshot, .unit))
    func testDockedPanelOriginKeepsRightSideAtExactFitBoundary() {
        // Inner right bound is 992 and the right candidate ends exactly at
        // 632 + 360 = 992, so the strict ">" overflow check must keep the right side.
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let selection = CGRect(x: 500, y: 300, width: 120, height: 40)
        let panelSize = CGSize(width: 360, height: 200)

        let origin = ScreenshotDockLayout.dockedPanelOrigin(
            panelSize: panelSize,
            selectionGlobalRect: selection,
            visibleFrame: visibleFrame
        )

        #expect(origin == CGPoint(x: 632, y: 140))
    }
}
