import AppKit
import XCTest
@testable import Attic

/// Notes hunt (12 Nov): seeded, reachable TextKit commands with a fresh
/// serialized reader after every step and a full history replay at the end.
/// The independent plain-text/list/table oracle remains in PhaseXHunt1GeneratedTests.
@MainActor
final class NotesEditorHuntTests: XCTestCase {
    private struct Action: CustomStringConvertible {
        let kind: Int
        let a: Int
        let b: Int
        var description: String { "\(kind):\(a):\(b)" }
    }

    private struct Random {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upper))
        }
    }

    private func saved(_ engine: NoteEditorEngine) throws -> Data {
        let document = engine.document()
        let data = try NoteContentCodec.encode(document)
        guard case let .editable(reloaded) = NoteContentCodec.decode(data) else {
            throw NSError(domain: "NotesEditorHunt", code: 1)
        }
        let copy = NoteEditorEngine(noteID: UUID(), document: reloaded,
            stagedAttachments: engine.stagedAttachments(for: document))
        let roundTrip = try NoteContentCodec.encode(copy.document())
        guard roundTrip == data else { throw NSError(domain: "NotesEditorHunt", code: 2) }
        let stored = Dictionary(uniqueKeysWithValues: engine.stagedAttachments(for: document).map { ($0.id, $0.data) })
        let recovered = Dictionary(uniqueKeysWithValues: copy.stagedAttachments(for: copy.document()).map { ($0.id, $0.data) })
        guard recovered == stored else { throw NSError(domain: "NotesEditorHunt", code: 3) }
        return data
    }

    private func firstDifference(_ expected: Data, _ actual: Data) -> String {
        guard case let .editable(lhs) = NoteContentCodec.decode(expected),
              case let .editable(rhs) = NoteContentCodec.decode(actual) else {
            return "decoded document is unavailable"
        }
        for index in 0..<min(lhs.blocks.count, rhs.blocks.count) where lhs.blocks[index] != rhs.blocks[index] {
            return "block[\(index)] expected=\(lhs.blocks[index]) actual=\(rhs.blocks[index])"
        }
        return "expected_blocks=\(lhs.blocks.count) actual_blocks=\(rhs.blocks.count) metadata_equal=\(lhs == rhs)"
    }

    /// Returns the first actual divergence, including its seed-independent step.
    private func replay(_ actions: [Action]) -> (Int, String)? {
        let document = NoteDocument(blocks: [
            .text("Hunt"), .text("first anchor words"), .text("second plain words"),
            .text("third more words", style: "bullet"),
            .table(NoteTable(texts: [["one", "two"], ["three", "four"]])),
            .text("last words")
        ])
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        let (scroll, view) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { engine.find.close(); engine.detachView(); window.close() }
        guard window.makeFirstResponder(view) else { return (0, "invisible editor did not take first-responder focus") }
        let rich = NSMutableAttributedString(string: " Rich phrase ")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14),
                          range: NSRange(location: 1, length: 4))
        guard let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
              let beginning = try? saved(engine) else { return (0, "fixture setup failed") }
        var checkpoints: [Data] = [beginning]
        var current = 0
        for (step, action) in actions.enumerated() {
            // XCTest runs the generator synchronously, without the event-loop
            // pool that normally drains after each keyboard command. Release
            // transient AppKit drawing objects after every simulated step.
            let failure: (Int, String)? = autoreleasepool {
                let label = "step=\(step) action=\(action)"
                let string = engine.textStorage.string as NSString
                var prose: [NSRange] = []
                var cursor = 0
                for (index, part) in engine.textStorage.string.components(separatedBy: "\n").enumerated() {
                    let length = (part as NSString).length
                    if index > 0 && !part.contains(NoteDocument.objectCharacter) {
                        prose.append(NSRange(location: cursor, length: length))
                    }
                    cursor += length + 1
                }
                guard !prose.isEmpty else { return (step, "\(label): no editable prose") }
                let line = prose[action.a % prose.count]
                let location = line.location + action.b % (line.length + 1)
                let selection = NSRange(location: location, length: 0)
                view.setSelectedRange(selection)
                // A real selection from a click/navigation begins on screen.
                // The generator jumps between arbitrary lines, so scroll to its
                // target before editing; the post-edit caret check remains strict.
                view.scrollRangeToVisible(selection)
                engine.history.breakCoalescing()
                let before = (try? saved(engine)) ?? Data()
                if before.isEmpty { return (step, "\(label): save before failed") }
                let generation = engine.history.recordingGeneration
                let tables = engine.objects().compactMap { $0.0 as? NoteTableAttachment }
                let table = tables.isEmpty ? nil : tables[action.a % tables.count]
                switch action.kind {
                case 0: view.insertText(["x", "é", "z", "😀"][action.b % 4], replacementRange: selection)
                case 1: if line.length > 0 && location < NSMaxRange(line) {
                    let char = string.rangeOfComposedCharacterSequence(at: location)
                    view.setSelectedRange(char); view.deleteBackward(nil)
                }
                case 2: view.insertNewline(nil) // lists, body and empty lines
                case 3: _ = engine.perform(.paragraph(.bullet), selection: selection)
                case 4: _ = engine.perform(.paragraph(.number), selection: selection)
                case 5: _ = engine.perform(.indent, selection: selection) // list Tab
                case 6: _ = engine.perform(.outdent, selection: selection) // Shift-Tab
                case 7: _ = engine.pastePlainText(" paste ", at: selection)
                case 8: _ = engine.pasteRichText(rtf, type: .rtf, at: selection)
                case 9: _ = engine.pastePlainText("a\tb\nc\td", at: selection) // table paste
                case 10: _ = engine.perform(.paragraph(.checklist), selection: selection)
                case 11: _ = engine.perform(.paragraph(.heading(2)), selection: selection)
                case 12: _ = engine.perform(.link("https://example.com/note"),
                                            selection: NSRange(location: line.location, length: min(3, line.length)))
                case 13: if let table { _ = engine.changeTable(table, name: "Cell") {
                    let r = action.a % $0.rowCount, c = action.b % $0.columnCount
                    $0.rows[r].cells[c].text += "x"
                } }
                case 14: if let table, table.table.rowCount < 8 {
                    _ = engine.addRow(to: table, at: action.b % (table.table.rowCount + 1), focusing: 0)
                }
                case 15: if let table, table.table.rowCount > 1 {
                    _ = engine.deleteRow(of: table, at: action.b % table.table.rowCount)
                }
                case 16: if let table, table.table.columnCount < 8 {
                    _ = engine.addColumn(to: table, at: action.b % (table.table.columnCount + 1), focusingRow: 0)
                }
                case 17: if let table, table.table.columnCount > 1 {
                    _ = engine.deleteColumn(of: table, at: action.b % table.table.columnCount)
                }
                case 18: // file/image import with owned, test-only bytes
                    let bytes = Data("Owned attachment \(step)".utf8)
                    let item = StagedNoteAttachment(id: UUID(), filename: "owned-\(step).txt",
                        contentTypeIdentifier: "public.plain-text", byteCount: Int64(bytes.count),
                        digest: NotePayloadDigest.sha256(bytes), data: bytes)
                    engine.beginImageImport(at: selection)
                    _ = engine.insertImportedObjects([NoteImportedObject(staged: item, pixelSize: nil)])
                case 19: // an image attachment and its owned bytes
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    if let bytes = bitmap?.representation(using: .png, properties: [:]) {
                        let item = StagedNoteAttachment(id: UUID(), filename: "image.png",
                            contentTypeIdentifier: "public.png", byteCount: Int64(bytes.count),
                            digest: NotePayloadDigest.sha256(bytes), data: bytes)
                        _ = engine.insertImage(item, pixelSize: CGSize(width: 2, height: 2))
                    }
                case 20: // delete an actual file/image attachment if one exists
                    if let object = engine.objects().first(where: { $0.0 is NoteFileAttachment || $0.0 is NoteImageAttachment }) {
                        _ = engine.performEdit(object.1, with: NSAttributedString(), name: "Delete Attachment")
                    }
                case 21:
                    engine.find.inTopRow = true
                    engine.find.show(); engine.find.query = "words"
                    engine.find.next(); engine.find.close()
                case 22:
                    engine.find.inTopRow = true
                    engine.find.show(); engine.find.query = "words"
                    if let match = engine.find.matches.first(where: { $0.tableID == nil }) {
                        _ = engine.performEdit(match.noteRange,
                            with: NSAttributedString(string: "terms"), name: "Replace Found Text")
                    }
                    engine.find.close()
                default:
                    _ = engine.perform(.mark(.bold),
                         selection: NSRange(location: line.location, length: min(3, line.length)))
                }
                if !engine.document().blocks.allSatisfy({ $0.table?.isRectangular != false }) {
                    return (step, "\(label): ragged table")
                }
                let actual: Data
                do { actual = try saved(engine) }
                catch { return (step, "\(label): save/reload or attachment bytes \(error)") }
                let selected = view.selectedRange()
                if selected.location == NSNotFound || selected.location > engine.textStorage.length ||
                    selected.length > engine.textStorage.length - selected.location {
                    return (step, "\(label): selection out of bounds: \(selected)")
                }
                if selected.length == 0, window.firstResponder === view {
                    if let textRange = engine.textRange(for: selected) {
                        engine.layoutManager?.ensureLayout(for: textRange)
                    }
                    view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                    view.layoutSubtreeIfNeeded()
                    guard let caret = engine.caretRect(at: selected.location) else {
                        return (step, "\(label): caret has no layout geometry")
                    }
                    let visible = view.convert(scroll.contentView.bounds, from: scroll.contentView)
                    if caret.maxY < visible.minY - 1 || caret.minY > visible.maxY + 1 {
                        return (step, "\(label): caret is offscreen: \(caret), viewport=\(visible)")
                    }
                }
                if engine.history.recordingGeneration != generation {
                    // A new user command truncates Redo and is one replayable step.
                    checkpoints = Array(checkpoints.prefix(current + 1))
                    checkpoints.append(actual)
                    current += 1
                    if !engine.undoCommand() { return (step, "\(label): cannot undo edit") }
                    if (try? saved(engine)) != before { return (step, "\(label): undo differs from before") }
                    if !engine.redoCommand() { return (step, "\(label): cannot redo edit") }
                    guard let redone = try? saved(engine) else {
                        return (step, "\(label): save after redo failed")
                    }
                    if redone != actual {
                        return (step, "\(label): redo differs from after: \(firstDifference(actual, redone))")
                    }
                } else if actual != before { return (step, "\(label): unrecorded edit") }
                if current > 0 && step % 13 == 0 {
                    if !engine.undoCommand() { return (step, "\(label): intermediate undo refused") }
                    if (try? saved(engine)) != checkpoints[current - 1] {
                        return (step, "\(label): intermediate undo mismatched prior checkpoint")
                    }
                    if !engine.redoCommand() || (try? saved(engine)) != checkpoints[current] {
                        return (step, "\(label): intermediate redo mismatch")
                    }
                }
                // The full history is a reversible document transformation after
                // EVERY generated command, not just at the end of the sequence.
                if current > 0 {
                    for _ in 0..<current {
                        if !engine.undoCommand() { return (step, "\(label): full-history undo refused") }
                    }
                    if (try? saved(engine)) != beginning {
                        return (step, "\(label): full-history undo differs from original")
                    }
                    for _ in 0..<current {
                        if !engine.redoCommand() { return (step, "\(label): full-history redo refused") }
                    }
                    if let replayed = try? saved(engine), replayed != actual {
                        return (step, "\(label): full-history redo differs from final: \(firstDifference(actual, replayed))")
                    }
                }
                return nil
            }
            if let failure { return failure }
        }
        let final = (try? saved(engine)) ?? Data()
        if current > 0 {
            for index in stride(from: current - 1, through: 0, by: -1) {
                if !engine.undoCommand() || (try? saved(engine)) != checkpoints[index] {
                    return (actions.count, "undo-all mismatch at history index \(index)")
                }
            }
        }
        if (try? saved(engine)) != beginning { return (actions.count, "undo-all differs from original") }
        if current > 0 {
            for index in 1...current {
                if !engine.redoCommand() || (try? saved(engine)) != checkpoints[index] {
                    return (actions.count, "redo-all mismatch at history index \(index)")
                }
            }
        }
        if (try? saved(engine)) != final { return (actions.count, "redo-all differs from final") }
        return nil
    }

    private func shrink(_ actions: [Action], through first: Int) -> [Action] {
        var minimal = Array(actions.prefix(min(actions.count, first + 1)))
        var chunk = max(1, minimal.count / 2)
        while chunk > 0 {
            var start = 0
            while start < minimal.count {
                var candidate = minimal
                candidate.removeSubrange(start..<min(start + chunk, candidate.count))
                if !candidate.isEmpty, autoreleasepool(invoking: { replay(candidate) != nil }) {
                    minimal = candidate; start = 0
                }
                else { start += chunk }
            }
            chunk = chunk == 1 ? 0 : max(1, chunk / 2)
        }
        return minimal
    }

    private func assertSeed(_ seed: Int) {
        var random = Random(state: UInt64(seed))
        let actions = (0..<280).map { _ in Action(kind: random.next(24), a: random.next(10_000), b: random.next(10_000)) }
        if let failure = replay(actions) {
            let minimal = shrink(actions, through: failure.0)
            XCTFail("seed=\(seed), \(failure.1), minimal=\(minimal)")
            return
        }
        print("NOTES_HUNT_FUZZ seed=\(seed) steps=\(actions.count) status=pass")
    }

    // Separate XCTest cases give each 280-step run its own autorelease pool
    // and test-time allowance while keeping the same deterministic sequence.
    func testGeneratedSeed11012() { assertSeed(11012) }
    func testGeneratedSeed11013() { assertSeed(11013) }
    func testGeneratedSeed11014() { assertSeed(11014) }
    func testGeneratedSeed11015() { assertSeed(11015) }

    func testRegressionUndoRedoAfterPastesAndAttachments() {
        // Shrunk from seed 11014, first divergence at step 37.
        let actions: [Action] = [
            .init(kind: 10, a: 8540, b: 7952),
            .init(kind: 10, a: 6844, b: 6142),
            .init(kind: 19, a: 4595, b: 6865),
            .init(kind: 3, a: 391, b: 5632),
            .init(kind: 8, a: 3937, b: 6386),
            .init(kind: 20, a: 8665, b: 1315),
            .init(kind: 18, a: 8336, b: 6202),
            .init(kind: 20, a: 160, b: 5131),
            .init(kind: 18, a: 4695, b: 9039),
            .init(kind: 9, a: 8047, b: 6393)
        ]
        XCTAssertNil(replay(actions))
    }

    /// Hosted frame candidate = edit + TextKit viewport layout + the pending
    /// AppKit draw pass. This is deliberately not display scan-out latency.
    /// The production NoteKeystrokeToLayout / NoteKeystrokeToDraw signposts
    /// bracket the same phases, including when Instruments is attached.
    func testLongNotesKeystrokeToFrameCandidateByPosition() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        func percentile(_ measurements: [Double], _ p: Double) -> Double {
            let sorted = measurements.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        func measure(_ edit: () -> Void, view: NoteEditorTextView) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            PerformanceSignposts.beginNoteKey()
            edit()
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            PerformanceSignposts.noteDidLayout()
            PerformanceSignposts.noteDidDraw()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        // The text scale is the only difference: both notes have 3 tables
        // and 10 byte-backed images. Each generated line contains 10 words.
        for (cohort, count) in [("short", 30), ("long", 1_000)] {
            let tableLines: Set<Int> = count == 30 ? [4, 14, 24] : [100, 500, 900]
            let imageLines: Set<Int> = count == 30
                ? Set((0..<10).map { $0 * 3 + 1 })
                : Set((0..<10).map { $0 * 100 + 50 })
            var blocks: [NoteBlock] = [.text("Latency probe")]
            var images: [StagedNoteAttachment] = []
            for index in 0..<count {
                blocks.append(.text("L\(index) alpha bravo charlie delta echo foxtrot golf hotel india"))
                if tableLines.contains(index) {
                    blocks.append(.table(NoteTable(texts: [["A", "B"], ["one", "two"]])))
                }
                if imageLines.contains(index) {
                    let id = UUID()
                    images.append(StagedNoteAttachment(id: id, filename: "hunt-\(index).png",
                        contentTypeIdentifier: "public.png", byteCount: Int64(png.count),
                        digest: NotePayloadDigest.sha256(png), data: png))
                    blocks.append(.image(attachmentID: id, pixelWidth: 2, pixelHeight: 2))
                }
            }
            XCTAssertEqual(blocks.filter { $0.kind == .table }.count, 3)
            XCTAssertEqual(images.count, 10)
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks),
                stagedAttachments: images)
            let (scroll, view) = engine.makeView()
            scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { engine.find.close(); engine.detachView(); window.close() }
            scroll.layoutSubtreeIfNeeded()

            for (position, number) in [("top", 0), ("middle", count / 2), ("end", count - 1)] {
                let marker = "L\(number) alpha"
                let found = (engine.textStorage.string as NSString).range(of: marker)
                XCTAssertNotEqual(found.location, NSNotFound)
                guard found.location != NSNotFound else { continue }
                view.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
                view.scrollRangeToVisible(view.selectedRange())
                view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                view.displayIfNeeded()
                let samples = Array("ordinary typing over a long note").map { character in
                    measure({ view.insertText(String(character), replacementRange: view.selectedRange()) }, view: view)
                }
                print(String(format: "NOTES_HUNT_LATENCY note=%@ position=%@ words=%d tables=3 images=10 n=%d median_ms=%.3f p90_ms=%.3f max_ms=%.3f",
                    cohort, position, count * 10, samples.count, percentile(samples, 0.5),
                    percentile(samples, 0.9), samples.max() ?? 0))
            }

            let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
            let tableRange = try XCTUnwrap(engine.range(ofTable: attachment))
            view.scrollRangeToVisible(tableRange)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            view.displayIfNeeded()
            attachment.tableView.activate(.init(row: 0, column: 0), caret: .end)
            let cell = attachment.tableView.editor
            let tableSamples = Array("table cell typing for notes").map { character in
                measure({ cell.insertText(String(character), replacementRange: cell.selectedRange()) }, view: view)
            }
            print(String(format: "NOTES_HUNT_LATENCY note=%@ position=table words=%d tables=3 images=10 n=%d median_ms=%.3f p90_ms=%.3f max_ms=%.3f",
                cohort, count * 10, tableSamples.count, percentile(tableSamples, 0.5),
                percentile(tableSamples, 0.9), tableSamples.max() ?? 0))
        }
    }
}
