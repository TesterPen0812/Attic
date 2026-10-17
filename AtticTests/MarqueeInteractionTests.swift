import AppKit
import XCTest
@testable import Attic

@MainActor
final class MarqueeInteractionTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var engines: [NoteEditorEngine] = []
    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        engines = []
        try await super.tearDown()
    }

    private func editor(_ blocks: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView, NoteMarqueeSelection) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        engines.append(engine)
        let (scroll, text) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 250)
        text.textContainerInset = CGSize(width: 24, height: 8)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeFirstResponder(text)
        window.contentView?.layoutSubtreeIfNeeded()
        windows.append(window)
        return (engine, text, text.marquee!)
    }

    private func event(_ type: NSEvent.EventType, point: CGPoint, in view: NSView,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func testOverlayAboveTheDocumentKeepsItsClick() throws {
        let (_, text, selection) = editor([.text("Title"), .text("Body")])
        let controller = try XCTUnwrap(selection.controller)
        let window = try XCTUnwrap(text.window)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let root = NSView(frame: scroll.frame)
        window.contentView = root
        root.addSubview(scroll)
        let card = NSView(frame: CGRect(x: 0, y: 20, width: 120, height: 60))
        // Standalone SwiftUI dropdowns are siblings of the content view,
        // matching AtticDropdownSpace's supported overlay placement.
        let parent = try XCTUnwrap(root.superview)
        card.frame = parent.convert(card.frame, from: root)
        parent.addSubview(card)
        var pressed = false
        controller.press = { _, _ in pressed = true; return .select }
        let click = event(.leftMouseDown, point: CGPoint(x: 60, y: 30), in: card)
        XCTAssertTrue(controller.handle(click) === click, "an overlay receives its native click")
        XCTAssertFalse(pressed, "overlay coordinates are never document whitespace")
    }

    func testTasksEscapeReachesThePageBeforeClearingSelection() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Selected"))
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.selectOnly(task.id)
        model.setExpanded(task.id, true)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = FlippedView(frame: scroll.bounds)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        XCTAssertTrue(window.makeFirstResponder(document))
        XCTAssertIdentical(window.firstResponder, document)
        let pointer = TasksPointer()
        pointer.view = document
        let adapter = TasksMarqueeSelection(scroll: scroll, model: model, pointer: pointer, tab: .now)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(adapter.controller.handle(escape) === escape, "Tasks owns its close-before-clear Escape chain")
        XCTAssertEqual(model.selection, [task.id])
        XCTAssertTrue(model.expanded.contains(task.id))
    }

    func testCompletedTodayDisclosureKeepsItsNativeClickInListWhitespace() throws {
        let store = try makeTestStore()
        let task = try XCTUnwrap(store.create(title: "Selected"))
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.selectOnly(task.id)
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = FlippedView(frame: scroll.bounds)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        let pointer = TasksPointer()
        pointer.view = document
        pointer.frames[TasksRowID(tab: .now, id: task.id)] = CGRect(x: 0, y: 20, width: 320, height: 40)
        pointer.completedTodayFrames[.now] = CGRect(x: 12, y: 80, width: 296, height: 28)
        let adapter = TasksMarqueeSelection(scroll: scroll, model: model, pointer: pointer, tab: .now)
        let click = event(.leftMouseDown, point: CGPoint(x: 140, y: 94), in: document)
        XCTAssertTrue(adapter.controller.handle(click) === click, "the disclosure owns its native click")
        XCTAssertEqual(model.selection, [task.id], "the press never starts an empty-space marquee")
        let blank = event(.leftMouseDown, point: CGPoint(x: 140, y: 160), in: document)
        XCTAssertNil(adapter.controller.handle(blank), "genuine whitespace still starts a marquee")
    }

    func testR12GeometryTracksFoldAndUnfoldBeforeDeletingTheHitBlock() throws {
        for initiallyFolded in [false, true] {
            var heading = NoteBlock.text("A", style: "heading")
            heading.level = 2
            let (engine, text, selection) = editor([.text("Title"), heading, .text("a1"),
                .text("B", style: "heading"), .text("Q")])
            if initiallyFolded { XCTAssertTrue(engine.toggleHeadingFold(at: 6)) }
            _ = selection.items() // Cache the old layout.
            XCTAssertTrue(engine.toggleHeadingFold(at: 6))
            let target = initiallyFolded ? 8 : 11 // Revealed a1, or visible B after folding A.
            let ink = try XCTUnwrap(engine.rect(for: engine.lineRange(at: target)))
            let hit = try XCTUnwrap(selection.items().first { $0.rect.minY <= ink.midY && $0.rect.maxY > ink.midY })
            selection.select(offsets: [try XCTUnwrap(hit.id.base as? Int)])
            try r12Capture(text, name: initiallyFolded ? "unfold-hit.png" : "fold-hit.png")
            XCTAssertEqual(selection.ranges, [engine.paragraphRange(at: target)])
            XCTAssertTrue(selection.delete())
            XCTAssertEqual(engine.document().blocks.map(\.text), initiallyFolded ? ["Title", "A", "B", "Q"] : ["Title", "A", "a1", "Q"])
        }
    }

    func testR12FoldedMarqueeCopiesMovesAndDeletesTheWholeSection() throws {
        for command in ["copy", "move", "delete"] {
            var heading = NoteBlock.text("A", style: "heading")
            heading.level = 2
            let (engine, _, selection) = editor([.text("Title"), heading, .text("a1"),
                .text("B", style: "heading"), .text("b1")])
            XCTAssertTrue(engine.toggleHeadingFold(at: 6))
            let original = engine.document()
            XCTAssertFalse(selection.items().contains { $0.id == AnyHashable(8) }, "hidden body has no hit target")
            selection.select(offsets: [6])
            XCTAssertEqual(selection.ranges, [NSRange(location: 6, length: 5)])
            if command == "copy" {
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                XCTAssertTrue(selection.copy(to: board))
                let data = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
                let copied = try XCTUnwrap(NoteContentCodec.decode(data, context: .fragment).document)
                XCTAssertEqual(copied.blocks.map(\.text), ["A", "a1", ""], "the copied section includes its paragraph separator")
            } else {
                XCTAssertTrue(command == "move" ? selection.move(to: engine.textStorage.length) : selection.delete())
                XCTAssertEqual(engine.document().blocks.map(\.text), command == "move" ? ["Title", "B", "b1", "A", "a1"] : ["Title", "B", "b1"])
                XCTAssertTrue(engine.undoCommand())
                XCTAssertEqual(engine.document(), original, command)
                XCTAssertTrue(engine.isRangeFolded(NSRange(location: 8, length: 2)), command)
            }
        }
    }

    func testR12MarginPressKeepsFiveThousandLinesLazilyLaidOut() throws {
        let (engine, text, selection) = editor([.text("Title")] + (0..<5_000).map { .text("Line \($0)") })
        let layout = try XCTUnwrap(engine.layoutManager)
        func laidOut() -> Int {
            var count = 0
            layout.enumerateTextLayoutFragments(from: engine.contentStorage.documentRange.location, options: []) { fragment in
                if fragment.state == .layoutAvailable { count += 1 }
                return true
            }
            return count
        }
        let before = laidOut()
        var passes = 0
        text.onLayout = { passes += 1 }
        let point = CGPoint(x: 4, y: 70)
        let start = DispatchTime.now().uptimeNanoseconds
        let press = try XCTUnwrap(selection.controller).press(point, event(.leftMouseDown, point: point, in: text))
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let after = laidOut()
        print("R12_MARGIN lines=5000 before=\(before) after=\(after) noteDidLayoutPasses=\(passes) ms=\(milliseconds)")
        XCTAssertEqual(press, .select)
        XCTAssertLessThan(after, 5_000, "one margin press must not lay out the whole note")
        XCTAssertLessThan(selection.items().count, 5_000, "only visible blocks receive hit targets")
    }

    func testR12PreDrawLayoutChangeRefreshesMarqueeWithoutATextEdit() throws {
        let (engine, text, selection) = editor([.text("Title"),
            .text("A long body paragraph that wraps differently when the column gets narrower."), .text("After")])
        let after = (engine.textStorage.string as NSString).range(of: "After")
        let old = try XCTUnwrap(selection.items().first { $0.id == AnyHashable(after.location) })
        let container = try XCTUnwrap(text.textContainer)
        container.widthTracksTextView = false
        container.size.width = 140
        engine.invalidateLayout(NSRange(location: 0, length: engine.textStorage.length))
        // Lay the whole note out first: TextKit only estimates an invalidated
        // paragraph's height, and with natural line boxes (O18-03) that
        // estimate no longer happens to move "After" down by itself.
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let ink = try XCTUnwrap(engine.rect(for: after))
        text.viewWillDraw() // TextKit's pre-draw layout path, with unchanged view bounds.
        let refreshed = try XCTUnwrap(selection.items().first { $0.id == AnyHashable(after.location) })
        XCTAssertGreaterThan(ink.minY, old.rect.minY)
        XCTAssertEqual(refreshed.rect.minY, ink.minY, accuracy: 1)
    }

    func testR12MarqueeKeepsVisitedBlocksSelectedWhileTheViewportScrolls() throws {
        let (engine, text, selection) = editor([.text("Title")] + (0..<80).map { .text("Line \($0)") })
        let controller = try XCTUnwrap(selection.controller)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let first = try XCTUnwrap(selection.items().first { $0.id == AnyHashable(6) })
        let down = CGPoint(x: 4, y: first.rect.midY)
        _ = controller.handle(event(.leftMouseDown, point: down, in: text))
        _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 30, y: 200), in: text))
        for y in stride(from: 120, through: 480, by: 120) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            engine.layoutManager?.textViewportLayoutController.layoutViewport()
            text.layoutSubtreeIfNeeded()
            _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 30, y: CGFloat(y) + 200), in: text))
            XCTAssertEqual(selection.ranges.first?.location, 6, "scrolling keeps the starting block")
        }
        XCTAssertGreaterThan(selection.ranges.count, 20)
        let last = CGPoint(x: 30, y: 680)
        _ = controller.handle(event(.leftMouseUp, point: last, in: text))
        XCTAssertEqual(selection.ranges.first?.location, 6)
    }

    func testThresholdReverseDirectionAndTouchingEdges() {
        XCTAssertFalse(MarqueeGeometry.activated(from: .zero, to: CGPoint(x: 0, y: 3.99)))
        XCTAssertTrue(MarqueeGeometry.activated(from: .zero, to: CGPoint(x: 0, y: 4)))
        XCTAssertEqual(MarqueeGeometry.box(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 5, y: 10)),
                       CGRect(x: 5, y: 10, width: 15, height: 30))
        XCTAssertTrue(MarqueeGeometry.touches(CGRect(x: 0, y: 0, width: 10, height: 10),
                                            CGRect(x: 10, y: 10, width: 20, height: 20)))
    }

    func testAutoScrollIsSymmetricAcceleratesAndClampsAtDocumentEnds() {
        let viewport = CGRect(x: 0, y: 100, width: 300, height: 400)
        XCTAssertEqual(MarqueeGeometry.scrollVelocity(pointerY: 124, viewport: viewport), 0)
        XCTAssertEqual(MarqueeGeometry.scrollVelocity(pointerY: 476, viewport: viewport), 0)
        let top = MarqueeGeometry.scrollVelocity(pointerY: 100, viewport: viewport)
        let bottom = MarqueeGeometry.scrollVelocity(pointerY: 500, viewport: viewport)
        XCTAssertEqual(top, -bottom)
        XCTAssertGreaterThan(MarqueeGeometry.scrollVelocity(pointerY: 520, viewport: viewport), bottom)
        XCTAssertEqual(MarqueeGeometry.scrollOrigin(current: 10, velocity: -600, seconds: 0.1, minimum: 0, maximum: 500), 0)
        XCTAssertEqual(MarqueeGeometry.scrollOrigin(current: 490, velocity: 600, seconds: 0.1, minimum: 0, maximum: 500), 500)
        let one = MarqueeGeometry.scrollOrigin(current: 100, velocity: 300, seconds: 1.0 / 60, minimum: 0, maximum: 500)
        let half = MarqueeGeometry.scrollOrigin(current: 100, velocity: 300, seconds: 1.0 / 120, minimum: 0, maximum: 500)
        XCTAssertEqual(one - 100, 2 * (half - 100), accuracy: 0.001)
    }

    func testMarginClickStaysACaretThenDragSelectsWholeBlocksAndShiftAdds() throws {
        let (_, text, selection) = editor([.text("Title"), .text("Alpha"), .text("Beta"), .text("Gamma")])
        let items = selection.items()
        XCTAssertEqual(items.count, 4)
        let alpha = items[1].rect
        let start = CGPoint(x: 4, y: alpha.midY)
        let controller = try XCTUnwrap(selection.controller)
        XCTAssertNil(controller.handle(event(.leftMouseDown, point: start, in: text)))
        XCTAssertNil(controller.handle(event(.leftMouseDragged, point: CGPoint(x: 7, y: alpha.midY), in: text)))
        XCTAssertNil(controller.box)
        XCTAssertNil(controller.handle(event(.leftMouseUp, point: start, in: text)))
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(text.selectedRange().length, 0)
        _ = controller.handle(event(.leftMouseDown, point: start, in: text))
        _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 80, y: items[2].rect.midY), in: text))
        XCTAssertEqual(selection.ranges.map(\.location), [items[1].id.base as! Int, items[2].id.base as! Int])
        XCTAssertEqual(text.accessibilitySelectedTextRanges()?.map(\.rangeValue), selection.ranges)
        XCTAssertTrue(text.accessibilitySelectedText()?.contains("Beta") == true)
        XCTAssertFalse(text.shouldDrawInsertionPoint)
        _ = controller.handle(event(.leftMouseUp, point: CGPoint(x: 80, y: items[2].rect.midY), in: text))
        let gammaStart = CGPoint(x: 4, y: items[3].rect.midY)
        _ = controller.handle(event(.leftMouseDown, point: gammaStart, in: text, flags: .shift))
        _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 80, y: gammaStart.y), in: text, flags: .shift))
        XCTAssertEqual(selection.ranges.count, 3)
        _ = controller.handle(event(.leftMouseUp, point: CGPoint(x: 80, y: gammaStart.y), in: text, flags: .shift))
        selection.clear()
        XCTAssertTrue(selection.isEmpty)
    }

    /// V-04 (recording 1937): a margin marquee over a code block, a table
    /// and a diagram selects them live, as it covers them, and the box is
    /// gone the moment the button comes up. The tint is the system's
    /// accent, so it shows on blocks that have their own fill.
    func testV04MarqueeSelectsBoxedBlocksLiveAndItsBoxGoesOnRelease() throws {
        let table = NoteBlock.table(NoteTable(texts: [["Name", "Value"], ["Alpha", "One"]]))
        let (engine, text, selection) = editor([.text("Title"), .text("let x = 1", style: "mono"), table,
                                                .text("flowchart LR", style: "mono"), .text("End")])
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        text.layoutSubtreeIfNeeded()
        let items = selection.items()
        let controller = try XCTUnwrap(selection.controller)
        let last = try XCTUnwrap(items.last)
        let start = CGPoint(x: 4, y: min(last.rect.maxY, text.visibleRect.maxY) - 4)
        _ = controller.handle(event(.leftMouseDown, point: start, in: text))
        let second = items[1].rect
        _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 120, y: second.midY), in: text))
        XCTAssertNotNil(controller.box, "the box shows while dragging")
        let selected = Set(selection.ranges.map(\.location))
        for item in items.dropFirst() {
            XCTAssertTrue(selected.contains(item.id.base as! Int), "block at \(item.id) highlights as the box covers it")
        }
        XCTAssertEqual(controller.highlightInk(), .controlAccentColor)
        _ = controller.handle(event(.leftMouseUp, point: CGPoint(x: 120, y: second.midY), in: text))
        XCTAssertNil(controller.box, "the box is gone the moment the drag ends")
        XCTAssertFalse(controller.isDragging)
        XCTAssertEqual(Set(selection.ranges.map(\.location)), selected, "the blocks stay selected")
    }

    /// V-04: hover UI (the page button's switcher) never opens while a mouse
    /// button is down.
    func testV04HoverUIOpensOnlyWithNoButtonDown() {
        XCTAssertTrue(AtticHoverGate.opens(pressedButtons: 0))
        XCTAssertFalse(AtticHoverGate.opens(pressedButtons: 1), "a drag passing over it")
        XCTAssertFalse(AtticHoverGate.opens(pressedButtons: 2))
    }

    /// V-06 (recording 1937): a block dragged by its handle lifts onto a
    /// card with a backing (no text shows through it), and its own place
    /// dims until the drop, then draws as before.
    func testV06ABlockDragLiftsOntoABackedCardAndDimsItsPlace() throws {
        let table = NoteBlock.table(NoteTable(texts: [["Name", "Value"], ["Alpha", "One"]]))
        let (engine, text, _) = editor([.text("Title"), .text("A quote", style: "quote"), table, .text("End")])
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        text.layoutSubtreeIfNeeded()
        let quote = engine.blockRange(at: (engine.textStorage.string as NSString).range(of: "A quote").location)
        let rect = try XCTUnwrap(engine.rect(for: quote))
        let card = NoteDragLiftView(snapshot: NoteDragLiftView.snapshot(of: rect, in: text), size: rect.size,
                                    padding: CGSize(width: 6, height: 4), tokens: engine.style.tokens)
        let fill = try XCTUnwrap(card.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        XCTAssertGreaterThan(fill.alphaComponent, 0.85, "an opaque backing: the text under the card never shows through")
        XCTAssertNotNil((card.layer?.sublayers?.first)?.contents, "the block's snapshot")
        XCTAssertEqual(card.frame.size, CGSize(width: rect.width + 12, height: rect.height + 8))

        let dim = NoteBlockDragDim(textView: text, block: quote, rect: rect)
        XCTAssertEqual(text.dragDimRange, quote, "its place dims while it is lifted")
        dim.restore()
        XCTAssertNil(text.dragDimRange)

        // A table block dims through its hosted view.
        let tableLocation = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first?.hostedView)
        let tableRect = text.convert(tableLocation.bounds, from: tableLocation)
        let tableDim = NoteBlockDragDim(textView: text, block: engine.blockRange(at: quote.location + quote.length), rect: tableRect.insetBy(dx: -2, dy: -2))
        XCTAssertEqual(tableLocation.alphaValue, NoteBlockDragDim.viewOpacity, accuracy: 0.01)
        tableDim.restore()
        XCTAssertEqual(tableLocation.alphaValue, 1)
    }

    func testDiscontiguousDeleteAndUndoPreserveUnselectedBlocksAndMarks() throws {
        let (engine, _, selection) = editor([.text("Title"), .text("Alpha", style: "quote"), .text("Beta"), .checklist("Gamma")])
        let original = engine.document()
        let items = selection.items()
        selection.select(offsets: [items[1].id.base as! Int, items[3].id.base as! Int])
        XCTAssertTrue(selection.delete())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Beta"])
        XCTAssertFalse(engine.textStorage.string.contains("Alpha"))
        XCTAssertFalse(engine.textStorage.string.contains("Gamma"))
        XCTAssertTrue(engine.undoCommand())
        XCTAssertEqual(engine.document(), original)
        XCTAssertFalse(engine.history.canUndo)
        XCTAssertTrue(engine.redoCommand())
        XCTAssertFalse(engine.textStorage.string.contains("Alpha"))
    }

    func testDiscontiguousCopyAndMoveKeepRichPayloadAndOneUndo() throws {
        let (engine, _, selection) = editor([.text("Title"), .text("Alpha", style: "quote"), .text("Beta"), .checklist("Gamma"), .text("End")])
        let original = engine.document()
        let items = selection.items()
        selection.select(offsets: [items[1].id.base as! Int, items[3].id.base as! Int])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(selection.copy(to: board))
        let rich = try NSAttributedString(data: XCTUnwrap(board.data(forType: .rtf)),
            options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(rich.string.contains("Alpha"))
        XCTAssertTrue(rich.string.contains("Gamma"))
        XCTAssertFalse(rich.string.contains("Beta"))
        let markdown = try XCTUnwrap(board.string(forType: TasksTextExport.markdownType))
        XCTAssertTrue(markdown.contains("> Alpha"))
        XCTAssertTrue(markdown.contains("- [ ] Gamma"))
        XCTAssertFalse(markdown.contains("Beta"))
        XCTAssertTrue(selection.move(to: engine.textStorage.length))
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Beta", "End", "Alpha", "Gamma"])
        XCTAssertTrue(engine.undoCommand())
        XCTAssertEqual(engine.document(), original)
        XCTAssertFalse(engine.history.canUndo)
    }

    func testObjectBlocksRemainWhole() {
        let (engine, _, selection) = editor([.text("Title"), .divider(), .checklist("One"), .text("End")])
        let original = engine.document()
        let items = selection.items()
        selection.select(offsets: [items[1].id.base as! Int, items[2].id.base as! Int])
        XCTAssertTrue(selection.delete())
        XCTAssertTrue(engine.undoCommand())
        XCTAssertEqual(engine.document(), original)
    }

    func testTableAndFileSelectionCopyAndMovePreserveObjectIdentity() throws {
        let table = NoteBlock.table(NoteTable(texts: [["Name", "Value"], ["Alpha", "One"]]))
        let file = NoteBlock.file(attachmentID: UUID(), filename: "Brief.pdf", contentTypeIdentifier: "com.adobe.pdf", byteCount: 123)
        let (engine, _, selection) = editor([.text("Title"), table, file, .text("End")])
        let original = engine.document()
        let items = selection.items()
        selection.select(offsets: [items[1].id.base as! Int, items[2].id.base as! Int])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(selection.copy(to: board))
        let payload = try XCTUnwrap(board.data(forType: NoteEditorEngine.fragmentType))
        let copied = try XCTUnwrap(NoteContentCodec.decode(payload, context: .fragment).document)
        XCTAssertEqual(copied.blocks.first { $0.kind == .table }?.table, table.table)
        XCTAssertEqual(copied.blocks.first { $0.kind == .file }?.attachmentID, file.attachmentID)
        XCTAssertTrue(try XCTUnwrap(board.string(forType: TasksTextExport.markdownType)).contains("Alpha"))
        XCTAssertTrue(selection.move(to: engine.textStorage.length))
        XCTAssertEqual(engine.document().blocks.first { $0.kind == .table }?.id, table.id)
        XCTAssertEqual(engine.document().blocks.first { $0.kind == .file }?.attachmentID, file.attachmentID)
        XCTAssertTrue(engine.undoCommand())
        XCTAssertEqual(engine.document(), original)
    }

    func testReadOnlyBlockSelectionCopiesButDoesNotDelete() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]), readOnly: true)
        let (_, text) = engine.makeView()
        let selection = try XCTUnwrap(text.marquee)
        selection.select(offsets: [6])
        XCTAssertFalse(selection.delete())
        XCTAssertFalse(selection.move(to: 0))
        XCTAssertEqual(engine.textStorage.string, "Title\nBody")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(selection.copy(to: board))
    }

    func testBlockSelectionHidesModernInsertionIndicatorAndClearingRestoresIt() {
        let (_, text, selection) = editor([.text("Title"), .text("Body")])
        for mode: NSTextInsertionIndicator.DisplayMode in [.automatic, .visible, .hidden] {
            let indicator = NSTextInsertionIndicator(frame: CGRect(x: 24, y: 50, width: 1, height: 18))
            text.addSubview(indicator)
            indicator.displayMode = mode
            selection.select(offsets: [6])
            text.caretVisibility.refresh()
            XCTAssertEqual(indicator.displayMode, .hidden)
            selection.clear()
            XCTAssertEqual(indicator.displayMode, mode)
            indicator.removeFromSuperview()
        }
    }

    func testR12TextChangeClearsBlockSelectionAndRestoresTheCaretWithoutAManualRefresh() {
        let (_, text, selection) = editor([.text("Title"), .text("Body")])
        let indicator = NSTextInsertionIndicator(frame: CGRect(x: 24, y: 50, width: 1, height: 18))
        text.addSubview(indicator)
        indicator.displayMode = .visible
        selection.select(offsets: [6])
        XCTAssertEqual(indicator.displayMode, .hidden)
        selection.textChanged()
        XCTAssertTrue(selection.isEmpty)
        XCTAssertEqual(indicator.displayMode, .visible)
    }

    func testTasksMarginSelectionUsesExistingBatchCommandsAndLeavesRowGrabsAlone() throws {
        let store = try makeTestStore()
        let first = try XCTUnwrap(store.create(title: "First"))
        let second = try XCTUnwrap(store.create(title: "Second"))
        let third = try XCTUnwrap(store.create(title: "Third"))
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        let pointer = TasksPointer()
        pointer.view = document
        for (index, id) in [first.id, second.id, third.id].enumerated() {
            pointer.frames[TasksRowID(tab: .now, id: id)] = CGRect(x: 0, y: 20 + index * 40, width: 320, height: 40)
        }
        var focus: UUID?
        let adapter = TasksMarqueeSelection(scroll: scroll, model: model, pointer: pointer, tab: .now,
            focusSelection: { focus = $0 })
        let controller = adapter.controller
        let grab = event(.leftMouseDown, point: CGPoint(x: 100, y: 35), in: document)
        XCTAssertTrue(controller.handle(grab) === grab, "row grab retains reorder")
        _ = controller.handle(event(.leftMouseDown, point: CGPoint(x: 2, y: 30), in: document))
        _ = controller.handle(event(.leftMouseDragged, point: CGPoint(x: 150, y: 80), in: document))
        XCTAssertNil(focus, "no focus handoff during the drag")
        _ = controller.handle(event(.leftMouseUp, point: CGPoint(x: 150, y: 80), in: document))
        XCTAssertEqual(focus, second.id, "the row at release owns the existing native keyboard commands")
        XCTAssertEqual(model.selection, [first.id, second.id])
        XCTAssertEqual(Set(model.targets(for: first.id)), model.selection)
        XCTAssertTrue(model.toggleDone(model.orderedSelection()).isApplied)
        XCTAssertEqual(store.task(withID: first.id)?.status, .done)
        XCTAssertEqual(store.task(withID: second.id)?.status, .done)
        XCTAssertEqual(store.task(withID: third.id)?.status, .todo)
        model.isPageShown = false
        let hidden = event(.leftMouseDown, point: CGPoint(x: 2, y: 30), in: document)
        XCTAssertTrue(controller.handle(hidden) === hidden, "a hidden Tasks page never takes Notes input")
    }

    func testDoneRowsRemainClickableAndSelectableAcrossTheArchiveAndToday() throws {
        let store = try makeTestStore()
        let archivedID = try XCTUnwrap(store.create(title: "Archived", status: .done)).id
        XCTAssertEqual(store.moveCompletedToDoneLog(before: Date().addingTimeInterval(60)), 1)
        let todayID = try XCTUnwrap(store.create(title: "Today", status: .done)).id
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        model.select(tab: .done)
        model.loadDoneLogIfNeeded()
        let rows = model.doneDays().flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.id)), [archivedID, todayID])
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        let pointer = TasksPointer()
        pointer.view = document
        for (index, row) in rows.enumerated() {
            pointer.frames[TasksRowID(tab: .done, id: row.id)] = CGRect(x: 0, y: 20 + index * 40, width: 320, height: 40)
        }
        let adapter = TasksMarqueeSelection(scroll: scroll, model: model, pointer: pointer, tab: .done)
        XCTAssertEqual(Set(adapter.items().compactMap { $0.id.base as? UUID }), [archivedID, todayID])
        let grab = event(.leftMouseDown, point: CGPoint(x: 100, y: 35), in: document)
        XCTAssertTrue(adapter.controller.handle(grab) === grab, "Done row clicks and drag-out keep their native route")
        _ = adapter.controller.handle(event(.leftMouseDown, point: CGPoint(x: 2, y: 30), in: document))
        _ = adapter.controller.handle(event(.leftMouseDragged, point: CGPoint(x: 150, y: 80), in: document))
        _ = adapter.controller.handle(event(.leftMouseUp, point: CGPoint(x: 150, y: 80), in: document))
        XCTAssertEqual(model.selection, [archivedID, todayID])
        XCTAssertEqual(model.orderedSelection(), rows.map(\.id))
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

/// Explicit native render evidence from disposable editor fixtures only.
@MainActor
func r12Capture(_ text: NoteEditorTextView, name: String) throws {
    guard let output = ProcessInfo.processInfo.environment["ATTIC_R12_CAPTURE_DIR"] else { return }
    let scroll = text.enclosingScrollView ?? NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 250))
    if scroll.documentView == nil { scroll.documentView = text }
    var window: NSWindow?
    if scroll.window == nil {
        window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window?.isReleasedWhenClosed = false
        window?.contentView = scroll
    }
    defer { window?.close() }
    scroll.drawsBackground = true
    scroll.backgroundColor = .white
    text.layoutSubtreeIfNeeded()
    text.textLayoutManager?.textViewportLayoutController.layoutViewport()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
    scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
        URL(fileURLWithPath: output).appendingPathComponent(name))
}
