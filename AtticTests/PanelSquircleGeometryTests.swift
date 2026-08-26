import XCTest
@testable import Attic

final class PanelSquircleGeometryTests: XCTestCase {
    func testRectangularSystemShadowIsDisabledForSquirclePanel() {
        XCTAssertFalse(AtticStyle.panelUsesSystemShadow)
    }

    func testContentInsetsAtMinimumCornerSize() {
        let insets = PanelGeometry.contentInsets(
            cornerSize: PanelCornerSize.min,
            panelSize: CGSize(width: PanelContentSize.min, height: 380)
        )
        let cornerInset = PanelCornerSize.min * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        let expectedHorizontal = max(AtticStyle.horizontalPadding, cornerInset + 6)
        let expectedTop = max(8, cornerInset + 4)
        let expectedBottom = max(10, cornerInset + 6)

        XCTAssertEqual(insets.leading, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.trailing, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.top, expectedTop, accuracy: 0.01)
        XCTAssertEqual(insets.bottom, expectedBottom, accuracy: 0.01)
    }

    func testContentInsetsAtDefaultCornerSize() {
        let insets = PanelGeometry.contentInsets(
            cornerSize: PanelCornerSize.standard.rawValue,
            panelSize: CGSize(width: PanelContentSize.standard.rawValue, height: 380)
        )
        let cornerInset = PanelCornerSize.standard.rawValue * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        let expectedHorizontal = max(AtticStyle.horizontalPadding, cornerInset + 6)
        let expectedTop = max(8, cornerInset + 4)
        let expectedBottom = max(10, cornerInset + 6)

        XCTAssertEqual(insets.leading, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.trailing, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.top, expectedTop, accuracy: 0.01)
        XCTAssertEqual(insets.bottom, expectedBottom, accuracy: 0.01)
    }

    func testContentInsetsAtMaximumCornerSize() {
        let insets = PanelGeometry.contentInsets(
            cornerSize: PanelCornerSize.max,
            panelSize: CGSize(width: PanelContentSize.max, height: 700)
        )
        let cornerInset = PanelCornerSize.max * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        let expectedHorizontal = max(AtticStyle.horizontalPadding, cornerInset + 6)
        let expectedTop = max(8, cornerInset + 4)
        let expectedBottom = max(10, cornerInset + 6)

        XCTAssertEqual(insets.leading, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.trailing, expectedHorizontal, accuracy: 0.01)
        XCTAssertEqual(insets.top, expectedTop, accuracy: 0.01)
        XCTAssertEqual(insets.bottom, expectedBottom, accuracy: 0.01)
    }

    func testContentInsetsIncreaseWithCornerSize() {
        let smallInsets = PanelGeometry.contentInsets(
            cornerSize: PanelCornerSize.min,
            panelSize: CGSize(width: PanelContentSize.standard.rawValue, height: 380)
        )
        let largeInsets = PanelGeometry.contentInsets(
            cornerSize: PanelCornerSize.max,
            panelSize: CGSize(width: PanelContentSize.standard.rawValue, height: 380)
        )
        XCTAssertGreaterThanOrEqual(largeInsets.leading, smallInsets.leading)
        XCTAssertGreaterThanOrEqual(largeInsets.top, smallInsets.top)
        XCTAssertGreaterThanOrEqual(largeInsets.bottom, smallInsets.bottom)
    }

    func testContentSafeBoundariesDoNotIntersectShapeAt380Height() {
        let cornerSize = PanelCornerSize.max
        let panelWidth = PanelContentSize.standard.rawValue
        let panelHeight: CGFloat = 380
        let panelSize = CGSize(width: panelWidth, height: panelHeight)
        let insets = PanelGeometry.contentInsets(cornerSize: cornerSize, panelSize: panelSize)

        // Content rect is the area inside the insets
        let contentRect = CGRect(
            x: insets.leading,
            y: insets.top,
            width: panelWidth - insets.leading - insets.trailing,
            height: panelHeight - insets.top - insets.bottom
        )

        // Verify content rect has positive dimensions (non-empty)
        XCTAssertGreaterThan(contentRect.width, 0)
        XCTAssertGreaterThan(contentRect.height, 0)

        // Verify content rect stays away from the corner regions
        let cornerInset = cornerSize * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        XCTAssertGreaterThanOrEqual(insets.leading, cornerInset + 4)
        XCTAssertGreaterThanOrEqual(insets.top, cornerInset + 2)
        XCTAssertGreaterThanOrEqual(insets.bottom, cornerInset + 4)
    }

    func testContentSafeBoundariesDoNotIntersectShapeAt700Height() {
        let cornerSize = PanelCornerSize.max
        let panelWidth = PanelContentSize.standard.rawValue
        let panelHeight: CGFloat = 700
        let panelSize = CGSize(width: panelWidth, height: panelHeight)
        let insets = PanelGeometry.contentInsets(cornerSize: cornerSize, panelSize: panelSize)

        let contentRect = CGRect(
            x: insets.leading,
            y: insets.top,
            width: panelWidth - insets.leading - insets.trailing,
            height: panelHeight - insets.top - insets.bottom
        )

        XCTAssertGreaterThan(contentRect.width, 0)
        XCTAssertGreaterThan(contentRect.height, 0)

        let cornerInset = cornerSize * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
        XCTAssertGreaterThanOrEqual(insets.leading, cornerInset + 4)
        XCTAssertGreaterThanOrEqual(insets.top, cornerInset + 2)
        XCTAssertGreaterThanOrEqual(insets.bottom, cornerInset + 4)
    }

    func testContentSafeBoundariesAtAllCornerSizes() {
        let panelWidth = PanelContentSize.standard.rawValue
        let panelHeight: CGFloat = 380

        for cornerSize in stride(from: PanelCornerSize.min, through: PanelCornerSize.max, by: 1) {
            let insets = PanelGeometry.contentInsets(
                cornerSize: cornerSize,
                panelSize: CGSize(width: panelWidth, height: panelHeight)
            )

            let contentWidth = panelWidth - insets.leading - insets.trailing
            let contentHeight = panelHeight - insets.top - insets.bottom

            // Content must remain usable
            XCTAssertGreaterThan(contentWidth, 200, "Content too narrow at corner size \(cornerSize)")
            XCTAssertGreaterThan(contentHeight, 200, "Content too short at corner size \(cornerSize)")

            // Content must stay inside the corner curve
            let cornerInset = cornerSize * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
            XCTAssertGreaterThanOrEqual(insets.leading, cornerInset + 4, "Horizontal inset too small at corner size \(cornerSize)")
        }
    }

    func testPanelWidthForContentSize() {
        XCTAssertEqual(PanelGeometry.panelWidth(for: 300), 300)
        XCTAssertEqual(PanelGeometry.panelWidth(for: 332), 332)
        XCTAssertEqual(PanelGeometry.panelWidth(for: 380), 380)
    }

    func testCornerInsetFactorIsPositiveAndLessThanOne() {
        let factor = Squircle.cornerInsetFactor(exponent: 5)
        XCTAssertGreaterThan(factor, 0)
        XCTAssertLessThan(factor, 1)
    }

    func testSquircleShapeProducesValidPath() {
        let rect = CGRect(x: 0, y: 0, width: 332, height: 380)
        let shape = Squircle(cornerRadius: 18, exponent: 5)
        let path = shape.path(in: rect)

        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThan(path.boundingRect.width, 300)
        XCTAssertGreaterThan(path.boundingRect.height, 350)
        XCTAssertLessThanOrEqual(path.boundingRect.width, 332)
        XCTAssertLessThanOrEqual(path.boundingRect.height, 380)
    }

    func testSquircleShapeWithMaxCornerAndMinPanel() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 380)
        let shape = Squircle(cornerRadius: 40, exponent: 5)
        let path = shape.path(in: rect)

        XCTAssertFalse(path.isEmpty)
        // With corner radius 40 on a 300pt wide panel, the corners are clamped to min(40, 150, 190) = 40
        let cornerInset = 40 * Squircle.cornerInsetFactor(exponent: 5)
        // Path should be within the rect bounds
        XCTAssertGreaterThanOrEqual(path.boundingRect.minX, -0.5)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -0.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxX, 300.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 380.5)

        // Content at horizontal inset should be inside the path
        let insets = PanelGeometry.contentInsets(cornerSize: 40, panelSize: CGSize(width: 300, height: 380))
        // Verify that at the corner depth, content is safe
        XCTAssertGreaterThanOrEqual(insets.leading, cornerInset + 4)
    }

    // MARK: - Expanded corner range (10...140)

    func testSquirclePathAtMax140WithMin300Width() {
        // Maximum radius 140 on the smallest 300pt panel. The radius clamps to
        // half the shorter dimension (190), so 140 stays unclamped and leaves a
        // 20pt straight section on each side (300 - 2*140 = 20).
        let rect = CGRect(x: 0, y: 0, width: 300, height: 380)
        let shape = Squircle(cornerRadius: 140, exponent: PanelGeometry.squircleExponent)
        let path = shape.path(in: rect)

        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minX, -0.5)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -0.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxX, 300.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 380.5)
    }

    func testSquirclePathAtMax140With380Width() {
        let rect = CGRect(x: 0, y: 0, width: 380, height: 380)
        let shape = Squircle(cornerRadius: 140, exponent: PanelGeometry.squircleExponent)
        let path = shape.path(in: rect)

        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minX, -0.5)
        XCTAssertGreaterThanOrEqual(path.boundingRect.minY, -0.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxX, 380.5)
        XCTAssertLessThanOrEqual(path.boundingRect.maxY, 380.5)
    }

    func testContentInsetsAtExpandedRadii() {
        let panelSize = CGSize(width: PanelContentSize.min, height: 380)
        for caseValue in PanelCornerSize.allCases {
            let insets = PanelGeometry.contentInsets(cornerSize: caseValue.rawValue, panelSize: panelSize)
            let cornerInset = caseValue.rawValue * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
            let expectedHorizontal = max(AtticStyle.horizontalPadding, cornerInset + 6)
            let expectedTop = max(8, cornerInset + 4)
            let expectedBottom = max(10, cornerInset + 6)

            XCTAssertEqual(insets.leading, expectedHorizontal, accuracy: 0.01, "at \(caseValue.rawValue)")
            XCTAssertEqual(insets.trailing, expectedHorizontal, accuracy: 0.01, "at \(caseValue.rawValue)")
            XCTAssertEqual(insets.top, expectedTop, accuracy: 0.01, "at \(caseValue.rawValue)")
            XCTAssertEqual(insets.bottom, expectedBottom, accuracy: 0.01, "at \(caseValue.rawValue)")
        }
    }

    func testContentInsetsMonotonicAcrossExpandedRadii() {
        let panelSize = CGSize(width: PanelContentSize.min, height: 380)
        let radii = PanelCornerSize.allCases.map(\.rawValue)
        var prevLeading: CGFloat = 0
        var prevTop: CGFloat = 0
        var prevBottom: CGFloat = 0
        for radius in radii {
            let insets = PanelGeometry.contentInsets(cornerSize: radius, panelSize: panelSize)
            XCTAssertGreaterThanOrEqual(insets.leading, prevLeading)
            XCTAssertGreaterThanOrEqual(insets.top, prevTop)
            XCTAssertGreaterThanOrEqual(insets.bottom, prevBottom)
            prevLeading = insets.leading
            prevTop = insets.top
            prevBottom = insets.bottom
        }
    }

    func testContentInsetsSymmetric() {
        let panelSize = CGSize(width: PanelContentSize.min, height: 380)
        for radius in PanelCornerSize.allCases.map(\.rawValue) {
            let insets = PanelGeometry.contentInsets(cornerSize: radius, panelSize: panelSize)
            XCTAssertEqual(insets.leading, insets.trailing, accuracy: 0.0001, "at \(radius)")
        }
    }

    func testUsableContentWidthReasonableAtMinPanelAndMax140() {
        // At the smallest 300pt panel with the maximum 140pt corner radius, the
        // usable content width must remain reasonable for task rows, the
        // header, and the tabs.
        let panelWidth: CGFloat = 300
        let insets = PanelGeometry.contentInsets(cornerSize: 140, panelSize: CGSize(width: panelWidth, height: 380))
        let usableWidth = panelWidth - insets.leading - insets.trailing
        XCTAssertGreaterThan(usableWidth, 240, "Usable content width too small at 140pt on 300pt panel")
        XCTAssertLessThanOrEqual(usableWidth, panelWidth)
    }

    func testUsableContentHeightReasonableAtMinHeightAndMax140() {
        // With the vertical content insets now applied, the content height
        // inside the squircle at the minimum 380pt panel and maximum 140pt
        // corner must remain usable for the header, picker, and scroll area.
        let panelHeight: CGFloat = 380
        let insets = PanelGeometry.contentInsets(cornerSize: 140, panelSize: CGSize(width: 300, height: panelHeight))
        let usableHeight = panelHeight - insets.top - insets.bottom
        XCTAssertGreaterThan(usableHeight, 300, "Usable content height too small at 140pt on 380pt panel")
    }

    func testContentSafeBoundariesAtMax140On300And380Width() {
        for panelWidth in [CGFloat(PanelContentSize.min), CGFloat(PanelContentSize.max)] {
            let insets = PanelGeometry.contentInsets(cornerSize: 140, panelSize: CGSize(width: panelWidth, height: 380))
            let cornerInset: CGFloat = 140 * Squircle.cornerInsetFactor(exponent: PanelGeometry.squircleExponent)
            XCTAssertGreaterThanOrEqual(insets.leading, cornerInset + 4, "leading at width \(panelWidth)")
            XCTAssertGreaterThanOrEqual(insets.top, cornerInset + 2, "top at width \(panelWidth)")
            XCTAssertGreaterThanOrEqual(insets.bottom, cornerInset + 4, "bottom at width \(panelWidth)")
        }
    }
}
