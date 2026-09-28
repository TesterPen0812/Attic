import AppKit
import CryptoKit
import SwiftData
import XCTest
@testable import Attic

/// Slice 2, "Everyday capture and return": the title's boundaries and its
/// hashtag shorthand, tags saved with the note, New note and reopening,
/// Delete and its Undo, Duplicate, Pin, Copy as Markdown, and All notes.
@MainActor
final class NotesSlice2EngineTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    private func makeEngine(_ document: NoteDocument, tags: [String] = []) -> (NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: document, tags: tags)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        let host = NSWindow(contentRect: scrollView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = scrollView
        windows.append(host)
        return (engine, textView)
    }

    private func type(_ text: String, _ textView: NoteEditorTextView) {
        for character in text {
            if character == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private func caretAtEnd(of engine: NoteEditorEngine, _ textView: NoteEditorTextView) {
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
    }

    // MARK: Title hashtags

    func testSpaceAfterAHashtagInTheTitleTakesTheTagAsOneUndoStep() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Pricing")]))
        var tagChanges = 0
        engine.onTagsChange = { tagChanges += 1 }
        caretAtEnd(of: engine, textView)
        type(" #Launch ", textView)
        XCTAssertEqual(engine.tags, ["launch"])
        XCTAssertEqual(engine.document().title, "Pricing ")
        XCTAssertEqual(textView.selectedRange().location, 8, "the caret stays where the tag was")
        XCTAssertEqual(tagChanges, 1)
        XCTAssertEqual(engine.history.undoActionName, "Add Tag")

        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().title, "Pricing #Launch", "one Undo brings the text back")
        XCTAssertEqual(engine.tags, [], "and takes the tag away")
        // Undo leaves the hashtag literal: the next Space is a space.
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        type(" ", textView)
        XCTAssertEqual(engine.document().title, "Pricing #Launch ")
        XCTAssertEqual(engine.tags, [])

        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.history.redo())
        XCTAssertTrue(engine.history.undo())
        XCTAssertTrue(engine.history.redo(), "redo of the typed space")
    }

    func testRedoOfTheShorthandAddsTheTagAgain() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Trip")]))
        caretAtEnd(of: engine, textView)
        type(" #kyoto ", textView)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.tags, [])
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.tags, ["kyoto"])
        XCTAssertEqual(engine.document().title, "Trip ")
    }

    func testReturnAfterAHashtagTakesTheTagThenStartsTheBody() {
        let (engine, textView) = makeEngine(NoteDocument.blank)
        type("Groceries #home\nMilk", textView)
        XCTAssertEqual(engine.tags, ["home"])
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Groceries ", "Milk"])
    }

    func testEscapeKeepsTheHashtagAsTextUntilItsHashIsTypedAgain() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Issue")]))
        caretAtEnd(of: engine, textView)
        type(" #design", textView)
        textView.cancelOperation(nil)
        type(" ", textView)
        XCTAssertEqual(engine.tags, [], "Esc keeps it literal")
        XCTAssertEqual(engine.document().title, "Issue #design ")
        // Typed again (a new #), it converts.
        type("#ux ", textView)
        XCTAssertEqual(engine.tags, ["ux"])
    }

    func testEscapeWithNoHashtagPassesOn() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Plain")]))
        caretAtEnd(of: engine, textView)
        XCTAssertFalse(engine.keepTitleHashtagLiteral())
    }

    func testHashtagsInTheBodyNumbersAndPastesStayText() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Body")]))
        caretAtEnd(of: engine, textView)
        type(" #launch ", textView)
        XCTAssertEqual(engine.tags, [], "a body hashtag is text")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        type(" #42 ", textView)
        XCTAssertEqual(engine.tags, [], "#42 is an issue number")
        XCTAssertTrue(engine.pastePlainText(" #pasted ", at: NSRange(location: 5, length: 0)))
        XCTAssertEqual(engine.tags, [], "a pasted hashtag stays text")
        XCTAssertTrue(engine.document().title.contains("#pasted"))
    }

    func testAHashtagInsideAWordStaysText() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("C")]))
        caretAtEnd(of: engine, textView)
        type("#sharp ", textView)
        XCTAssertEqual(engine.tags, [])
    }

    func testNoConversionWhileComposing() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Kanji #tag")]))
        caretAtEnd(of: engine, textView)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.takeTitleHashtag())
        textView.unmarkText()
    }

    // MARK: Title boundaries

    func testBackspaceAtTheBodyStartJoinsTheTextIntoTheTitleAsOneStep() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Pricing"), .text("page")]))
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Pricingpage"])
        XCTAssertEqual(engine.textStorage.attribute(.font, at: 9, effectiveRange: nil) as? NSFont, engine.style.titleFont,
                       "the joined text takes the title's style")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Pricing", "page"])
    }

    func testBackspaceBeforeAnImageUnderTheTitleSelectsTheImage() {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 10, pixelHeight: 10)
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), image, .text("")]))
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1), "the image is selected, not joined")
        XCTAssertEqual(engine.document().blocks.count, 3)
    }

    func testBackspaceBeforeAnImageRemovesAnEmptyLineAbove() {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 10, pixelHeight: 10)
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Text"), .text(""), image]))
        let imageLocation = engine.textStorage.length - 1
        textView.setSelectedRange(NSRange(location: imageLocation, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .image], "the empty line goes")
    }

    func testForwardDeleteAtTheTitleEndRemovesTheCheckboxFirst() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .checklist("Milk")]))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.deleteForward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text], "the box goes, the title never takes it")
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Milk"])
    }

    func testReturnAtTheTitleEndStepsIntoAnEmptyFirstLine() {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text(""), .text("Body")]))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.count, 3, "no extra empty line")
        XCTAssertEqual(textView.selectedRange().location, 6)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        engine.performEdit(NSRange(location: 6, length: 0), with: NSAttributedString(string: "x"), name: "Typing")
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(engine.document().blocks.count, 4, "a first line with text gets a new line above it")
    }

    func testTitleLinesKeepClearOfTheMenuAndReserveTheTagLine() {
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("A title"), .text("Body")]))
        engine.setTitleReserves(tagLine: 15, trailing: 32)
        let style = engine.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.tailIndent, -32)
        XCTAssertEqual(style?.paragraphSpacing, NoteTextStyle.titleToTags + 15 + NoteTextStyle.tagsToBody)
        let body = engine.textStorage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(body?.tailIndent, 0, "the body is not narrowed")
        XCTAssertTrue(engine.history.undoOps.isEmpty, "reserves are never an Undo step")
        XCTAssertEqual(style?.lineSpacing ?? 0, NoteTextStyle.lineSpacing(for: engine.style.titleFont, lineHeight: 22), accuracy: 0.01)
    }

    func testNoteTextIsRounded() {
        XCTAssertTrue(AtticTextStyle.noteTitle.spec.rounded)
        XCTAssertTrue(AtticTextStyle.noteBody.spec.rounded)
    }
}

@MainActor
final class NotesSlice2ControllerTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticSlice2-\(UUID().uuidString)")
        suiteName = "AtticSlice2-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeController(journal: NoteDraftJournaling? = nil) -> NotesPageController {
        NotesPageController(store: store, journal: journal ?? NoteDraftJournal(directory: directory), defaults: defaults,
                            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
    }

    private func type(_ text: String, into session: NoteSession) {
        let engine = session.engine
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: text), name: "Typing")
    }

    private func realImage() throws -> StagedNoteAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return StagedNoteAttachment(id: UUID(), filename: "pixel.png", contentTypeIdentifier: "public.png",
                                    byteCount: Int64(bytes.count), digest: digest, data: bytes)
    }

    private func create(_ blocks: [NoteBlock], tags: [String] = []) throws -> UUID {
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    // MARK: Tags

    func testTagsAreSavedWithTheTextAndATagOnlyChangeKeepsTheRevision() throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let revision = try XCTUnwrap(store.note(withID: id)?.revisionID)
        let updated = try XCTUnwrap(store.note(withID: id)?.updatedAt)
        session.engine.setTags(["launch"])
        XCTAssertEqual(session.state, .dirty, "a tag change is an edit")
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch"])
        XCTAssertEqual(store.note(withID: id)?.revisionID, revision, "tags alone keep the revision")
        XCTAssertEqual(store.note(withID: id)?.updatedAt, updated, "and the note's place in the list")
        XCTAssertEqual(session.state, .clean)
        // Text and a tag in one save.
        type(" page", into: session)
        session.engine.setTags(["launch", "pricing"])
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch", "pricing"])
        XCTAssertEqual(store.note(withID: id)?.title, "Pricing page")
    }

    func testANewNoteWithOnlyATagIsKept() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        session.engine.setTags(["idea"])
        XCTAssertFalse(session.isUntouchedDraft)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.notes.first?.tags, ["idea"])
    }

    func testTagsSetElsewhereReachACleanNoteWhenItIsShown() throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(store.setTags(["agent"], for: try XCTUnwrap(store.note(withID: id))))
        controller.present()
        XCTAssertEqual(session.engine.tags, ["agent"])
        XCTAssertEqual(session.state, .clean, "a refresh is not an edit")
    }

    func testAFailedSaveKeepsTheTagInTheRecoveryCopyAndRecoveryRestoresIt() throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.setTags(["launch"])
        gate.shouldFail = true
        XCTAssertTrue(controller.preserve(session))
        if case .notSaved = session.state {} else { XCTFail("expected Not saved") }
        let entry = try XCTUnwrap(try NoteDraftJournal(directory: directory).entries().first?.0)
        XCTAssertEqual(entry.tags, ["launch"])
        gate.shouldFail = false
        let relaunched = makeController()
        relaunched.recoverAtLaunch()
        relaunched.start()
        XCTAssertEqual(relaunched.active?.noteID, id)
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch"], "the recovered tag is saved")
    }

    // MARK: Opening

    func testNotesReopensTheLastNoteWithItsCaretAndNewNoteIsFresh() throws {
        let id = try create([.text("Pricing"), .text("Lead with the free tier.")])
        let first = makeController()
        XCTAssertTrue(first.open(noteID: id))
        let session = try XCTUnwrap(first.active)
        let (scroll, textView) = session.engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        textView.setSelectedRange(NSRange(location: 12, length: 3))
        XCTAssertTrue(first.prepareToLeave(.hide))

        let second = makeController()
        second.start()
        XCTAssertEqual(second.active?.noteID, id, "Notes resumes the last note viewed")
        XCTAssertEqual(second.active?.selection, NSRange(location: 12, length: 3))
        XCTAssertTrue(second.requestNewNote())
        XCTAssertFalse(second.active?.isPersisted ?? true, "New note always starts fresh")
        XCTAssertEqual(second.librarySelectionID, id, "All notes from a new draft selects the last note visited")
    }

    func testNewNoteFromTheMenuBarBeforeThePageStartsGivesAFreshDraft() throws {
        let id = try create([.text("Pricing")])
        defaults.set(id.uuidString, forKey: "notes.lastViewedNote.v2")
        let controller = makeController()
        XCTAssertTrue(controller.requestNewNote())
        controller.start()
        XCTAssertFalse(controller.active?.isPersisted ?? true)
    }

    func testARecoveredDraftOpensBeforeANewNoteRequest() throws {
        let id = try create([.text("Pricing")])
        let first = makeController()
        XCTAssertTrue(first.open(noteID: id))
        let session = try XCTUnwrap(first.active)
        type(" unsaved", into: session)
        gate.shouldFail = true
        XCTAssertTrue(first.preserve(session))
        gate.shouldFail = false
        let second = makeController()
        second.recoverAtLaunch()
        XCTAssertTrue(second.requestNewNote())
        second.start()
        XCTAssertEqual(second.active?.noteID, id, "recovery comes first")
    }

    func testAnEmptiedNoteIsKeptAsUntitled() throws {
        let id = try create([.text("Temporary"), .text("text")])
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: 0, length: session.engine.textStorage.length),
                                   with: NSAttributedString(), name: "Delete")
        XCTAssertTrue(controller.newNote())
        XCTAssertNotNil(store.note(withID: id), "clearing a note keeps it")
        let summary = NoteRowSummary(note: try XCTUnwrap(store.note(withID: id)), attachments: [])
        XCTAssertEqual(summary.title, "Untitled note")
    }

    // MARK: Delete and Undo

    func testDeletingTheNoteOnScreenSavesItFirstThenShowsAllNotesAndRestoreBringsItBack() throws {
        let id = try create([.text("Pricing")], tags: ["launch"])
        let controller = makeController()
        controller.start()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" latest", into: session)
        XCTAssertEqual(session.state, .dirty)
        XCTAssertTrue(controller.deleteNote(noteID: id))
        XCTAssertNil(controller.active)
        XCTAssertTrue(controller.isLibraryPresented, "deleting the open note shows All notes")
        XCTAssertNil(store.note(withID: id))
        XCTAssertEqual(store.agentWriteDisposition(id), .direct, "no session is left for it")
        XCTAssertTrue(controller.failedDrafts.isEmpty, "never 'Deleted elsewhere'")
        XCTAssertTrue(controller.restoreDeletedNote(noteID: id, reopen: true))
        XCTAssertFalse(controller.isLibraryPresented)
        XCTAssertEqual(controller.active?.noteID, id)
        XCTAssertEqual(controller.active?.engine.document().title, "Pricing latest", "the latest text comes back")
        XCTAssertEqual(controller.active?.engine.tags, ["launch"])
        XCTAssertEqual(controller.active?.state, .clean)
    }

    func testDeleteIsRefusedInAConflictAndWhenTheLatestTextCannotBeSaved() throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" draft", into: session)
        gate.shouldFail = true
        XCTAssertFalse(controller.deleteNote(noteID: id))
        XCTAssertNotNil(store.note(withID: id), "a note whose text can't be saved is not deleted")
        XCTAssertNotNil(session.notice)
        gate.shouldFail = false
        let note = try XCTUnwrap(store.note(withID: id))
        _ = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                             document: NoteDocument(blocks: [.text("Elsewhere")]), agentName: "Test", disposition: .direct)
        _ = controller.preserve(session)
        XCTAssertTrue(session.isConflict)
        XCTAssertFalse(controller.deleteNote(noteID: id), "a conflict keeps its text until Keep as new note")
        XCTAssertNotNil(store.note(withID: id))
    }

    func testDeletingAnUnsavedDraftSavesItThenDeletesIt() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Draft text", into: session)
        let id = session.noteID
        XCTAssertTrue(controller.deleteNote(noteID: id))
        XCTAssertTrue(store.recentlyDeletedNotes().contains { $0.ref.id == id })
    }

    func testDismissingAllNotesAfterADeleteOpensTheLastNoteOrANewDraft() throws {
        let controller = makeController()
        let id = try create([.text("Only")])
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertTrue(controller.deleteNote(noteID: id))
        controller.dismissLibrary()
        XCTAssertNotNil(controller.active)
        XCTAssertFalse(controller.active?.isPersisted ?? true)
    }

    // MARK: Duplicate, pin, Markdown

    func testDuplicateCopiesTextTagsAndImagesAndOpensTheCopy() throws {
        let image = try realImage()
        let blockID = UUID()
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Pricing"), .checklist("Milk"), .image(id: blockID, attachmentID: image.id, pixelWidth: 2, pixelHeight: 2)
        ]), staged: [image], tags: ["launch"]) else { return XCTFail("fixture") }
        let controller = makeController()
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertTrue(controller.duplicateNote(noteID: id))
        let copy = try XCTUnwrap(controller.active)
        XCTAssertNotEqual(copy.noteID, id)
        XCTAssertEqual(copy.engine.document().title, "Pricing copy")
        XCTAssertEqual(copy.engine.tags, ["launch"])
        let copied = try XCTUnwrap(store.loadDocument(noteID: copy.noteID)?.content.document)
        XCTAssertEqual(copied.attachmentIDs.count, 1)
        XCTAssertNotEqual(copied.attachmentIDs.first, image.id, "the image is a copy")
        XCTAssertEqual(try store.attachmentRows(forNoteID: copy.noteID).first?.payload, image.data)
        XCTAssertEqual(try store.attachmentRows(forNoteID: id).count, 1, "the original keeps its image")
    }

    func testPinningIsMetadata() throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        let note = try XCTUnwrap(store.note(withID: id))
        let revision = note.revisionID
        let updated = note.updatedAt
        XCTAssertTrue(controller.setPinned(true, noteID: id))
        XCTAssertTrue(store.note(withID: id)?.isPinned ?? false)
        XCTAssertEqual(store.note(withID: id)?.revisionID, revision)
        XCTAssertEqual(store.note(withID: id)?.updatedAt, updated)
        XCTAssertTrue(controller.setPinned(false, noteID: id))
        XCTAssertFalse(store.note(withID: id)?.isPinned ?? true)
    }

    func testCopyAsMarkdownIsTextOnly() throws {
        var dated = NoteBlock.text("Launch is \u{FFFC}.")
        dated.inlines = [NoteInline(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 1)!))]
        let attachmentID = UUID()
        let document = NoteDocument(blocks: [
            .text("Pricing"), dated, .text(""), .checklist("Final copy", checked: true), .checklist("Screenshots"),
            .text("Plain *stars* stay"), .image(attachmentID: attachmentID)
        ])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let markdown = NoteMarkdownExport.markdown(document, calendar: calendar, locale: Locale(identifier: "en_GB")) {
            $0 == attachmentID ? "pricing-v2.png" : nil
        }
        let day = NoteMarkdownExport.dateText(NoteDay(year: 2026, month: 10, day: 1)!, calendar: calendar,
                                              locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(day.contains("2026") && day.contains("Oct"), day)
        XCTAssertEqual(markdown, """
        # Pricing

        Launch is \(day).

        - [x] Final copy
        - [ ] Screenshots

        Plain *stars* stay

        [image: pricing-v2.png]
        """)
    }

    func testDeletePolicyTable() {
        let states: [NoteSession.State] = [.untouched, .clean, .dirty, .notSaved("x"), .onlyInMemory("x"),
                                           .conflict(.changed), .conflict(.deleted), .readOnly]
        for state in states {
            for activity in [NoteEditorEngine.Activity.idle, .composing, .writingToolsSafe, .writingToolsRefused] {
                for batch in [false, true] {
                    let allowed = NoteSessionPolicy.deleteAllowed(state, activity: activity, hasBatch: batch)
                    let conflict = if case .conflict = state { true } else { false }
                    XCTAssertEqual(allowed, activity == .idle && !batch && !conflict, "\(state) \(activity) \(batch)")
                }
            }
        }
    }
}

@MainActor
final class NotesLibraryModelTests: XCTestCase {
    private var store: NoteStore!
    private var now = Date(timeIntervalSince1970: 1_790_000_000) // a Wednesday in Sept 2026

    override func setUp() async throws {
        let clock = { [unowned self] in self.now }
        store = try makeTestNoteStore(now: clock, attachmentFileStore: makeTestAttachmentFileStore())
    }

    private func create(_ title: String, _ body: [NoteBlock] = [], daysAgo: Double) throws -> UUID {
        let saved = now
        now = saved.addingTimeInterval(-daysAgo * 86_400)
        defer { now = saved }
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text(title)] + body)) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    private func model(search: @escaping (String) async throws -> Set<UUID> = { _ in [] }) -> NotesLibraryModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return NotesLibraryModel(search: search, now: { [unowned self] in self.now }, calendar: calendar)
    }

    func testRowsFallIntoPinnedTodayThisWeekAndEarlier() throws {
        _ = try create("Today", daysAgo: 0)
        _ = try create("Monday", daysAgo: 2)
        _ = try create("Long ago", daysAgo: 40)
        let pinned = try create("Pinned", daysAgo: 10)
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let groups = model().groups(store: store, drafts: [])
        XCTAssertEqual(groups.map(\.title), ["Pinned", "Today", "This week", "Earlier"])
        XCTAssertEqual(groups.map { $0.rows.map(\.title) }, [["Pinned"], ["Today"], ["Monday"], ["Long ago"]])
    }

    func testRowsSummariseChecklistsImagesAndFileOnlyNotes() throws {
        _ = try create("Groceries", [.checklist("Oat milk", checked: true), .checklist("Lemons"), .checklist("Rice")], daysAgo: 0)
        let groups = model().groups(store: store, drafts: [])
        let row = try XCTUnwrap(groups.first?.rows.first)
        XCTAssertEqual(row.preview, "Oat milk, Lemons, Rice")
        XCTAssertEqual(row.checklist?.done, 1)
        XCTAssertEqual(row.checklist?.total, 3)
        XCTAssertTrue(row.spoken.contains("1 of 3 checked"))
        let imageOnly = NoteRowSummary(document: NoteDocument(blocks: [.text(""), .image(attachmentID: UUID())]),
                                       filename: { _ in "pricing-v2.png" })
        XCTAssertEqual(imageOnly.title, "pricing-v2.png", "a file-only note takes its file's name")
        XCTAssertEqual(imageOnly.preview, "1 image")
    }

    func testSearchShowsResultsAndFailureKeepsEarlierResults() async throws {
        let hit = try create("Kyoto trip", daysAgo: 0)
        _ = try create("Groceries", daysAgo: 0)
        var fails = false
        let library = model { query in
            if fails { throw NSError(domain: "search", code: 7, userInfo: [NSLocalizedDescriptionKey: "Index busy"]) }
            return query == "kyoto" ? [hit] : []
        }
        library.query = "kyoto"
        for _ in 0..<50 where library.matches == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(library.groups(store: store, drafts: []).first?.rows.map(\.title), ["Kyoto trip"])
        XCTAssertEqual(library.groups(store: store, drafts: []).first?.title, "1 note")
        fails = true
        library.retry()
        for _ in 0..<50 where library.searchState == .idle || library.searchState == .loading {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(library.searchState, .failed("Index busy"))
        XCTAssertEqual(library.groups(store: store, drafts: []).first?.rows.map(\.title), ["Kyoto trip"],
                       "earlier results stay while search fails")
        library.clearSearch()
        XCTAssertNil(library.matches)
        XCTAssertEqual(library.searchState, .idle)
    }

    func testStoreSearchFindsTitlesTextAndSkipsDeletedNotes() async throws {
        let title = try create("Kyoto trip", daysAgo: 0)
        let body = try create("Plans", [.text("Temples in kyoto")], daysAgo: 0)
        let gone = try create("Kyoto old", daysAgo: 0)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: gone))))
        let found = try await store.searchNoteIDs(matching: "KYOTO")
        XCTAssertEqual(found, [title, body])
    }

    func testTimesReadAsTimeWeekdayOrDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = NotesLibraryModel.time(now.addingTimeInterval(-60), now: now, calendar: calendar)
        XCTAssertTrue(today.contains(":"), today)
        let week = NotesLibraryModel.time(now.addingTimeInterval(-2 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(week.contains(":"))
        XCTAssertLessThanOrEqual(week.count, 4, week)
    }

    func testKeyboardHighlightMovesThroughTheRows() throws {
        let a = try create("A", daysAgo: 0)
        let b = try create("B", daysAgo: 1)
        let library = model()
        let groups = library.groups(store: store, drafts: [])
        library.moveHighlight(by: 1, in: groups, from: a)
        XCTAssertEqual(library.highlightedID, b)
        library.moveHighlight(by: 1, in: groups, from: a)
        XCTAssertEqual(library.highlightedID, b, "stops at the end")
        library.moveHighlight(by: -1, in: groups, from: a)
        XCTAssertEqual(library.highlightedID, a)
    }
}

/// Legacy notes through the migration gate and into the new page (fixtures
/// only; the real-store dry run waits for the owner's approval at slice 6).
@MainActor
final class NotesSlice2MigrationTests: XCTestCase {
    private var store: NoteStore!
    private var directory: URL!

    override func setUp() async throws {
        store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticSlice2Migration-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// A legacy note written the way the old page wrote them.
    private func legacyNote(title: String, body: String,
                            attachments: [(name: String, offset: Int?, sort: Int64, payload: Data?)]) throws -> UUID {
        let note = NoteItem(id: UUID(), title: title, body: body)
        note.plainText = NoteStore.legacyPlainText(title: title, body: body)
        store.modelContext.insert(note)
        for item in attachments {
            let digest = item.payload.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
            let row = NoteAttachment(id: UUID(), noteID: note.id, originalFilename: item.name,
                                     contentTypeIdentifier: "public.png", byteCount: Int64(item.payload?.count ?? 0),
                                     sortIndex: item.sort, contentDigest: digest, payload: item.payload)
            row.inlineOffset = item.offset
            store.modelContext.insert(row)
        }
        try store.modelContext.save()
        try store.reloadPresentation()
        return note.id
    }

    private func migrate(_ id: UUID) throws -> NoteDocument {
        guard case let .success(snapshot) = store.legacySnapshot(noteID: id),
              case let .success(plan) = LegacyNoteMigration.plan(snapshot),
              case let .success(verified) = LegacyNoteMigration.verify(plan, roundTrip: {
                  NoteTextKitRoundTrip.document(afterRoundTrip: $0)
              }),
              case .success = store.commitMigration(verified) else {
            throw NSError(domain: "migration", code: 1)
        }
        return try XCTUnwrap(store.loadDocument(noteID: id)?.content.document)
    }

    func testAnAttachmentOnlyNoteMigratesAndOpensInTheNewPageTitledByItsFile() throws {
        let data = try png()
        let id = try legacyNote(title: "", body: "", attachments: [
            (name: "receipt.png", offset: nil, sort: 0, payload: data),
            (name: "second.png", offset: 0, sort: 1, payload: data)
        ])
        let before = NoteRowSummary(note: try XCTUnwrap(store.note(withID: id)), attachments: store.attachments(for: id))
        XCTAssertEqual(before.title, "receipt.png", "the old page's file-only note keeps its file name as title")
        XCTAssertEqual(before.preview, "2 images")

        let document = try migrate(id)
        XCTAssertEqual(document.blocks.map(\.kind), [.text, .image, .image], "the tray becomes trailing images")
        XCTAssertEqual(document.title, "")
        let rows = try store.attachmentRows(forNoteID: id)
        XCTAssertEqual(Set(document.attachmentIDs), Set(rows.map(\.id)), "every attachment keeps its row and id")

        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60))
        XCTAssertTrue(controller.open(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertNil(controller.legacyNoteID, "a migrated note opens in the new editor")
        XCTAssertEqual(session.engine.objectIDs().count, 2)
        XCTAssertEqual(session.state, .clean, "opening writes nothing")
        let after = NoteRowSummary(note: try XCTUnwrap(store.note(withID: id)), attachments: store.attachments(for: id))
        XCTAssertEqual(after.title, "receipt.png")
        XCTAssertEqual(after.preview, "2 images")
    }

    func testNilAndEndAnchorsTiesAndATextNoteMigrate() throws {
        let data = try png()
        let id = try legacyNote(title: "Trip", body: "Tickets\nHotel", attachments: [
            (name: "a.png", offset: 99, sort: 2, payload: data),
            (name: "b.png", offset: 8, sort: 1, payload: data),
            (name: "c.png", offset: 8, sort: 0, payload: data),
            (name: "d.png", offset: nil, sort: 3, payload: data)
        ])
        let document = try migrate(id)
        XCTAssertEqual(document.blocks.map { $0.kind == .image ? "img" : $0.text },
                       ["Trip", "Tickets", "img", "img", "Hotel", "img", "img"])
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60))
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertEqual(controller.markdown(noteID: id)?.hasPrefix("# Trip\n\nTickets"), true)
    }

    func testAMissingPayloadKeepsItsPlaceAndItsRow() throws {
        let id = try legacyNote(title: "Scan", body: "Page", attachments: [
            (name: "lost.png", offset: nil, sort: 0, payload: nil)
        ])
        let document = try migrate(id)
        XCTAssertEqual(document.blocks.map(\.kind), [.text, .text, .image], "the image is never dropped")
        XCTAssertEqual(try store.attachmentRows(forNoteID: id).count, 1)
    }

    func testAFileAttachmentKeepsTheNoteInTheOldEditor() throws {
        let note = NoteItem(id: UUID(), title: "Contract", body: "See file")
        store.modelContext.insert(note)
        let row = NoteAttachment(id: UUID(), noteID: note.id, originalFilename: "contract.pdf",
                                 contentTypeIdentifier: "com.adobe.pdf", byteCount: 3, sortIndex: 0,
                                 contentDigest: "x", payload: Data([1, 2, 3]))
        store.modelContext.insert(row)
        try store.modelContext.save()
        try store.reloadPresentation()
        guard case let .success(snapshot) = store.legacySnapshot(noteID: note.id) else { return XCTFail("snapshot") }
        guard case .failure(.fileAttachment) = LegacyNoteMigration.plan(snapshot) else { return XCTFail("refused") }
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                                             saveDelay: .seconds(60))
        XCTAssertTrue(controller.open(noteID: note.id))
        XCTAssertEqual(controller.legacyNoteID, note.id, "the old editor keeps a note the gate refused")
        let summary = NoteRowSummary(note: try XCTUnwrap(store.note(withID: note.id)), attachments: store.attachments(for: note.id))
        XCTAssertEqual(summary.files, 1)
    }
}

@MainActor
final class NotesTagSuggestionTests: XCTestCase {
    func testSuggestionsPreferPrefixesThenCountsAndOfferANewTag() {
        let counts = ["pricing": 6, "print-shop": 1, "sprint": 3, "launch": 4]
        let list = AtticTagSuggestion.make(typed: "pri", counts: counts, excluding: [])
        XCTAssertEqual(list.map(\.name), ["pricing", "print-shop", "sprint", "pri"])
        XCTAssertEqual(list.last?.isNew, true)
        let exact = AtticTagSuggestion.make(typed: "launch", counts: counts, excluding: [])
        XCTAssertEqual(exact.map(\.name), ["launch"], "an existing tag is offered, not a new one")
        let owned = AtticTagSuggestion.make(typed: "pri", counts: counts, excluding: ["pricing"])
        XCTAssertFalse(owned.contains { $0.name == "pricing" }, "tags the note has are left out")
        XCTAssertTrue(AtticTagSuggestion.make(typed: "", counts: counts, excluding: []).isEmpty)
    }

    func testTakingASuggestionUsesItsNameAsOneStep() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Pricing")]))
        let (scroll, textView) = engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        for character in " #pri" { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(engine.activeTitleHashtag?.tag, "pri")
        XCTAssertTrue(engine.takeTitleHashtag(as: "pricing"))
        XCTAssertEqual(engine.tags, ["pricing"])
        XCTAssertEqual(engine.document().title, "Pricing ")
        XCTAssertNil(engine.activeTitleHashtag)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().title, "Pricing #pri")
        XCTAssertEqual(engine.tags, [])
        XCTAssertNil(engine.activeTitleHashtag, "after Undo the hashtag stays text")
    }
}
