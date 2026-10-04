import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Clean cut in every app identity and card (owner, A7). Former soft-edge
/// choices must never enable a native effect, even when injected in code.
@MainActor
final class ScrollEdgeTests: XCTestCase {
    private var saved: AtticScrollEdgeStyle?

    override func tearDown() async throws {
        if let saved { AtticScrollEdgeLab.shared.style = saved }
        saved = nil
        try await super.tearDown()
    }

    private func use(_ style: AtticScrollEdgeStyle) {
        if saved == nil { saved = AtticScrollEdgeLab.shared.style }
        AtticScrollEdgeLab.shared.style = style
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

    // MARK: - The switch

    private func scratchDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suite = "AtticScrollEdgeLabTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testTheCleanCutIsTheDefault() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: true).style, .cleanCut)
        XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: false).style, .cleanCut)
        XCTAssertEqual(AtticScrollEdgeLab.shared.style, .cleanCut, "the test host, not a preview, draws Clean cut")
    }

    func testAPreviewIgnoresSavedAndEnvironmentSoftEdges() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        defaults.set(AtticScrollEdgeStyle.systemSoft.rawValue, forKey: AtticScrollEdgeLab.styleKey)
        for environment in [[:], ["ATTIC_UI_TEST_SCROLL_EDGES": "soft"], ["ATTIC_UI_TEST_SCROLL_EDGES": "clean"]] {
            let lab = AtticScrollEdgeLab(defaults: defaults, environment: environment, isPreview: true)
            XCTAssertEqual(lab.style, .cleanCut, "the owner's native-edge-off policy also covers previews")
            XCTAssertFalse(lab.offersChoice, "there is no preview switch to re-enable the native effect")
        }
        XCTAssertEqual(defaults.string(forKey: AtticScrollEdgeLab.styleKey), "systemSoft",
                       "ignore the old preference without changing user defaults")
        defaults.removeObject(forKey: AtticScrollEdgeLab.styleKey)
        let lab = AtticScrollEdgeLab(defaults: defaults, isPreview: true)
        lab.style = .systemSoft
        XCTAssertEqual(lab.style, .cleanCut, "even an injected former choice stays disabled")
        XCTAssertNil(defaults.string(forKey: AtticScrollEdgeLab.styleKey), "no choice is persisted")
    }

    /// The official identity and every other non-preview one: Clean cut,
    /// whatever the environment or the stored choice says, no
    /// switch, and nothing is kept. The strict predicate ignores the launch
    /// arguments (`--attic-motion-lab` widens the Motion Lab, not this), so
    /// each identity is paired with and without it.
    func testNoNonPreviewIdentityLeavesTheCleanCut() throws {
        let identities: [String?] = [
            "com.taha.Attic", "com.taha.Attic.UnitTestHost", "com.taha.Attic.perf.ui",
            "com.taha.Attic.previewish", "com.taha.Attic.preview.", "com.taha.AtticUITests", "", nil,
        ]
        for identity in identities {
            for arguments in [[String](), [AtticMotionLab.argument]] {
                let name = "\(identity ?? "nil") \(arguments)"
                let isPreview = AtticPreviewOverrides.isPreviewIdentity(identity)
                XCTAssertFalse(isPreview, "\(name) is not a preview")
                let (defaults, cleanup) = try scratchDefaults()
                defer { cleanup() }
                // The environment says soft.
                let forced = AtticScrollEdgeLab(defaults: defaults, environment: ["ATTIC_UI_TEST_SCROLL_EDGES": "soft"], isPreview: isPreview)
                XCTAssertEqual(forced.style, .cleanCut, "\(name): the environment cannot choose the soft edge")
                XCTAssertFalse(forced.offersChoice, "\(name): no switch")
                // The defaults say soft.
                defaults.set(AtticScrollEdgeStyle.systemSoft.rawValue, forKey: AtticScrollEdgeLab.styleKey)
                XCTAssertEqual(AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style, .cleanCut,
                               "\(name): a stored soft edge is ignored")
                // A choice made in code is not kept.
                defaults.removeObject(forKey: AtticScrollEdgeLab.styleKey)
                AtticScrollEdgeLab(defaults: defaults, isPreview: isPreview).style = .systemSoft
                XCTAssertNil(defaults.string(forKey: AtticScrollEdgeLab.styleKey), "\(name): nothing is kept")
            }
        }
        // The Motion Lab's own policy is wider, and is left as it is: this is
        // the gap the strict predicate closes.
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.perf.ui", arguments: [AtticMotionLab.argument]))
        XCTAssertTrue(AtticMotionLab.isAvailable(bundleIdentifier: "com.taha.Attic.preview.", arguments: [AtticMotionLab.argument]))
        // A preview identity also follows the native-edge-off policy.
        XCTAssertTrue(AtticPreviewOverrides.isPreviewIdentity("com.taha.Attic.preview.main"))
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let preview = AtticScrollEdgeLab(defaults: defaults, isPreview: true)
        XCTAssertFalse(preview.offersChoice)
    }

    // MARK: - Former soft choices cannot enable native geometry

    /// A former soft choice leaves the first row in its Clean cut place
    /// and must not enable native pockets.
    func testAFormerSoftChoiceLeavesTheFirstRowAtRestWithoutNativeEdges() throws {
        use(.systemSoft)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        let tabsTop = layout.headerBottom + AtticLayout.pageTabsTop
        let listTop = TasksViewport.listTop(tabsTop: tabsTop)
        let content = try XCTUnwrap(hosted.window.contentView)
        let frame = list.convert(list.bounds, to: content)
        XCTAssertEqual(frame.minY, 0, accuracy: 0.5)
        XCTAssertEqual(list.contentInsets.top, listTop, accuracy: 0.5)
        let first = try XCTUnwrap(hosted.model.rows(for: .now).first?.id)
        XCTAssertEqual(try XCTUnwrap(hosted.pointer.frames[TasksRowID(tab: .now, id: first)]).minY, listTop, accuracy: 0.5,
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
        use(.cleanCut)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: AtticLayout.panelSize.width, height: 520))
        XCTAssertEqual(list.contentInsets.top, TasksViewport.listTop(tabsTop: layout.headerBottom + AtticLayout.pageTabsTop),
                       accuracy: 0.5)
        list.contentView.scroll(to: CGPoint(x: 0, y: 400))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.5)
        XCTAssertTrue(Self.pockets(in: list).isEmpty, "no system edge effect")
        XCTAssertTrue(Self.blurredLayers(in: try XCTUnwrap(list.documentView?.layer)).isEmpty, "no row is blurred by Attic")
    }

    /// Done's log also ignores a former soft choice injected in code.
    func testDoneHasNoNativeEdgeEvenWithAFormerSoftChoice() throws {
        use(.systemSoft)
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
        use(.systemSoft)
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
        use(.systemSoft)
        let hosted = try Hosted(height: 520, long: true)
        defer { hosted.close() }
        let list = try shownList(hosted)
        list.contentView.scroll(to: CGPoint(x: 0, y: 300))
        list.reflectScrolledClipView(list.contentView)
        hosted.spin(0.3)
        let place = list.contentView.bounds.minY + list.contentView.contentInsets.top
        for style in [AtticScrollEdgeStyle.cleanCut, .systemSoft] {
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
