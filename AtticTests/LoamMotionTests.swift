import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// What Attic takes from Loam (Accepted 2026-11-10, "Motion: what Attic
/// takes from Loam, both Reduced choices"): light arrivals pop, exits ease
/// in, presses shrink, rows lift, the toast rises and sinks, and Reduced
/// offers Fade as well as Instant.
@MainActor
final class LoamMotionTests: XCTestCase {
    private final class ArrivalState: ObservableObject {
        @Published var reduced = true
    }

    private struct ArrivalSurface: View {
        @ObservedObject var state: ArrivalState

        var body: some View {
            let design = AtticDesignContext(mode: .light, reduceMotion: state.reduced)
            Color.black.frame(width: 40, height: 40)
                .modifier(AtticStaggeredArrival(index: 3))
                .frame(width: 80, height: 80)
                .background(Color.white)
                .atticDesign(design)
        }
    }

    /// E-2: an arrival first displayed under Reduced must remain opaque
    /// when motion is re-enabled without unmounting the existing view.
    func testE2StaggeredArrivalStaysVisibleWhenReductionTurnsOff() throws {
        let state = ArrivalState()
        let host = NSHostingView(rootView: ArrivalSurface(state: state))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 80, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func centreRed() throws -> CGFloat {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let colour = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            return try XCTUnwrap(colour.usingColorSpace(.deviceRGB)).redComponent
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertLessThan(try centreRed(), 0.25, "Reduced arrives visible")
        state.reduced = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(try centreRed(), 0.25, "turning off Reduced cannot hide an existing button")
    }

    private var savedTuning = AtticMotionTuning.current
    private var savedStyle = AtticReducedMotionStyle.current

    override func setUp() {
        super.setUp()
        savedTuning = AtticMotionTuning.current
        savedStyle = AtticReducedMotionStyle.current
    }

    override func tearDown() {
        AtticMotionTuning.current = savedTuning
        AtticReducedMotionStyle.current = savedStyle
        super.tearDown()
    }

    // MARK: - Tokens

    /// Exits speed up: the one exit curve eases in over F (0.12 s).
    func testExitsEaseIn() {
        XCTAssertEqual(AtticMotionScale.exit, Animation.easeIn(duration: 0.12))
        XCTAssertEqual(AtticMotionPreset.toast.leaveAnimation(reduceMotion: false), Animation.easeIn(duration: 0.12))
    }

    /// The Undo toast arrives on pop (0.30 s, bounce 0.28) in Lively.
    func testTheToastArrivesOnPop() {
        XCTAssertEqual(AtticMotionPreset.toast.spring(in: .lively), AtticMotionSpring(response: 0.30, bounce: 0.28))
        AtticMotionTuning.current = .lively
        XCTAssertEqual(AtticMotionPreset.toast.animation(reduceMotion: false), .spring(duration: 0.30, bounce: 0.28))
    }

    /// The named values: pop, lift, press, stagger, the cross-fade, the
    /// chrome fold and the chat's exception.
    func testTheTokenTable() {
        XCTAssertEqual(AtticMotionScale.pop, AtticMotionSpring(response: 0.30, bounce: 0.28))
        XCTAssertEqual(AtticMotionScale.lift, AtticMotionSpring(response: 0.30, bounce: 0.18))
        XCTAssertTrue((1.02...1.03).contains(AtticMotionScale.liftScale))
        XCTAssertEqual(AtticMotionScale.pressScale, 0.97)
        XCTAssertEqual(AtticMotionScale.press, AtticMotionSpring(response: 0.20, bounce: 0))
        XCTAssertEqual(AtticMotionScale.crossfade, .easeOut(duration: 0.16))
        XCTAssertEqual(AtticMotionScale.deleteScale, 0.96)
        XCTAssertEqual(AtticMotionScale.gapCloseDelay, 0.06, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.toastRise, 12)
        XCTAssertEqual(AtticMotionScale.toastSink, 8)
        XCTAssertEqual(AtticMotionScale.detailsDrop, 4)
        // The chrome fold: named, unchanged (0.26 s on .3, .7, .2, 1).
        XCTAssertEqual(AtticMotionScale.chromeFold, 0.26)
        XCTAssertEqual(AtticPanelChromeMetrics.fold(reduceMotion: false), .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.26))
        XCTAssertEqual(AtticPanelChromeMetrics.curve(0.2), .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.2))
        // Unchanged: the page slide's spring, the sweep, the Reduced fade.
        XCTAssertEqual(AtticMotionTuning.lively.slide, AtticMotionSpring(response: 0.28, bounce: 0.12))
        XCTAssertEqual(AtticMotionTuning.lively.complete, AtticMotionSpring(response: 0.20, bounce: 0.12))
        XCTAssertEqual(AtticMotionScale.reducedFade, .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12))
    }

    /// 30 ms apart, never past 240 ms; none when motion is reduced.
    func testStaggerIsCapped() {
        XCTAssertEqual(AtticMotionScale.stagger(index: 0, reduceMotion: false), 0)
        XCTAssertEqual(AtticMotionScale.stagger(index: 1, reduceMotion: false), 0.03, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 3, reduceMotion: false), 0.09, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 8, reduceMotion: false), 0.24, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 40, reduceMotion: false), 0.24, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionScale.stagger(index: 5, reduceMotion: true), 0)
    }

    /// The tick lands on pop; the sweep keeps `complete`.
    func testTheTickLandsOnPop() {
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: false, tuning: .lively), .spring(duration: 0.30, bounce: 0.28))
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: false, tuning: .subtle), .spring(duration: 0.30, bounce: 0.04))
        XCTAssertEqual(AtticStatusCircle.tickAnimation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertLessThan(AtticStatusCircle.tickStartScale, 1)
    }

    /// Press: 0.97 while held on a 0.20 s spring; nothing when reduced.
    func testPressIsOffWhenMotionIsReduced() {
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: true, reduceMotion: false), 0.97)
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: false, reduceMotion: false), 1)
        XCTAssertEqual(AtticMotionScale.pressedScale(pressed: true, reduceMotion: true), 1)
        XCTAssertEqual(AtticMotionScale.pressAnimation(reduceMotion: false), .spring(duration: 0.20, bounce: 0))
        XCTAssertNil(AtticMotionScale.pressAnimation(reduceMotion: true))
    }

    /// Delete: the row leaves on the eased-in exit at once; the list's
    /// move (the gap closing) starts 60 ms later.
    func testDeleteLeavesFirstThenTheGapCloses() {
        let travel = AtticMotionPreset.settle.animation(reduceMotion: false)
        XCTAssertEqual(AtticMotionScale.gapClose(travel, afterRowsLeave: true), travel?.delay(0.06))
        XCTAssertEqual(AtticMotionScale.gapClose(travel, afterRowsLeave: false), travel)
        XCTAssertNil(AtticMotionScale.gapClose(nil, afterRowsLeave: true))
    }

    /// The toast goes on a swipe down past 24 pt (or a flick), never up.
    func testTheToastSwipesDownToDismiss() {
        XCTAssertTrue(PanelToastSwipe.swipeDismisses(translation: 24, predicted: 24))
        XCTAssertTrue(PanelToastSwipe.swipeDismisses(translation: 10, predicted: 60))
        XCTAssertFalse(PanelToastSwipe.swipeDismisses(translation: 10, predicted: 20))
        XCTAssertFalse(PanelToastSwipe.swipeDismisses(translation: -40, predicted: -80))
    }

    /// A row picked up grows on `lift` and settles back as it lands; never
    /// when motion is reduced.
    func testAPickedUpRowLifts() {
        typealias Layer = TasksLiftedCardLayer<EmptyView>
        XCTAssertEqual(Layer.scale(raised: true, landed: false, reduceMotion: false), AtticMotionScale.liftScale)
        XCTAssertEqual(Layer.scale(raised: true, landed: true, reduceMotion: false), 1)
        XCTAssertEqual(Layer.scale(raised: true, landed: false, reduceMotion: true), 1)
        XCTAssertEqual(Layer.scale(raised: false, landed: false, reduceMotion: false), 1)
        XCTAssertEqual(Layer.liftAnimation, .spring(duration: 0.30, bounce: 0.18))
        let card = TasksLiftedCard()
        card.begin(id: UUID(), tab: .now, origin: CGRect(x: 0, y: 40, width: 300, height: 30))
        XCTAssertEqual(card.lift?.landed, false)
        card.land(at: 70)
        XCTAssertEqual(card.lift?.landed, true)
        card.begin(id: UUID(), tab: .now, origin: CGRect(x: 0, y: 40, width: 300, height: 30))
        XCTAssertEqual(card.lift?.landed, false, "a new pick-up starts lifted")
    }

    // MARK: - Reduced motion, both

    /// Instant (the default): pages and expansions at once, the rest fades.
    /// Fade: every movement becomes the 0.12 s fade.
    func testReducedFadeAndInstant() {
        AtticReducedMotionStyle.current = .instant
        XCTAssertEqual(AtticReducedMotionStyle.default, .instant)
        XCTAssertNil(AtticMotionPreset.pageSwitch.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionPreset.expand.animation(reduceMotion: true))
        XCTAssertNil(AtticMotionScale.reducedChange)
        XCTAssertNil(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: true))
        XCTAssertEqual(PanelPageMotion.current(reduceMotion: true), .instant)
        XCTAssertNil(PanelPageMotion.current(reduceMotion: true).animation)
        XCTAssertEqual(AtticMotionPreset.popover.animation(reduceMotion: true), AtticMotionScale.reducedFade)

        AtticReducedMotionStyle.current = .fade
        XCTAssertEqual(AtticMotionPreset.pageSwitch.animation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionPreset.expand.animation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionPreset.expand.leaveAnimation(reduceMotion: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: true), AtticMotionScale.reducedFade)
        let page = PanelPageMotion.current(reduceMotion: true)
        XCTAssertEqual(page, .fade)
        XCTAssertFalse(page.travels, "a faded switch never travels")
        XCTAssertEqual(page.restingOffset(side: 1, width: 400), 0)
        XCTAssertEqual(page.animation, AtticMotionScale.reducedFade)
        XCTAssertEqual(page.pageOpacityAnimation(incoming: true), AtticMotionScale.reducedFade)
        XCTAssertEqual(page.pageOpacityAnimation(incoming: false), AtticMotionScale.reducedFade)
        XCTAssertEqual(page.inPlaceOpacityAnimation(incoming: true), AtticMotionScale.reducedFade)
        // Nothing scales either way, and motion that isn't reduced is untouched.
        for preset in AtticMotionPreset.allCases {
            XCTAssertEqual(preset.hiddenScale(reduceMotion: true), 1, "\(preset)")
        }
        XCTAssertNotEqual(PanelPageMotion.current(reduceMotion: false), .fade)
        XCTAssertTrue(PanelPageMotion.current(reduceMotion: false).travels, "the slide stays")
        XCTAssertEqual(AtticMotionScale.resolved(.easeOut(duration: 0.3), reduceMotion: false), .easeOut(duration: 0.3))
    }

    func testReducedPickerCardsFadeOpacityForFadeAndAppearInstantlyForInstant() {
        AtticReducedMotionStyle.current = .fade
        XCTAssertEqual(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: true), AtticMotionScale.reducedFade,
                       "the picker and unfold cards must fade for 0.12 s")
        AtticReducedMotionStyle.current = .instant
        XCTAssertNil(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: true),
                     "the current Instant behavior remains")
        AtticReducedMotionStyle.current = .fade
        XCTAssertNil(AtticDropdownReveal.reducedOpacityAnimation(reduceMotion: false),
                     "the standard spring/unfold path must remain unchanged")
    }

    /// The choice persists like the other appearance settings; the row
    /// shows only while motion is reduced.
    func testTheReducedChoicePersistsAndShowsOnlyWhenReduced() throws {
        let suite = "LoamMotionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            AtticMotionPreference.level = .lively
        }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(settings.reducedMotionStyle, .instant)
        settings.reducedMotionStyle = .fade
        XCTAssertEqual(defaults.string(forKey: "reducedMotionStyle"), "fade")
        XCTAssertEqual(AtticReducedMotionStyle.current, .fade)
        AtticReducedMotionStyle.current = .instant
        let reopened = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertEqual(reopened.reducedMotionStyle, .fade)
        XCTAssertEqual(AtticReducedMotionStyle.current, .fade, "loading applies the stored choice")

        XCTAssertFalse(GeneralSettingsView.showsReducedStyle(level: .lively, systemReduceMotion: false))
        XCTAssertFalse(GeneralSettingsView.showsReducedStyle(level: .subtle, systemReduceMotion: false))
        XCTAssertTrue(GeneralSettingsView.showsReducedStyle(level: .reduced, systemReduceMotion: false))
        XCTAssertTrue(GeneralSettingsView.showsReducedStyle(level: .lively, systemReduceMotion: true))
        XCTAssertEqual(AtticReducedMotionStyle.allCases.map(\.title), ["Instant", "Fade"])
    }
}


/// Live, off-screen SwiftUI deletions. The coloured top-edge calibration
/// marks are *inside* the real Attic row/card's transition, so their rendered
/// size and intensity report the animation actually presented by the host.
/// The green mark on the next row reports when the list gap begins closing.
@MainActor
final class DeleteMotionHostedTests: XCTestCase {
    private enum Surface: String {
        case notesLibrary = "notes-library"
        case notesBoard = "notes-board"
        case completedToday = "completed-today"
        case tasks = "tasks-reference"
    }

    private final class Rows: ObservableObject {
        @Published var ids: [UUID]
        var deleted: Set<UUID> = []
        init(_ ids: [UUID]) { self.ids = ids }
        func removeFirst() {
            guard let first = ids.first else { return }
            deleted.insert(first)
            ids.removeFirst()
        }
    }

    private struct LiveScene: View {
        @ObservedObject var rows: Rows
        let surface: Surface
        let leadID: UUID
        let details: [UUID: NotesLibraryModel.RowDetails]
        let thumbnails: NoteThumbnailCache
        let dark: Bool
        let reduced: Bool
        let anchors = AtticNoteRowAnchors()

        var body: some View {
            let travel = AtticMotionPreset.settle.animation(reduceMotion: reduced)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.ids, id: \.self) { id in
                    actualRow(id)
                        .frame(width: 280, height: 65)
                        // Test-only calibration marks move and fade with the
                        // real content; no reference frame is ever constructed.
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(id == leadID ? Color(red: 1, green: 0, blue: 1) : Color(red: 0, green: 1, blue: 0))
                                .frame(width: 240, height: 6)
                        }
                        .frame(width: 280, height: 75, alignment: .top)
                        .transition(transition)
                }
            }
            .modifier(AtticDeleteGapMotion(ids: rows.ids, travel: travel,
                                           isDeleted: { rows.deleted.contains($0) }))
            .frame(width: 280, height: 190, alignment: .topLeading)
            .padding(.leading, 20)
            .frame(width: 320, height: 210, alignment: .topLeading)
            .background(dark ? Color(white: 0.12) : .white)
            .atticDesign(AtticDesignContext(mode: dark ? .dark : .light, reduceMotion: reduced))
        }

        private var transition: AnyTransition {
            switch surface {
            case .notesLibrary:
                return .asymmetric(insertion: reduced ? .opacity : .opacity.combined(with: .move(edge: .leading)),
                                   removal: AtticMotionScale.deleteExit(reduceMotion: reduced))
            case .notesBoard:
                return .asymmetric(insertion: .opacity, removal: AtticMotionScale.deleteExit(reduceMotion: reduced))
            case .completedToday:
                return .asymmetric(insertion: .identity, removal: AtticMotionScale.deleteExit(reduceMotion: reduced))
            case .tasks:
                return AtticMotionScale.rowTransition(reduceMotion: reduced)
            }
        }

        @ViewBuilder
        private func actualRow(_ id: UUID) -> some View {
            switch surface {
            case .notesLibrary:
                if let detail = details[id] {
                    NotesLibraryRow(details: detail, thumbnails: thumbnails, commands: { [] },
                                    anchors: anchors, onShowActions: {}, onOpen: {})
                        .frame(width: 280)
                }
            case .notesBoard:
                if let detail = details[id] {
                    NotesBoardCard(details: detail, pinned: false, commands: { [] },
                                   anchors: anchors, onShowActions: {}, onOpen: {})
                        .frame(width: 280)
                }
            case .completedToday, .tasks:
                AtticTaskRow(
                    model: AtticTaskRowModel(id: id, title: id == leadID ? "Delete task" : "Next task",
                                             state: surface == .completedToday ? .done : .todo),
                    actions: AtticTaskActions(toggleDone: {}, openPage: {}),
                    onToggleExpanded: {}
                )
            }
        }
    }

    private struct PixelFrame {
        let bitmap: NSBitmapImageRep
        let red: CGFloat
        let width: CGFloat
        let redY: CGFloat
        let nextY: CGFloat
    }

    private let times: [Double] = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.12, 0.16, 0.24]

    private func measure(_ bitmap: NSBitmapImageRep, redAnchor: Int?) throws -> PixelFrame {
        func channel(_ x: Int, _ y: Int, red: Bool) -> CGFloat {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
            // Magenta avoids the reddish tones of the Notes board's real
            // surface. Both R and B must exceed G to identify the mark.
            return red ? max(0, min(c.redComponent, c.blueComponent) - c.greenComponent)
                       : max(0, c.greenComponent - max(c.redComponent, c.blueComponent))
        }
        func band(red: Bool) -> (level: CGFloat, width: CGFloat, y: CGFloat) {
            // Find the solid six-point calibration stripe in the captured
            // pixels; this intentionally reads the *rendered image*.
            var bestRow = 0, bestSum: CGFloat = 0
            // Once the outgoing mark has been found in the initial frame,
            // track that exact area. Board cards have other red-tinged
            // material which must not become a substitute disappearing row.
            let low = red && redAnchor != nil ? max(0, redAnchor! - 5) : 0
            let high = red && redAnchor != nil ? min(bitmap.pixelsHigh - 1, redAnchor! + 5) : bitmap.pixelsHigh - 1
            for y in low...high {
                var sum: CGFloat = 0
                for x in stride(from: 30, to: 278, by: 3) { sum += channel(x, y, red: red) }
                if sum > bestSum { bestRow = y; bestSum = sum }
            }
            var level: CGFloat = 0, first = bitmap.pixelsWide, last = 0
            for x in 20..<280 { level = max(level, channel(x, bestRow, red: red)) }
            if level > 0.025 {
                for x in 20..<280 where channel(x, bestRow, red: red) > level * 0.5 {
                    first = min(first, x)
                    last = max(last, x)
                }
            }
            return (level, last >= first ? CGFloat(last - first + 1) : 0, CGFloat(bestRow))
        }
        let outgoing = band(red: true), following = band(red: false)
        XCTAssertGreaterThan(following.level, 0.4, "the actual next row must be rendered")
        return PixelFrame(bitmap: bitmap, red: outgoing.level, width: outgoing.width,
                          redY: outgoing.y, nextY: following.y)
    }

    private func capture(_ host: NSHostingView<LiveScene>) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func saveSheet(_ frames: [PixelFrame], surface: Surface, dark: Bool) throws {
        guard ProcessInfo.processInfo.environment["ATTIC_DELETE_FRAME_OUTPUT"] != nil else { return }
        // The XCTest host is sandboxed. Write to its own temporary directory;
        // the test runner copies these sheets to the Air job folder afterward.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attic-delete-motion-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        print("LIVE_DELETE_FRAME_DIR=\(directory.path)")
        let width = 320, height = 210
        let sheet = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * frames.count, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: sheet))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, frame) in frames.enumerated() {
            NSImage(data: try XCTUnwrap(frame.bitmap.representation(using: .png, properties: [:])))?
                .draw(in: CGRect(x: width * index, y: 0, width: width, height: height))
            NSString(string: "\(Int(times[index] * 1_000)) ms").draw(
                at: CGPoint(x: width * index + 8, y: 8),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: dark ? NSColor.white : NSColor.black
                ])
        }
        context.flushGraphics()
        try XCTUnwrap(sheet.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(surface.rawValue)-\(dark ? "dark" : "light").png"))
    }

    private func check(_ surface: Surface, reduced: Bool) throws {
        let savedOverride = AtticMotionPreference.systemReduceMotionOverride
        let savedFeel = AtticMotionTuning.current
        let savedStyle = AtticReducedMotionStyle.current
        defer {
            AtticMotionPreference.systemReduceMotionOverride = savedOverride
            AtticMotionTuning.current = savedFeel
            AtticReducedMotionStyle.current = savedStyle
        }
        AtticMotionPreference.systemReduceMotionOverride = reduced
        AtticReducedMotionStyle.current = .fade

        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        var ids: [UUID] = []
        for title in ["Delete note", "Next note"] {
            let doc = NoteDocument(blocks: [.text(title)])
            guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: doc) else {
                XCTFail("unable to build in-memory note")
                return
            }
            ids.append(id)
        }
        let library = NotesLibraryModel(search: { _ in [] }, store: store)
        let details = Dictionary(uniqueKeysWithValues: library.groups(store: store, drafts: [], prepareSummaries: false)
            .flatMap(\.rows).map { ($0.id, library.libraryRow($0, store: store)) })

        for dark in reduced ? [false] : [false, true] {
            AtticMotionTuning.current = AtticMotionFeel.lively.tuning
            let rows = Rows(ids)
            let scene = LiveScene(rows: rows, surface: surface, leadID: ids[0], details: details,
                                  thumbnails: library.thumbnails, dark: dark, reduced: reduced)
            let host = NSHostingView(rootView: scene)
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 210)
            host.wantsLayer = true
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 210),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            let layer = try XCTUnwrap(host.layer)
            let begin = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = begin
            defer { layer.speed = 1; layer.timeOffset = 0 }
            host._renderForTest(interval: 0)

            // Removing an identified row from a mounted SwiftUI ForEach is a
            // live deletion, not a synthetic change of opacity or scale.
            withAnimation(reduced ? AtticMotionScale.reducedFade
                                  : AtticMotionPreset.settle.animation(reduceMotion: false)) {
                rows.removeFirst()
            }
            // Commit the deletion transaction at paused t=0 before advancing
            // the render clock; an initial cold host may need two passes.
            for _ in 0..<3 {
                RunLoop.main.run(until: Date())
                host._renderForTest(interval: 0)
            }
            var frames: [PixelFrame] = []
            var previous = 0.0
            var redAnchor: Int?
            for time in times {
                RunLoop.main.run(until: Date())
                host._renderForTest(interval: time - previous)
                layer.timeOffset = begin + time
                CATransaction.flush()
                host.layoutSubtreeIfNeeded()
                let frame = try measure(capture(host), redAnchor: redAnchor)
                if redAnchor == nil { redAnchor = Int(frame.redY) }
                frames.append(frame)
                previous = time
            }
            let red0 = try XCTUnwrap(frames.first?.red)
            let width0 = try XCTUnwrap(frames.first?.width)
            XCTAssertGreaterThan(red0, 0.5, "\(surface): initial red calibration mark is visible")
            XCTAssertGreaterThan(width0, 200, "\(surface): full-width mark before deletion")
            func opacity(_ index: Int) -> CGFloat { frames[index].red / max(red0, 0.001) }
            func scale(_ index: Int) -> CGFloat { frames[index].width / max(width0, 1) }
            let gap0 = frames[0].nextY
            let motion = frames.map { abs($0.nextY - gap0) }

            if reduced {
                print("LIVE REDUCED \(surface.rawValue): " +
                      zip(times, frames).map { time, frame in
                          "\(Int(time * 1000))ms opacity=\(String(format: "%.3f", frame.red / max(red0, 0.001))) " +
                          "scale=\(String(format: "%.3f", frame.width / max(width0, 1))) " +
                          "redY=\(Int(frame.redY))"
                      }.joined(separator: "; "))
                XCTAssertEqual(scale(2), 1, accuracy: 0.015, "\(surface): Reduced must never scale")
                XCTAssertEqual(scale(4), 1, accuracy: 0.015, "\(surface): Reduced must never scale")
                XCTAssertLessThan(opacity(6), 0.12, "\(surface): Reduced fades")
            } else {
                XCTAssertEqual(opacity(2), 0.844, accuracy: 0.16, "\(surface): 40ms live opacity")
                XCTAssertEqual(opacity(4), 0.488, accuracy: 0.16, "\(surface): 80ms live opacity")
                XCTAssertLessThan(opacity(6), 0.12, "\(surface): 120ms live opacity")
                XCTAssertEqual(scale(2), 0.9938, accuracy: 0.015, "\(surface): 40ms live scale")
                XCTAssertEqual(scale(4), 0.9795, accuracy: 0.015, "\(surface): 80ms live scale")
                XCTAssertEqual(scale(5), 0.969, accuracy: 0.015, "\(surface): near-final 100ms live scale")
                XCTAssertLessThan(motion[2], 2, "\(surface): gap stays open through 40ms")
                XCTAssertLessThan(motion[3], 2, "\(surface): gap starts after 60ms")
                XCTAssertGreaterThan(motion[6], 2, "\(surface): gap is closing by 120ms")
                XCTAssertGreaterThan(motion[8], 10, "\(surface): gap closes on settle spring")
                if !dark {
                    print("LIVE DELETE \(surface.rawValue): " +
                          zip(times, frames).map { time, frame in
                              "\(Int(time * 1000))ms opacity=\(String(format: "%.3f", frame.red / max(red0, 0.001))) " +
                              "scale=\(String(format: "%.3f", frame.width / max(width0, 1))) " +
                              "gap=\(Int(abs(frame.nextY - gap0))) redY=\(Int(frame.redY))"
                          }.joined(separator: "; "))
                }
                try saveSheet(frames, surface: surface, dark: dark)
            }
        }
    }

    func testNotesLibraryDeleteExitFrames() throws { try check(.notesLibrary, reduced: false) }
    func testNotesBoardDeleteExitFrames() throws { try check(.notesBoard, reduced: false) }
    func testCompletedTodayDeleteExitFrames() throws { try check(.completedToday, reduced: false) }
    func testOrdinaryTasksReferenceExitFrames() throws { try check(.tasks, reduced: false) }
    func testNotesLibraryReduceMotionFade() throws { try check(.notesLibrary, reduced: true) }
    func testNotesBoardReduceMotionFade() throws { try check(.notesBoard, reduced: true) }
    func testCompletedTodayReduceMotionFade() throws { try check(.completedToday, reduced: true) }
}
