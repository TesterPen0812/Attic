import SwiftUI
import XCTest
@testable import Attic

final class PanelSquircleGeometryTests: XCTestCase {
    func testCompactControlMetricsKeepLargerPointerTargets() {
        XCTAssertEqual(AtticStyle.actionControlSize, 36)
        XCTAssertEqual(AtticStyle.modeControlSize, 34)
        XCTAssertEqual(AtticStyle.entryControlHeight, 38)
        XCTAssertEqual(AtticStyle.controlHitSize, 42)
        XCTAssertEqual(AtticStyle.composerControlHeight, 42)
        XCTAssertEqual(AtticStyle.composerActionSize, 34)
        XCTAssertEqual(AtticStyle.chromeMinimumInset, 22)
        XCTAssertEqual(AtticStyle.chromeCornerClearance, 8)
        XCTAssertEqual(AtticStyle.chromeWorkspaceSpacing, 24)
        XCTAssertEqual(AtticStyle.taskScrollTopPadding, 22)
        XCTAssertGreaterThan(AtticStyle.controlHitSize, AtticStyle.actionControlSize)
        XCTAssertGreaterThan(AtticStyle.controlHitSize, AtticStyle.modeControlSize)
    }

    func testModeDockCollapsesToSelectedSectionAndExpandsInCanonicalOrder() {
        for selectedSection in PanelSection.allCases {
            let collapsedSections = PanelSection.allCases.filter {
                PanelModeDockLayout.isVisible(
                    $0,
                    selectedSection: selectedSection,
                    isExpanded: false
                )
            }
            let expandedSections = PanelSection.allCases.filter {
                PanelModeDockLayout.isVisible(
                    $0,
                    selectedSection: selectedSection,
                    isExpanded: true
                )
            }

            XCTAssertEqual(collapsedSections, [selectedSection])
            XCTAssertEqual(expandedSections, PanelSection.allCases)
        }

        XCTAssertEqual(
            PanelModeDockLayout.width(isExpanded: false),
            AtticStyle.controlHitSize
        )
        XCTAssertEqual(
            PanelModeDockLayout.width(isExpanded: true),
            AtticStyle.controlHitSize * CGFloat(PanelSection.allCases.count)
        )
    }

    func testTaskWorkspaceMaintainsDeliberateGapBelowChromeAtEveryRadiusAndWidth() {
        for width in stride(from: PanelContentSize.min, through: PanelContentSize.max, by: 1) {
            let panelSize = CGSize(
                width: width,
                height: PanelGeometry.preferredWorkspaceHeight(contentWidth: width)
            )

            for radius in stride(from: PanelCornerSize.min, through: PanelCornerSize.max, by: 1) {
                let content = PanelGeometry.contentInsets(cornerSize: radius, panelSize: panelSize)
                let chrome = PanelGeometry.chromeInsets(cornerSize: radius, panelSize: panelSize)
                let workspace = PanelGeometry.taskWorkspaceTopPadding(
                    cornerSize: radius,
                    panelSize: panelSize
                )
                let firstSectionTop = content.top + workspace + AtticStyle.taskScrollTopPadding
                let chromeBottom = chrome.top + AtticStyle.controlHitSize

                XCTAssertEqual(
                    firstSectionTop - chromeBottom,
                    AtticStyle.chromeWorkspaceSpacing,
                    accuracy: 0.0001,
                    "Incorrect workspace gap at width \(width), radius \(radius)"
                )
            }
        }
    }

    func testChromeInsetsAreSymmetricAndRadiusAware() {
        let panelSize = CGSize(width: PanelContentSize.min, height: 480)
        var previousInset: CGFloat = 0

        for radius in stride(from: PanelCornerSize.min, through: PanelCornerSize.max, by: 1) {
            let insets = PanelGeometry.chromeInsets(cornerSize: radius, panelSize: panelSize)

            XCTAssertEqual(insets.top, insets.leading, accuracy: 0.0001)
            XCTAssertEqual(insets.top, insets.bottom, accuracy: 0.0001)
            XCTAssertEqual(insets.top, insets.trailing, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(insets.top, AtticStyle.chromeMinimumInset)
            XCTAssertGreaterThanOrEqual(insets.top, previousInset)
            previousInset = insets.top
        }

        XCTAssertGreaterThan(
            PanelGeometry.chromeInsets(cornerSize: PanelCornerSize.max, panelSize: panelSize).top,
            PanelGeometry.chromeInsets(cornerSize: PanelCornerSize.defaultValue, panelSize: panelSize).top
        )
    }

    func testPermanentChromeHitRegionsStayInsideEverySupportedSquircle() {
        let hitSize = AtticStyle.controlHitSize
        let modeDockWidth = hitSize * CGFloat(PanelSection.allCases.count)

        for width in stride(from: PanelContentSize.min, through: PanelContentSize.max, by: 1) {
            let height = PanelGeometry.preferredWorkspaceHeight(contentWidth: width)
            let panelSize = CGSize(width: width, height: height)
            let panelRect = CGRect(origin: .zero, size: panelSize)

            for radius in stride(from: PanelCornerSize.min, through: PanelCornerSize.max, by: 1) {
                let insets = PanelGeometry.chromeInsets(cornerSize: radius, panelSize: panelSize)
                let regions = [
                    CGRect(x: insets.leading, y: insets.top, width: hitSize, height: hitSize),
                    CGRect(
                        x: width - insets.trailing - modeDockWidth,
                        y: insets.top,
                        width: modeDockWidth,
                        height: hitSize
                    ),
                    CGRect(
                        x: insets.leading,
                        y: height - insets.bottom - hitSize,
                        width: hitSize,
                        height: hitSize
                    ),
                    CGRect(
                        x: width - insets.trailing - hitSize,
                        y: height - insets.bottom - hitSize,
                        width: hitSize,
                        height: hitSize
                    )
                ]

                for region in regions {
                    for point in region.corners {
                        XCTAssertTrue(
                            Squircle.contains(
                                point,
                                in: panelRect,
                                cornerRadius: radius,
                                exponent: PanelGeometry.squircleExponent
                            ),
                            "Chrome point \(point) escaped at width \(width), radius \(radius)"
                        )
                    }
                }
            }
        }
    }

    func testPermanentChromeStillFitsAtCompactWidthAndMaximumRadius() {
        let width = PanelContentSize.min
        let height = PanelGeometry.preferredWorkspaceHeight(contentWidth: width)
        let insets = PanelGeometry.chromeInsets(
            cornerSize: PanelCornerSize.max,
            panelSize: CGSize(width: width, height: height)
        )
        let hitSize = AtticStyle.controlHitSize
        let modeDockWidth = hitSize * CGFloat(PanelSection.allCases.count)
        let topGroupSpacing = width
            - insets.leading
            - hitSize
            - modeDockWidth
            - insets.trailing
        let quickEntryWidth = TaskEntryBarLayout.textFieldWidth(
            panelWidth: width,
            chromeInsets: insets
        )

        XCTAssertGreaterThanOrEqual(topGroupSpacing, 12)
        XCTAssertGreaterThanOrEqual(quickEntryWidth, 120)
    }

    func testUnifiedTaskEntryBarKeepsItsFieldAndActionsUsableAcrossSupportedGeometry() {
        for width in stride(from: PanelContentSize.min, through: PanelContentSize.max, by: 1) {
            let panelSize = CGSize(
                width: width,
                height: PanelGeometry.preferredWorkspaceHeight(contentWidth: width)
            )

            for radius in stride(from: PanelCornerSize.min, through: PanelCornerSize.max, by: 1) {
                let insets = PanelGeometry.chromeInsets(cornerSize: radius, panelSize: panelSize)
                let barWidth = TaskEntryBarLayout.width(
                    panelWidth: width,
                    chromeInsets: insets
                )
                let fieldWidth = TaskEntryBarLayout.textFieldWidth(
                    panelWidth: width,
                    chromeInsets: insets
                )

                XCTAssertGreaterThanOrEqual(
                    barWidth,
                    (2 * AtticStyle.controlHitSize) + 120 + 4
                )
                XCTAssertGreaterThanOrEqual(fieldWidth, 120)
            }
        }
    }

    @MainActor
    func testPanelInteractionPolicyMakesFirstEligibleClickKey() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true

        AtticPanelInteractionPolicy.configure(panel)

        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
    }

    @MainActor
    func testPanelResizePolicyDisablesWindowServerResizeAndUsesExplicitLimits() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 332, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        AtticPanelResizePolicy.configure(panel)

        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertEqual(panel.minSize, PanelGeometry.minimumPanelSize)
        XCTAssertEqual(panel.contentMinSize, PanelGeometry.minimumPanelSize)
        XCTAssertTrue(panel.preservesContentDuringLiveResize)
    }

    @MainActor
    func testPanelResizePolicyAppliesDisplayLimitsToFrameAndContent() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let maximumSize = CGSize(width: 1_000, height: 900)

        AtticPanelResizePolicy.configure(panel, maximumSize: maximumSize)

        XCTAssertEqual(panel.minSize, PanelGeometry.minimumPanelSize)
        XCTAssertEqual(panel.contentMinSize, PanelGeometry.minimumPanelSize)
        XCTAssertEqual(panel.maxSize, maximumSize)
        XCTAssertEqual(panel.contentMaxSize, maximumSize)
    }

    @MainActor
    func testPanelRoutesAccessibilitySizeChangesWithoutRestoringNativeResizeBorder() {
        let initialFrame = NSRect(x: 200, y: 150, width: 500, height: 600)
        let panel = AtticPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        AtticPanelResizePolicy.configure(panel)
        var requestedSize: CGSize?
        panel.onAccessibilityResizeRequest = { requestedSize = $0 }

        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.accessibilityIsAttributeSettable(.size))

        panel.setAccessibilityFrame(
            NSRect(x: 9_000, y: 9_000, width: 280, height: 320)
        )

        XCTAssertEqual(requestedSize, CGSize(width: 280, height: 320))
        XCTAssertEqual(panel.frame, initialFrame)
    }

    @MainActor
    func testPanelLeavesSameSizeAccessibilityMovementWithAppKit() {
        let initialFrame = NSRect(x: 200, y: 150, width: 500, height: 600)
        let panel = AtticPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var requestedSize: CGSize?
        panel.onAccessibilityResizeRequest = { requestedSize = $0 }
        let movedFrame = NSRect(origin: CGPoint(x: 260, y: 190), size: initialFrame.size)

        panel.setAccessibilityFrame(movedFrame)

        XCTAssertNil(requestedSize)
        XCTAssertEqual(panel.frame.origin, movedFrame.origin)
    }

    @MainActor
    func testPanelRoutesAccessibilityMovementForUsableAreaConfinement() {
        let initialFrame = NSRect(x: 200, y: 150, width: 500, height: 600)
        let panel = AtticPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        var requestedFrame: CGRect?
        panel.onAccessibilityMoveRequest = { requestedFrame = $0 }
        let movedFrame = NSRect(origin: CGPoint(x: 260, y: -900), size: initialFrame.size)

        panel.setAccessibilityFrame(movedFrame)

        XCTAssertEqual(requestedFrame, movedFrame)
        XCTAssertEqual(panel.frame, initialFrame)
    }

    func testResizeHitTestingFindsVisibleEdgesAndCornersButNotTransparentPixels() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 380)

        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: 19, y: 19),
                in: bounds,
                cornerRadius: 140
            ),
            [.left, .bottom]
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                in: bounds,
                cornerRadius: 140
            ),
            .left
        )
        XCTAssertNil(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: 0, y: 0),
                in: bounds,
                cornerRadius: 140
            )
        )
        XCTAssertNil(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                in: bounds,
                cornerRadius: 140
            )
        )

        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                in: bounds,
                cornerRadius: 140
            ),
            .right
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.midX, y: bounds.minY),
                in: bounds,
                cornerRadius: 140
            ),
            .bottom
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.midX, y: bounds.maxY),
                in: bounds,
                cornerRadius: 140
            ),
            .top
        )
    }

    func testTransparentCornerAcquisitionUsesOnlyAThinDiagonalHalo() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 380)
        let radius: CGFloat = 140

        XCTAssertEqual(
            AtticPanelResizePolicy.cornerAcquisitionEdges(
                at: CGPoint(x: 14, y: 14),
                in: bounds,
                cornerRadius: radius
            ),
            [.left, .bottom]
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: bounds.maxX - 14, y: bounds.maxY - 14),
                in: bounds,
                cornerRadius: radius
            ),
            [.right, .top]
        )

        // The far transparent pixel and non-corner transparent side remain
        // owned by the application behind the panel.
        XCTAssertNil(
            AtticPanelResizePolicy.cornerAcquisitionEdges(
                at: CGPoint(x: 0, y: 0),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertNil(
            AtticPanelResizePolicy.cornerAcquisitionEdges(
                at: CGPoint(x: 0, y: 50),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertNil(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: 0, y: 0),
                in: bounds,
                cornerRadius: radius
            )
        )
    }

    func testTransparentCornerAcquisitionMapsEveryDiagonalDirection() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 380)
        let radius: CGFloat = 140
        let cases: [(CGPoint, PanelResizeEdges)] = [
            (CGPoint(x: 14, y: 14), [.left, .bottom]),
            (CGPoint(x: bounds.maxX - 14, y: 14), [.right, .bottom]),
            (CGPoint(x: 14, y: bounds.maxY - 14), [.left, .top]),
            (CGPoint(x: bounds.maxX - 14, y: bounds.maxY - 14), [.right, .top])
        ]

        for (point, expected) in cases {
            XCTAssertEqual(
                AtticPanelResizePolicy.cornerAcquisitionEdges(
                    at: point,
                    in: bounds,
                    cornerRadius: radius
                ),
                expected
            )
        }
    }

    func testRawResizeGeometryClassifiesEveryGenerousVisibleTarget() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 380)
        let radius: CGFloat = 140
        let cases: [(CGPoint, PanelResizeEdges)] = [
            (CGPoint(x: 12, y: bounds.midY), .left),
            (CGPoint(x: bounds.maxX - 12, y: bounds.midY), .right),
            (CGPoint(x: bounds.midX, y: 12), .bottom),
            (CGPoint(x: bounds.midX, y: bounds.maxY - 12), .top),
            (CGPoint(x: 19, y: 19), [.left, .bottom]),
            (CGPoint(x: bounds.maxX - 19, y: 19), [.right, .bottom]),
            (CGPoint(x: 19, y: bounds.maxY - 19), [.left, .top]),
            (CGPoint(x: bounds.maxX - 19, y: bounds.maxY - 19), [.right, .top])
        ]

        for (point, expectedEdges) in cases {
            XCTAssertEqual(
                AtticPanelResizePolicy.resizeEdges(
                    at: point,
                    in: bounds,
                    cornerRadius: radius
                ),
                expectedEdges,
                "Unexpected resize ownership at \(point)"
            )
        }
    }

    func testDockCornerLocksBothScreenFacingResizeEdges() {
        let allDirections: [PanelResizeEdges] = [
            .left, .right, .bottom, .top,
            [.left, .bottom], [.right, .bottom],
            [.left, .top], [.right, .top]
        ]
        let expected: [ScreenCorner: [PanelResizeEdges]] = [
            .topLeft: [.right, .bottom, [.right, .bottom]],
            .topRight: [.left, .bottom, [.left, .bottom]],
            .bottomLeft: [.right, .top, [.right, .top]],
            .bottomRight: [.left, .top, [.left, .top]]
        ]

        for corner in ScreenCorner.allCases {
            for direction in allDirections {
                let actual = AtticPanelResizePolicy.allowedResizeEdges(
                    direction,
                    dockedAt: corner
                )
                if expected[corner, default: []].contains(direction) {
                    XCTAssertEqual(actual, direction, "\(corner) should allow \(direction)")
                } else {
                    XCTAssertNil(actual, "\(corner) should lock \(direction)")
                }
            }
        }
    }

    func testDockAwareHitTestingExposesOnlyThreeInwardResizeHandlesPerCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 560)
        let radius: CGFloat = 80
        let handles: [(CGPoint, PanelResizeEdges)] = [
            (CGPoint(x: 12, y: bounds.midY), .left),
            (CGPoint(x: bounds.maxX - 12, y: bounds.midY), .right),
            (CGPoint(x: bounds.midX, y: 12), .bottom),
            (CGPoint(x: bounds.midX, y: bounds.maxY - 12), .top),
            (CGPoint(x: 19, y: 19), [.left, .bottom]),
            (CGPoint(x: bounds.maxX - 19, y: 19), [.right, .bottom]),
            (CGPoint(x: 19, y: bounds.maxY - 19), [.left, .top]),
            (CGPoint(x: bounds.maxX - 19, y: bounds.maxY - 19), [.right, .top])
        ]
        let expected: [ScreenCorner: [PanelResizeEdges]] = [
            .topLeft: [.right, .bottom, [.right, .bottom]],
            .topRight: [.left, .bottom, [.left, .bottom]],
            .bottomLeft: [.right, .top, [.right, .top]],
            .bottomRight: [.left, .top, [.left, .top]]
        ]

        for corner in ScreenCorner.allCases {
            for (point, direction) in handles {
                let actual = AtticPanelResizePolicy.resizeEdges(
                    at: point,
                    in: bounds,
                    cornerRadius: radius,
                    dockedAt: corner
                )
                if expected[corner, default: []].contains(direction) {
                    XCTAssertEqual(actual, direction, "\(corner) should own \(direction)")
                } else {
                    XCTAssertNil(actual, "\(corner) should not own \(direction)")
                }
            }
        }
    }

    func testDockAwareTransparentHaloExistsOnlyAtAllowedInwardCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 380)
        let radius: CGFloat = 140
        let halos: [(CGPoint, PanelResizeEdges)] = [
            (CGPoint(x: 14, y: 14), [.left, .bottom]),
            (CGPoint(x: bounds.maxX - 14, y: 14), [.right, .bottom]),
            (CGPoint(x: 14, y: bounds.maxY - 14), [.left, .top]),
            (CGPoint(x: bounds.maxX - 14, y: bounds.maxY - 14), [.right, .top])
        ]
        let allowedCorner: [ScreenCorner: PanelResizeEdges] = [
            .topLeft: [.right, .bottom],
            .topRight: [.left, .bottom],
            .bottomLeft: [.right, .top],
            .bottomRight: [.left, .top]
        ]

        for corner in ScreenCorner.allCases {
            for (point, direction) in halos {
                let actual = AtticPanelResizePolicy.resizeEdges(
                    at: point,
                    in: bounds,
                    cornerRadius: radius,
                    dockedAt: corner
                )
                if allowedCorner[corner] == direction {
                    XCTAssertEqual(actual, direction)
                } else {
                    XCTAssertNil(actual)
                }
            }
        }
    }

    func testDockAwareResizePreservesTheSelectedCornerAnchor() {
        let frame = CGRect(x: 500, y: 200, width: 400, height: 520)
        let cases: [(ScreenCorner, PanelResizeEdges, CGPoint)] = [
            (.topLeft, [.right, .bottom], CGPoint(x: 80, y: -60)),
            (.topRight, [.left, .bottom], CGPoint(x: -80, y: -60)),
            (.bottomLeft, [.right, .top], CGPoint(x: 80, y: 60)),
            (.bottomRight, [.left, .top], CGPoint(x: -80, y: 60))
        ]

        for (corner, edges, delta) in cases {
            let resized = AtticPanelResizePolicy.resizedFrame(
                from: frame,
                mouseDelta: delta,
                edges: edges,
                minimumSize: PanelGeometry.minimumPanelSize,
                maximumSize: CGSize(width: 1_200, height: 1_000)
            )
            switch corner {
            case .topLeft:
                XCTAssertEqual(resized.minX, frame.minX)
                XCTAssertEqual(resized.maxY, frame.maxY)
            case .topRight:
                XCTAssertEqual(resized.maxX, frame.maxX)
                XCTAssertEqual(resized.maxY, frame.maxY)
            case .bottomLeft:
                XCTAssertEqual(resized.minX, frame.minX)
                XCTAssertEqual(resized.minY, frame.minY)
            case .bottomRight:
                XCTAssertEqual(resized.maxX, frame.maxX)
                XCTAssertEqual(resized.minY, frame.minY)
            }
        }
    }

    func testLockedTopResizeBandDoesNotRemoveTheIntentionalDragLane() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 620)
        let radius: CGFloat = 80
        let dragRegion = AtticPanelDragPolicy.topDragRegion(
            in: bounds,
            cornerRadius: radius
        )
        let topEdge = CGPoint(x: dragRegion.midX, y: bounds.maxY)
        let dragPoint = CGPoint(x: dragRegion.midX, y: dragRegion.midY)

        for corner in [ScreenCorner.topLeft, .topRight] {
            XCTAssertNil(
                AtticPanelResizePolicy.resizeEdges(
                    at: topEdge,
                    in: bounds,
                    cornerRadius: radius,
                    dockedAt: corner
                )
            )
            XCTAssertTrue(
                AtticPanelDragPolicy.isTopDragPoint(
                    dragPoint,
                    in: bounds,
                    cornerRadius: radius
                )
            )
        }
    }

    func testEveryResizeDirectionPreservesItsOppositeEdges() {
        let frame = CGRect(x: 500, y: 200, width: 400, height: 520)
        let cases: [(PanelResizeEdges, CGPoint)] = [
            (.left, CGPoint(x: -80, y: 60)),
            (.right, CGPoint(x: 80, y: 60)),
            (.bottom, CGPoint(x: 80, y: -60)),
            (.top, CGPoint(x: 80, y: 60)),
            ([.left, .bottom], CGPoint(x: -80, y: -60)),
            ([.right, .bottom], CGPoint(x: 80, y: -60)),
            ([.left, .top], CGPoint(x: -80, y: 60)),
            ([.right, .top], CGPoint(x: 80, y: 60))
        ]

        for (edges, delta) in cases {
            let resized = AtticPanelResizePolicy.resizedFrame(
                from: frame,
                mouseDelta: delta,
                edges: edges,
                minimumSize: PanelGeometry.minimumPanelSize,
                maximumSize: CGSize(width: 1_200, height: 1_000)
            )
            if edges.contains(.left) { XCTAssertEqual(resized.maxX, frame.maxX) }
            if edges.contains(.right) { XCTAssertEqual(resized.minX, frame.minX) }
            if edges.contains(.bottom) { XCTAssertEqual(resized.maxY, frame.maxY) }
            if edges.contains(.top) { XCTAssertEqual(resized.minY, frame.minY) }
            if !edges.contains(.left), !edges.contains(.right) {
                XCTAssertEqual(resized.minX, frame.minX)
                XCTAssertEqual(resized.width, frame.width)
            }
            if !edges.contains(.bottom), !edges.contains(.top) {
                XCTAssertEqual(resized.minY, frame.minY)
                XCTAssertEqual(resized.height, frame.height)
            }
        }
    }

    func testCustomResizeCannotCrossMinimumAtAnyEdgeOrCorner() {
        let frame = CGRect(x: 500, y: 200, width: 581, height: 700)
        let cases: [(PanelResizeEdges, CGPoint)] = [
            (.left, CGPoint(x: 900, y: 0)),
            (.right, CGPoint(x: -900, y: 0)),
            (.bottom, CGPoint(x: 0, y: 900)),
            (.top, CGPoint(x: 0, y: -900)),
            ([.left, .bottom], CGPoint(x: 900, y: 900)),
            ([.right, .bottom], CGPoint(x: -900, y: 900)),
            ([.left, .top], CGPoint(x: 900, y: -900)),
            ([.right, .top], CGPoint(x: -900, y: -900))
        ]

        for (edges, delta) in cases {
            let resized = AtticPanelResizePolicy.resizedFrame(
                from: frame,
                mouseDelta: delta,
                edges: edges,
                minimumSize: PanelGeometry.minimumPanelSize,
                maximumSize: CGSize(width: 1_200, height: 1_000)
            )

            if edges.contains(.left) || edges.contains(.right) {
                XCTAssertEqual(resized.width, PanelGeometry.minimumPanelSize.width)
            } else {
                XCTAssertEqual(resized.width, frame.width)
            }
            if edges.contains(.bottom) || edges.contains(.top) {
                XCTAssertEqual(resized.height, PanelGeometry.minimumPanelSize.height)
            } else {
                XCTAssertEqual(resized.height, frame.height)
            }
            if edges.contains(.left) { XCTAssertEqual(resized.maxX, frame.maxX) }
            if edges.contains(.right) { XCTAssertEqual(resized.minX, frame.minX) }
            if edges.contains(.bottom) { XCTAssertEqual(resized.maxY, frame.maxY) }
            if edges.contains(.top) { XCTAssertEqual(resized.minY, frame.minY) }
        }
    }

    func testTopDragRegionIsSeparateFromResizeAndControlAreas() {
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 560)
        let radius: CGFloat = 80
        let dragRegion = AtticPanelDragPolicy.topDragRegion(
            in: bounds,
            cornerRadius: radius
        )

        XCTAssertGreaterThan(dragRegion.width, 0)
        XCTAssertEqual(
            dragRegion.maxY,
            bounds.maxY - AtticPanelResizePolicy.edgeGripThickness
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: CGPoint(x: dragRegion.midX, y: bounds.maxY),
                in: bounds,
                cornerRadius: radius
            ),
            .top
        )
        XCTAssertFalse(
            AtticPanelDragPolicy.isTopDragPoint(
                CGPoint(x: dragRegion.midX, y: bounds.maxY),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertTrue(
            AtticPanelDragPolicy.isTopDragPoint(
                CGPoint(x: dragRegion.midX, y: dragRegion.maxY.nextDown),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertTrue(
            AtticPanelDragPolicy.isTopDragPoint(
                CGPoint(x: dragRegion.midX, y: dragRegion.midY),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertFalse(
            AtticPanelDragPolicy.isTopDragPoint(
                CGPoint(x: bounds.minX + 12, y: bounds.maxY - 60),
                in: bounds,
                cornerRadius: radius
            )
        )
        XCTAssertFalse(
            AtticPanelDragPolicy.isTopDragPoint(
                CGPoint(x: bounds.midX, y: bounds.midY),
                in: bounds,
                cornerRadius: radius
            )
        )
    }

    func testTopDragRegionRemainsUsableAtMinimumMediumAndLargeSizes() {
        for size in [
            PanelGeometry.minimumPanelSize,
            CGSize(width: 480, height: 620),
            CGSize(width: 760, height: 820)
        ] {
            for radius in [PanelCornerSize.min, PanelCornerSize.defaultValue, PanelCornerSize.max] {
                let region = AtticPanelDragPolicy.topDragRegion(
                    in: CGRect(origin: .zero, size: size),
                    cornerRadius: radius
                )
                XCTAssertGreaterThanOrEqual(
                    region.width,
                    40,
                    "Top drag lane too narrow at \(size) with radius \(radius)"
                )
            }
        }
    }

    func testCollapsedModeDockExposesBroadTopDragLaneWithoutClaimingExpandedControls() {
        let bounds = CGRect(origin: .zero, size: PanelGeometry.minimumPanelSize)
        let radius = PanelCornerSize.defaultValue
        let collapsedWidth = PanelModeDockLayout.width(isExpanded: false)
        let expandedWidth = PanelModeDockLayout.width(isExpanded: true)
        let collapsedRegion = AtticPanelDragPolicy.topDragRegion(
            in: bounds,
            cornerRadius: radius,
            modeDockWidth: collapsedWidth,
            dockedAt: .topRight
        )
        let expandedRegion = AtticPanelDragPolicy.topDragRegion(
            in: bounds,
            cornerRadius: radius,
            modeDockWidth: expandedWidth,
            dockedAt: .topRight
        )

        XCTAssertGreaterThan(collapsedRegion.width, expandedRegion.width + 100)
        let newlyAvailablePoint = CGPoint(
            x: (expandedRegion.maxX + collapsedRegion.maxX) / 2,
            y: collapsedRegion.midY
        )
        XCTAssertTrue(
            AtticPanelDragPolicy.isTopDragPoint(
                newlyAvailablePoint,
                in: bounds,
                cornerRadius: radius,
                modeDockWidth: collapsedWidth,
                dockedAt: .topRight
            )
        )
        XCTAssertFalse(
            AtticPanelDragPolicy.isTopDragPoint(
                newlyAvailablePoint,
                in: bounds,
                cornerRadius: radius,
                modeDockWidth: expandedWidth,
                dockedAt: .topRight
            )
        )
    }

    func testAttachedTopEdgeBecomesDragSurfaceButInwardTopResizeRemainsOwned() {
        let bounds = CGRect(x: 0, y: 0, width: 480, height: 620)
        let radius: CGFloat = 80
        let point = CGPoint(x: bounds.midX, y: bounds.maxY)

        XCTAssertTrue(
            AtticPanelDragPolicy.isTopDragPoint(
                point,
                in: bounds,
                cornerRadius: radius,
                modeDockWidth: PanelModeDockLayout.width(isExpanded: false),
                dockedAt: .topRight
            )
        )
        XCTAssertFalse(
            AtticPanelDragPolicy.isTopDragPoint(
                point,
                in: bounds,
                cornerRadius: radius,
                modeDockWidth: PanelModeDockLayout.width(isExpanded: false),
                dockedAt: .bottomRight
            )
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: point,
                in: bounds,
                cornerRadius: radius,
                dockedAt: .bottomRight
            ),
            .top
        )
    }

    @MainActor
    func testFlippedHostingCoordinatesMapVisualTopBottomCornersAndDragLane() {
        let hostingView = NSHostingView(rootView: EmptyView())
        hostingView.frame = CGRect(x: 0, y: 0, width: 300, height: 380)
        let bounds = hostingView.bounds
        let radius: CGFloat = 140

        XCTAssertTrue(hostingView.isFlipped)

        func policyPoint(_ localPoint: CGPoint) -> CGPoint {
            AtticPanelCoordinateSpace.policyPoint(
                fromHostingPoint: localPoint,
                in: bounds,
                isFlipped: hostingView.isFlipped
            )
        }

        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: policyPoint(CGPoint(x: bounds.midX, y: 12)),
                in: bounds,
                cornerRadius: radius
            ),
            .top
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: policyPoint(CGPoint(x: bounds.midX, y: bounds.maxY - 12)),
                in: bounds,
                cornerRadius: radius
            ),
            .bottom
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: policyPoint(CGPoint(x: 19, y: 19)),
                in: bounds,
                cornerRadius: radius
            ),
            [.left, .top]
        )
        XCTAssertEqual(
            AtticPanelResizePolicy.resizeEdges(
                at: policyPoint(CGPoint(x: bounds.maxX - 19, y: bounds.maxY - 19)),
                in: bounds,
                cornerRadius: radius
            ),
            [.right, .bottom]
        )

        let policyTopCursorRect = CGRect(
            x: 28,
            y: bounds.maxY - AtticPanelResizePolicy.edgeGripThickness,
            width: bounds.width - 56,
            height: AtticPanelResizePolicy.edgeGripThickness
        )
        let policyBottomCursorRect = CGRect(
            x: 28,
            y: bounds.minY,
            width: bounds.width - 56,
            height: AtticPanelResizePolicy.edgeGripThickness
        )
        let localTopCursorRect = AtticPanelCoordinateSpace.hostingRect(
            fromPolicyRect: policyTopCursorRect,
            in: bounds,
            isFlipped: hostingView.isFlipped
        )
        let localBottomCursorRect = AtticPanelCoordinateSpace.hostingRect(
            fromPolicyRect: policyBottomCursorRect,
            in: bounds,
            isFlipped: hostingView.isFlipped
        )
        XCTAssertEqual(localTopCursorRect.minY, bounds.minY)
        XCTAssertEqual(localBottomCursorRect.maxY, bounds.maxY)

        let localDragRegion = AtticPanelCoordinateSpace.hostingRect(
            fromPolicyRect: AtticPanelDragPolicy.topDragRegion(
                in: bounds,
                cornerRadius: radius
            ),
            in: bounds,
            isFlipped: hostingView.isFlipped
        )
        XCTAssertLessThan(localDragRegion.minY, 80)
        XCTAssertFalse(
            localDragRegion.intersects(
                CGRect(x: 0, y: bounds.maxY - 80, width: bounds.width, height: 80)
            ),
            "The visual top drag lane must not overlap the bottom composer"
        )
        XCTAssertTrue(
            AtticPanelDragPolicy.isTopDragPoint(
                policyPoint(CGPoint(x: localDragRegion.midX, y: localDragRegion.midY)),
                in: bounds,
                cornerRadius: radius
            )
        )
    }

    func testResizeFramePreservesOppositeEdgesAndClampsDimensionsIndependently() {
        let frame = CGRect(x: 1_000, y: 200, width: 332, height: 482)

        let enlarged = AtticPanelResizePolicy.resizedFrame(
            from: frame,
            mouseDelta: CGPoint(x: -108, y: -118),
            edges: [.left, .bottom],
            minimumSize: PanelGeometry.minimumPanelSize,
            maximumSize: CGSize(width: 1_000, height: 900)
        )
        XCTAssertEqual(enlarged, CGRect(x: 892, y: 82, width: 440, height: 600))
        XCTAssertEqual(enlarged.maxX, frame.maxX)
        XCTAssertEqual(enlarged.maxY, frame.maxY)

        let clamped = AtticPanelResizePolicy.resizedFrame(
            from: frame,
            mouseDelta: CGPoint(x: 200, y: -40),
            edges: [.left, .bottom],
            minimumSize: PanelGeometry.minimumPanelSize,
            maximumSize: CGSize(width: 1_000, height: 900)
        )
        XCTAssertEqual(clamped.width, PanelGeometry.minimumPanelSize.width)
        XCTAssertEqual(clamped.height, 522)
        XCTAssertEqual(clamped.maxX, frame.maxX)
        XCTAssertEqual(clamped.maxY, frame.maxY)
    }

    func testCustomResizeRecoversAFrameThatWasPreviouslyBelowTheDock() {
        let visibleFrame = CGRect(x: 0, y: 70, width: 1_440, height: 800)
        let recovered = AtticPanelResizePolicy.resizedFrame(
            from: CGRect(x: 900, y: -100, width: 400, height: 600),
            mouseDelta: CGPoint(x: -40, y: 0),
            edges: .left,
            minimumSize: PanelGeometry.minimumPanelSize,
            maximumSize: PanelGeometry.resizeMaximumSize(in: visibleFrame),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(recovered.minY, visibleFrame.minY + PanelGeometry.screenInset)
        XCTAssertGreaterThanOrEqual(recovered.minX, visibleFrame.minX + PanelGeometry.screenInset)
        XCTAssertLessThanOrEqual(recovered.maxX, visibleFrame.maxX - PanelGeometry.screenInset)
        XCTAssertLessThanOrEqual(recovered.maxY, visibleFrame.maxY - PanelGeometry.screenInset)
    }

    func testResizeFrameStopsDraggedEdgesAtTheVisibleScreenInset() {
        let visibleFrame = CGRect(x: 0, y: 25, width: 1_200, height: 800)
        let frame = CGRect(x: 700, y: 225, width: 332, height: 480)

        let rightAndTop = AtticPanelResizePolicy.resizedFrame(
            from: frame,
            mouseDelta: CGPoint(x: 900, y: 900),
            edges: [.right, .top],
            minimumSize: PanelGeometry.minimumPanelSize,
            maximumSize: PanelGeometry.resizeMaximumSize(in: visibleFrame),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(rightAndTop.maxX, visibleFrame.maxX - PanelGeometry.screenInset)
        XCTAssertEqual(rightAndTop.maxY, visibleFrame.maxY - PanelGeometry.screenInset)
        XCTAssertEqual(rightAndTop.minX, frame.minX)
        XCTAssertEqual(rightAndTop.minY, frame.minY)

        let leftAndBottom = AtticPanelResizePolicy.resizedFrame(
            from: frame,
            mouseDelta: CGPoint(x: -900, y: -900),
            edges: [.left, .bottom],
            minimumSize: PanelGeometry.minimumPanelSize,
            maximumSize: PanelGeometry.resizeMaximumSize(in: visibleFrame),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(leftAndBottom.minX, visibleFrame.minX + PanelGeometry.screenInset)
        XCTAssertEqual(leftAndBottom.minY, visibleFrame.minY + PanelGeometry.screenInset)
        XCTAssertEqual(leftAndBottom.maxX, frame.maxX)
        XCTAssertEqual(leftAndBottom.maxY, frame.maxY)
    }

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

    func testAnalyticHitRegionExcludesTransparentCorners() {
        let rect = CGRect(x: 0, y: 0, width: 332, height: 481.4)

        XCTAssertFalse(
            Squircle.contains(
                CGPoint(x: 0, y: 0),
                in: rect,
                cornerRadius: 80,
                exponent: 5
            )
        )
        XCTAssertFalse(
            Squircle.contains(
                CGPoint(x: 331.9, y: 481.3),
                in: rect,
                cornerRadius: 80,
                exponent: 5
            )
        )
    }

    func testAnalyticHitRegionIncludesVisibleSurfaceAndEdges() {
        let rect = CGRect(x: 0, y: 0, width: 332, height: 481.4)

        XCTAssertTrue(
            Squircle.contains(
                CGPoint(x: rect.midX, y: rect.midY),
                in: rect,
                cornerRadius: 80,
                exponent: 5
            )
        )
        XCTAssertTrue(
            Squircle.contains(
                CGPoint(x: rect.midX, y: rect.minY + 0.01),
                in: rect,
                cornerRadius: 80,
                exponent: 5
            )
        )
        XCTAssertTrue(
            Squircle.contains(
                CGPoint(x: rect.minX + 0.01, y: rect.midY),
                in: rect,
                cornerRadius: 80,
                exponent: 5
            )
        )
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
private extension CGRect {
    var corners: [CGPoint] {
        [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY)
        ]
    }
}
