import AppKit
import SwiftUI
import XCTest
@testable import Attic

final class PanelSquircleSettingsTests: XCTestCase {
    @MainActor
    func testDefaultsMatchExpectedValues() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelCornerSize, 52)
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.standard.rawValue)
        XCTAssertEqual(settings.panelHeight, PanelGeometry.defaultPanelSize.height, accuracy: 0.001)
    }

    @MainActor
    func testCornerSizeRangeAndPresets() {
        XCTAssertEqual(PanelCornerSize.min, 10)
        XCTAssertEqual(PanelCornerSize.max, 140)
        XCTAssertEqual(PanelCornerSize.defaultValue, 52)
        XCTAssertEqual(
            PanelCornerSize.allCases.map(\.rawValue),
            [10, 18, 28, 40, 80, 110, 140]
        )
    }

    /// Phase 1 moved the fresh-install default from 80 to 52; a size someone
    /// already chose (including the old default, stored) is kept.
    @MainActor
    func testStoredCornerSizeSurvivesTheNewDefault() {
        for stored in [80.0, 18, 110] {
            let (defaults, suiteName) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(stored, forKey: "panelCornerSize")
            XCTAssertEqual(AppSettings(defaults: defaults).panelCornerSize, stored)
        }
    }

    @MainActor
    func testCornerSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelCornerSize = 2
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.min)

        settings.panelCornerSize = 100
        // 100 is within the expanded 10...140 range and must not be clamped.
        XCTAssertEqual(settings.panelCornerSize, 100)

        settings.panelCornerSize = 200
        XCTAssertEqual(settings.panelCornerSize, PanelCornerSize.max)

        settings.panelCornerSize = 140
        XCTAssertEqual(settings.panelCornerSize, 140)
    }

    @MainActor
    func testContentSizeClampedToRange() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)

        settings.panelContentSize = 200
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.min)

        settings.panelContentSize = 900
        XCTAssertEqual(settings.panelContentSize, 600)
    }

    @MainActor
    func testCornerSizePersistedAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.panelCornerSize = 28

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelCornerSize, 28)
    }

    @MainActor
    func testContentSizePersistedAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.panelContentSize = 360

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelContentSize, 360)
    }

    @MainActor
    func testManuallyResizedPanelSizePersistsAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings1 = AppSettings(defaults: defaults)
        settings1.persistPanelSize(CGSize(width: 612, height: 644))

        let settings2 = AppSettings(defaults: defaults)
        XCTAssertEqual(settings2.panelContentSize, 600)
        XCTAssertEqual(settings2.panelHeight, 644)
    }

    @MainActor
    func testPersistedPanelSizeClampsEachDimensionIndependently() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.persistPanelSize(CGSize(width: 200, height: 640))
        XCTAssertEqual(settings.panelContentSize, PanelGeometry.minimumPanelSize.width)
        XCTAssertEqual(settings.panelHeight, 640)

        settings.persistPanelSize(CGSize(width: 680, height: 900))
        XCTAssertEqual(settings.panelContentSize, 600)
        XCTAssertEqual(settings.panelHeight, 900)
    }

    @MainActor
    func testNonFiniteCornerSizeUsesFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.nan, forKey: "panelCornerSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.panelCornerSize, 52)
    }

    @MainActor
    func testNonFiniteContentSizeUsesFallback() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Double.infinity, forKey: "panelContentSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.panelContentSize, PanelContentSize.standard.rawValue)
    }

    // MARK: The squircle's path is built once per shape and rect

    /// Scroll trace 27 Nov: every hit test during a scroll rebuilt the
    /// panel's unchanged squircle through `Squircle.path(in:)`. Repeated asks
    /// for one shape and rect build it once; interleaved shapes each keep
    /// theirs; any change of rect, corner size, exponent, inset or squared
    /// corner builds again; and the kept path is the fresh one, point for point.
    @MainActor
    func testTheSquirclePathIsBuiltOncePerShapeAndRect() throws {
        let cache = SquirclePathCache.shared
        cache.removeAll()
        let panel = Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent)
        let rect = CGRect(x: 0, y: 0, width: 340, height: 560)
        let row = Squircle(cornerRadius: 10, exponent: 5)
        let rowRect = CGRect(x: 0, y: 0, width: 300, height: 44)

        var builds = cache.buildCount
        let kept = panel.path(in: rect)
        XCTAssertEqual(cache.buildCount - builds, 1, "the first ask builds the path")
        builds = cache.buildCount
        for _ in 0..<200 { _ = panel.path(in: rect) }
        XCTAssertEqual(cache.buildCount - builds, 0, "unchanged shape and rect: no rebuild")
        for _ in 0..<50 { _ = row.path(in: rowRect); _ = panel.path(in: rect) }
        XCTAssertEqual(cache.buildCount - builds, 1, "a second shape builds once and does not evict the first")

        var variants: [(String, Squircle, CGRect)] = [
            ("height", panel, CGRect(x: 0, y: 0, width: 340, height: 561)),
            ("width", panel, CGRect(x: 0, y: 0, width: 341, height: 560)),
            ("origin", panel, CGRect(x: 1, y: 0, width: 340, height: 560)),
            ("corner size", Squircle(cornerRadius: 40, exponent: AtticStyle.panelSquircleExponent), rect),
            ("exponent", Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent + 1), rect),
            ("inset", panel.inset(by: 1), rect),
            ("squared top", Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent, squaredTop: true), rect),
            ("squared bottom", Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent, squaredBottom: true), rect),
        ]
        variants.append(("row height", row, CGRect(x: 0, y: 0, width: 300, height: 61.5)))
        for (name, shape, shapeRect) in variants {
            builds = cache.buildCount
            _ = shape.path(in: shapeRect)
            XCTAssertEqual(cache.buildCount - builds, 1, "a changed \(name) rebuilds")
            _ = shape.path(in: shapeRect)
            XCTAssertEqual(cache.buildCount - builds, 1, "the changed \(name) is kept in turn")
        }

        cache.isEnabled = false
        defer { cache.isEnabled = true }
        for (name, shape, shapeRect) in variants + [("panel", panel, rect), ("row", row, rowRect)] {
            cache.isEnabled = true
            let kept = shape.path(in: shapeRect)
            cache.isEnabled = false
            let fresh = shape.path(in: shapeRect)
            XCTAssertEqual(kept, fresh, "\(name): the kept path is the fresh one")
            let r = shapeRect
            let points = [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX - 2, y: r.midY), CGPoint(x: r.maxX + 2, y: r.midY),
                          CGPoint(x: r.minX + 0.5, y: r.minY + 0.5), CGPoint(x: r.maxX - 0.5, y: r.minY + 0.5),
                          CGPoint(x: r.minX + 0.5, y: r.maxY - 0.5), CGPoint(x: r.maxX - 0.5, y: r.maxY - 0.5),
                          CGPoint(x: r.minX + 6, y: r.minY + 6), CGPoint(x: r.maxX - 6, y: r.maxY - 6)]
            for point in points {
                XCTAssertEqual(kept.contains(point), fresh.contains(point), "\(name): \(point) answers as before")
            }
        }
        _ = kept
    }

    /// The route the trace named: `AtticPanelContentContainer.hitTest` into
    /// the panel's SwiftUI content, which is clipped to and hit-tests inside
    /// the squircle (`PanelShellSurface`). Many hit tests at unchanged bounds
    /// build no path after the first pass, and every point (inside, outside,
    /// each corner) answers as it does with every path built fresh.
    @MainActor
    func testPanelHitTestsAtUnchangedBoundsBuildTheSquircleOnce() throws {
        let suite = "SquircleHitTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 340, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let tasksState = TasksPageState()
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: NoteDraftController(noteStore: notes),
                                     chromeInteractionState: chrome, uiState: state, settings: settings,
                                     tasksPageState: tasksState),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        defer { host.cancelActiveInteraction(reason: .lostWindow); state.releasePageContent(); panel.close() }
        let model = tasksState.model(for: store, toasts: nil)
        waitForTestOperation("the Tasks page's rows") { !model.rows(for: .now).isEmpty }
        content.layoutSubtreeIfNeeded()

        let b = content.bounds
        let points = [CGPoint(x: b.midX, y: b.midY), CGPoint(x: b.midX, y: b.minY + 40), CGPoint(x: b.midX, y: b.maxY - 40),
                      CGPoint(x: b.minX + 1, y: b.minY + 1), CGPoint(x: b.maxX - 1, y: b.minY + 1),
                      CGPoint(x: b.minX + 1, y: b.maxY - 1), CGPoint(x: b.maxX - 1, y: b.maxY - 1),
                      CGPoint(x: b.minX + 8, y: b.minY + 8), CGPoint(x: b.maxX - 8, y: b.maxY - 8),
                      CGPoint(x: b.minX - 3, y: b.midY), CGPoint(x: b.maxX + 3, y: b.midY)]
        func hits() -> [ObjectIdentifier?] {
            points.map { point in content.hitTest(content.convert(point, to: content.superview)).map(ObjectIdentifier.init) }
        }
        let cache = SquirclePathCache.shared
        cache.isEnabled = false
        let fresh = hits()
        cache.isEnabled = true
        cache.removeAll()
        let start = cache.buildCount
        let first = hits()
        let afterFirst = cache.buildCount
        XCTAssertGreaterThan(afterFirst, start, "the panel's hit test asks the squircle for its path (the traced route)")
        for pass in 0..<50 {
            XCTAssertEqual(hits(), first, "pass \(pass): the same views answer")
        }
        XCTAssertEqual(cache.buildCount, afterFirst, "50 passes of hit tests at unchanged bounds build no squircle path")
        XCTAssertEqual(first, fresh, "every point answers as it does with the path built fresh each time")
        XCTAssertNil(first[first.count - 1], "outside the panel nothing answers")
        XCTAssertNotNil(first[0], "the panel's middle answers")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "PanelSquircleSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
