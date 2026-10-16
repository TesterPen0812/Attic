import AppKit
import XCTest
@testable import Attic

/// Deterministic work counters; times are evidence, never invented budgets.
@MainActor
final class NotesTypingCostTests: XCTestCase {
    private func editor(_ blocks: [NoteBlock]) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
        let (scroll, view) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        return (engine, view)
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testNumberedListTypingWork() async {
        for count in [200, 2000] {
            let (engine, view) = editor([.text("Title")] + (0..<count).map { .text("Item \($0) words", style: "number") })
            // Warm every marker, as scrolling through the list does.
            var offsets: [Int] = []
            var offset = 6
            for i in 0..<count { offsets.append(offset); offset += "Item \(i) words\n".utf16.count }
            engine.textStorage.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
            let visits = engine.ordinalParagraphVisitCount
            let markerMS = milliseconds { for offset in offsets { _ = engine.listMarker(at: offset) } }
            let markerVisits = engine.ordinalParagraphVisitCount - visits
            XCTAssertEqual(markerVisits, count - 1, "cold sequential markers cross each preceding item once")
            let warmVisits = engine.ordinalParagraphVisitCount
            for offset in offsets { _ = engine.listMarker(at: offset) }
            XCTAssertEqual(engine.ordinalParagraphVisitCount, warmVisits, "unchanged markers use their checkpoints")
            let passes = engine.renumberPassCount, paragraphs = engine.renumberParagraphVisitCount
            view.setSelectedRange(NSRange(location: offsets[1] + 3, length: 0))
            let typingMS = milliseconds { view.insertText("x", replacementRange: view.selectedRange()) }
            // Drain the actual deferred renumber work without a screen.
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            print("P1_LIST size=\(count) renumber_passes=\(engine.renumberPassCount - passes) tail_paragraphs=\(engine.renumberParagraphVisitCount - paragraphs) ordinal_visits=\(markerVisits) markers_ms=\(markerMS) typing_ms=\(typingMS)")
            XCTAssertEqual(engine.renumberPassCount, passes, "an ordinary letter changes no later ordinal")
            XCTAssertEqual(engine.renumberParagraphVisitCount, paragraphs)
            XCTAssertEqual(engine.listMarker(at: offsets.last! + 1), .number("\(count)."))
            engine.detachView()
        }
    }

    func testHeadingOutlineWork() {
        for count in [50, 500] {
            var blocks: [NoteBlock] = [.text("Title")]
            for i in 0..<count {
                var heading = NoteBlock.text("Heading \(i)", style: "heading"); heading.level = 2
                blocks += [heading, .text("Body words for section \(i)"), .text("More mixed body words")]
            }
            let (engine, _) = editor(blocks)
            let sections = engine.headingSections
            let builds = engine.outlineRebuildCount, paragraphs = engine.outlineParagraphVisitCount
            let attributeMS = milliseconds {
                engine.textStorage.addAttribute(.foregroundColor, value: NSColor.red, range: sections[1].heading)
                _ = engine.headingSections
            }
            let start = sections[count / 2].heading.location
            let visits = engine.outlineViewportVisitCount
            let viewportMS = milliseconds { XCTAssertEqual(engine.headings(in: NSRange(location: start, length: 1)).count, 1) }
            print("P1_OUTLINE size=\(count) rebuilds=\(engine.outlineRebuildCount - builds) heading_visits=\(engine.outlineParagraphVisitCount - paragraphs) viewport_visits=\(engine.outlineViewportVisitCount - visits) attributes_ms=\(attributeMS) viewport_ms=\(viewportMS)")
            XCTAssertEqual(engine.outlineRebuildCount, builds)
            XCTAssertEqual(engine.outlineParagraphVisitCount, paragraphs)
            XCTAssertEqual(engine.outlineViewportVisitCount - visits, count == 50 ? 11 : 17)
            engine.detachView()
        }
    }

    func testFindTypingAndNavigationWork() {
        for count in [1000, 5000] {
            var blocks: [NoteBlock] = [.text("Title")]
            blocks += (0..<count).map { .text("Line \($0) needle and other words") }
            blocks.insert(.table(NoteTable(texts: [["needle", "cell"], ["other", "needle"]])), at: count / 2)
            let (engine, view) = editor(blocks)
            engine.find.show(); engine.find.query = "needle"
            XCTAssertEqual(engine.find.matches.count, count + 2)
            let searches = engine.find.objectSearchPassCount, scanned = engine.find.searchedUTF16Count
            let invalidated = engine.find.invalidatedUTF16Count
            view.setSelectedRange(NSRange(location: 10, length: 0))
            let typingMS = milliseconds { view.insertText("x", replacementRange: view.selectedRange()) }
            print("P1_FIND size=\(count) searches=\(engine.find.objectSearchPassCount - searches) scanned_utf16=\(engine.find.searchedUTF16Count - scanned) invalidated_utf16=\(engine.find.invalidatedUTF16Count - invalidated) typing_ms=\(typingMS)")
            let editedParagraphLength = engine.paragraphRange(at: 10).length
            XCTAssertEqual(engine.find.searchedUTF16Count - scanned, editedParagraphLength)
            XCTAssertLessThanOrEqual(engine.find.invalidatedUTF16Count - invalidated, editedParagraphLength)
            let navSearches = engine.find.objectSearchPassCount, navScan = engine.find.searchedUTF16Count
            let navInvalidation = engine.find.invalidatedUTF16Count
            let navigationMS = milliseconds { engine.find.next(); engine.find.next(backward: true) }
            print("P1_FIND_NAV size=\(count) searches=\(engine.find.objectSearchPassCount - navSearches) scanned_utf16=\(engine.find.searchedUTF16Count - navScan) invalidated_utf16=\(engine.find.invalidatedUTF16Count - navInvalidation) navigation_ms=\(navigationMS)")
            XCTAssertEqual(engine.find.objectSearchPassCount, navSearches)
            XCTAssertEqual(engine.find.searchedUTF16Count, navScan)
            XCTAssertEqual(engine.find.invalidatedUTF16Count, navInvalidation)
            XCTAssertEqual(engine.find.matches.count, count + 2)
            let table = engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first!
            let tableScanned = engine.find.searchedUTF16Count, tableInvalidated = engine.find.invalidatedUTF16Count
            let tableMS = milliseconds {
                XCTAssertTrue(engine.changeTable(table, name: "Typing", coalescing: .init(row: 0, column: 0)) {
                    $0[.init(row: 0, column: 0)].text = "neexdle"
                })
            }
            print("P1_FIND_TABLE size=\(count) scanned_utf16=\(engine.find.searchedUTF16Count - tableScanned) invalidated_utf16=\(engine.find.invalidatedUTF16Count - tableInvalidated) typing_ms=\(tableMS)")
            let gridCharacters = table.table.rows.flatMap { $0.cells }.reduce(0) { $0 + $1.text.utf16.count }
            XCTAssertEqual(engine.find.searchedUTF16Count - tableScanned, gridCharacters)
            XCTAssertEqual(engine.find.invalidatedUTF16Count, tableInvalidated)
            XCTAssertEqual(engine.find.matches.count, count + 1)
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.find.matches.count, count + 2)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.find.matches.count, count + 1)
            engine.find.close(); engine.detachView()
        }
    }
    func testFindEditsAgreeWithFullSearchAndLeaveNoStaleInk() throws {
        let (engine, view) = editor([.text("Title"), .text("needle needle café"), .text("middle words"),
            .table(NoteTable(texts: [["needle", "café"]])), .text("last needle café")])
        defer { engine.find.close(); engine.detachView() }
        engine.find.show(); engine.find.query = "needle"
        func verify() {
            let incremental = engine.find.matches
            var painted = Set<Int>()
            engine.layoutManager?.enumerateRenderingAttributes(from: engine.contentStorage.documentRange.location, reverse: false) { _, attributes, range in
                if attributes[.backgroundColor] != nil {
                    let start = engine.contentStorage.offset(from: engine.contentStorage.documentRange.location, to: range.location)
                    let end = engine.contentStorage.offset(from: engine.contentStorage.documentRange.location, to: range.endLocation)
                    if end > start { painted.formUnion(start..<end) }
                }
                return true
            }
            let expected = Set(incremental.filter { $0.tableID == nil }.flatMap { Array($0.noteRange.location..<NSMaxRange($0.noteRange)) })
            XCTAssertEqual(painted, expected, "rendering ink follows shifted and removed matches")
            engine.find.refresh(selectFirst: true)
            XCTAssertEqual(incremental, engine.find.matches, "incremental matches agree with a fresh full scan")
        }
        func replace(_ range: NSRange, with text: String) {
            view.setSelectedRange(range); view.insertText(text, replacementRange: range); verify()
        }
        verify()
        replace(NSRange(location: 8, length: 0), with: "x") // destroy a match
        XCTAssertTrue(engine.history.undo()); verify()
        XCTAssertTrue(engine.history.redo()); verify()
        replace(NSRange(location: 6, length: 0), with: "😀") // shift every later match by two UTF-16 units
        let middle = (view.string as NSString).range(of: "middle words")
        replace(middle, with: "new needle\nsecond needle")
        let separator = (view.string as NSString).range(of: "\nsecond")
        replace(NSRange(location: separator.location, length: 1), with: " ") // join
        engine.find.query = "cafe"; verify() // diacritic insensitive
        replace(NSRange(location: engine.textStorage.length, length: 0), with: " cafe\u{301}")
        engine.find.query = "needle\n"; verify() // cross-paragraph query keeps full-search semantics
        replace(NSRange(location: 6, length: 0), with: "needle\n")
        engine.find.query = ""; verify()
    }

    func testNumberCacheSurvivesStructureAndReplay() {
        var first = NoteBlock.text("parent", style: "number"); first.start = 12
        var child = NoteBlock.text("child", style: "number"); child.indent = 1
        var deep = NoteBlock.text("deep", style: "number"); deep.indent = 2
        let (engine, view) = editor([.text("Title"), first, child, deep, .text("peer", style: "number")])
        defer { engine.detachView() }
        func at(_ word: String) -> Int { (engine.textStorage.string as NSString).range(of: word).location }
        func verify(_ last: String) {
            // Cold, reverse and warm reads must agree for all three levels.
            XCTAssertEqual(engine.listMarker(at: at("peer")), .number(last))
            XCTAssertEqual(engine.listMarker(at: at("deep")), .roman("i."))
            XCTAssertEqual(engine.listMarker(at: at("child")), .letter("a."))
            XCTAssertEqual(engine.listMarker(at: at("parent")), .number("12."))
            XCTAssertEqual(engine.listMarker(at: at("peer")), .number(last))
        }
        verify("13.")
        view.setSelectedRange(NSRange(location: at("parent") + 6, length: 0)); view.insertNewline(nil)
        verify("14.")
        XCTAssertTrue(engine.history.undo()); verify("13.")
        XCTAssertTrue(engine.history.redo()); verify("14.")
        XCTAssertTrue(engine.setListStart(20, at: at("peer")))
        XCTAssertEqual(engine.listMarker(at: at("peer")), .number("22."))
    }

    func testOutlineMetadataChangesStillRebuildAndFold() throws {
        var heading = NoteBlock.text("Section", id: UUID(), style: "heading"); heading.level = 2
        let (engine, _) = editor([.text("Title"), heading, .text("body words"), .text("Next")])
        defer { engine.detachView() }
        let section = try XCTUnwrap(engine.headingSections.first)
        let id = try XCTUnwrap(section.id)
        engine.setHeadingFold(id: id, folded: true)
        XCTAssertTrue(engine.isRangeFolded(section.content))
        engine.textStorage.addAttribute(.noteBlockLevel, value: 3, range: section.heading)
        XCTAssertEqual(engine.headingSections.first?.level, 3)
        engine.textStorage.removeAttribute(.noteBlockStyle, range: section.heading)
        XCTAssertTrue(engine.headingSections.isEmpty)
        let next = (engine.textStorage.string as NSString).range(of: "Next")
        engine.textStorage.addAttribute(.noteBlockStyle, value: "heading", range: next)
        XCTAssertEqual(engine.headingSections.count, 1)
        XCTAssertEqual(engine.headingSections.first?.heading.location, next.location)
    }

    func testTypingRebasesOutlineWithoutRebuilding() {
        for trailingBody in [false, true] {
            var heading = NoteBlock.text("Section", id: UUID(), style: "heading"); heading.level = 2
            let (engine, view) = editor([.text("Title"), heading, .text("body"), heading] + (trailingBody ? [.text("")] : []))
            defer { engine.detachView() }
            _ = engine.headingSections
            for location in [0, 6, 16, engine.textStorage.length] {
                let builds = engine.outlineRebuildCount
                view.setSelectedRange(NSRange(location: min(location, engine.textStorage.length), length: 0))
                view.insertText("x", replacementRange: view.selectedRange())
                let incremental = engine.headingSections
                XCTAssertEqual(engine.outlineRebuildCount, builds)
                let fresh = NoteEditorEngine(noteID: UUID(), document: engine.document()).headingSections
                XCTAssertEqual(incremental.map(\.heading), fresh.map(\.heading))
                XCTAssertEqual(incremental.map(\.content), fresh.map(\.content))
                XCTAssertEqual(incremental.map(\.id), fresh.map(\.id))
            }
        }
    }

}
