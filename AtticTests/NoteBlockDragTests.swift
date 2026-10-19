import AppKit
import XCTest
@testable import Attic

/// DG1: a block drag (⋮⋮) feels like a native list reorder. The card
/// follows the pointer one to one above the page's controls, the drop
/// slot comes from block frames measured once, Esc cancels, and a drop is
/// one move and one Undo step.
@MainActor
final class NoteBlockDragTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var engines: [NoteEditorEngine] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows.removeAll()
        engines.removeAll()
        super.tearDown()
    }

    private func editor(_ blocks: [NoteBlock], height: CGFloat = 400) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        engines.append(engine)
        let (scroll, text) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: height)
        text.textContainerInset = CGSize(width: 28, height: 8)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(text)
        windows.append(window)
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        text.layoutSubtreeIfNeeded()
        return (engine, text)
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func escape(in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: view.window!.windowNumber, context: nil, characters: "\u{1b}",
                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    private var blocks: [NoteBlock] {
        [.text("Title"), .text("Alpha"), .text("Bravo"), .text("Charlie"), .text("Delta"), .text("Echo")]
    }

    // MARK: Slots

    func testTheSlotIsTheBlockHalfUnderThePointerWithHysteresis() {
        func block(_ y: CGFloat, _ index: Int) -> NoteBlockDropSlots.Block {
            let slot = { (location: Int) in
                NoteBlockDropSlots.Slot(position: NoteBlockDropPosition(location: location, depth: 0),
                                        line: CGRect(x: 0, y: CGFloat(location), width: 10, height: 2))
            }
            return .init(range: NSRange(location: index * 10, length: 10), rect: CGRect(x: 0, y: y, width: 100, height: 20),
                         before: slot(index * 10), after: slot(index * 10 + 10))
        }
        let slots = NoteBlockDropSlots(blocks: [block(0, 0), block(30, 1), block(60, 2)])
        typealias C = NoteBlockDropSlots.Choice
        XCTAssertEqual(slots.choice(atY: -50, current: nil), C(index: 0, after: false), "above the first block")
        XCTAssertEqual(slots.choice(atY: 5, current: nil), C(index: 0, after: false))
        XCTAssertEqual(slots.choice(atY: 15, current: nil), C(index: 0, after: true))
        XCTAssertEqual(slots.choice(atY: 24, current: nil), C(index: 0, after: true), "the gap's upper half")
        XCTAssertEqual(slots.choice(atY: 26, current: nil), C(index: 1, after: false), "the gap's lower half")
        XCTAssertEqual(slots.choice(atY: 500, current: nil), C(index: 2, after: true), "below the last block")
        // On the boundary the choice holds until the pointer is clearly past it.
        XCTAssertEqual(slots.choice(atY: 42, current: C(index: 1, after: false)), C(index: 1, after: false))
        XCTAssertEqual(slots.choice(atY: 38, current: C(index: 1, after: true)), C(index: 1, after: true))
        XCTAssertEqual(slots.choice(atY: 45, current: C(index: 1, after: false)), C(index: 1, after: true))
        XCTAssertEqual(slots.slot(for: C(index: 1, after: true))?.position.location, 20)
    }

    func testSlotsAreMeasuredOnceAndOnlyOfferDropsTheMoveAccepts() throws {
        let (engine, text) = editor(blocks)
        let source = engine.blockRange(at: location(of: "Charlie", in: engine))
        let slots = text.blockDropSlots(moving: source)
        let names = slots.blocks.map { (engine.textStorage.string as NSString).substring(with: $0.range)
            .trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        XCTAssertEqual(names, ["Alpha", "Bravo", "Charlie", "Delta", "Echo"], "every block below the title, top to bottom")
        XCTAssertEqual(slots.blocks.map(\.rect.minY), slots.blocks.map(\.rect.minY).sorted())
        let charlie = try XCTUnwrap(slots.blocks.first { $0.range == source })
        XCTAssertNil(charlie.before, "no move over its own place")
        XCTAssertNil(charlie.after)
        let bravo = try XCTUnwrap(slots.blocks.first { $0.range.location == location(of: "Bravo", in: engine) })
        XCTAssertNil(bravo.after, "right above its own place is no move")
        XCTAssertNotNil(bravo.before)
        let alpha = try XCTUnwrap(slots.blocks.first)
        XCTAssertNil(alpha.before, "the first block below the title keeps its place (moveBlock's rule)")
        for block in slots.blocks {
            for slot in [block.before, block.after].compactMap({ $0 }) {
                let undo = engine.textStorage.string
                XCTAssertTrue(engine.moveBlock(source, to: slot.position.location), "\(slot.position)")
                XCTAssertTrue(engine.history.undo())
                XCTAssertEqual(engine.textStorage.string, undo)
            }
        }
    }

    // MARK: The drag

    /// Drags the handle of `block` by `path` (text-view offsets from the
    /// press), calling `during` mid-drag, then `finish` (a release or Esc).
    private func drag(_ text: NoteEditorTextView, block: Int, path: [CGFloat], escape cancel: Bool = false,
                      during: @escaping (NoteBlockDragSession?) -> Void = { _ in }) {
        text.showBlockHandle(forBlockAt: block)
        let handle = text.blockHandle
        let start = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
        for dy in path {
            NSApp.postEvent(event(.leftMouseDragged, point: CGPoint(x: start.x, y: start.y + dy), in: text), atStart: false)
        }
        nonisolated(unsafe) let release = event(.leftMouseUp, point: CGPoint(x: start.x, y: start.y + (path.last ?? 0)), in: text)
        nonisolated(unsafe) let esc = escape(in: text)
        let midway = Timer(timeInterval: 0.15, repeats: false) { [weak text] _ in
            MainActor.assumeIsolated {
                during(text?.lastBlockDrag)
                if cancel { NSApp.postEvent(esc, atStart: false) }
                NSApp.postEvent(release, atStart: false)
            }
        }
        RunLoop.current.add(midway, forMode: .common)
        handle.mouseDown(with: event(.leftMouseDown, point: start, in: text))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testTheCardFollowsThePointerOneToOneAboveThePage() throws {
        let (engine, text) = editor(blocks)
        let source = location(of: "Bravo", in: engine)
        var followed: CGFloat?
        var lifted: CGFloat?
        var onTop = false
        var target: Int?
        let echo = location(of: "Echo", in: engine)
        let travel = (text.rect(ofBlock: engine.blockRange(at: echo))?.midY ?? 0) - (text.rect(ofBlock: engine.blockRange(at: source))?.midY ?? 0)
        drag(text, block: source, path: [6, travel / 2, travel + 4]) { session in
            guard let session else { return }
            let stage = session.stage
            onTop = stage.superview?.subviews.last === stage
            lifted = text.convert(text.rect(ofBlock: session.source)!, to: nil).maxY
            followed = stage.convert(stage.cardFrame, to: nil).maxY
            target = session.target?.location
        }
        // Window y runs up: dragging down the note lowers the card by the
        // same distance (the 4 pt card padding aside).
        let moved = try XCTUnwrap(lifted) - (try XCTUnwrap(followed))
        XCTAssertEqual(moved, travel + 4 - 4, accuracy: 1.5, "the card moved with the pointer, not to a slot")
        XCTAssertTrue(onTop, "the card is the overlay's top view, above every floating control")
        XCTAssertEqual(target, NSMaxRange(engine.blockRange(at: echo)), "over Echo's lower half: after Echo")
        XCTAssertEqual(engine.textStorage.string.components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["Title", "Alpha", "Charlie", "Delta", "Echo", "Bravo"], "dropped after Echo")
        XCTAssertTrue(engine.history.undo(), "one Undo step")
        XCTAssertEqual(engine.textStorage.string.components(separatedBy: "\n").filter { !$0.isEmpty },
                       ["Title", "Alpha", "Bravo", "Charlie", "Delta", "Echo"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(text.lastBlockDrag?.stage.superview, "the card is gone after it lands")
    }

    func testEscapeCancelsABlockDragAndTheCardGoesHome() throws {
        let (engine, text) = editor(blocks)
        let before = engine.textStorage.string
        var shown = false
        drag(text, block: location(of: "Bravo", in: engine), path: [6, 40, 60], escape: true) { session in
            shown = session?.stage.superview != nil && session?.target != nil && !text.dropLine.isHidden
        }
        XCTAssertTrue(shown, "mid-drag: a card and a drop line")
        XCTAssertEqual(engine.textStorage.string, before, "Esc: nothing moved")
        XCTAssertTrue(text.dropLine.isHidden)
        XCTAssertFalse(engine.history.undo(), "no Undo step")
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(text.lastBlockDrag?.stage.superview, "the card went home and away")
    }

    func testAPageSwitchMidDragCancelsIt() throws {
        let (engine, text) = editor(blocks)
        let before = engine.textStorage.string
        drag(text, block: location(of: "Bravo", in: engine), path: [6, 40, 60]) { _ in AtticDragTracking.cancelAll() }
        while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) != nil {}
        XCTAssertEqual(engine.textStorage.string, before)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(text.lastBlockDrag?.stage.superview)
    }
}
