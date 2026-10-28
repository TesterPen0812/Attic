import AppKit
import QuartzCore
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Fix round 1 of the owner's panel design (2026-10-27): the Air's
/// on-screen gate measured more app, WindowServer and GPU work than the
/// base while the composer takes and leaves the keyboard, and more GPU
/// while the list scrolls. These checks count, headlessly, what the
/// compositor is handed (layers, glass/backdrop surfaces, masks, shadows
/// without a path, filters) and what the composer's focus turn costs the
/// main thread, frame by frame. They print `ATTIC_PD_COST` lines; the
/// asserts guard only the structural fixes (no geometry animation of the
/// add field, no offscreen shadows on the footer tabs), never timings.
@MainActor
final class TasksPanelDesignSmoothnessTests: XCTestCase {
    private var hosted: FrameCostHost?

    override func tearDown() async throws {
        hosted?.close()
        hosted = nil
        try await super.tearDown()
    }

    // MARK: - Census

    struct Census: CustomStringConvertible {
        var views = 0
        var layers = 0
        var masks = 0
        var shadowsWithoutPath = 0
        var filtered = 0
        var backdrops = 0
        var glassViews = 0
        var rasterized = 0
        var glassClasses: [String: Int] = [:]
        var backdropRects: [CGRect] = []
        var backdropOwners: [String] = []
        var maskOwners: [String] = []
        /// Layers, masks and filtered layers per region.
        var regions: [String: [Int]] = [:]

        var description: String {
            "views=\(views) layers=\(layers) masks=\(masks) shadowsNoPath=\(shadowsWithoutPath) filtered=\(filtered) "
                + "backdrops=\(backdrops) glassViews=\(glassViews) rasterized=\(rasterized) "
                + "glassClasses=\(glassClasses.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
        }
    }

    static func census(_ root: NSView) -> Census {
        var census = Census()
        func visit(_ view: NSView) {
            census.views += 1
            let name = String(describing: type(of: view))
            if name.contains("Glass") || name.contains("VisualEffect") || name.contains("Backdrop") {
                census.glassViews += 1
                census.glassClasses[name, default: 0] += 1
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        guard let rootLayer = root.layer else { return census }
        func visit(_ layer: CALayer) {
            census.layers += 1
            let rect = layer.convert(layer.bounds, to: rootLayer)
            let region = rect.midY > 404 ? "header" : (rect.midY < 52 ? "footer" : "list")
            census.regions[region, default: [0, 0, 0]][0] += 1
            if layer.mask != nil {
                census.masks += 1
                census.regions[region, default: [0, 0, 0]][1] += 1
                census.maskOwners.append("\(region):\(layer.delegate.map { String(describing: type(of: $0)) } ?? "-") \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
            }
            if layer.shadowOpacity > 0, layer.shadowPath == nil {
                census.maskOwners.append("SHADOW \(region) \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
            }
            if !(layer.filters ?? []).isEmpty || layer.compositingFilter != nil { census.regions[region, default: [0, 0, 0]][2] += 1 }
            if layer.shadowOpacity > 0, layer.shadowPath == nil { census.shadowsWithoutPath += 1 }
            if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty || layer.compositingFilter != nil {
                census.filtered += 1
            }
            if layer.shouldRasterize { census.rasterized += 1 }
            if String(describing: type(of: layer)).contains("Backdrop") {
                census.backdrops += 1
                census.backdropRects.append(layer.convert(layer.bounds, to: rootLayer))
                let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? "-"
                let parent = layer.superlayer?.delegate.map { String(describing: type(of: $0)) } ?? "-"
                let filters = ((layer.filters ?? []) + (layer.backgroundFilters ?? [])).map { String(describing: $0).prefix(60) }
                census.backdropOwners.append("\(String(describing: type(of: layer)))<\(owner)<\(parent) \(filters)")
            }
            layer.sublayers?.forEach(visit)
        }
        visit(rootLayer)
        return census
    }

    /// The panel as the app hosts it (shell header, page switch, Tasks,
    /// footer), at rest on Now, light and dark, glass surface and controls.
    func testCountsWhatTheCompositorIsHandedAtRest() throws {
        for appearance in [AppearancePreference.light, .dark] {
            let (census, composing, searching) = try withHostedPanel(appearance: appearance) { content, state in
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                let rest = Self.census(content)
                state.isComposerPresented = true
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                let composing = Self.census(content)
                state.isComposerPresented = false
                state.requestSearch()
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                return (rest, composing, Self.census(content))
            }
            for (name, other) in [("composing", composing), ("searching", searching)] {
                print("ATTIC_PD_COST census.\(appearance).\(name) \(other) regions=\(other.regions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
            }
            print("ATTIC_PD_COST census.\(appearance) \(census)")
            let header = census.backdropRects.filter { $0.minY < 60 || $0.maxY < 60 }.count
            print("ATTIC_PD_COST census.\(appearance).regions \(census.regions.sorted { $0.key < $1.key })")
            census.maskOwners.forEach { print("ATTIC_PD_COST census.\(appearance).mask \($0)") }
            XCTAssertEqual(census.shadowsWithoutPath, 0, "\(appearance): a shadow without a path is an offscreen pass every frame")
            census.backdropOwners.forEach { print("ATTIC_PD_COST census.\(appearance).owner \($0)") }
            print("ATTIC_PD_COST census.\(appearance).backdrops \(census.backdropRects.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }) headerish=\(header)")
        }
    }

    func withHostedPanel<T>(appearance: AppearancePreference, _ body: (NSView, PanelUIState) throws -> T) throws -> T {
        let suite = "PanelDesignCost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedDemo(in: container, long: true)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 464)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        settings.appearance = appearance
        settings.panelSurfaceStyle = .glass
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: NoteDraftController(noteStore: notes),
                                     chromeInteractionState: chrome, uiState: state, settings: settings,
                                     tasksPageState: TasksPageState()),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        let content = AtticPanelContentContainer(hostingView: host, visibleSize: size, perimeter: 0)
        let panel = AtticPanel(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        panel.contentView = content
        panel.orderFront(nil)
        defer { host.cancelActiveInteraction(reason: .lostWindow); state.releasePageContent(); panel.close() }
        state.selectSection(.tasks)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        return try body(content, state)
    }

    // MARK: - The composer's focus turn

    /// The add field's text view: the composer's native field.
    static func addFieldViews(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if String(describing: type(of: view)).contains("TokenField") { found.append(view) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    struct Turn: CustomStringConvertible {
        var frames: [Double] = []
        /// Distinct widths the add field's native view took over the turn.
        var fieldWidths: Set<CGFloat> = []
        /// The add field's leading edge in the window, each frame.
        var fieldLeads: [CGFloat] = []
        /// Frames in which some glass surface changed its frame.
        var glassGeometryFrames = 0

        var total: Double { frames.reduce(0, +) }
        static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        var description: String {
            String(format: "frames=%d total=%.1fms median=%.2fms max=%.2fms fieldWidths=%d glassGeometryFrames=%d", frames.count, total,
                   Self.median(frames), frames.max() ?? 0, fieldWidths.count, glassGeometryFrames)
        }
    }

    private func glassFrames(in root: NSView) -> [CGRect] {
        var rects: [CGRect] = []
        func visit(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.contains("Glass") || name.contains("Backdrop") { rects.append(view.convert(view.bounds, to: nil)) }
            view.subviews.forEach(visit)
        }
        visit(root)
        if let layer = root.layer {
            func visit(_ layer: CALayer) {
                if String(describing: type(of: layer)).contains("Backdrop") { rects.append(layer.convert(layer.bounds, to: root.layer)) }
                layer.sublayers?.forEach(visit)
            }
            visit(layer)
        }
        return rects
    }

    /// Times every frame for `seconds` after `change`, noting the add
    /// field's width and the glass surfaces' frames each frame.
    private func turn(_ host: FrameCostHost, seconds: TimeInterval, _ change: () -> Void) -> Turn {
        guard let root = host.window.contentView else { return Turn() }
        var turn = Turn()
        var lastGlass = glassFrames(in: root)
        turn.frames.append(host.frame(change))
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
            turn.frames.append(host.frame())
            for field in Self.addFieldViews(in: root) {
                turn.fieldWidths.insert((field.frame.width * 2).rounded() / 2)
                turn.fieldLeads.append(field.convert(field.bounds, to: nil).minX)
            }
            let glass = glassFrames(in: root)
            if glass != lastGlass { turn.glassGeometryFrames += 1 }
            lastGlass = glass
        }
        return turn
    }

    /// The composer's focus and blur, as the Air's gate drives them (six
    /// cycles there; three here): what each turn costs the main thread, that
    /// the add field takes the tabs' room once they have folded and gives it
    /// back, and that the footer never leaves the panel while they turn
    /// (fix round 2). (Off screen, SwiftUI's animations do not tick: the turn
    /// itself is drawn on the Air.)
    func testTheComposerTurnKeepsTheFooterInsideThePanel() throws {
        let host = try FrameCostHost()
        hosted = host
        host.spin(0.5)
        guard let root = host.window.contentView else { return XCTFail("no page") }
        func width() -> CGFloat { Self.addFieldViews(in: root).first?.frame.width ?? -1 }
        func lead() -> CGFloat { Self.addFieldViews(in: root).first.map { $0.convert($0.bounds, to: nil).minX } ?? -1 }
        var focusTurns: [Turn] = []
        var blurTurns: [Turn] = []
        for cycle in 0..<3 {
            let rest = width()
            focusTurns.append(turn(host, seconds: 0.1) {
                host.focus.addBar = true
                host.model.objectWillChange.send()
            })
            print("ATTIC_PD_COST composer.focus.widths \(focusTurns.last?.fieldWidths.sorted() ?? []) focused=\(host.focus.addBar)")
            host.spin(0.6)
            let composing = width()
            XCTAssertGreaterThan(composing, rest, "cycle \(cycle): the field takes the tabs' room once they have folded")
            blurTurns.append(turn(host, seconds: 0.1) {
                host.focus.addBar = false
                host.model.objectWillChange.send()
            })
            print("ATTIC_PD_COST composer.blur.widths \(blurTurns.last?.fieldWidths.sorted() ?? []) focused=\(host.focus.addBar)")
            host.spin(0.6)
            XCTAssertEqual(width(), rest, "cycle \(cycle): the field is back to its width beside the tabs")
            // Fix round 2 (the Air: on blur the footer stretched past both
            // panel edges, then snapped): the held field never widens the
            // bar, so the field's leading edge is never left of where it
            // rests beside the tabs.
            let restLead = lead()
            for (index, value) in (blurTurns.last?.fieldLeads ?? []).enumerated() {
                XCTAssertGreaterThanOrEqual(value, restLead - 0.5,
                                            "cycle \(cycle), frame \(index): the footer is pushed past the panel's edge while the tabs return")
            }
        }
        for (name, turns) in [("focus", focusTurns), ("blur", blurTurns)] {
            for (index, turn) in turns.enumerated() { print("ATTIC_PD_COST composer.\(name).\(index) \(turn)") }
            print("ATTIC_PD_COST composer.\(name) first-frame-median="
                + String(format: "%.1fms", Turn.median(turns.compactMap(\.frames.first))))
        }
    }

    // MARK: - Folding a date group

    /// Fix round 2 (the Air, 28 Oct: mid-fold, the next header and its rows
    /// had already risen while the folding rows faded in place behind
    /// them). A group's body closes like the design's `overflow: hidden`
    /// body with a height transition: in a stack, the rows' part above the
    /// fold line is all the room they take, so the next header is carried
    /// up by the body's edge and no row draws at or below it. Drawn at
    /// points of the turn: a green header, the group's red rows, the next
    /// (blue) header, laid out by the stack itself.
    func testAFoldingGroupsBodyCarriesTheNextHeaderOnItsEdge() throws {
        let heights: [CGFloat] = [29, 45.5, 29, 61.5]
        let total = heights.reduce(0, +)
        let tops = heights.indices.map { heights[..<$0].reduce(0, +) }
        let above: CGFloat = 20
        for progress in stride(from: 0.0, through: 1.0, by: 0.125) {
            let p = CGFloat(progress)
            let view = VStack(alignment: .leading, spacing: 0) {
                Color.green.frame(width: 100, height: above)
                ForEach(heights.indices, id: \.self) { index in
                    Color.red
                        .frame(width: 100, height: heights[index])
                        .modifier(TasksFoldBody(progress: p, place: TasksFoldPlace(top: tops[index], total: total)))
                }
                Color.blue.frame(width: 100, height: 26)
                Spacer(minLength: 0)
            }
            .frame(width: 120, height: above + total + 26 + 20, alignment: .topLeading)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            func colour(_ y: Int) -> NSColor? {
                guard let c = rep.colorAt(x: 100, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { return nil }
                return c
            }
            let blueTop = (0..<rep.pixelsHigh).first { colour($0).map { $0.blueComponent > 0.5 && $0.redComponent < 0.3 } ?? false }
            let edge = (above + total * p) * 2
            XCTAssertEqual(CGFloat(blueTop ?? -100), edge, accuracy: 2, "progress \(progress): the next header is not on the body's edge")
            // From the first device pixel wholly under the edge (the one it
            // crosses is shared, antialiased).
            let redBelow = (Int(edge.rounded(.up))..<rep.pixelsHigh).filter { y in
                (stride(from: 4, to: 196, by: 8)).contains { x in
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.02 else { return false }
                    return c.redComponent > c.blueComponent + 0.05 && c.redComponent > c.greenComponent + 0.05
                }
            }
            XCTAssertEqual(redBelow.count, 0, "progress \(progress): a folding row draws at or below the next header")
        }
        // Folded, nothing; open, every row whole.
        for (index, top) in tops.enumerated() {
            let place = TasksFoldPlace(top: top, total: total)
            XCTAssertEqual(TasksFoldBody.visibleHeight(progress: 0, place: place), 0)
            XCTAssertGreaterThanOrEqual(TasksFoldBody.visibleHeight(progress: 1, place: place), heights[index])
        }
    }
}
