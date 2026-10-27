import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Clean cut in every app identity and card (owner, A7). Former soft-edge
/// choices must never enable a native effect, even when injected through obsolete inputs.
@MainActor
final class ScrollEdgeTests: XCTestCase {
    private var savedEnvironment: String?
    private var savedDefault: Any?
    private var injected = false

    override func tearDown() async throws {
        if injected {
            if let savedEnvironment { setenv("ATTIC_UI_TEST_SCROLL_EDGES", savedEnvironment, 1) }
            else { unsetenv("ATTIC_UI_TEST_SCROLL_EDGES") }
            if let savedDefault { UserDefaults.standard.set(savedDefault, forKey: "AtticScrollEdgeStyle") }
            else { UserDefaults.standard.removeObject(forKey: "AtticScrollEdgeStyle") }
        }
        injected = false
        try await super.tearDown()
    }

    /// Obsolete inputs are still supplied to the real hosted page as negative controls.
    private func use(_ obsolete: String) {
        if !injected {
            savedEnvironment = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SCROLL_EDGES"]
            savedDefault = UserDefaults.standard.object(forKey: "AtticScrollEdgeStyle")
            injected = true
        }
        setenv("ATTIC_UI_TEST_SCROLL_EDGES", obsolete, 1)
        UserDefaults.standard.set("systemSoft", forKey: "AtticScrollEdgeStyle")
    }

    func testNoSurfaceOrCardEnablesANativeScrollEdge() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Attic")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the guard must inspect the product sources")
        let enabling = try NSRegularExpression(pattern:
            #"\bscrollEdgeEffectStyle\s*\(|\bscrollEdgeEffectHidden\s*\((?!\s*true\b)"#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(enabling.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                         "\(file.path): native scroll edges must remain disabled, including E1 cards")
        }
    }

    func testNoNonPreviewIdentityLeavesTheCleanCut() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Attic")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("ATTIC_UI_TEST_SCROLL_EDGES"), file.path)
            XCTAssertFalse(source.contains("AtticScrollEdgeStyle"), file.path)
        }
    }

    func testAPreviewIgnoresSavedAndEnvironmentSoftEdges() throws {
        for obsolete in ["soft", "clean", "unknown"] {
            use(obsolete)
            let hosted = try Hosted(height: 520, long: true)
            defer { hosted.close() }
            XCTAssertTrue(Self.pockets(in: try shownList(hosted)).isEmpty,
                          "obsolete defaults and \(obsolete) cannot enable native edges")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "AtticScrollEdgeStyle"), "systemSoft",
                           "the old preference is ignored without rewriting it")
        }
    }

    // MARK: - Former soft choices cannot enable native geometry

    /// A former soft choice leaves the first row in its Clean cut place
    /// and must not enable native pockets.
    func testAFormerSoftChoiceLeavesTheFirstRowAtRestWithoutNativeEdges() throws {
        use("soft")
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let tabsTop = layout.headerBottom
        let listTop = TasksViewport.listTop(tabsTop: tabsTop)
        let content = try XCTUnwrap(hosted.window.contentView)
        let frame = list.convert(list.bounds, to: content)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(list.contentInsets.top, listTop, accuracy: 0.5)
        let first = try XCTUnwrap(hosted.model.rows(for: .now).first?.id)
        XCTAssertEqual(try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first)]).minY, listTop + TasksDesignMetrics.groupHeaderHeight, accuracy: 0.5,
                       "the first row keeps its Clean cut resting place")
        XCTAssertTrue(Self.pockets(in: list).isEmpty, "a former soft choice cannot enable native edges")
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertTrue(Self.pockets(in: list).isEmpty, "scrolling cannot enable native edges")
        XCTAssertTrue(Self.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty, "no row is blurred by Attic")
    }

    /// Clean cut: no bars and no system pockets; the list's own mask cuts
    /// the rows, and the rows rest in the same place.
    func testTheCleanCutHasNoSystemEdgeEffect() throws {
        use("clean")
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        XCTAssertEqual(list.contentInsets.top, TasksViewport.listTop(tabsTop: layout.headerBottom),
                       accuracy: 0.5)
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertTrue(Self.pockets(in: list).isEmpty, "no system edge effect")
        XCTAssertTrue(Self.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty, "no row is blurred by Attic")
    }

    /// Done's log also ignores a former soft choice injected through obsolete inputs.
    func testDoneHasNoNativeEdgeEvenWithAFormerSoftChoice() throws {
        use("soft")
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        hosted.go(to: .done)
        let list = try shownList(hosted)
        list.contentView.scroll(to: CGPoint(x: 0, y: 200))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertTrue(Self.pockets(in: list).isEmpty)
    }

    /// The tabs still work under the lists' top bar: a tab click switches
    /// the page. (Typing in the add bar is a UI test's: `TasksPageUITests`.)
    func testTheTabsStillSwitchThePagesUnderTheBar() throws {
        use("soft")
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .backlog)
        XCTAssertEqual(hosted.model.tab, .backlog)
        XCTAssertEqual(hosted.shownPage(), 1)
        hosted.go(to: .now)
        XCTAssertEqual(hosted.shownPage(), 0)
    }

    /// A former A/B choice cannot change the person's scrolled place.
    func testAFormerPreviewChoiceKeepsTheScrolledPlace() throws {
        use("soft")
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        list.contentView.scroll(to: CGPoint(x: 0, y: 300))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.3)
        let place = list.contentView.bounds.minY + list.contentView.contentInsets.top
        for style in ["clean", "soft"] {
            use(style)
            hosted.spin(0.6)
            let current = try shownList(hosted)
            XCTAssertEqual(current.contentView.bounds.minY + current.contentView.contentInsets.top, place, accuracy: 1,
                           "the same distance from the first row's resting position after \(style)")
        }
    }

    // MARK: - Helpers

    private func shownList(_ hosted: Hosted) throws -> NSScrollView {
        let content = try XCTUnwrap(hosted.window.contentView)
        content.layoutSubtreeIfNeeded()
        return try XCTUnwrap(hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        })
    }

    /// AppKit's scroll edge effect views (`NSScrollPocket`) in a scroll view.
    static func pockets(in scroll: NSScrollView) -> [NSView] {
        scroll.subviews.filter { String(describing: type(of: $0)) == "NSScrollPocket" }
    }

    /// The nearest ancestor (or the view) whose layer is masked.
    static func maskedAncestor(of view: NSView, below root: NSView?) -> NSView? {
        var current: NSView? = view
        while let candidate = current, candidate !== root {
            if candidate.layer?.mask != nil { return candidate }
            current = candidate.superview
        }
        return nil
    }

    /// Layers with a blur filter (Attic's own, as `.blur` or a visual effect).
    static func blurredLayers(in layer: CALayer) -> [CALayer] {
        let own = (layer.filters ?? []).contains { String(describing: $0).localizedCaseInsensitiveContains("blur") } ? [layer] : []
        return own + (layer.sublayers ?? []).flatMap { blurredLayers(in: $0) }
    }
}
