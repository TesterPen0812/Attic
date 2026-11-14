import AppKit
import XCTest
@testable import Attic

/// Deterministic work counters; times are evidence, never invented budgets.
@MainActor
final class NotesTypingCostTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
    }

    override func tearDown() async throws {
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        try await super.tearDown()
    }

    func testFindNavigationDoesNotEnumerateALargeNotesObjectsAgain() {
        for count in [1_000, 5_000] {
            let (engine, view) = editor([.text("Title")] + (0..<count).map { .text("Line \($0) needle") })
            defer { engine.find.close(); engine.detachView() }
            engine.find.show()
            engine.find.query = "needle"
            let searches = engine.find.searchedUTF16Count
            let enumerations = engine.objectEnumerationPassCount
            #if DEBUG
            let checkingWrites = view.continuousSpellCheckingWriteCount
            #endif
            let ms = milliseconds { engine.find.next(); engine.find.next(backward: true) }
            print("QUALITY1_FIND paragraphs=\(count) next_previous_ms=\(ms) object_enumerations=\(engine.objectEnumerationPassCount - enumerations)")
            XCTAssertEqual(engine.find.searchedUTF16Count, searches)
            XCTAssertEqual(engine.objectEnumerationPassCount, enumerations,
                           "navigation reuses matches and ink; it must not enumerate the whole note")
            #if DEBUG
            XCTAssertEqual(view.continuousSpellCheckingWriteCount, checkingWrites,
                           "unchanged prose selection must not reset all native temporary attribute runs")
            #endif
            XCTAssertEqual(view.selectedRange(), engine.find.matches[0].noteRange)
        }
    }

    func testVisibleFindNavigationDoesNotResolveTheWholePrefixOnEveryStep() throws {
        // With the two targets inside one warm viewport, navigating a deep
        // note should not walk all 5,000 preceding paragraphs on each ⌘G.
        let filler = (0..<5_000).map { NoteBlock.text("Unrelated paragraph \($0) with wrapping words.") }
        let matches: [NoteBlock] = [.text("needle first"), .text("needle second")]
        for nearEnd in [false, true] {
            let (engine, view) = editor([.text("Title")] + (nearEnd ? filler + matches : matches + filler))
            let scroll = try XCTUnwrap(view.enclosingScrollView)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll.frame = window.contentView!.bounds
            window.contentView = scroll
            defer { engine.find.close(); engine.detachView(); window.close() }
            scroll.layoutSubtreeIfNeeded()
            engine.layoutManager?.textViewportLayoutController.layoutViewport()
            engine.find.inTopRow = true
            engine.find.show()
            engine.find.query = "needle"
            scroll.layoutSubtreeIfNeeded()
            engine.layoutManager?.textViewportLayoutController.layoutViewport()
            XCTAssertEqual(engine.find.matches.count, 2)
            let visible = view.convert(scroll.contentView.bounds, from: scroll.contentView)
            for match in engine.find.matches {
                XCTAssertTrue(try XCTUnwrap(engine.rect(for: match.noteRange)).intersects(visible),
                              "both targets should already be in the laid-out viewport")
            }
            let before = view.prefixLayoutRequestCount
            var samples: [Double] = []
            for _ in 0..<60 {
                let start = DispatchTime.now().uptimeNanoseconds
                engine.find.next()
                engine.find.next(backward: true)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            samples.sort()
            print("NOTES_FIND_VISIBLE_NAV position=\(nearEnd ? "tail" : "head") paragraphs=5000 pairs=60 median_ms=\(samples[30]) p95_ms=\(samples[57]) prefix_requests=\(view.prefixLayoutRequestCount - before)")
            XCTAssertEqual(view.prefixLayoutRequestCount, before,
                           "visible Find matches must reuse viewport layout without walking the prefix")
        }
    }

    func testE01FirstDistantFindRevealsWrappedMatch() throws {
        for width in [CGFloat(340), CGFloat(420)] {
            let blocks: [NoteBlock] = [.text("Title")] + (0..<5_000).map { number in
                .text("Paragraph \(number) needle " +
                    String(repeating: "Words that wrap on narrow columns. ", count: number % 5 + 1))
            }
            let (engine, view) = editor(blocks)
            let scroll = try XCTUnwrap(view.enclosingScrollView)
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { engine.find.close(); engine.detachView(); window.close() }
            scroll.layoutSubtreeIfNeeded()
            engine.find.inTopRow = true
            engine.find.show()
            engine.find.query = "needle"
            let target = try XCTUnwrap(engine.find.matches.last?.noteRange)
            let searches = engine.find.objectSearchPassCount
            let scans = engine.find.searchedUTF16Count
            let coldMS = milliseconds { engine.find.next(backward: true) }
            XCTAssertEqual(view.selectedRange(), target)
            view.layoutSubtreeIfNeeded()
            engine.layoutManager?.textViewportLayoutController.layoutViewport()
            let viewport = try XCTUnwrap(engine.layoutManager?.textViewportLayoutController.viewportRange)
            let textTarget = try XCTUnwrap(engine.textRange(for: target))
            XCTAssertTrue(viewport.intersects(textTarget), "Find must scroll onto the distant target")
            let visible = view.convert(scroll.contentView.bounds, from: scroll.contentView)
            let rect = try XCTUnwrap(engine.rect(for: target))
            XCTAssertTrue(rect.intersects(visible), "the wrapped match must actually be visible")
            let warmMS = milliseconds { engine.find.next(); engine.find.next(backward: true) }
            XCTAssertEqual(engine.find.objectSearchPassCount, searches)
            XCTAssertEqual(engine.find.searchedUTF16Count, scans)
            print("E01_FIND width=\(width) first_ms=\(coldMS) warm_ms=\(warmMS)")
        }
    }

    func testFindTableFocusDoesNotRepaintEveryTableInALargeNote() throws {
        let (engine, view) = editor([.text("Title"), .text("needle body"),
            .table(NoteTable(texts: [["needle cell", "needle other"]]))]
            + (0..<5_000).map { .text("needle paragraph \($0)") })
        let table = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = try XCTUnwrap(view.enclosingScrollView)
        scroll.frame = root.bounds
        root.addSubview(scroll)
        root.addSubview(table.tableView)
        let window = NSWindow(contentRect: root.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { engine.find.close(); window.close(); engine.detachView() }
        engine.find.show()
        engine.find.query = "needle"
        let enumerations = engine.objectEnumerationPassCount
        engine.find.next()
        XCTAssertTrue(window.firstResponder === table.tableView.editor)
        XCTAssertEqual(table.tableView.editor.selectedRange(), engine.find.matches[1].cellRange)
        engine.find.next()
        XCTAssertEqual(table.tableView.editor.selectedRange(), engine.find.matches[2].cellRange)
        engine.find.next()
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(view.selectedRange(), engine.find.matches[3].noteRange)
        XCTAssertEqual(engine.objectEnumerationPassCount, enumerations,
                       "cell focus needs only that table's cached match ink")
    }

    func testB11MeasureWrapLayout() throws {
        for run in 0..<5 {
            let (engine, view) = editor([.text("Title"), .text("")])
            let scroll = try XCTUnwrap(view.enclosingScrollView)
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeFirstResponder(view)
            defer { engine.detachView(); window.close() }
            view.setFrameSize(NSSize(width: 400, height: 600))
            view.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
            engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
            var previousY = engine.caretRect(at: view.selectedRange().location)?.minY ?? 0
            var samples: [Double] = [], wraps: [Double] = []
            for _ in 0..<100 {
                let elapsed = milliseconds {
                    view.insertText("x", replacementRange: view.selectedRange())
                    engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
                    view.layoutSubtreeIfNeeded()
                }
                let y = try XCTUnwrap(engine.caretRect(at: view.selectedRange().location)).minY
                if y > previousY + 1 { wraps.append(elapsed) } else { samples.append(elapsed) }
                previousY = y
            }
            XCTAssertFalse(wraps.isEmpty)
            print("B11_LAYOUT run=\(run) wraps_ms=\(wraps) ordinary_median_ms=\(samples.sorted()[samples.count / 2])")
        }
    }

    func testP06TailAttachmentLookupWork() throws {
        for count in [100, 1000, 5000] {
            let document = NoteDocument(blocks: [.text("Title")] + (0..<count).map { .text("Unrelated paragraph \($0)") } + [
                .table(NoteTable(texts: [["a", "b"], ["c", "d"]])),
                .image(attachmentID: UUID(), pixelWidth: 800, pixelHeight: 400)])
            let engine = NoteEditorEngine(noteID: UUID(), document: document)
            let table = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
            let image = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteImageAttachment }.first)
            let beforeImage = engine.attachmentRangeEnumerationVisits
            let imageMS = milliseconds { XCTAssertNotNil(engine.range(of: image)) }
            let imageVisits = engine.attachmentRangeEnumerationVisits - beforeImage
            let beforeTable = engine.attachmentRangeEnumerationVisits
            let tableMS = milliseconds {
                XCTAssertTrue(engine.changeTable(table, name: "Cell") { $0[.init(row: 0, column: 0)].text = "edited" })
            }
            let tableVisits = engine.attachmentRangeEnumerationVisits - beforeTable
            print("P3_ATTACHMENT size=\(count) image_visits=\(imageVisits) table_visits=\(tableVisits) image_ms=\(imageMS) table_ms=\(tableMS)")
            // Measured P3 baseline: absent attachment attributes coalesce
            // across unrelated paragraphs; lookup visits do not grow.
            XCTAssertEqual(imageVisits, 4)
            XCTAssertEqual(tableVisits, 2)
        }
    }

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
            if count == 5_000, ProcessInfo.processInfo.environment["ATTIC_FIND_NAV_PROFILE"] == "1" {
                print("QUALITY1_FIND_PROFILE pid=\(ProcessInfo.processInfo.processIdentifier)")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 3)
                let deadline = Date().addingTimeInterval(20)
                var alternate = false
                while Date() < deadline {
                    view.setSelectedRange(NSRange(location: 10, length: 1))
                    view.insertText(alternate ? "x" : "y", replacementRange: view.selectedRange())
                    alternate.toggle()
                    engine.find.next()
                    engine.find.next(backward: true)
                }
            }
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
            let changedCellCharacters = table.table[.init(row: 0, column: 0)].text.utf16.count
            XCTAssertEqual(engine.find.searchedUTF16Count - tableScanned, changedCellCharacters,
                           "Find must search the changed cell and keep all other matches")
            XCTAssertEqual(engine.find.invalidatedUTF16Count, tableInvalidated)
            XCTAssertEqual(engine.find.matches.count, count + 1)
            XCTAssertTrue(engine.history.undo()); XCTAssertEqual(engine.find.matches.count, count + 2)
            XCTAssertTrue(engine.history.redo()); XCTAssertEqual(engine.find.matches.count, count + 1)
            engine.find.close(); engine.detachView()
        }
    }

    func testPF12PlainTypingDoesNotRestyleUnchangedRichNeighbor() {
        for length in [1_000, 100_000] {
            var rich = NoteBlock.text(String(repeating: "a", count: length))
            rich.marks = [NoteMark(.bold, offset: 0, length: length / 2),
                          NoteMark(.italic, offset: length / 2, length: length / 2)]
            let (engine, view) = editor([.text("Title"), .text("edit here"), rich])
            defer { engine.detachView() }
            let originalMarks = engine.document().blocks[2].marks
            let offset = (view.string as NSString).range(of: "edit here").location + 4
            view.setSelectedRange(NSRange(location: offset, length: 0))
            let touched = engine.restyleTouchedUTF16Count
            let visited = engine.restyleMarkRunVisitCount
            for _ in 0..<100 {
                view.insertText("x", replacementRange: view.selectedRange())
            }
            let change = engine.restyleTouchedUTF16Count - touched
            let runs = engine.restyleMarkRunVisitCount - visited
            print("PF12 length=\(length) edits=100 restyled_utf16=\(change) mark_runs=\(runs)")
            XCTAssertLessThan(change, 5_000, "ordinary typing must not restyle unchanged rich neighbors")
            XCTAssertLessThan(runs, 500)
            XCTAssertEqual(engine.document().blocks[2].marks, originalMarks)
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.document().blocks[2].marks, originalMarks)
        }
    }

    func testPF16SingleTableCellFindEditDoesNotScanUnrelatedCells() throws {
        for rows in [10, 250] {
            let table = NoteTable(texts: (0..<rows).map { row in
                (0..<15).map { column in "cell \(row)-\(column) needle" }
            })
            let (engine, _) = editor([.text("Title"), .table(table)])
            defer { engine.find.close(); engine.detachView() }
            engine.find.show(); engine.find.query = "needle"
            let object = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
            let before = engine.find.searchedUTF16Count
            for step in 0..<100 {
                XCTAssertTrue(engine.changeTable(object, name: "Cell", coalescing: .init(row: 0, column: 0)) {
                    $0[.init(row: 0, column: 0)].text = "changed \(step) needle"
                })
            }
            let searched = engine.find.searchedUTF16Count - before
            print("PF16 table_rows=\(rows) edits=100 searched_utf16=\(searched)")
            XCTAssertLessThan(searched, 10_000, "Find cell updates must not scan unrelated table cells")
            XCTAssertEqual(engine.find.matches.count, rows * 15)
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(engine.find.matches.count, rows * 15)
        }
    }

    func testPF16RapidQueryKeysDoNotSynchronouslyScanLongNote() async {
        let longBody = String(repeating: "a", count: 350_000) + " needleTarget"
        let (engine, _) = editor([.text("Title"), .text(longBody)])
        defer { engine.find.close(); engine.detachView() }
        engine.find.show()
        let before = engine.find.searchedUTF16Count
        let snapshots = engine.find.backgroundSnapshotBuildCount
        let publications = engine.find.backgroundQueryPublicationCount
        for count in 1...12 {
            engine.find.query = String("needleTarget".prefix(count))
        }
        let inlineWork = engine.find.searchedUTF16Count - before
        print("PF16 query_keys=12 body_utf16=350012 inline_scanned_utf16=\(inlineWork)")
        XCTAssertLessThan(inlineWork, 50_000, "Find query updates must move full-text scans off the input callback")
        await engine.find.waitForSearch()
        XCTAssertEqual(engine.find.backgroundSnapshotBuildCount - snapshots, 1,
                       "repeated query keys reuse one immutable document snapshot")
        XCTAssertEqual(engine.find.backgroundQueryPublicationCount - publications, 1,
                       "superseded query generations must not publish old matches")
        XCTAssertEqual(engine.find.matches.count, 1, "the latest query must publish its one matching range")
        XCTAssertEqual(engine.find.matches[0].noteRange.length, 12)
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

    func testDeletingFinalHeadingTextDropsItsCachedSection() {
        var heading = NoteBlock.text("Section", id: UUID(), style: "heading"); heading.level = 2
        let (engine, view) = editor([.text("Title"), heading])
        defer { engine.detachView() }
        XCTAssertEqual(engine.headingSections.count, 1)
        let range = engine.lineRange(at: 6)
        view.setSelectedRange(range)
        view.insertText("", replacementRange: range)
        XCTAssertEqual(view.string, "Title\n")
        XCTAssertTrue(engine.headingSections.isEmpty)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.headingSections.count, 1)
        XCTAssertTrue(engine.history.redo())
        XCTAssertTrue(engine.headingSections.isEmpty)
    }

}
