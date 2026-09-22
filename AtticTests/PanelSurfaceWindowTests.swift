import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The subtask checklist windows carry the main panel's frame: the same
/// transparent shadow margin, the same visible-frame conversions, an
/// accessibility frame equal to the painted surface, and click-through
/// everywhere off the squircle. Placement and restore are expressed in
/// visible frames, so nothing the user saw or saved moves.
@MainActor
final class PanelSurfaceWindowTests: XCTestCase {
    private let visibleSize = CGSize(width: SubtaskPanelLayout.panelWidth, height: 220)

    private func makeWindow(margin: CGFloat? = nil) -> (PanelSurfaceWindow, NSView) {
        let content = NSView(frame: CGRect(origin: .zero, size: visibleSize))
        let window = margin.map {
            PanelSurfaceWindow(contentView: content, initialSize: visibleSize, surfaceMargin: $0)
        } ?? PanelSurfaceWindow(contentView: content, initialSize: visibleSize)
        addTeardownBlock { window.contentView = nil }
        return (window, content)
    }

    func testTheMarginIsTheMainPanelsAndCoversTheShadow() {
        let (window, _) = makeWindow()
        XCTAssertEqual(window.surfaceMargin, AtticStyle.panelElevationMargin)
        XCTAssertGreaterThanOrEqual(window.surfaceMargin, AtticPanelSurfaceElevation.dark.extent)
        XCTAssertGreaterThanOrEqual(window.surfaceMargin, AtticPanelSurfaceElevation.light.extent)
        XCTAssertFalse(window.hasShadow, "the AppKit window never draws a rectangular shadow")
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(SubtaskPanelContent.showsSurfaceElevation)
        XCTAssertTrue(AtticPanelView.showsSurfaceElevation)
    }

    func testNativeFrameIsTheVisibleFramePlusTheMargin() {
        let (window, content) = makeWindow()
        let margin = window.surfaceMargin
        XCTAssertEqual(window.frame.size, CGSize(width: visibleSize.width + margin * 2,
                                                 height: visibleSize.height + margin * 2))
        XCTAssertEqual(window.visibleContentFrame.size, visibleSize)
        XCTAssertEqual(content.frame, CGRect(x: margin, y: margin,
                                             width: visibleSize.width, height: visibleSize.height))
        let visible = CGRect(x: 400, y: 300, width: visibleSize.width, height: 260)
        window.setVisibleContentFrame(visible, display: false)
        XCTAssertEqual(window.visibleContentFrame, visible)
        XCTAssertEqual(window.frame, visible.insetBy(dx: -margin, dy: -margin))
        XCTAssertEqual(window.nativeFrame(forVisibleFrame: visible), window.frame)
        // The host follows the visible frame exactly, so its fitting size
        // is still the visible size the controller reasons with.
        XCTAssertEqual(content.frame.size, visible.size)
        XCTAssertEqual(window.surfaceContentView, content)
        // A zero margin degrades to the old tight-bounds window.
        let (tight, _) = makeWindow(margin: 0)
        XCTAssertEqual(tight.frame.size, visibleSize)
        XCTAssertEqual(tight.visibleContentFrame, tight.frame)
    }

    func testAccessibilityFrameIsTheVisibleSurface() {
        let (window, _) = makeWindow()
        let visible = CGRect(x: 120, y: 80, width: visibleSize.width, height: 200)
        window.setVisibleContentFrame(visible, display: false)
        XCTAssertEqual(window.accessibilityFrame(), visible)
        XCTAssertNotEqual(window.accessibilityFrame(), window.frame)
    }

    func testASavedFrameFromBeforeTheMarginRestoresUnchanged() {
        // Pinned frames were, and are, the visible frame. A frame saved by
        // the tight-bounds window restores to the same painted rectangle;
        // only the native window around it is larger.
        let saved = CGRect(x: 640, y: 420, width: SubtaskPanelLayout.panelWidth, height: 232)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let restored = SubtaskPanelLayout.restoredPinnedFrame(
            saved: saved, size: saved.size, screenVisibleFrames: [screen]
        )
        XCTAssertEqual(restored, saved)
        let (window, _) = makeWindow()
        window.setVisibleContentFrame(restored, display: false)
        XCTAssertEqual(window.visibleContentFrame, saved)
        XCTAssertEqual(window.frame, saved.insetBy(dx: -window.surfaceMargin, dy: -window.surfaceMargin))
        // Round trip through the persisted string form.
        let stored = NSStringFromRect(window.visibleContentFrame)
        XCTAssertEqual(NSRectFromString(stored), saved)
        XCTAssertTrue(AppSettings.isRestorableFrame(NSRectFromString(stored)))
    }

    func testTransientPlacementAndCoverageAreUnchangedByTheMargin() {
        // Placement takes visible frames in and gives visible frames out; the
        // side gap between the panel and the checklist is still 10 pt of
        // painted-edge-to-painted-edge distance.
        let panel = CGRect(x: 1000, y: 200, width: 320, height: 464)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = SubtaskPanelLayout.transientFrame(
            size: visibleSize, anchorScreenRect: CGRect(x: 1010, y: 500, width: 300, height: 42),
            panelScreenFrame: panel, screenVisibleFrame: screen
        )
        XCTAssertEqual(frame.maxX, panel.minX - SubtaskPanelLayout.sideGap, accuracy: 0.001)
        let (window, _) = makeWindow()
        window.setVisibleContentFrame(frame, display: false)
        XCTAssertEqual(window.visibleContentFrame.maxX, panel.minX - SubtaskPanelLayout.sideGap, accuracy: 0.001)
        // The native frame overlaps the panel by the margin; that overlap
        // is click-through, never surface.
        XCTAssertGreaterThan(window.frame.maxX, panel.minX)
        let inOverlap = CGPoint(x: panel.minX + 2, y: frame.midY)
        XCTAssertFalse(window.surfaceContains(screenPoint: inOverlap, cornerSize: 80))
        XCTAssertTrue(PanelSurfacePointerPolicy.shouldIgnoreMouseEvents(
            at: inOverlap, nativeFrame: window.frame, visibleFrame: window.visibleContentFrame, cornerSize: 80))
        XCTAssertEqual(SubtaskPanelLayout.pointerCoverage(
            CGPoint(x: frame.midX, y: frame.midY), surfaceFrame: window.visibleContentFrame,
            cornerSize: 80, mainPanelFrame: panel, anchorRect: nil), .surface)
        XCTAssertEqual(SubtaskPanelLayout.pointerCoverage(
            inOverlap, surfaceFrame: window.visibleContentFrame,
            cornerSize: 80, mainPanelFrame: panel, anchorRect: nil), .transit)
    }

    func testPointerPolicyIgnoresTheMarginAndCornersAndOwnsTheSquircle() {
        let visible = CGRect(x: 100, y: 100, width: 272, height: 220)
        let margin = AtticStyle.panelElevationMargin
        let native = visible.insetBy(dx: -margin, dy: -margin)
        let corner: CGFloat = 80
        func ignores(_ point: CGPoint) -> Bool {
            PanelSurfacePointerPolicy.shouldIgnoreMouseEvents(
                at: point, nativeFrame: native, visibleFrame: visible, cornerSize: corner)
        }
        // Inside the painted surface: the window owns the pointer.
        XCTAssertFalse(ignores(CGPoint(x: visible.midX, y: visible.midY)))
        XCTAssertFalse(ignores(CGPoint(x: visible.minX + 1, y: visible.midY)))
        XCTAssertFalse(ignores(CGPoint(x: visible.midX, y: visible.maxY - 1)))
        // The margin, all the way round, on every side and diagonal.
        for distance in stride(from: CGFloat(1), through: margin - 1, by: 4) {
            XCTAssertTrue(ignores(CGPoint(x: visible.minX - distance, y: visible.midY)), "\(distance)")
            XCTAssertTrue(ignores(CGPoint(x: visible.maxX + distance, y: visible.midY)), "\(distance)")
            XCTAssertTrue(ignores(CGPoint(x: visible.midX, y: visible.minY - distance)), "\(distance)")
            XCTAssertTrue(ignores(CGPoint(x: visible.midX, y: visible.maxY + distance)), "\(distance)")
            XCTAssertTrue(ignores(CGPoint(x: visible.minX - distance, y: visible.minY - distance)), "\(distance)")
        }
        // The transparent corner wedge inside the visible rectangle.
        XCTAssertTrue(ignores(CGPoint(x: visible.minX + 2, y: visible.minY + 2)))
        XCTAssertTrue(ignores(CGPoint(x: visible.maxX - 2, y: visible.maxY - 2)))
        // Beyond the native frame the window is not under the pointer at
        // all; nothing to ignore.
        XCTAssertFalse(ignores(CGPoint(x: native.minX - 1, y: visible.midY)))
        XCTAssertFalse(ignores(CGPoint(x: visible.midX, y: native.maxY + 1)))
    }

    func testTheContainerHandsHitsToTheHostAndNothingToTheMargin() {
        let child = NSView()
        let host = PanelSurfaceHostingView(rootView: HitOwningContent(view: child).frame(width: 272, height: 220))
        let window = PanelSurfaceWindow(contentView: host, initialSize: CGSize(width: 272, height: 220))
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        guard let container = window.contentView else { return XCTFail("no container") }
        let margin = window.surfaceMargin
        // Container coordinates: the host sits at (margin, margin).
        XCTAssertTrue(container.hitTest(CGPoint(x: margin + 220, y: margin + 30)) === child)
        XCTAssertNil(container.hitTest(CGPoint(x: margin / 2, y: margin + 100)), "left margin")
        XCTAssertNil(container.hitTest(CGPoint(x: margin + 100, y: margin / 2)), "bottom margin")
        XCTAssertNil(container.hitTest(CGPoint(x: margin + 272 + margin / 2, y: margin + 100)), "right margin")
        XCTAssertNil(container.hitTest(CGPoint(x: margin + 1, y: margin + 1)), "corner wedge")
    }

    func testControllerMonitorsThePointerOnlyWhileASurfaceIsPresented() throws {
        let suite = "PanelSurfaceWindowTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = TaskStore(container: container)
        let uiState = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        let controller = SubtaskPanelController(store: store, uiState: uiState, settings: settings)
        controller.mainPanelVisibleForTesting = true
        controller.anchorsAreScreenCoordinatesForTesting = true
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        _ = try XCTUnwrap(store.create(title: "Child", parentID: parent.id))
        controller.updateTaskRowFrames([parent.id: CGRect(x: 300, y: 400, width: 300, height: 42)])
        controller.updateTaskListViewport(CGRect(x: 0, y: 0, width: 800, height: 800))
        XCTAssertFalse(controller.isMonitoringPointerPassthrough)
        // With presentation suppressed (the unit-test host cannot order a
        // real panel on screen) the monitors stay off too.
        controller.presentationEnabled = false
        controller.openFamilyPanel(for: parent.id, focusEntry: false)
        XCTAssertFalse(controller.isMonitoringPointerPassthrough)
        controller.dismissTransient()
        controller.presentationEnabled = true
        controller.pinFamily(parent.id)
        XCTAssertTrue(controller.isMonitoringPointerPassthrough)
        controller.closePinned(parent.id)
        XCTAssertFalse(controller.isMonitoringPointerPassthrough)
        controller.pinFamily(parent.id)
        XCTAssertTrue(controller.isMonitoringPointerPassthrough)
        controller.tearDown()
        XCTAssertFalse(controller.isMonitoringPointerPassthrough)
    }

    func testPaintAndHitTestingShareOneSquircleExponent() {
        // The drawn shape and the hosting view's hit test use
        // AtticStyle.panelSquircleExponent; placement, coverage and the
        // pointer policy go through PanelGeometry.squircleExponent. They
        // must be the same number or paint and clicks could disagree.
        XCTAssertEqual(AtticStyle.panelSquircleExponent, PanelGeometry.squircleExponent)
    }

    /// Pins the plumbing: both windows resolve through
    /// `AppSettings.panelSurfaceTreatment`, which is the theme's own
    /// resolver, so every frame token they read is the same value. That the
    /// two views call it (rather than a hand-rolled treatment) is checked by
    /// reading; the captures compare what they draw.
    func testSharedResolverIsTheThemeResolverForEverySetting() throws {
        let suite = "PanelSurfaceWindowTests-parity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for theme in AtticPanelTheme.allCases {
            for surface in PanelSurfaceStyle.allCases {
                for depth in [false, true] {
                    for tint in PanelTintLevel.allCases {
                        settings.panelTheme = theme
                        settings.panelSurfaceStyle = surface
                        settings.panelDepthEnabled = depth
                        settings.panelTint = tint
                        for scheme in [ColorScheme.light, .dark] {
                            for contrast in [ColorSchemeContrast.standard, .increased] {
                                for reduce in [false, true] {
                                    let shared = settings.panelSurfaceTreatment(
                                        colorScheme: scheme, contrast: contrast, reduceTransparency: reduce)
                                    let direct = theme.surfaceTreatment(
                                        colorScheme: scheme, contrast: contrast, surface: surface,
                                        depth: depth, tint: tint, reduceTransparency: reduce)
                                    XCTAssertEqual(shared, direct)
                                    // The frame tokens are properties of the
                                    // treatment, so both windows get the same.
                                    XCTAssertEqual(shared.surfaceEdgeOpacity(for: contrast),
                                                   direct.surfaceEdgeOpacity(for: contrast))
                                    XCTAssertEqual(shared.surfaceElevation, direct.surfaceElevation)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct HitOwningContent: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
