import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Draw input on the real panel (brief "Draw input", 2 Nov): pinch and
/// ⌘-scroll zoom, two-finger panning against swipe-to-close, the tool
/// cursors and the canvas menu's card. Every event is a `CGEvent` made
/// into an `NSEvent` and sent through the panel, as the system delivers
/// it, with the panel not key (the invisible test host's panels can't be).
@MainActor
final class DrawInputTests: XCTestCase {
    private var previousModel: DrawPageModel?

    override func setUp() {
        super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        AtticDraw.enabledOverride = true
    }

    override func tearDown() {
        if let previousModel { DrawPageModel.replaceShared(previousModel) }
        previousModel = nil
        AtticDraw.enabledOverride = nil
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        super.tearDown()
    }

    // MARK: The rig: the app's panel on the Draw page

    private struct Rig {
        let controller: AtticPanelController
        let panel: AtticPanel
        let uiState: PanelUIState
        let model: DrawPageModel
        let board: DrawBoardView
        let defaults: UserDefaults
        let suite: String
        let hideRequests: () -> Int
    }

    private func makeRig(width: Double = PanelContentSize.standard.rawValue) throws -> Rig {
        let suite = "DrawInputTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let model = DrawPageModel(store: DrawInMemoryStore())
        model.pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-draw-input-\(UUID().uuidString)"))
        if previousModel == nil { previousModel = DrawPageModel.shared }
        DrawPageModel.replaceShared(model)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let settings = AppSettings(defaults: defaults)
        settings.panelContentSize = width
        let uiState = PanelUIState()
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        uiState.selectSection(.canvas)
        let probe = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))
        let deadline = Date().addingTimeInterval(5)
        spin(0.3)
        while (panel.canBeginTrackpadSwipe?(probe) != true || board(in: panel) == nil), Date() < deadline { spin(0.05) }
        let board = try XCTUnwrap(board(in: panel), "the Draw page's board is in the panel")
        XCTAssertTrue(model.isShown, "the Draw page is shown")
        XCTAssertFalse(panel.isKeyWindow, "the panel is not key")
        var requests = 0
        let original = panel.onTrackpadDismissRequest
        panel.onTrackpadDismissRequest = { requests += 1; original?() }
        spin(0.2)
        return Rig(controller: controller, panel: panel, uiState: uiState, model: model, board: board,
                   defaults: defaults, suite: suite, hideRequests: { requests })
    }

    private func close(_ rig: Rig) {
        rig.model.setShown(false)
        rig.panel.orderOut(nil)
        rig.model.pasteboard.releaseGlobally()
        rig.defaults.removePersistentDomain(forName: rig.suite)
    }

    private func board(in panel: NSWindow) -> DrawBoardView? {
        func find(_ view: NSView) -> DrawBoardView? {
            if let board = view as? DrawBoardView { return board }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// A board point (y down, the model's space) in the panel's window space.
    private func windowPoint(_ board: DrawBoardView, _ point: CGPoint) -> CGPoint {
        board.convert(CGPoint(x: point.x, y: board.bounds.height - point.y), to: nil)
    }

    private func boardCentre(_ rig: Rig) -> CGPoint {
        CGPoint(x: rig.model.clearRect.midX, y: rig.model.clearRect.midY)
    }

    /// A window point as the CGEvent's global location (top-left origin).
    private func place(_ event: CGEvent, at point: CGPoint, in panel: NSWindow) {
        let screen = panel.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(panel.windowNumber))
        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
    }

    /// The `NSEvent` the panel gets, at `point` in its window. A made event
    /// is tied to the panel when AppKit reads the window fields; when it
    /// isn't, AppKit reads its location as the window's own, so the event
    /// is placed there instead. Either way the event lands where asked.
    private func made(_ event: CGEvent, at point: CGPoint, in panel: NSWindow) throws -> NSEvent {
        place(event, at: point, in: panel)
        if let ns = NSEvent(cgEvent: event), ns.window === panel,
           hypot(ns.locationInWindow.x - point.x, ns.locationInWindow.y - point.y) < 0.5 { return ns }
        event.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        var ns = try XCTUnwrap(NSEvent(cgEvent: event))
        // Do not assume AppKit's coordinate basis for a recorded gesture.
        // Translate by its measured error, preserving every
        // touch, phase, delta and magnification sample in the recording.
        let correction = CGPoint(x: point.x - ns.locationInWindow.x, y: point.y - ns.locationInWindow.y)
        event.location = CGPoint(x: event.location.x + correction.x, y: event.location.y - correction.y)
        ns = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(ns.locationInWindow.x, point.x, accuracy: 0.5, "the event lands at the point (window \(String(describing: ns.window)))")
        XCTAssertEqual(ns.locationInWindow.y, point.y, accuracy: 0.5)
        return ns
    }

    /// Phases: 1 began, 2 changed, 4 ended. Momentum: 1 begin, 2 continue, 3 end.
    private func scroll(dx: Int32 = 0, dy: Int32 = 0, phase: Int64, momentum: Int64 = 0, command: Bool = false,
                        at point: CGPoint, in panel: NSWindow) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        if command { event.flags = .maskCommand }
        return try made(event, at: point, in: panel)
    }

    /// A trackpad pinch sample: a gesture event (type 29) of the zoom kind
    /// (HID type 8), which AppKit reads as `.magnify`.
    private func pinch(_ amount: Double, phase: Int64, at point: CGPoint, in panel: NSWindow) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = try XCTUnwrap(CGEventType(rawValue: 29))
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 110)), value: 8)
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 113)), value: amount)
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 132)), value: phase)
        let ns = try made(event, at: point, in: panel)
        XCTAssertEqual(ns.type, .magnify, "a real magnify event")
        XCTAssertEqual(ns.magnification, amount, accuracy: 0.0001)
        return ns
    }

    private func key(_ characters: String, code: UInt16, shift: Bool = false, in panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                       isARepeat: false, keyCode: code))
    }

    private func hitChain(_ panel: NSWindow, at point: CGPoint) -> String {
        guard let content = panel.contentView else { return "no content" }
        var names: [String] = []
        var view = content.hitTest(content.convert(point, from: nil))
        while let current = view {
            let recognizers = current.gestureRecognizers.map { "\(type(of: $0))" }
            names.append("\(type(of: current))" + (recognizers.isEmpty ? "" : "\(recognizers)"))
            view = current.superview
        }
        return names.joined(separator: " < ")
    }

    // MARK: 1. Zoom

    private struct RecordedEvent: Decodable {
        let t: UInt64
        let data: String
    }

    /// Preserve the real trackpad's touches, paired gesture/scroll samples,
    /// phases and timing. Only the target window/point changes in this hosted
    /// test; WindowServer delivery belongs to the separate Air replay check.
    private func replay(_ name: String, in rig: Rig, at point: CGPoint) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/DrawTrackpad/\(name).jsonl")
        let samples = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(RecordedEvent.self, from: Data($0.utf8))
        }
        let first = try XCTUnwrap(samples.first)
        let firstBytes = try XCTUnwrap(Data(base64Encoded: first.data))
        let origin = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: firstBytes as CFData)).location
        let start = ProcessInfo.processInfo.systemUptime
        for sample in samples {
            let deadline = start + Double(sample.t - first.t) / 1_000_000_000
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { spin(delay) }
            let bytes = try XCTUnwrap(Data(base64Encoded: sample.data))
            let cg = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: bytes as CFData))
            let relative = CGPoint(x: cg.location.x - origin.x, y: origin.y - cg.location.y)
            let event = try made(cg, at: CGPoint(x: point.x + relative.x, y: point.y + relative.y), in: rig.panel)
            rig.panel.sendEvent(event)
        }
        spin(0.1)
    }

    func testOwnersRecordedPinchesAndCommandScrollsZoomWithTheirCompleteStreams() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let anchor = boardCentre(rig)
        let point = windowPoint(rig.board, anchor)
        for name in ["pinch-out", "pinch-in", "command-scroll-out", "command-scroll-in"] {
            rig.model.setViewport(DrawViewport(), byUser: false)
            let world = rig.model.viewport.world(anchor)
            try replay(name, in: rig, at: point)
            if name.hasSuffix("out") { XCTAssertGreaterThan(rig.model.viewport.zoom, 1.1, name) }
            else { XCTAssertLessThan(rig.model.viewport.zoom, 0.95, name) }
            let after = rig.model.viewport.screen(world)
            XCTAssertEqual(after.x, anchor.x, accuracy: 0.5, name)
            XCTAssertEqual(after.y, anchor.y, accuracy: 0.5, name)
            XCTAssertTrue(rig.model.viewportState.pillShown, name)
            XCTAssertEqual(rig.hideRequests(), 0, name)
        }
    }

    func testOwnersRecordedZoomWorksOverASelectionAndAnEditingTextBox() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let anchor = boardCentre(rig)
        let stroke = DrawObject(frame: DrawFrame(x: 60, y: 100, width: 50, height: 50),
                                content: .stroke([DrawPoint(x: 60, y: 100), DrawPoint(x: 110, y: 150)]))
        let text = DrawObject(frame: DrawFrame(x: anchor.x - 5, y: anchor.y - 5, width: 160, height: 30),
                              content: .text("Recorded trackpad"))
        rig.model.perform(.put([stroke, text]))
        for editing in [false, true] {
            for name in ["pinch-out", "command-scroll-out"] {
                rig.model.endEditing()
                rig.model.setViewport(DrawViewport(), byUser: false)
                if editing { rig.model.edit(text.id) } else { rig.model.select([stroke.id]) }
                spin(0.2)
                let point = windowPoint(rig.board, anchor)
                if editing {
                    XCTAssertTrue(rig.panel.contentView.map { $0.hitTest($0.convert(point, from: nil)) is DrawTextEditorView } == true, "the event starts over the editor")
                }
                try replay(name, in: rig, at: point)
                XCTAssertGreaterThan(rig.model.viewport.zoom, 1.1, "\(name), editing=\(editing)")
                XCTAssertEqual(rig.hideRequests(), 0)
                if editing { XCTAssertEqual(rig.model.editingID, text.id, "zoom must preserve the edit") }
            }
        }
    }

    func testTheBoardIsWhatTheMiddleOfThePanelHitTests() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        let content = try XCTUnwrap(rig.panel.contentView)
        let hit = content.hitTest(content.convert(point, from: nil))
        XCTAssertTrue(hit === rig.board, "hit chain: \(hitChain(rig.panel, at: point))")
    }

    private func describeHit(_ panel: NSWindow, at point: CGPoint) -> String {
        guard let content = panel.contentView, let hit = content.hitTest(content.convert(point, from: nil)) else { return "nil" }
        let frame = hit.convert(hit.bounds, to: nil)
        return "\(type(of: hit)) \(frame) subviews \(hit.subviews.map { "\(type(of: $0))" }) in \(hit.superview.map { "\(type(of: $0))" } ?? "-")"
    }

    /// Fields in the top row (the canvas menu's, Rename's, Search's) are
    /// AppKit views; after any of them has shown, the board must still be
    /// what the middle of the panel hit tests to, and still pan and zoom.
    func testTheBoardKeepsItsGesturesAfterTheTopRowsFieldsHaveShown() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        let content = try XCTUnwrap(rig.panel.contentView)
        let steps: [(String, () -> Void, () -> Void)] = [
            ("the canvas menu", { rig.model.openFilter() }, { rig.model.closeFilter() }),
            ("Rename", { rig.model.openFilter(); rig.model.library.perform(.rename) }, { rig.model.library.cancelRename() }),
            ("Search", { rig.model.openSearch() }, { rig.model.closeSearch() }),
        ]
        for (name, open, close) in steps {
            open()
            spin(0.4)
            close()
            spin(0.4)
            XCTAssertTrue(content.hitTest(content.convert(point, from: nil)) === rig.board,
                          "after \(name): \(describeHit(rig.panel, at: point))")
            let zoom = rig.model.viewport.zoom
            rig.panel.sendEvent(try pinch(0, phase: 1, at: point, in: rig.panel))
            rig.panel.sendEvent(try pinch(0.2, phase: 2, at: point, in: rig.panel))
            rig.panel.sendEvent(try pinch(0, phase: 4, at: point, in: rig.panel))
            XCTAssertNotEqual(rig.model.viewport.zoom, zoom, "after \(name): a pinch zooms")
            let x = rig.model.viewport.x
            rig.panel.sendEvent(try scroll(phase: 1, at: point, in: rig.panel))
            rig.panel.sendEvent(try scroll(dx: 10, phase: 2, at: point, in: rig.panel))
            rig.panel.sendEvent(try scroll(phase: 4, at: point, in: rig.panel))
            XCTAssertNotEqual(rig.model.viewport.x, x, "after \(name): a scroll pans")
            XCTAssertEqual(rig.hideRequests(), 0)
        }
    }

    func testAPinchThroughThePanelZoomsAroundThePointerWithTheClamp() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let anchor = CGPoint(x: rig.model.clearRect.midX + 40, y: rig.model.clearRect.midY - 30)
        let point = windowPoint(rig.board, anchor)
        let world = rig.model.viewport.world(anchor)
        rig.panel.sendEvent(try pinch(0, phase: 1, at: point, in: rig.panel))
        for _ in 0..<5 { rig.panel.sendEvent(try pinch(0.1, phase: 2, at: point, in: rig.panel)) }
        rig.panel.sendEvent(try pinch(0, phase: 4, at: point, in: rig.panel))
        spin(0.05)
        XCTAssertEqual(rig.model.viewport.zoom, pow(1.1, 5), accuracy: 0.01,
                       "five 10 % steps zoom in (hit chain: \(hitChain(rig.panel, at: point)))")
        let after = rig.model.viewport.screen(world)
        XCTAssertEqual(after.x, anchor.x, accuracy: 0.5, "the point under the fingers stays put")
        XCTAssertEqual(after.y, anchor.y, accuracy: 0.5)
        XCTAssertTrue(rig.model.viewportState.pillShown, "the pill shows the level")
        XCTAssertEqual(rig.model.viewportState.pillLabel, "\(Int((rig.model.viewport.zoom * 100).rounded())) %")
        // The clamp, both ways.
        rig.panel.sendEvent(try pinch(0, phase: 1, at: point, in: rig.panel))
        for _ in 0..<40 { rig.panel.sendEvent(try pinch(0.5, phase: 2, at: point, in: rig.panel)) }
        rig.panel.sendEvent(try pinch(0, phase: 4, at: point, in: rig.panel))
        XCTAssertEqual(rig.model.viewport.zoom, DrawViewport.maxZoom, accuracy: 0.0001, "400 % at most")
        rig.panel.sendEvent(try pinch(0, phase: 1, at: point, in: rig.panel))
        for _ in 0..<60 { rig.panel.sendEvent(try pinch(-0.5, phase: 2, at: point, in: rig.panel)) }
        rig.panel.sendEvent(try pinch(0, phase: 4, at: point, in: rig.panel))
        XCTAssertEqual(rig.model.viewport.zoom, DrawViewport.minZoom, accuracy: 0.0001, "10 % at least")
    }

    func testCommandScrollThroughThePanelZoomsAroundThePointerWithTheClamp() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let anchor = CGPoint(x: rig.model.clearRect.midX - 30, y: rig.model.clearRect.midY + 20)
        let point = windowPoint(rig.board, anchor)
        let world = rig.model.viewport.world(anchor)
        rig.panel.sendEvent(try scroll(phase: 1, command: true, at: point, in: rig.panel))
        for _ in 0..<4 { rig.panel.sendEvent(try scroll(dy: 10, phase: 2, command: true, at: point, in: rig.panel)) }
        rig.panel.sendEvent(try scroll(phase: 4, command: true, at: point, in: rig.panel))
        spin(0.05)
        XCTAssertNotEqual(rig.model.viewport.zoom, 1, accuracy: 0.01, "⌘-scroll zooms (hit chain: \(hitChain(rig.panel, at: point)))")
        let after = rig.model.viewport.screen(world)
        XCTAssertEqual(after.x, anchor.x, accuracy: 0.5, "around the pointer")
        XCTAssertEqual(after.y, anchor.y, accuracy: 0.5)
        XCTAssertTrue(rig.model.viewportState.pillShown)
        for _ in 0..<200 { rig.panel.sendEvent(try scroll(dy: 25, phase: 2, command: true, at: point, in: rig.panel)) }
        XCTAssertEqual(rig.model.viewport.zoom, DrawViewport.maxZoom, accuracy: 0.0001)
        for _ in 0..<400 { rig.panel.sendEvent(try scroll(dy: -25, phase: 2, command: true, at: point, in: rig.panel)) }
        XCTAssertEqual(rig.model.viewport.zoom, DrawViewport.minZoom, accuracy: 0.0001)
        XCTAssertEqual(rig.hideRequests(), 0)
    }

    /// A mouse wheel with ⌘ (line deltas, not precise ones) zooms by a step
    /// a notch can see, not by 1 %.
    func testCommandWheelNotchesZoomAVisibleStep() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        event.flags = .maskCommand
        let notch = try made(event, at: point, in: rig.panel)
        XCTAssertFalse(notch.hasPreciseScrollingDeltas)
        rig.panel.sendEvent(notch)
        XCTAssertGreaterThan(abs(rig.model.viewport.zoom - 1), 0.05, "one notch zooms at least 5 %")
    }

    func testShiftOneFitsAndShiftZeroIsActualSize() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.model.setTool(.pen)
        rig.model.pointerDown(at: CGPoint(x: 60, y: 100))
        rig.model.pointerDragged(to: CGPoint(x: 200, y: 200))
        rig.model.pointerUp(at: CGPoint(x: 200, y: 200))
        XCTAssertTrue(rig.panel.makeFirstResponder(rig.board))
        rig.panel.sendEvent(try key("!", code: 18, shift: true, in: rig.panel))
        let fitted = DrawViewport.fit(DrawGeometry.union(rig.model.objects), in: rig.model.clearRect)
        XCTAssertEqual(rig.model.viewport, fitted, "⇧1 fits")
        rig.panel.sendEvent(try key(")", code: 29, shift: true, in: rig.panel))
        XCTAssertEqual(rig.model.viewport.zoom, 1, "⇧0 is 100 %")
    }

    // MARK: 2. Panning and swipe-to-close

    func testASidewaysScrollOverTheBoardPansWithMomentumAndNeverHides() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        for direction: Int32 in [-1, 1] {
            let start = rig.model.viewport
            var expected: CGFloat = 0
            func send(_ event: NSEvent) { expected += event.scrollingDeltaX; rig.panel.sendEvent(event) }
            send(try scroll(phase: 1, at: point, in: rig.panel))
            for _ in 0..<12 { spin(1.0 / 120); send(try scroll(dx: 8 * direction, phase: 2, at: point, in: rig.panel)) }
            send(try scroll(phase: 4, at: point, in: rig.panel))
            XCTAssertEqual(rig.model.viewport.x - start.x, expected, accuracy: 0.5,
                           "direction \(direction): the board follows the fingers (hit chain: \(hitChain(rig.panel, at: point)))")
            // Momentum: through the panel it never hides. AppKit hands made
            // momentum events to no view (the board got none of them through
            // the window), so the board then gets them as AppKit hands real
            // ones on: they keep panning the gesture it owns.
            var momentumEvents: [NSEvent] = []
            for phase: Int64 in [1, 2, 2, 2, 2, 3] {
                momentumEvents.append(try scroll(dx: 6 * direction, phase: 0, momentum: phase, at: point, in: rig.panel))
            }
            for event in momentumEvents { rig.panel.sendEvent(event) }
            let beforeMomentum = rig.model.viewport.x
            for event in momentumEvents { rig.board.scrollWheel(with: event) }
            XCTAssertEqual(rig.model.viewport.x - beforeMomentum, momentumEvents.reduce(0) { $0 + $1.scrollingDeltaX }, accuracy: 0.5,
                           "momentum keeps panning")
            spin(0.1)
            XCTAssertEqual(rig.hideRequests(), 0, "direction \(direction): never a hide")
            XCTAssertEqual(rig.controller.displayedProgressForProbe, 0, accuracy: 0.0001, "the panel never followed")
            XCTAssertTrue(rig.panel.isVisible)
        }
        // Up and down too.
        let start = rig.model.viewport.y
        rig.panel.sendEvent(try scroll(phase: 1, at: point, in: rig.panel))
        for _ in 0..<6 { rig.panel.sendEvent(try scroll(dy: 10, phase: 2, at: point, in: rig.panel)) }
        rig.panel.sendEvent(try scroll(phase: 4, at: point, in: rig.panel))
        XCTAssertNotEqual(rig.model.viewport.y, start, "vertical scrolling pans too")
    }

    private func towardEdge(_ dx: Int32, in panel: NSWindow) throws -> Int32 {
        let probe = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 1, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: probe)).isDirectionInvertedFromDevice ? -dx : dx
    }

    private func swipeToEdge(at point: CGPoint, on rig: Rig) throws {
        let step = try towardEdge(-6, in: rig.panel)
        rig.panel.sendEvent(try scroll(phase: 1, at: point, in: rig.panel))
        for _ in 0..<14 { spin(1.0 / 120); rig.panel.sendEvent(try scroll(dx: step, phase: 2, at: point, in: rig.panel)) }
        spin(1.0 / 120)
        rig.panel.sendEvent(try scroll(phase: 4, at: point, in: rig.panel))
        spin(0.1)
    }

    func testTheSameSwipeOverTheTopRowStillCloses() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let top = CGPoint(x: rig.panel.frame.width / 2, y: rig.panel.frame.height - rig.panel.nativeMargin - 20)
        let viewport = rig.model.viewport
        try swipeToEdge(at: top, on: rig)
        XCTAssertEqual(rig.hideRequests(), 1, "a swipe over the top row closes (hit chain: \(hitChain(rig.panel, at: top)))")
        XCTAssertEqual(rig.model.viewport, viewport, "and doesn't pan")
    }

    func testTheSameSwipeOverTheBottomBarsEmptySpaceStillCloses() throws {
        let rig = try makeRig()
        defer { close(rig) }
        // Between the tool capsule and "+", inside the bar's band.
        let band = CGPoint(x: rig.model.boardSize.width - 70, y: rig.model.boardSize.height - rig.model.clearInsets.bottom / 2)
        let point = windowPoint(rig.board, band)
        let viewport = rig.model.viewport
        try swipeToEdge(at: point, on: rig)
        XCTAssertEqual(rig.hideRequests(), 1, "a swipe over the bar's empty space closes (hit chain: \(hitChain(rig.panel, at: point)))")
        XCTAssertEqual(rig.model.viewport, viewport, "and doesn't pan")
    }

    func testTheSwipeTowardTheEdgeOverTheBoardPansInstead() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        let viewport = rig.model.viewport
        try swipeToEdge(at: point, on: rig)
        XCTAssertEqual(rig.hideRequests(), 0, "the board's swipe is its own")
        XCTAssertNotEqual(rig.model.viewport.x, viewport.x, "it pans")
    }

    // MARK: 3. Tool cursors

    /// The cursor the drawing gives each tool (the pen's and the eraser's
    /// are images; text, shape and select are the system's).
    private func assertCursor(_ tool: DrawTool, _ rig: Rig, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let cursor = NSCursor.current
        let named = cursor === NSCursor.arrow ? "arrow" : cursor === NSCursor.operationNotAllowed ? "sentinel" : "\(cursor.image.size)"
        let when = "\(when) [now \(named); \(rig.board.cursorLog.suffix(3).joined(separator: " | "))]"
        switch tool {
        case .pen:
            XCTAssertEqual(cursor.hotSpot.x, cursor.image.size.width / 2, accuracy: 0.01, "\(when): pen hot spot centred", file: file, line: line)
            XCTAssertEqual(cursor.image.size.width, 8, accuracy: 0.01,
                           "\(when): the pen's dot (\(cursor.image.size))", file: file, line: line)
        case .eraser:
            XCTAssertEqual(cursor.image.size.width, DrawBoardView.eraserCursorSize, accuracy: 0.01,
                           "\(when): the eraser's ring (\(cursor.image.size))", file: file, line: line)
            XCTAssertEqual(cursor.hotSpot.x, DrawBoardView.eraserCursorSize / 2, accuracy: 0.01, file: file, line: line)
        case .text: XCTAssertTrue(cursor === NSCursor.iBeam, "\(when): the I-beam", file: file, line: line)
        case .shape: XCTAssertTrue(cursor === NSCursor.crosshair, "\(when): the crosshair", file: file, line: line)
        case .select: XCTAssertTrue(cursor === NSCursor.arrow, "\(when): the arrow", file: file, line: line)
        }
    }

    /// The pointer rests on the board; each transition must leave the tool's cursor.
    func testTheCursorIsTheToolsAfterEveryTransition() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = boardCentre(rig)
        rig.board.pointerOverride = windowPoint(rig.board, point)
        func reset() { NSCursor.operationNotAllowed.set() }
        let keys: [(DrawTool, String, UInt16)] = [(.select, "v", 9), (.pen, "p", 35), (.eraser, "e", 14), (.text, "t", 17), (.shape, "r", 15)]
        for (tool, character, code) in keys {
            // A click on the tool (the tool bar's action).
            reset()
            rig.model.setTool(tool == .shape ? .select : (tool == .select ? .pen : .select))
            spin(0.2)
            reset()
            if tool == .shape { rig.model.pickShape(.rectangle) } else { rig.model.setTool(tool) }
            spin(0.2)
            assertCursor(tool, rig, "\(tool) by click")
            // Its key.
            rig.model.setTool(tool == .select ? .pen : .select)
            spin(0.2)
            reset()
            XCTAssertTrue(rig.panel.makeFirstResponder(rig.board))
            rig.panel.sendEvent(try key(character, code: code, in: rig.panel))
            spin(0.2)
            XCTAssertEqual(rig.model.tool, tool)
            assertCursor(tool, rig, "\(tool) by key")
            // A pan, then a pinch.
            let at = windowPoint(rig.board, point)
            reset()
            rig.panel.sendEvent(try scroll(phase: 1, at: at, in: rig.panel))
            rig.panel.sendEvent(try scroll(dx: 5, phase: 2, at: at, in: rig.panel))
            rig.panel.sendEvent(try scroll(phase: 4, at: at, in: rig.panel))
            spin(0.2)
            assertCursor(tool, rig, "\(tool) after a pan")
            reset()
            rig.panel.sendEvent(try pinch(0, phase: 1, at: at, in: rig.panel))
            rig.panel.sendEvent(try pinch(0.2, phase: 2, at: at, in: rig.panel))
            rig.panel.sendEvent(try pinch(0, phase: 4, at: at, in: rig.panel))
            spin(0.2)
            assertCursor(tool, rig, "\(tool) after a zoom")
            // The canvas menu, and the swatch's colours (a popover), closing.
            rig.model.openFilter()
            spin(0.2)
            reset()
            rig.model.closeFilter()
            spin(0.6)
            assertCursor(tool, rig, "\(tool) after the menu closes")
            rig.model.strip = .colour
            spin(0.2)
            reset()
            rig.model.strip = nil
            spin(0.6)
            assertCursor(tool, rig, "\(tool) after the colours close")
            // A hide and a reveal.
            rig.uiState.panelDidHide()
            spin(0.2)
            reset()
            rig.uiState.panelDidReveal()
            spin(0.2)
            assertCursor(tool, rig, "\(tool) after the panel reveals")
            rig.model.setViewport(DrawViewport(), byUser: false)
        }
    }

    func testThePensCursorFollowsItsColourButKeepsItsScreenSize() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.board.pointerOverride = windowPoint(rig.board, boardCentre(rig))
        rig.model.setTool(.pen)
        spin(0.2)
        let medium = NSCursor.current
        rig.model.pickSize(.large, for: .pen)
        spin(0.2)
        // 2 Nov zoom-for-good brief: stroke width no longer sizes the cursor.
        XCTAssertEqual(NSCursor.current.image.size, medium.image.size, "stroke width must not resize the dot")
        assertCursor(.pen, rig, "large")
        let large = NSCursor.current
        rig.model.pickColour(.red)
        spin(0.2)
        XCTAssertFalse(NSCursor.current === large, "a new colour, a new dot [\(rig.board.cursorLog.suffix(5).joined(separator: " | "))]")
        assertCursor(.pen, rig, "red")
    }

    func testEveryToolCursorHasTheSameImageAndHotSpotAtEveryZoom() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.board.pointerOverride = windowPoint(rig.board, boardCentre(rig))
        for tool in [DrawTool.pen, .eraser, .text, .shape, .select] {
            rig.model.setTool(tool)
            rig.model.setViewport(DrawViewport(zoom: 1), byUser: false)
            spin(0.2)
            let reference = try XCTUnwrap(rig.board.cursor(atWindowPoint: rig.board.pointerOverride!))
            for zoom in [CGFloat(0.1), 0.25, 0.5, 1, 2, 4] {
                rig.model.setViewport(DrawViewport(zoom: zoom), byUser: false)
                spin(0.1)
                let cursor = try XCTUnwrap(rig.board.cursor(atWindowPoint: rig.board.pointerOverride!))
                XCTAssertEqual(cursor.image.size, reference.image.size, "\(tool) at \(zoom)")
                XCTAssertEqual(cursor.hotSpot, reference.hotSpot, "\(tool) at \(zoom)")
                XCTAssertEqual(cursor.image.tiffRepresentation, reference.image.tiffRepresentation, "\(tool) at \(zoom)")
            }
        }
    }

    func testReturningToDrawGivesTheBoardItsZoomShortcutsWithoutAnotherClick() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.uiState.selectSection(.tasks)
        spin(0.2)
        rig.model.magnify(by: -0.5, at: boardCentre(rig))
        rig.uiState.selectSection(.canvas)
        spin(0.3)
        XCTAssertTrue(rig.panel.firstResponder === rig.board,
                      "the shell clears old-page focus; the new Draw page must claim it")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rig.panel.windowNumber, context: nil, characters: ")",
            charactersIgnoringModifiers: ")", isARepeat: false, keyCode: DrawKey.zeroCode))
        rig.panel.sendEvent(event)
        XCTAssertEqual(rig.model.viewport.zoom, 1, accuracy: 0.001)
    }

    func testWorkspaceFocusChangeRefreshesTheRestingCursorAfterBackgroundPolicyRestoration() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.model.setTool(.eraser)
        rig.board.pointerOverride = windowPoint(rig.board, boardCentre(rig))
        spin(0.6)
        rig.board.refreshCursor()
        assertCursor(.eraser, rig, "before focus change")
        // A process activation change need not emit another AppKit active
        // notification. The policy repair must refresh a stationary pointer,
        // even when the last mouse-moved event preceded that repair.
        NSCursor.arrow.set()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                                                   object: nil)
        spin(0.2)
        assertCursor(.eraser, rig, "after workspace-only focus change")
    }

    func testTheCursorResetsOnExitAndWhenTheWindowHidesWithoutPointerMotion() throws {
        let rig = try makeRig()
        defer { close(rig) }
        let point = windowPoint(rig.board, boardCentre(rig))
        rig.board.pointerOverride = point
        rig.model.setTool(.pen)
        rig.board.refreshCursor()
        XCTAssertFalse(NSCursor.current === NSCursor.arrow)
        // Exit can arrive with the last in-bounds point when a view is clipped.
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: rig.panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        rig.board.mouseExited(with: exit)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "exit releases the board cursor immediately")
        rig.board.refreshCursor()
        XCTAssertFalse(NSCursor.current === NSCursor.arrow)
        rig.panel.orderOut(nil)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "hiding under a stationary pointer releases the cursor")
        spin(0.5)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "a queued refresh cannot restore a hidden cursor")
    }

    func testPenCursorHasSixPointColourAndAnOuterRingOnAnEightPointImage() throws {
        let colour = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!
        let cursor = DrawBoardView.penCursor(colour: colour)
        XCTAssertEqual(cursor.image.size, CGSize(width: 8, height: 8))
        XCTAssertEqual(cursor.hotSpot, CGPoint(x: 4, y: 4))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 20, y: 20)
        cursor.image.draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let red = try XCTUnwrap(bitmap.colorAt(x: 132, y: 80)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, 0.95)
        XCTAssertLessThan(red.greenComponent, 0.1, "2.6 pt from centre is inside the coloured dot")
        let ring = try XCTUnwrap(bitmap.colorAt(x: 146, y: 80)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(ring.greenComponent, 0.9, "3.3 pt from centre is the outside white ring")
        XCTAssertGreaterThan(ring.alphaComponent, 0.9)
    }

    func testPenCursorCacheDistinguishesColourSpacesWithTheSameComponents() {
        let components: [CGFloat] = [0.7, 0.3, 0.2, 1]
        let srgb = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
        let p3 = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: components)!
        XCTAssertFalse(DrawBoardView.penCursor(colour: srgb) === DrawBoardView.penCursor(colour: p3))
    }

    func testOffTheBoardTheCursorIsTheNormalOneAndHandlesWin() throws {
        let rig = try makeRig()
        defer { close(rig) }
        rig.model.setTool(.shape)
        rig.model.pointerDown(at: CGPoint(x: 80, y: 120))
        rig.model.pointerDragged(to: CGPoint(x: 180, y: 220))
        rig.model.pointerUp(at: CGPoint(x: 180, y: 220))
        let id = try XCTUnwrap(rig.model.objects.last?.id)
        rig.model.select([id])
        spin(0.2)
        let spot = try XCTUnwrap(rig.model.handleSpots.first { $0.handle == .bottomRight })
        rig.board.pointerOverride = windowPoint(rig.board, spot.point)
        NSCursor.operationNotAllowed.set()
        rig.model.setTool(.select)
        spin(0.2)
        XCTAssertTrue(NSCursor.current === DrawBoardView.cursor(for: .bottomRight), "the handle's cursor wins over its reach")
        // Over the tool bar: the normal cursor.
        rig.model.setTool(.pen)
        let bar = CGPoint(x: rig.model.clearInsets.left + 20, y: rig.model.boardSize.height - rig.model.clearInsets.bottom / 2)
        rig.board.pointerOverride = windowPoint(rig.board, bar)
        NSCursor.operationNotAllowed.set()
        rig.model.setTool(.eraser)
        spin(0.2)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow, "over the tool bar [\(rig.board.cursorLog.suffix(3).joined(separator: " | "))] (hit chain: \(hitChain(rig.panel, at: windowPoint(rig.board, bar))))")
    }

    // MARK: 4. The canvas menu's card

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func frame(of identifier: String, in rig: Rig) -> CGRect? {
        guard let content = rig.panel.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        guard let element = elements(content).first(where: { ($0.accessibilityIdentifier?() ?? "") == identifier }),
              let screen = element.accessibilityFrame?(), screen.width > 0 else { return nil }
        return rig.panel.convertFromScreen(screen)
    }

    func testTheMenuCardAndTitleFilterClearPinMoreAndSearchAtEveryWidth() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let widest = min(PanelContentSize.max, 640)
        for width in [PanelContentSize.standard.rawValue, PanelContentSize.extraLarge.rawValue, widest] {
            let rig = try makeRig(width: width)
            defer { close(rig) }
            rig.model.openFilter()
            spin(0.6)
            let card = try XCTUnwrap(frame(of: "draw-library-menu", in: rig), "\(width): the menu card")
            let field = try XCTUnwrap(frame(of: "draw-title-filter", in: rig), "\(width): the title filter")
            let title = try XCTUnwrap(frame(of: "draw-title-filter", in: rig), "\(width): the title capsule is the filter")
            for id in ["panel-pin-button", "panel-more-button", "draw-search-button"] {
                let control = try XCTUnwrap(frame(of: id, in: rig), "\(width): \(id)")
                XCTAssertFalse(card.intersects(control), "\(width): the card clears \(id) (\(card) / \(control))")
                XCTAssertFalse(field.intersects(control), "\(width): the field clears \(id)")
                XCTAssertLessThanOrEqual(card.maxY, control.minY + 0.5, "\(width): the card starts below the top row")
            }
            XCTAssertLessThanOrEqual(card.maxY, title.minY + 0.5, "\(width): below the title")
            XCTAssertFalse(card.intersects(field), "\(width): filtering stays in the title, above the card")
            XCTAssertNil(frame(of: "draw-library-search", in: rig), "D4 removes the duplicate search row")
            XCTAssertLessThanOrEqual(field.height, DrawPageMetrics.capsule + 1)
            XCTAssertEqual(card.midX, title.midX, accuracy: 1, "\(width): centred under the title")
        }
    }

    private func searchField(in rig: Rig) throws -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "draw-title-filter" { return field }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return try XCTUnwrap(rig.panel.contentView.flatMap(find), "the title's filter field")
    }

    func testTheTitleFilterReturnOpensAndNewCanvasStillWork() throws {
        try requireKeyWindowTests()
        let rig = try makeRig()
        defer { close(rig) }
        rig.panel.makeKeyAndOrderFront(nil)
        let model = rig.model
        for name in ["Alpha", "Beta"] {
            model.newCanvas(name: name)
            model.setTool(.pen)
            model.pointerDown(at: CGPoint(x: 60, y: 100))
            model.pointerDragged(to: CGPoint(x: 120, y: 150))
            model.pointerUp(at: CGPoint(x: 120, y: 150))
        }
        let alpha = try XCTUnwrap(model.library.rows.compactMap(\.canvas).first { $0.name == "Alpha" }?.id)
        model.open(alpha)
        model.openFilter()
        spin(0.4)
        let field = try searchField(in: rig)
        XCTAssertTrue(rig.panel.firstResponder === field.currentEditor(), "the field has the keyboard when the menu opens")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Bet", replacementRange: editor.selectedRange())
        spin(0.05)
        XCTAssertEqual(model.library.filter, "Bet", "typing filters")
        XCTAssertEqual(model.library.rows.compactMap(\.canvas).map(\.name), ["Beta"])
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(0.1)
        XCTAssertEqual(model.canvasName, "Beta", "Return opens the first match")
        XCTAssertFalse(model.isFiltering)
        // No match: Return makes New canvas "Gamma".
        model.openFilter()
        spin(0.4)
        let again = try XCTUnwrap(try searchField(in: rig).currentEditor() as? NSTextView)
        again.insertText("Gamma", replacementRange: again.selectedRange())
        spin(0.05)
        again.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(0.1)
        XCTAssertEqual(model.canvasName, "Gamma", "New canvas “Gamma”")
        // Escape closes it.
        model.openFilter()
        spin(0.4)
        let third = try XCTUnwrap(try searchField(in: rig).currentEditor() as? NSTextView)
        third.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin(0.1)
        XCTAssertFalse(model.isFiltering, "Escape closes the menu")
    }

    // MARK: 5. The open strips and the bar's ✦ (owner, 13 Nov)

    /// The tool capsule's width the ✦ reads is the width it lays out.
    func testTheCapsuleWidthMatchesTheToolBarForEveryStrip() throws {
        let model = DrawPageModel(store: DrawInMemoryStore())
        for strip: DrawStrip? in [nil, .pen, .text, .shape, .colour] {
            model.closeStrip()
            switch strip {
            case .colour?: model.clickSwatch()
            case .shape?: model.clickTool(.shape)
            case let widths?:
                let tool: DrawTool = widths == .pen ? .pen : .text
                model.setTool(tool)
                model.clickTool(tool)
            case nil: break
            }
            XCTAssertEqual(model.strip, strip)
            let host = NSHostingView(rootView: DrawToolBar(model: model).atticDesign(AtticDesignContext()))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, DrawPageMetrics.capsuleWidth(strip: strip), accuracy: 0.5, "\(String(describing: strip))")
        }
    }

    func testTheAgentStepsAsideOnlyWhenTheOpenStripWouldReachIt() {
        XCTAssertFalse(PanelSharedBottomBar.agentStepsAside(reach: nil, agentMinX: 10), "nothing open: it stays")
        XCTAssertFalse(PanelSharedBottomBar.agentStepsAside(reach: 200, agentMinX: .infinity), "not laid out yet")
        XCTAssertFalse(PanelSharedBottomBar.agentStepsAside(reach: 200, agentMinX: 200 + AtticPanelChromeMetrics.footerGap))
        XCTAssertTrue(PanelSharedBottomBar.agentStepsAside(reach: 200, agentMinX: 200 + AtticPanelChromeMetrics.footerGap - 0.5))
    }

    /// Every strip at the narrowest and widest panel: the capsule never runs
    /// under the ✦. Where it would, the ✦ steps aside (hidden from
    /// VoiceOver, no hits) and comes back when the strip shuts; where there
    /// is room, it stays. Esc from the capsule shuts the strip.
    func testOpenStripsNeverRunUnderTheAgentButton() throws {
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let widest = min(PanelContentSize.max, 640)
        for width in [PanelContentSize.standard.rawValue, widest] {
            let rig = try makeRig(width: width)
            defer { close(rig) }
            // The app connects before the panel shows; here the bar redraws
            // on a page change to pick the connection up.
            rig.uiState.agentChat.connect(StripTestRunner())
            rig.uiState.selectSection(.tasks)
            spin(0.5)
            rig.uiState.selectSection(.canvas)
            spin(0.8)
            let agent = try XCTUnwrap(frame(of: "agent-chat-button", in: rig), "\(width): the ✦ is on the bar")
            var steppedAside: [DrawStrip] = []
            for strip in [DrawStrip.pen, .text, .shape, .colour] {
                switch strip {
                case .colour: rig.model.clickSwatch()
                case .shape: rig.model.clickTool(.shape)
                case .pen, .text:
                    let tool: DrawTool = strip == .pen ? .pen : .text
                    rig.model.setTool(tool)
                    rig.model.clickTool(tool)
                }
                XCTAssertEqual(rig.model.strip, strip)
                spin(0.6)
                let bar = try XCTUnwrap(frame(of: "draw-tool-bar", in: rig), "\(width) \(strip): the capsule")
                XCTAssertEqual(bar.width, DrawPageMetrics.capsuleWidth(strip: strip), accuracy: 0.5)
                if let shown = frame(of: "agent-chat-button", in: rig) {
                    XCTAssertLessThanOrEqual(bar.maxX + AtticPanelChromeMetrics.footerGap, shown.minX + 0.5,
                                             "\(width) \(strip): the capsule stops short of the ✦")
                } else {
                    steppedAside.append(strip)
                    XCTAssertGreaterThan(bar.maxX + AtticPanelChromeMetrics.footerGap, agent.minX,
                                         "\(width) \(strip): the ✦ steps aside only when the strip would reach it")
                }
                rig.model.closeStrip()
                spin(0.6)
                XCTAssertNotNil(frame(of: "agent-chat-button", in: rig), "\(width) \(strip): the ✦ comes back as the strip shuts")
            }
            if width == widest {
                XCTAssertEqual(steppedAside, [], "the widest panel has room for every strip")
            } else {
                XCTAssertTrue(steppedAside.contains(.colour), "\(width): the colours reach the ✦ (\(steppedAside))")
            }
        }
    }

    func testTheMenusListRoomUsesTheSpaceRecoveredFromTheSearchRow() {
        let room = DrawPageMetrics.menuListRoom(boardHeight: 700, chromeTop: 15.5, chromeBottom: 15.5)
        XCTAssertEqual(room, 700 - 15.5 - DrawPageMetrics.capsule - DrawPageMetrics.menuGap - 15.5
                       - AtticGlassMenuShape.inset * 2 + DrawPageMetrics.bottomGrace, accuracy: 0.01,
                       "D4 keeps both card insets and gives the old search row's height to the list")
    }
}

/// A connected runner that never runs: the ✦ only needs a connection.
@MainActor
private final class StripTestRunner: AgentRunning {
    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func setWatching(_ watching: Bool) {}
    func setMode(_ mode: AgentChatMode) {}
    func resolve(approval id: UUID, allow: Bool) {}
    func undo(changeSet id: UUID) async throws {}
    func cancel() {}
    func observe() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func threadSnapshot() -> AgentThreadSnapshot { AgentThreadSnapshot(entries: [], events: [], isRunning: false) }
    var retainsThread: Bool { false }
    func forgetThread() {}
    func chats() -> [AgentChatSummary] { [] }
    func reopen(chat id: UUID) -> Bool { false }
}
