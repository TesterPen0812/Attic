import XCTest
@testable import Attic

final class PanelGeometryTests: XCTestCase {
    func testHotspotsOccupyExactScreenCorners() {
        let frame = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .topLeft), CGRect(x: -1_440, y: 884, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .topRight), CGRect(x: -16, y: 884, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .bottomLeft), CGRect(x: -1_440, y: 0, width: 16, height: 16))
        XCTAssertEqual(PanelGeometry.hotspot(in: frame, corner: .bottomRight), CGRect(x: -16, y: 0, width: 16, height: 16))
    }

    func testPanelAnchorsInsideVisibleFrame() {
        let frame = CGRect(x: 0, y: 25, width: 1_920, height: 1_030)
        let size = CGSize(width: 340, height: 400)

        XCTAssertEqual(
            PanelGeometry.panelFrame(in: frame, size: size, corner: .topRight),
            CGRect(x: 1_568, y: 643, width: 340, height: 400)
        )
        XCTAssertEqual(
            PanelGeometry.panelFrame(in: frame, size: size, corner: .bottomLeft),
            CGRect(x: 12, y: 37, width: 340, height: 400)
        )
    }

    func testPreferredHeightIsClamped() {
        XCTAssertEqual(PanelGeometry.preferredHeight(taskCount: 0, sectionCount: 0, isComposing: false), PanelGeometry.minimumHeight)
        XCTAssertEqual(PanelGeometry.preferredHeight(taskCount: 100, sectionCount: 3, isComposing: true), PanelGeometry.preferredHeightCeiling)
    }

    func testLiveResizeLimitsAllowIndependentWidthAndHeightChanges() {
        XCTAssertEqual(PanelGeometry.minimumPanelSize, CGSize(width: 332, height: 480))
        XCTAssertEqual(PanelGeometry.defaultPanelSize.width, 332)
        XCTAssertEqual(PanelGeometry.defaultPanelSize.height, 481.4, accuracy: 0.001)

        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(CGSize(width: 250, height: 620)),
            CGSize(width: 332, height: 620)
        )
        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(CGSize(width: 640, height: 900)),
            CGSize(width: 640, height: 900)
        )
    }

    func testResizeMaximumSizeFitsTheVisibleScreen() {
        let compactVisibleFrame = CGRect(x: 0, y: 25, width: 600, height: 600)
        XCTAssertEqual(
            PanelGeometry.resizeMaximumSize(in: compactVisibleFrame),
            CGSize(width: 576, height: 576)
        )
        XCTAssertEqual(
            PanelGeometry.clampedPanelSize(
                CGSize(width: 700, height: 650),
                in: compactVisibleFrame
            ),
            CGSize(width: 576, height: 576)
        )
    }

    func testTaskScrollMaskUsesPointSizedFadesAcrossPanelHeights() {
        let compact = TaskScrollMaskLayout.stops(panelHeight: 480)
        let tall = TaskScrollMaskLayout.stops(panelHeight: 900)

        XCTAssertEqual(compact.topFadeEnd * 480, 18, accuracy: 0.001)
        XCTAssertEqual((1 - compact.bottomFadeStart) * 480, 76, accuracy: 0.001)
        XCTAssertEqual(tall.topFadeEnd * 900, 18, accuracy: 0.001)
        XCTAssertEqual((1 - tall.bottomFadeStart) * 900, 76, accuracy: 0.001)
    }

    @MainActor
    func testSectionSwitchingPreservesTheActualLivePanelSize() {
        let uiState = PanelUIState()
        let manuallySelectedSize = CGSize(width: 604, height: 638)
        uiState.updatePanelSize(manuallySelectedSize)

        for section in PanelSection.allCases {
            uiState.selectSection(section)
            XCTAssertEqual(uiState.panelSize, manuallySelectedSize)
        }
    }

    func testWorkspaceHeightIsStableAndResponsiveToConfiguredWidth() {
        XCTAssertEqual(PanelGeometry.preferredWorkspaceHeight(contentWidth: 300), 480)
        XCTAssertEqual(
            PanelGeometry.preferredWorkspaceHeight(contentWidth: 332),
            481.4,
            accuracy: 0.001
        )
        XCTAssertEqual(PanelGeometry.preferredWorkspaceHeight(contentWidth: 380), 551)
        XCTAssertEqual(
            PanelGeometry.preferredWorkspaceHeight(contentWidth: 1_000),
            PanelGeometry.preferredHeightCeiling
        )
    }
}
