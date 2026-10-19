import AppKit
import XCTest
@testable import Attic

/// Find-only H18 on 1514eeab. Owned documents, never-ordered windows and private
/// pasteboards; production sources and the owner's clipboard stay untouched.
@MainActor
final class PhaseXHunt18Tests: XCTestCase {
    private struct RNG {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
    }

    func testRawExternalMarkdownMatrix() throws {
        let cases: [(String, [String])] = [
            ("# Café 👩🏽‍💻\r\n\r\n**bold** and *italic* &amp; `a < b`", ["Café 👩🏽‍💻", "bold and italic & a < b"]),
            ("Setext\n======\n\n---\n\nEnd", ["Setext", "", "End"]),
            ("- parent\n  - child\n    - [x] done\n\n7. seven\n8. eight", ["parent", "child", "done", "seven", "eight"]),
            ("> quoted\n> continuation\n>\n> next", ["quoted continuation", "next"]),
            ("~~~html\n<u>literal</u> &amp;\n~~~", ["<u>literal</u> &amp;"]),
            ("[label][ref]\n\n[ref]: https://example.invalid/a \"title\"", ["label"]),
            ("<https://example.invalid/a>\n\n![description](https://example.invalid/image)", ["https://example.invalid/a", "description"]),
            ("before  \nafter\\\nlast", ["before\u{2028}after\u{2028}last"]),
            ("<section>\nraw &amp; **literal**\n</section>", ["<section>", "raw &amp; **literal**", "</section>"])
        ]
        for (source, expected) in cases {
            let document = try NoteMarkdownImport.document(source)
            XCTAssertEqual(document.blocks.map(\.text), expected, source.debugDescription)
            XCTAssertNoThrow(try NoteContentCodec.encode(NoteDocument(blocks: [.text("Title")] + document.blocks)))
        }
    }

    // Person route: copy a multiline underlined passage in raw Markdown,
    // including one in a quote/list, and paste into a note body.
    func testH18_01PairedInlineHTMLAcrossExternalSoftBreaks() throws {
        for (source, expected) in [
            ("<u>first\nsecond</u>", "first second"),
            ("> <u>first\n> second</u>", "first second"),
            ("- <u>first\n  second</u>", "first second"),
            ("<strong>first\nsecond</strong>", "first second")
        ] {
            let plainSource = source.replacingOccurrences(of: #"</?(?:u|strong)>"#, with: "", options: .regularExpression)
            XCTAssertEqual(try NoteMarkdownImport.document(plainSource).blocks.map(\.text), [expected], "unformatted source control")
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
            let (scroll, view) = engine.makeView()
            defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(source, forType: .string)
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            let before = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.handlePaste(board), source)
            XCTAssertEqual(engine.document().blocks.dropFirst().map(\.text).joined(separator: "\n"), expected, source)
            let after = try NoteContentCodec.encode(engine.document())
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
        }
    }

    func testGeneratedExternalTablesAndNestedLiteralCode() throws {
        for seed in 0..<96 {
            try autoreleasepool {
                let payload = "é👩🏽‍💻\(seed)"
                let wrappers = ["", "> ", "  "]
                let prefix = wrappers[seed % wrappers.count]
                let grid = ["| Header | Other |", "| :--- | ---: |", "| <u>\(payload)\\|Q</u> | `&amp;` |"].map { prefix + $0 }.joined(separator: "\n")
                let source = (seed % 3 == 2 ? "- parent\n\n" : "") + grid + "\n\n- ```html\n  <u>code\(seed)</u> &#65; <br>\n  ```"
                let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Target"), .text("")]))
                let (scroll, view) = engine.makeView()
                defer { engine.detachView(); withExtendedLifetime((scroll, view)) {} }
                let before = try NoteContentCodec.encode(engine.document())
                XCTAssertTrue(engine.pasteMarkdown(source, at: NSRange(location: engine.textStorage.length, length: 0)))
                let document = engine.document()
                let table = try XCTUnwrap(document.blocks.compactMap(\.table).first)
                XCTAssertEqual(table.texts, [["Header", "Other"], [payload + "|Q", "&amp;"]], "seed=\(seed)")
                XCTAssertEqual(table.rows[1].cells[0].marks, [NoteMark(.underline, offset: 0, length: (payload + "|Q").utf16.count)])
                XCTAssertEqual(document.blocks.last?.text, "<u>code\(seed)</u> &#65; <br>")
                let after = try NoteContentCodec.encode(document)
                XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before)
                XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
                guard case let .editable(reopened) = NoteContentCodec.decode(after) else { return XCTFail("decode") }
                XCTAssertEqual(try NoteContentCodec.encode(reopened), after)
            }
        }
        print("H18 external table/code seeds=96")
    }

    func testGeneratedSlotChoiceMatchesIndependentLinearOracle() {
        var rng = RNG(state: 0x1818)
        var y: CGFloat = 0
        let blocks: [NoteBlockDropSlots.Block] = (0..<80).map { index in
            y += CGFloat(1 + rng.next(24))
            let rect = CGRect(x: 0, y: y, width: 300, height: CGFloat(8 + rng.next(170)))
            y = rect.maxY
            return .init(range: NSRange(location: index * 10, length: 10), rect: rect, before: nil, after: nil)
        }
        let slots = NoteBlockDropSlots(blocks: blocks)
        var current: NoteBlockDropSlots.Choice?
        for step in 0..<4_000 {
            let point = CGFloat(rng.next(Int(y) + 200) - 100)
            let expected: NoteBlockDropSlots.Choice
            if let index = blocks.firstIndex(where: { $0.rect.maxY >= point }) {
                let rect = blocks[index].rect
                if point < rect.minY {
                    if index > 0, point < (blocks[index - 1].rect.maxY + rect.minY) / 2 {
                        expected = .init(index: index - 1, after: true)
                    } else { expected = .init(index: index, after: false) }
                } else if let previous = current, previous.index == index, abs(point - rect.midY) < 4 {
                    expected = previous
                } else { expected = .init(index: index, after: point > rect.midY) }
            } else { expected = .init(index: blocks.count - 1, after: true) }
            current = slots.choice(atY: point, current: current)
            XCTAssertEqual(current, expected, "step=\(step), y=\(point)")
        }
        print("H18 linear slot oracle points=4000")
    }

    func testGeneratedMovesEditsScrollsKeepParkedAttachmentAtItsFragment() throws {
        for seed in 0..<8 {
            let blocks: [NoteBlock] = [.text("Title"), .text("Anchor"), .text("Code", style: "mono"),
                .table(NoteTable(texts: [["H", "R"], ["A", "B"]]))] + (0..<18).map { .text("Paragraph \($0) " + String(repeating: "wrap ", count: $0 % 4)) }
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
            let (scroll, view) = engine.makeView()
            scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 280)
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = scroll
            defer { engine.detachView(); window.close() }
            engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
            view.layoutSubtreeIfNeeded()
            let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
            let hosted = attachment.tableView
            // Exercise DG1's real parked-view path without ordering a window
            // or stealing the owner's keyboard to cause native parking.
            hosted.park(in: view)
            var rng = RNG(state: UInt64(seed) + 0xD618)
            for step in 0..<32 {
                let before = try NoteContentCodec.encode(engine.document())
                let sourceText = "Paragraph \(rng.next(18)) "
                let sourceLocation = (engine.textStorage.string as NSString).range(of: sourceText).location
                XCTAssertNotEqual(sourceLocation, NSNotFound)
                let source = engine.blockRange(at: sourceLocation)
                let slots = view.blockDropSlots(moving: source)
                let choices = slots.blocks.flatMap { [$0.before, $0.after].compactMap { $0 } }
                if step % 3 == 0 {
                    let end = engine.textStorage.length
                    view.setSelectedRange(NSRange(location: end, length: 0))
                    view.insertText("x", replacementRange: view.selectedRange())
                } else {
                    let choice = try XCTUnwrap(choices.isEmpty ? nil : choices[rng.next(choices.count)])
                    XCTAssertTrue(engine.moveBlock(source, to: choice.position.location), "every offered slot accepts its move")
                }
                let after = try NoteContentCodec.encode(engine.document())
                XCTAssertTrue(engine.history.undo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before, "seed=\(seed) step=\(step) undo")
                XCTAssertTrue(engine.history.redo()); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after, "seed=\(seed) step=\(step) redo")
                scroll.setFrameSize(CGSize(width: [260, 320, 420][rng.next(3)], height: 280))
                engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: rng.next(850)))
                scroll.reflectScrolledClipView(scroll.contentView)
                view.needsLayout = true; view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                // A view TextKit has removed from its viewport has no meaningful
                // coordinates in the note. Re-enter the focused parked path,
                // as NoteTableView's rehost callback does, before measuring.
                if hosted.window == nil { hosted.park(in: view) }
                XCTAssertTrue(hosted.window === window)
                XCTAssertTrue(hosted.isDescendant(of: view))
                let range = try XCTUnwrap(engine.range(ofTable: attachment))
                let location = try XCTUnwrap(engine.textRange(for: NSRange(location: range.location, length: 0))?.location)
                let fragment = try XCTUnwrap(engine.layoutManager?.textLayoutFragment(for: location))
                let local = fragment.frameForTextAttachment(at: location)
                let expected = local.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                              dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
                let actual = hosted.convert(hosted.bounds, to: view)
                XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, "seed=\(seed) step=\(step)")
                XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, "seed=\(seed) step=\(step)")
                XCTAssertEqual(engine.document().blocks.compactMap(\.table).first?.texts, [["H", "R"], ["A", "B"]])
            }
        }
        print("H18 attachment edit/move/scroll sequences=8x32=256")
    }

    func testUndoBoundariesAcrossRepeatedDeparturesAndRemounts() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let id = UUID(), other = UUID()
        for noteID in [id, other] {
            guard case .success = store.createDocumentNote(id: noteID, document: NoteDocument(blocks: [.text("Title"), .text("Body")])) else { return XCTFail("seed") }
        }
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H18-Visits")),
            saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        for step in 0..<24 {
            let session = try XCTUnwrap(controller.active)
            let engine = session.engine
            let (scroll, view) = engine.makeView()
            let before = try NoteContentCodec.encode(engine.document())
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            for character in " + visit\(step)" { view.insertText(String(character), replacementRange: view.selectedRange()) }
            let after = try NoteContentCodec.encode(engine.document())
            switch step % 4 {
            case 0:
                await XCTAssertTrueAsync(await controller.openDurably(noteID: other))
                await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
            case 1:
                await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.pageSwitch)); controller.present()
            case 2:
                await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.hide)); controller.present()
            default:
                XCTAssertTrue(controller.showLibrary())
                await XCTAssertTrueAsync(await controller.openFromLibrary(noteID: id)); controller.dismissLibrary()
            }
            XCTAssertTrue(controller.active?.engine === engine)
            engine.detachView()
            let (nextScroll, nextView) = engine.makeView()
            nextView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            nextView.insertText("!", replacementRange: nextView.selectedRange())
            engine.undoCommand(); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after, "step=\(step) latest visit only")
            engine.undoCommand(); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), before, "step=\(step) earlier visit")
            engine.redoCommand(); XCTAssertEqual(try NoteContentCodec.encode(engine.document()), after)
            nextView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            nextView.insertText("?", replacementRange: nextView.selectedRange())
            XCTAssertFalse(engine.history.canRedo, "new edit clears Redo")
            engine.detachView()
            withExtendedLifetime((scroll, view, nextScroll, nextView)) {}
        }
        await XCTAssertTrueAsync(await controller.prepareToLeaveDurably(.pageSwitch))
        print("H18 departures/remounts=24")
    }
}
