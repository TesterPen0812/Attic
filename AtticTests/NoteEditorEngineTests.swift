import AppKit
import XCTest
@testable import Attic

/// The TextKit 2 engine: editor-owned undo (requirement 4), the object
/// guard for Find and Writing Tools (requirements 3 and 9), stable object
/// identity, IME over a selection, VoiceOver elements.
@MainActor
final class NoteEditorEngineTests: XCTestCase {
    private let checklistID = UUID()
    private let dateID = UUID()
    private let imageID = UUID()
    private let attachmentID = UUID()

    private func sample() -> NoteDocument {
        var dated = NoteBlock.text("Due \u{FFFC} for sure")
        dated.inlines = [NoteInline(id: dateID, kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        return NoteDocument(blocks: [
            .text("Title"),
            .text("Hello world"),
            .checklist("Buy cake", id: checklistID),
            dated,
            .image(id: imageID, attachmentID: attachmentID, pixelWidth: 800, pixelHeight: 400),
            .text("End")
        ])
    }

    private func makeEngine(_ document: NoteDocument? = nil, window: Bool = false) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document ?? sample())
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        if window {
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled],
                                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = scrollView
            windows.append(host)
        }
        return (engine, textView)
    }

    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func location(of text: String, in engine: NoteEditorEngine) -> Int {
        (engine.textStorage.string as NSString).range(of: text).location
    }

    /// Typing as a person does (the sanctioned path).
    private func type(_ text: String, _ textView: NoteEditorTextView) {
        for character in text { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // MARK: Drawing

    func testObjectsAreDrawnFromTheDesignSystem() {
        let (engine, _) = makeEngine()
        for (object, _) in engine.objects() where !(object is NoteImageAttachment) {
            let image = object.image
            XCTAssertNotNil(image, "\(String(describing: Swift.type(of: object))) has an image TextKit 2 can draw")
            XCTAssertGreaterThan(image?.size.width ?? 0, 4)
            XCTAssertGreaterThan(image?.size.height ?? 0, 4)
            XCTAssertNotNil(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    // MARK: Round trip

    func testDocumentSurvivesTheTextSystem() {
        let document = sample()
        XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: document), document)
        let (engine, _) = makeEngine()
        XCTAssertEqual(engine.document(), document)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
    }

    func testCachedFinalParagraphMatchesFullExtractionAndInvalidatesForObjectsAndNewlines() {
        let document = NoteDocument(blocks: (0..<500).map { .text("Line \($0)") })
        let (engine, _) = makeEngine(document)
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        for _ in 0..<10 {
            engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                               with: NSAttributedString(string: "x"), name: "Typing")
            XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        }
        engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: "\nAnother line"), name: "Typing")
        XCTAssertEqual(engine.document(), NoteTextCodec.document(from: engine.textStorage))
    }

    func testTitleStyleFollowsTheFirstParagraph() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertNewline(nil)
        let titleFont = engine.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let secondFont = engine.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        XCTAssertEqual(titleFont?.pointSize, AtticTextStyle.noteTitle.nsFont.pointSize)
        XCTAssertEqual(secondFont?.pointSize, AtticTextStyle.noteBody.nsFont.pointSize)
        XCTAssertEqual(engine.document().blocks.prefix(2).map(\.text), ["Ti", "tle"])
    }

    // MARK: Editor-owned undo

    func testTypingCoalescesAndUndoesInOneStep() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type(" of note", textView)
        XCTAssertEqual(engine.document().blocks.last?.text, "End of note")
        XCTAssertEqual(engine.history.undoOps.count, 1)
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        XCTAssertEqual(engine.document().blocks.last?.text, "End of note")
    }

    func testLongUninterruptedTypingRemainsOneUndoStep() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        let started = DispatchTime.now().uptimeNanoseconds
        type(String(repeating: "x", count: 2_000), textView)
        print("NOTE_LONG_TYPING_MS=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        XCTAssertEqual(engine.history.undoOps.count, 1)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document(), sample())
    }

    func testCheckboxHitTestingDeepInALargeDocument() throws {
        var blocks = [NoteBlock.text("Title")]
        blocks += (0..<2_000).map { NoteBlock.text("Line \($0)") }
        blocks.append(.checklist("Deep item"))
        let (engine, textView) = makeEngine(NoteDocument(blocks: blocks))
        let index = (engine.textStorage.string as NSString).range(of: "\u{FFFC}Deep item").location
        XCTAssertNotEqual(index, NSNotFound)
        let range = NSRange(location: index, length: 1)
        engine.contentStorage.primaryTextLayoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        let rect = try XCTUnwrap(engine.rect(for: range))
        let point = NSPoint(x: rect.minX + 4, y: rect.midY)
        XCTAssertEqual(textView.checkboxLocation(at: point), index)
    }

    /// Finding D: a composition that replaces a selection undoes back to the
    /// selected text, and redoes to the committed text.
    func testCompositionReplacingASelectionUndoesAndRedoes() {
        let (engine, textView) = makeEngine()
        let world = NSRange(location: location(of: "world", in: engine), length: 5)
        textView.setSelectedRange(world)
        textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(engine.document().blocks[1].text, "Hello 日本")
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks[1].text, "Hello world")
        engine.history.redo()
        XCTAssertEqual(engine.document().blocks[1].text, "Hello 日本")
        XCTAssertEqual(engine.document().objectIDs, sample().objectIDs, "objects untouched throughout")
    }

    func testCompositionOverAnObjectRemovesItAndUndoBringsTheSameObjectBack() {
        let (engine, textView) = makeEngine()
        let dateLocation = location(of: "\u{FFFC} for", in: engine)
        textView.setSelectedRange(NSRange(location: dateLocation, length: 1))
        textView.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("明日", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.objectIDs().contains(dateID))
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
    }

    /// Autocorrect parity. AppKit applies a correction as a change through
    /// `shouldChangeText` + a storage replacement + `didChangeText` (the
    /// step stock NSTextView records as "Undo Correction"). The same change
    /// on this editor and on a stock NSTextView with built-in undo gives the
    /// same text after the correction, after Undo and after Redo. The real
    /// text-checking entry point is exercised too when AppKit applies it
    /// headlessly (it does not always without a spelling server session).
    func testAutocorrectParityWithStockTextView() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("teh cat")]))
        let stockUndo = UndoManager()
        let stockDelegate = StockUndoDelegate(undoManager: stockUndo)
        let stock = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        stock.delegate = stockDelegate
        stock.allowsUndo = true
        stock.string = "Title\nteh cat"
        let range = NSRange(location: 6, length: 3)
        for view in [textView as NSTextView, stock] {
            view.setSelectedRange(NSRange(location: 9, length: 0))
            XCTAssertTrue(view.shouldChangeText(in: range, replacementString: "the"))
            view.textStorage?.replaceCharacters(in: range, with: "the")
            view.didChangeText()
        }
        XCTAssertEqual(stock.string, "Title\nthe cat")
        XCTAssertEqual(engine.textStorage.string, stock.string)
        stockUndo.undo()
        engine.history.undo()
        XCTAssertEqual(stock.string, "Title\nteh cat")
        XCTAssertEqual(engine.textStorage.string, stock.string)
        stockUndo.redo()
        engine.history.redo()
        XCTAssertEqual(engine.textStorage.string, stock.string)

        // The real entry point, when AppKit applies it here.
        let (engine2, textView2) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("teh cat")]))
        let stock2 = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let stock2Undo = UndoManager()
        let stock2Delegate = StockUndoDelegate(undoManager: stock2Undo)
        stock2.delegate = stock2Delegate
        stock2.allowsUndo = true
        stock2.string = "Title\nteh cat"
        let correction = NSTextCheckingResult.correctionCheckingResult(range: range, replacementString: "the")
        for view in [textView2 as NSTextView, stock2] {
            view.isAutomaticSpellingCorrectionEnabled = true
            view.setSelectedRange(NSRange(location: 9, length: 0))
            view.handleTextCheckingResults([correction], forRange: NSRange(location: 6, length: 7),
                                           types: NSTextCheckingResult.CheckingType.correction.rawValue,
                                           options: [:], orthography: NSOrthography.defaultOrthography(forLanguage: "en"),
                                           wordCount: 2)
        }
        if stock2.string == "Title\nthe cat" {
            XCTAssertEqual(engine2.textStorage.string, stock2.string)
            stock2Undo.undo()
            engine2.history.undo()
            XCTAssertEqual(engine2.textStorage.string, stock2.string)
        }
    }

    func testOutsideEditRebasesHistoryInsteadOfCorruptingText() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type(" typed", textView)
        // An edit from outside the history, above the typing (e.g. a rename).
        engine.history.performUnrecorded {
            engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Renamed title")
        }
        engine.history.rebase(editAt: NSRange(location: 0, length: 5), newLength: 13)
        engine.history.undo()
        XCTAssertEqual(engine.document().blocks.first?.text, "Renamed title")
        XCTAssertEqual(engine.document().blocks.last?.text, "End")
    }

    // MARK: Object guard: Find and Replace (requirement 9)

    func testReplaceThroughTheFindClientCannotRemoveAnObject() {
        let (engine, textView) = makeEngine()
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        // What NSTextFinder's single Replace does to its client.
        XCTAssertFalse(textView.shouldChangeText(in: date, replacementString: ""))
        // Replace All asks for every match at once.
        let box = NSRange(location: location(of: "\u{FFFC}Buy", in: engine), length: 1)
        XCTAssertFalse(textView.shouldChangeText(inRanges: [NSValue(range: box), NSValue(range: date)], replacementStrings: ["", ""]))
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.refusals.count, 2)
        // Plain text is still replaceable that way.
        XCTAssertTrue(textView.shouldChangeText(in: NSRange(location: location(of: "world", in: engine), length: 5), replacementString: "there"))
    }

    func testRealFindBarReplaceAndReplaceAllCannotRemoveObjects() throws {
        let (engine, textView) = makeEngine(window: true)
        textView.window?.makeFirstResponder(textView)
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        textView.setSelectedRange(date)
        func perform(_ action: NSTextFinder.Action) {
            let item = NSMenuItem()
            item.tag = action.rawValue
            textView.performTextFinderAction(item)
        }
        perform(.showReplaceInterface)
        // Control: the same flow replaces plain text, so the harness really
        // drives Replace (with the find bar's empty replacement).
        let world = NSRange(location: location(of: "world", in: engine), length: 5)
        textView.setSelectedRange(world)
        perform(.setSearchString)
        textView.setSelectedRange(world)
        perform(.replace)
        XCTAssertFalse(engine.textStorage.string.contains("world"), "control: Replace ran")
        let movedDate = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: movedDate), "\u{FFFC}")
        textView.setSelectedRange(movedDate)
        perform(.setSearchString)        // ⌘E with the date selected: the find string is its U+FFFC
        textView.setSelectedRange(movedDate)
        XCTAssertEqual((engine.textStorage.string as NSString).substring(with: textView.selectedRange()), "\u{FFFC}")
        perform(.replace)                // single Replace (empty replacement)
        perform(.replaceAll)
        perform(.replaceAndFind)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID], "no object removed by Find")
    }

    func testNativeRichTextCommandsAreDisabledUntilTheFormatStoresMarks() {
        let (engine, textView) = makeEngine()
        XCTAssertFalse(textView.isRichText)
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
    }

    func testImageWidthFollowsTheTextColumn() {
        let image = NoteImageAttachment(attachmentID: UUID(), preferredWidthFraction: 0.5,
                                        pixelSize: CGSize(width: 2_000, height: 1_000))
        XCTAssertEqual(image.displaySize(columnWidth: 200).width, 100)
        XCTAssertEqual(image.displaySize(columnWidth: 400).width, 200)
    }

    func testPersonsOwnEditingMayRemoveObjectsAndUndoRestoresTheSameIDs() {
        let (engine, textView) = makeEngine()
        let date = NSRange(location: location(of: "\u{FFFC} for", in: engine), length: 1)
        textView.setSelectedRange(date)
        textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.objectIDs().contains(dateID))
        engine.history.undo()
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        textView.setSelectedRange(NSRange(location: 0, length: engine.textStorage.length))
        textView.delete(nil)
        XCTAssertTrue(engine.objectIDs().isEmpty)
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
    }

    // MARK: Writing Tools (requirement 3)

    func testWritingToolsCannotRemoveObjectsDuringASession() {
        let (engine, textView) = makeEngine()
        engine.writingToolsWillBegin()
        let box = NSRange(location: location(of: "\u{FFFC}Buy", in: engine), length: 1)
        textView.setSelectedRange(box)
        textView.insertText("rewritten", replacementRange: box)
        XCTAssertTrue(engine.objectIDs().contains(checklistID))
        // Prose changes are allowed.
        textView.insertText("Hi", replacementRange: NSRange(location: location(of: "Hello", in: engine), length: 5))
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document().blocks[1].text, "Hi world")
        XCTAssertEqual(engine.writingToolsRecoveries, 0)
        XCTAssertTrue(engine.writingToolsProtectedRanges(in: NSRange(location: 0, length: engine.textStorage.length))
            .contains { engine.rangeContainsObject($0) })
    }

    /// Layer 2: a removal that slipped past the guard is recovered, and
    /// neither Undo nor Redo can bring the loss back.
    func testWritingToolsRecoveryCannotBeUndoneOrRedoneIntoObjectLoss() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "End", in: engine) + 3, length: 0))
        type("!", textView)                                     // an earlier step of the person's own
        let before = engine.document()
        engine.writingToolsWillBegin()
        let whole = NSRange(location: location(of: "Hello", in: engine), length: engine.textStorage.length - location(of: "Hello", in: engine))
        // A rewrite that reaches the storage without asking (bypassing the guard).
        engine.textStorage.replaceCharacters(in: whole, with: NSAttributedString(string: "All prose now."))
        XCTAssertTrue(engine.objectIDs().isEmpty)
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document(), before, "objects and text restored")
        XCTAssertEqual(engine.writingToolsRecoveries, 1)
        XCTAssertFalse(engine.history.canRedo)
        engine.history.redo()
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        engine.history.undo()                                   // undoes the person's "!", nothing else
        XCTAssertEqual(engine.objectIDs(), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.document().blocks.last?.text, "End")
        engine.history.redo()
        XCTAssertEqual(engine.document(), before)
    }

    func testRefusedWritingToolsSessionIsFrozenAndRestoresExactly() throws {
        let (engine, textView) = makeEngine()
        type("!", textView)
        let before = engine.document()
        let undoBefore = engine.history.canUndo
        engine.onWritingToolsWillBegin = { false }
        engine.writingToolsWillBegin()
        XCTAssertEqual(engine.activity, .writingToolsRefused)
        let box = try XCTUnwrap(engine.objects().first?.1)
        engine.toggleCheckbox(atLineOf: box.location)
        engine.insertDate(NoteDay(year: 2026, month: 10, day: 2)!)
        XCTAssertFalse(engine.history.undo())
        XCTAssertFalse(engine.history.redo())
        XCTAssertFalse(engine.performEdit(NSRange(location: 0, length: 0), with: NSAttributedString(string: "typed"), name: "Typing"))
        engine.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Rewrite")
        XCTAssertEqual(engine.checkpointDocument(), before)
        engine.writingToolsDidEnd()
        XCTAssertEqual(engine.document(), before)
        XCTAssertEqual(engine.history.canUndo, undoBefore)
        XCTAssertFalse(engine.history.canRedo)
        XCTAssertEqual(engine.activity, .idle)
    }

    func testImportedBatchIsOneUndoStepAndAnchorFollowsTyping() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Body")]))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        engine.beginImageImport()
        type(" plus", textView)
        let first = StagedNoteAttachment(id: UUID(), filename: "one.png", contentTypeIdentifier: "public.png",
                                         byteCount: 1, digest: String(repeating: "a", count: 64), data: Data([1]))
        let second = StagedNoteAttachment(id: UUID(), filename: "two.png", contentTypeIdentifier: "public.png",
                                          byteCount: 1, digest: String(repeating: "b", count: 64), data: Data([2]))
        XCTAssertTrue(engine.insertImportedImages([(first, nil), (second, nil)]))
        XCTAssertEqual(engine.document().title, "Title plus")
        XCTAssertEqual(engine.document().attachmentIDs, [first.id, second.id])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().title, "Title plus")
        XCTAssertTrue(engine.document().attachmentIDs.isEmpty)
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.document().attachmentIDs, [first.id, second.id])
    }

    func testImportAnchorClampsWhenItsParagraphIsDeleted() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Middle"), .text("After")]))
        let middle = location(of: "Middle", in: engine)
        textView.setSelectedRange(NSRange(location: middle + 3, length: 0))
        engine.beginImageImport()
        XCTAssertTrue(engine.performEdit(NSRange(location: middle, length: 6),
                                         with: NSAttributedString(string: ""), name: "Delete Middle"))
        let image = StagedNoteAttachment(id: UUID(), filename: "image.png", contentTypeIdentifier: "public.png",
                                         byteCount: 1, digest: String(repeating: "a", count: 64), data: Data([1]))
        XCTAssertTrue(engine.insertImportedImages([(image, nil)]))
        let blocks = engine.document().blocks
        let imageIndex = try? XCTUnwrap(blocks.firstIndex { $0.attachmentID == image.id })
        let afterIndex = try? XCTUnwrap(blocks.firstIndex { $0.text == "After" })
        XCTAssertNotNil(imageIndex)
        XCTAssertNotNil(afterIndex)
        if let imageIndex, let afterIndex { XCTAssertLessThan(imageIndex, afterIndex) }
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.document().attachmentIDs.isEmpty)
        XCTAssertFalse(engine.document().blocks.contains { $0.text == "Middle" })
    }

    // MARK: Object identity

    func testChecklistTickKeepsIdentityAndUndoes() {
        let (engine, _) = makeEngine()
        engine.toggleCheckbox(atLineOf: location(of: "Buy", in: engine))
        XCTAssertEqual(engine.document().blocks[2].id, checklistID)
        XCTAssertTrue(engine.document().blocks[2].checked)
        engine.history.undo()
        XCTAssertFalse(engine.document().blocks[2].checked)
        XCTAssertEqual(engine.document().blocks[2].id, checklistID)
    }

    func testCopyPasteMintsNewIDsAndCutPasteKeepsThem() {
        let (engine, textView) = makeEngine()
        let lines = NSRange(location: location(of: "\u{FFFC}Buy", in: engine),
                            length: location(of: "End", in: engine) - location(of: "\u{FFFC}Buy", in: engine))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-test-\(UUID().uuidString)"))
        XCTAssertTrue(engine.writeSelection(lines, to: pasteboard, types: [NoteEditorEngine.fragmentType, .string]))
        let data = pasteboard.data(forType: NoteEditorEngine.fragmentType)!

        // Copy then paste: new objects beside the originals.
        let end = engine.textStorage.length
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: end, length: 0)))
        let ids = engine.objectIDs()
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6, "no duplicate ids")
        XCTAssertEqual(Array(ids.prefix(3)), [checklistID, dateID, imageID])
        XCTAssertEqual(engine.document().attachmentIDs, [attachmentID, attachmentID], "same note: the same stored image")
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())

        // Cut then paste: the same objects.
        textView.setSelectedRange(lines)
        textView.delete(nil)
        XCTAssertTrue(engine.objectIDs().isEmpty)
        XCTAssertTrue(engine.paste(fragmentData: data, at: NSRange(location: engine.textStorage.length, length: 0)))
        XCTAssertEqual(Set(engine.objectIDs()), [checklistID, dateID, imageID])
        engine.history.undo()
        engine.history.undo()
        XCTAssertEqual(engine.document(), sample())
        engine.history.redo()
        engine.history.redo()
        XCTAssertEqual(Set(engine.objectIDs()), [checklistID, dateID, imageID])
    }

    func testPasteIntoAnotherNoteCopiesImagesAndARefusedPasteLeavesNothingStaged() {
        let (source, _) = makeEngine()
        let all = NSRange(location: 0, length: source.textStorage.length)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("attic-test-\(UUID().uuidString)"))
        XCTAssertTrue(source.writeSelection(all, to: pasteboard, types: [NoteEditorEngine.fragmentType]))
        let data = pasteboard.data(forType: NoteEditorEngine.fragmentType)!

        let provider = StubImages(bytes: [attachmentID: Data([9, 9])])
        let (destination, _) = makeEngine(NoteDocument(blocks: [.text("Other")]))
        destination.imageProvider = provider
        XCTAssertTrue(destination.paste(fragmentData: data, at: NSRange(location: destination.textStorage.length, length: 0)))
        let pasted = destination.document()
        XCTAssertTrue(Set(pasted.objectIDs).isDisjoint(with: [checklistID, dateID, imageID]))
        XCTAssertNotEqual(pasted.attachmentIDs.first, attachmentID, "copied into a new attachment for this note")
        XCTAssertEqual(destination.stagedAttachments(for: pasted).count, 1)

        // Read-only: the paste is refused and nothing is staged.
        let readOnly = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("RO")]), readOnly: true)
        readOnly.imageProvider = provider
        XCTAssertFalse(readOnly.paste(fragmentData: data, at: NSRange(location: 2, length: 0)))
        XCTAssertTrue(readOnly.staged.isEmpty)
    }

    func testChecklistReturnContinuesAndBackspaceRemovesTheBoxFirst() {
        let (engine, textView) = makeEngine()
        textView.setSelectedRange(NSRange(location: location(of: "Buy cake", in: engine) + 8, length: 0))
        textView.insertNewline(nil)
        type("Milk", textView)
        let blocks = engine.document().blocks
        XCTAssertEqual(blocks[3].kind, .checklist)
        XCTAssertEqual(blocks[3].text, "Milk")
        XCTAssertNotEqual(blocks[3].id, checklistID)
        textView.setSelectedRange(NSRange(location: location(of: "Milk", in: engine), length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks[3].kind, .text)
        XCTAssertEqual(engine.document().blocks[3].text, "Milk")
    }

    // MARK: VoiceOver

    func testObjectsAreAccessibilityElements() {
        let (engine, textView) = makeEngine(window: true)
        let elements = engine.accessibilityElements(for: textView)
        XCTAssertEqual(elements.map { $0.accessibilityRole() }, [.checkBox, .button, .image])
        XCTAssertEqual(elements.first?.accessibilityLabel(), "Buy cake")
        XCTAssertEqual(elements.first?.accessibilityValue() as? Int, 0)
        XCTAssertTrue(elements[1].accessibilityLabel()?.hasPrefix("Date,") ?? false)
        XCTAssertTrue(textView.accessibilityChildren()?.contains { ($0 as AnyObject) === elements[0] } == false,
                      "elements are made per request")
        XCTAssertTrue(elements.first?.accessibilityPerformPress() ?? false)
        XCTAssertTrue(engine.document().blocks[2].checked)
        let spoken = textView.accessibilityAttributedString(for: NSRange(location: 0, length: engine.textStorage.length))
        var attached = 0
        spoken?.enumerateAttribute(.accessibilityAttachment, in: NSRange(location: 0, length: spoken?.length ?? 0)) { value, _, _ in
            if value != nil { attached += 1 }
        }
        XCTAssertEqual(attached, 3)
    }

    // MARK: Performance (5,000 lines, 100 objects)

    func testKeystrokeUpkeepOnAStressNote() throws {
        var blocks: [NoteBlock] = [.text("Stress")]
        for index in 0..<5_000 {
            guard index % 50 == 10 else {
                blocks.append(.text("Line \(index) with some ordinary words to wrap a little in a narrow panel."))
                continue
            }
            switch (index / 50) % 3 {
            case 0: blocks.append(.checklist("Item \(index)"))
            case 1:
                var line = NoteBlock.text("Due \u{FFFC} line \(index)")
                line.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
                blocks.append(line)
            default: blocks.append(.image(attachmentID: UUID(), pixelWidth: 1200, pixelHeight: 600))
            }
        }
        let document = NoteDocument(blocks: blocks)
        XCTAssertEqual(document.objectIDs.count, 100)
        let (engine, textView) = makeEngine(document, window: true)
        textView.layoutSubtreeIfNeeded()
        let middle = location(of: "Line 2501 ", in: engine)
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        textView.displayIfNeeded()
        var samples: [Double] = []
        var upkeep: [Double] = []
        for character in "the quick brown fox jumps over the lazy dog again and again!" {
            let start = DispatchTime.now().uptimeNanoseconds
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            textView.displayIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            upkeep.append(engine.lastUpkeepMilliseconds)
        }
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        let encoded = try NoteContentCodec.encode(engine.document())
        let encodeMs = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 1_000_000
        func pct(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        let report = String(format: "NOTE-PERF keystroke median %.2f ms p95 %.2f ms max %.2f ms; upkeep median %.3f ms; document+encode %.1f ms (%d bytes)",
                            pct(samples, 0.5), pct(samples, 0.95), samples.max() ?? 0, pct(upkeep, 0.5), encodeMs, encoded.count)
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        XCTAssertLessThan(pct(upkeep, 0.5), 5, "per-edit upkeep stays local")
    }
}

private final class StockUndoDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(undoManager: UndoManager) { manager = undoManager }
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

@MainActor
private final class StubImages: NoteImageProviding {
    let bytes: [UUID: Data]
    init(bytes: [UUID: Data]) { self.bytes = bytes }
    func fileURL(forAttachment id: UUID) async -> URL? { nil }
    func filename(forAttachment id: UUID) -> String? { bytes[id] == nil ? nil : "shot.png" }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? {
        bytes[id].map { StagedNoteAttachment(id: id, filename: "shot.png", contentTypeIdentifier: "public.png",
                                             byteCount: Int64($0.count), digest: "d", data: $0) }
    }
}
