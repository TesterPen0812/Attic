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

    func testSpaceAfterAHashtagInTheTitleTakesTheTagAsOneUndoStep() async {
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

    func testRedoOfTheShorthandAddsTheTagAgain() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Trip")]))
        caretAtEnd(of: engine, textView)
        type(" #kyoto ", textView)
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.tags, [])
        XCTAssertTrue(engine.history.redo())
        XCTAssertEqual(engine.tags, ["kyoto"])
        XCTAssertEqual(engine.document().title, "Trip ")
    }

    func testReturnAfterAHashtagTakesTheTagThenStartsTheBody() async {
        let (engine, textView) = makeEngine(NoteDocument.blank)
        type("Groceries #home\nMilk", textView)
        XCTAssertEqual(engine.tags, ["home"])
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Groceries ", "Milk"])
    }

    func testEscapeKeepsTheHashtagAsTextUntilItsHashIsTypedAgain() async {
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

    func testEscapeWithNoHashtagPassesOn() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Plain")]))
        caretAtEnd(of: engine, textView)
        XCTAssertFalse(engine.keepTitleHashtagLiteral())
    }

    func testHashtagsInTheBodyNumbersAndPastesStayText() async {
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

    func testAHashtagInsideAWordStaysText() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("C")]))
        caretAtEnd(of: engine, textView)
        type("#sharp ", textView)
        XCTAssertEqual(engine.tags, [])
    }

    func testNoConversionWhileComposing() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Kanji #tag")]))
        caretAtEnd(of: engine, textView)
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(engine.takeTitleHashtag())
        textView.unmarkText()
    }

    // MARK: Title boundaries

    func testBackspaceAtTheBodyStartJoinsTheTextIntoTheTitleAsOneStep() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Pricing"), .text("page")]))
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Pricingpage"])
        XCTAssertEqual(engine.textStorage.attribute(.font, at: 9, effectiveRange: nil) as? NSFont, engine.style.titleFont,
                       "the joined text takes the title's style")
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Pricing", "page"])
    }

    func testBackspaceBeforeAnImageUnderTheTitleSelectsTheImage() async {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 10, pixelHeight: 10)
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), image, .text("")]))
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 1), "the image is selected, not joined")
        XCTAssertEqual(engine.document().blocks.count, 3)
    }

    func testBackspaceBeforeAnImageRemovesAnEmptyLineAbove() async {
        let image = NoteBlock.image(attachmentID: UUID(), pixelWidth: 10, pixelHeight: 10)
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .text("Text"), .text(""), image]))
        let imageLocation = engine.textStorage.length - 1
        textView.setSelectedRange(NSRange(location: imageLocation, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text, .image], "the empty line goes")
    }

    func testForwardDeleteAtTheTitleEndRemovesTheCheckboxFirst() async {
        let (engine, textView) = makeEngine(NoteDocument(blocks: [.text("Title"), .checklist("Milk")]))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.deleteForward(nil)
        XCTAssertEqual(engine.document().blocks.map(\.kind), [.text, .text], "the box goes, the title never takes it")
        XCTAssertEqual(engine.document().blocks.map(\.text), ["Title", "Milk"])
    }

    func testReturnAtTheTitleEndStepsIntoAnEmptyFirstLine() async {
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

    func testTitleLinesKeepClearOfTheMenuAndReserveTheTagLine() async {
        let (engine, _) = makeEngine(NoteDocument(blocks: [.text("A title"), .text("Body")]))
        engine.setTitleReserves(tagLine: 15, trailing: 32)
        let style = engine.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.tailIndent, -32)
        // The tag line with 4 above it and 8 below; the first block keeps
        // its own 12 from the title (Notes v2), so the title adds the rest.
        let body = engine.textStorage.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual((style?.paragraphSpacing ?? 0) + NoteTextStyle.titleToBody,
                       NoteTextStyle.titleToTags + 15 + NoteTextStyle.tagsToBody)
        XCTAssertEqual(body?.paragraphSpacingBefore ?? 0,
                       NoteTextStyle.spacingBefore(.body, after: .title), accuracy: 0.001)
        XCTAssertEqual(body?.tailIndent, 0, "the body is not narrowed")
        XCTAssertTrue(engine.history.undoOps.isEmpty, "reserves are never an Undo step")
        XCTAssertEqual(style?.minimumLineHeight, AtticNoteType.title.lineHeight)
        XCTAssertEqual(style?.maximumLineHeight, AtticNoteType.title.lineHeight)
    }

    /// Notes v2, text direction 5 (owner, 2026-10-08): SF Pro in the note,
    /// Rounded stays Tasks' voice.
    func testNoteTextIsSFPro() async {
        XCTAssertFalse(AtticTextStyle.noteTitle.spec.rounded)
        XCTAssertFalse(AtticTextStyle.noteBody.spec.rounded)
        XCTAssertTrue(AtticTextStyle.rowTitle.spec.rounded)
        let style = NoteTextStyle()
        for font in [style.titleFont, style.bodyFont, style.titleStyleFont, style.headingFont, style.subheadingFont, style.quoteFont] {
            XCTAssertNotEqual(font.fontDescriptor.object(forKey: .init(rawValue: "NSCTFontUIFontDesignTrait")) as? String,
                              "NSCTFontUIFontDesignRounded", font.fontName)
            XCTAssertFalse(font.fontName.localizedCaseInsensitiveContains("rounded"), font.fontName)
        }
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
        directory = ownedTemporaryDirectory(prefix: "AtticSlice2")
        suiteName = "AtticSlice2-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {

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

    func testTagsAreSavedWithTheTextAndATagOnlyChangeKeepsTheRevision() async throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let revision = try XCTUnwrap(store.note(withID: id)?.revisionID)
        let updated = try XCTUnwrap(store.note(withID: id)?.updatedAt)
        session.engine.setTags(["launch"])
        XCTAssertEqual(session.state, .dirty, "a tag change is an edit")
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch"])
        XCTAssertEqual(store.note(withID: id)?.revisionID, revision, "tags alone keep the revision")
        XCTAssertEqual(store.note(withID: id)?.updatedAt, updated, "and the note's place in the list")
        XCTAssertEqual(session.state, .clean)
        // Text and a tag in one save.
        type(" page", into: session)
        session.engine.setTags(["launch", "pricing"])
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch", "pricing"])
        XCTAssertEqual(store.note(withID: id)?.title, "Pricing page")
    }

    func testANewNoteWithOnlyATagIsKept() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        session.engine.setTags(["idea"])
        XCTAssertFalse(session.isUntouchedDraft)
        await XCTAssertTrueAsync(await controller.preserveAllDurably())
        XCTAssertEqual(store.notes.first?.tags, ["idea"])
    }

    func testTagsSetElsewhereReachACleanNoteWhenItIsShown() async throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        XCTAssertTrue(store.setTags(["agent"], for: try XCTUnwrap(store.note(withID: id))))
        controller.present()
        XCTAssertEqual(session.engine.tags, ["agent"])
        XCTAssertEqual(session.state, .clean, "a refresh is not an edit")
    }

    func testAFailedSaveKeepsTheTagInTheRecoveryCopyAndRecoveryRestoresIt() async throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.setTags(["launch"])
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(session))
        if case .notSaved = session.state {} else { XCTFail("expected Not saved") }
        let entry = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
        XCTAssertEqual(entry.tags, ["launch"])
        gate.shouldFail = false
        let relaunched = makeController()
        await relaunched.recoverAtLaunchAndWait()
        await relaunched.startAndWait()
        XCTAssertEqual(relaunched.active?.noteID, id)
        XCTAssertEqual(store.note(withID: id)?.tags, ["launch"], "the recovered tag is saved")
    }

    // MARK: Opening

    func testNotesReopensTheLastNoteWithItsCaretAndNewNoteIsFresh() async throws {
        let id = try create([.text("Pricing"), .text("Lead with the free tier.")])
        let first = makeController()
        await XCTAssertTrueAsync(await first.openDurably(noteID: id))
        let session = try XCTUnwrap(first.active)
        let (scroll, textView) = session.engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        textView.setSelectedRange(NSRange(location: 12, length: 3))
        await XCTAssertTrueAsync(await first.prepareToLeaveDurably(.hide))

        let second = makeController()
        await second.startAndWait()
        XCTAssertEqual(second.active?.noteID, id, "Notes resumes the last note viewed")
        XCTAssertEqual(second.active?.selection, NSRange(location: 12, length: 3))
        XCTAssertTrue(second.requestNewNote())
        XCTAssertFalse(second.active?.isPersisted ?? true, "New note always starts fresh")
        XCTAssertEqual(second.librarySelectionID, id, "All notes from a new draft selects the last note visited")
    }

    func testNewNoteFromTheMenuBarBeforeThePageStartsGivesAFreshDraft() async throws {
        let id = try create([.text("Pricing")])
        defaults.set(id.uuidString, forKey: "notes.lastViewedNote.v2")
        let controller = makeController()
        XCTAssertTrue(controller.requestNewNote())
        await controller.startAndWait()
        XCTAssertFalse(controller.active?.isPersisted ?? true)
    }

    func testARecoveredDraftOpensBeforeANewNoteRequest() async throws {
        let id = try create([.text("Pricing")])
        let first = makeController()
        await XCTAssertTrueAsync(await first.openDurably(noteID: id))
        let session = try XCTUnwrap(first.active)
        type(" unsaved", into: session)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await first.preserveDurably(session))
        gate.shouldFail = false
        let second = makeController()
        await second.recoverAtLaunchAndWait()
        XCTAssertTrue(second.requestNewNote())
        await second.startAndWait()
        XCTAssertEqual(second.active?.noteID, id, "recovery comes first")
    }

    func testAnEmptiedNoteIsKeptAsUntitled() async throws {
        let id = try create([.text("Temporary"), .text("text")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        session.engine.performEdit(NSRange(location: 0, length: session.engine.textStorage.length),
                                   with: NSAttributedString(), name: "Delete")
        await XCTAssertTrueAsync(await controller.newNoteDurably())
        XCTAssertNotNil(store.note(withID: id), "clearing a note keeps it")
        let summary = NoteRowSummary(note: try XCTUnwrap(store.note(withID: id)), attachments: [])
        XCTAssertEqual(summary.title, "Untitled note")
    }

    // MARK: Delete and Undo

    func testDeletingTheNoteOnScreenSavesItFirstThenShowsAllNotesAndRestoreBringsItBack() async throws {
        let id = try create([.text("Pricing")], tags: ["launch"])
        let controller = makeController()
        await controller.startAndWait()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" latest", into: session)
        XCTAssertEqual(session.state, .dirty)
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
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

    func testDeleteIsRefusedInAConflictAndWhenTheLatestTextCannotBeSaved() async throws {
        let id = try create([.text("Pricing")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" draft", into: session)
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertNotNil(store.note(withID: id), "a note whose text can't be saved is not deleted")
        XCTAssertNotNil(session.notice)
        gate.shouldFail = false
        let note = try XCTUnwrap(store.note(withID: id))
        _ = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
                             document: NoteDocument(blocks: [.text("Elsewhere")]), agentName: "Test", disposition: .direct)
        _ = await controller.preserveDurably(session)
        XCTAssertTrue(session.isConflict)
        await XCTAssertFalseAsync(await controller.deleteNoteDurably(noteID: id), "a conflict keeps its text until Keep as new note")
        XCTAssertNotNil(store.note(withID: id))
    }

    func testDeletingAnUnsavedDraftSavesItThenDeletesIt() async throws {
        let controller = makeController()
        await controller.startAndWait()
        let session = try XCTUnwrap(controller.active)
        type("Draft text", into: session)
        let id = session.noteID
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertTrue(store.recentlyDeletedNotes().contains { $0.ref.id == id })
    }

    func testDismissingAllNotesAfterADeleteOpensTheLastNoteOrANewDraft() async throws {
        let controller = makeController()
        let id = try create([.text("Only")])
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        controller.dismissLibrary()
        XCTAssertNotNil(controller.active)
        XCTAssertFalse(controller.active?.isPersisted ?? true)
    }

    // MARK: Duplicate, pin, Markdown

    func testDuplicateCopiesTextTagsAndImagesAndOpensTheCopy() async throws {
        let image = try realImage()
        let blockID = UUID()
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [
            .text("Pricing"), .checklist("Milk"), .image(id: blockID, attachmentID: image.id, pixelWidth: 2, pixelHeight: 2)
        ]), staged: [image], tags: ["launch"]) else { return XCTFail("fixture") }
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
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

    func testPinningIsMetadata() async throws {
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

    func testCopyAsMarkdownIsTextOnly() async throws {
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

    func testDeletePolicyTable() async {
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

    func testS5LibraryKeepsTimeAndNamesEveryPendingProposal() throws {
        let id = try create("Current", daysAgo: 0)
        let note = try XCTUnwrap(store.note(withID: id))
        let library = model()
        let before = try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first)
        XCTAssertFalse(before.hasProposal)
        guard case let .success(.pending(editID)) = store.agentWrite(noteID: id, baseRevisionToken: note.revisionToken,
            document: NoteDocument(blocks: [.text("Proposed")]), agentName: "Claude", disposition: .proposal) else { return XCTFail() }
        let row = try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first)
        XCTAssertEqual(row.time, before.time)
        XCTAssertTrue(row.hasProposal)
        XCTAssertTrue(row.spoken.contains("proposal waiting"))
        XCTAssertTrue(store.discardProposal(editID, noteID: id))
        XCTAssertFalse(try XCTUnwrap(library.groups(store: store, drafts: []).flatMap(\.rows).first).hasProposal)
    }

    func testHiddenLibraryAutosavesDoNotRunSearchAfterAnyDismissalRoute() async throws {
        enum Exit: CaseIterable { case dismiss, newNote, duplicate, openNote, failedDraft }
        for route in Exit.allCases {
            let controller = NotesPageController(store: store, journal: nil, saveDelay: .seconds(60))
            await controller.startAndWait()
            let initial = try XCTUnwrap(controller.active)
            _ = initial.engine.performEdit(NSRange(location: 0, length: 0),
                                          with: NSAttributedString(string: "quartz"), name: "Typing")
            XCTAssertTrue(controller.save(initial))
            var searches = 0
            let library = NotesLibraryModel(search: { _ in searches += 1; return [] },
                                            store: store, controller: controller)
            XCTAssertTrue(controller.showLibrary())
            library.query = "quartz"
            await library.waitForSearch()
            XCTAssertEqual(searches, 1)
            switch route {
            case .dismiss: controller.dismissLibrary()
            case .newNote: XCTAssertTrue(controller.requestNewNote())
            case .duplicate: XCTAssertTrue(controller.duplicateNote(noteID: initial.noteID))
            case .openNote: await XCTAssertTrueAsync(await controller.openDurably(noteID: initial.noteID)); controller.dismissLibrary()
            case .failedDraft: XCTAssertTrue(controller.openFailedDraft(sessionID: initial.id))
            }
            XCTAssertFalse(controller.isLibraryPresented)
            XCTAssertEqual(library.query, "", "\(route) must end the search")
            let target = try XCTUnwrap(controller.active)
            for _ in 0..<3 {
                _ = target.engine.performEdit(NSRange(location: target.engine.textStorage.length, length: 0),
                                              with: NSAttributedString(string: " edit"), name: "Typing")
                await controller.runDueSave(target)
                await library.waitForSearch()
            }
            XCTAssertEqual(searches, 1, "autosaves with the library hidden must do no full-library search")
        }
    }

    func testWarmedTagInventoryDoesNotRereadTheLibraryWhileTypingOrSavingText() throws {
        for index in 0..<1_000 {
            let note = NoteItem(title: "Unrelated \(index)")
            note.tagsRaw = AtticTag.encode(["shared", index % 2 == 0 ? "even" : "odd"])
            store.modelContext.insert(note)
        }
        XCTAssertTrue(store.commitStagedChanges()); store.refresh()
        guard case let .success((id, revision)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Target")]), tags: ["target"]) else { return XCTFail() }
        let counts = store.tagCounts
        XCTAssertEqual(counts["shared"], 1_000)
        let builds = store.tagInventoryBuildCount, reads = store.tagInventoryNoteReadCount
        for index in 0..<200 {
            _ = AtticTagSuggestion.make(typed: index % 2 == 0 ? "sh" : "ev", counts: store.tagCounts, excluding: ["target"])
        }
        XCTAssertEqual(store.tagInventoryBuildCount, builds)
        XCTAssertEqual(store.tagInventoryNoteReadCount, reads, "caret changes read no note properties")
        guard case .success = store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Updated text")]),
                                                baseRevisionID: revision) else { return XCTFail() }
        XCTAssertEqual(store.tagCounts, counts)
        XCTAssertEqual(store.tagInventoryBuildCount, builds, "ordinary content saves retain the inventory")
        XCTAssertEqual(store.tagInventoryNoteReadCount, reads)
        let plainTextNote = try XCTUnwrap(store.notes.first { $0.id != id })
        XCTAssertTrue(store.update(plainTextNote, body: "Only text changed"))
        XCTAssertEqual(store.tagCounts, counts)
        XCTAssertEqual(store.tagInventoryBuildCount, builds, "plain-text API saves retain the warm tag inventory")
    }

    func testTagInventoryInvalidatesForTagsMembershipExternalRefreshAndRollback() throws {
        let gate = PersistenceGate()
        let tracked = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        guard case let .success((id, _)) = tracked.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("A")]), tags: ["old"]) else { return XCTFail() }
        XCTAssertEqual(tracked.tagCounts, ["old": 1])
        XCTAssertTrue(tracked.setTags(["new"], for: try XCTUnwrap(tracked.note(withID: id))))
        XCTAssertEqual(tracked.tagCounts, ["new": 1])
        guard case let .success((second, _)) = tracked.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("B")]), tags: ["new"]) else { return XCTFail() }
        XCTAssertEqual(tracked.tagCounts, ["new": 2])
        XCTAssertTrue(tracked.delete(try XCTUnwrap(tracked.note(withID: second))))
        XCTAssertEqual(tracked.tagCounts, ["new": 1])
        XCTAssertTrue(tracked.restoreDeleted(noteID: second))
        XCTAssertEqual(tracked.tagCounts, ["new": 2])
        let external = ModelContext(tracked.container)
        let rows = try external.fetch(FetchDescriptor<NoteItem>())
        for row in rows where row.id == id { row.tagsRaw = AtticTag.encode(["external"]) }
        try external.save(); tracked.refresh()
        XCTAssertEqual(tracked.tagCounts, ["new": 1, "external": 1])
        gate.shouldFail = true
        XCTAssertFalse(tracked.setTags(["failed"], for: try XCTUnwrap(tracked.note(withID: id))))
        XCTAssertEqual(tracked.tagCounts, ["new": 1, "external": 1], "rollback invalidates without publishing failed tags")
    }

    func testRowsFallIntoPinnedTodayThisWeekAndEarlier() async throws {
        _ = try create("Today", daysAgo: 0)
        _ = try create("Monday", daysAgo: 2)
        _ = try create("Long ago", daysAgo: 40)
        let pinned = try create("Pinned", daysAgo: 10)
        XCTAssertTrue(store.setPinned(true, noteID: pinned))
        let groups = model().groups(store: store, drafts: [])
        XCTAssertEqual(groups.map(\.title), ["Pinned", "Today", "This week", "Earlier"])
        XCTAssertEqual(groups.map { $0.rows.map(\.title) }, [["Pinned"], ["Today"], ["Monday"], ["Long ago"]])
    }

    func testRowsSummariseChecklistsImagesAndFileOnlyNotes() async throws {
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

    func testActiveSearchRerunsAfterAgentEditsAndNoteMembershipChanges() async throws {
        let old = try create("quartz", daysAgo: 0), other = try create("Other", daysAgo: 0)
        let model = NotesLibraryModel(search: { [store] text in try await store!.searchNoteIDs(matching: text) }, store: store)
        model.query = "quartz"
        await model.waitForSearch()
        XCTAssertEqual(model.matches, [old])
        func write(_ id: UUID, _ title: String) throws {
            let token = try XCTUnwrap(store.note(withID: id)?.revisionToken)
            guard case .success = store.agentWrite(noteID: id, baseRevisionToken: token,
                document: NoteDocument(blocks: [.text(title)]), agentName: "Agent", disposition: .direct) else { return XCTFail() }
        }
        try write(other, "quartz arrived")
        await model.waitForSearch()
        XCTAssertEqual(model.matches, [old, other])
        try write(old, "No longer matches")
        await model.waitForSearch()
        XCTAssertEqual(model.matches, [other])
        XCTAssertEqual(model.groups(store: store, drafts: []).flatMap { $0.rows.map(\.id) }, [other])
        let added = try create("new quartz", daysAgo: 0)
        await model.waitForSearch(); XCTAssertEqual(model.matches, [other, added])
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: other))))
        await model.waitForSearch(); XCTAssertEqual(model.matches, [added])
        XCTAssertEqual(model.matchedRevision, store.revision)
    }

    func testActiveSearchRerunsWhenAnAttachmentFilenameChanges() async throws {
        let bytes = Data("payload".utf8)
        let file = StagedNoteAttachment(id: UUID(), filename: "plain.pdf", contentTypeIdentifier: "com.adobe.pdf",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(),
            document: NoteDocument(blocks: [.text("Files"), .file(attachmentID: file.id, filename: file.filename,
                contentTypeIdentifier: file.contentTypeIdentifier, byteCount: file.byteCount)]), staged: [file]) else { return XCTFail() }
        let model = NotesLibraryModel(search: { [store] text in try await store!.searchNoteIDs(matching: text) }, store: store)
        model.query = "quartz"; await model.waitForSearch(); XCTAssertEqual(model.matches, [])
        let row = try XCTUnwrap(store.attachmentRows(forNoteID: id).first)
        row.originalFilename = "quartz.pdf"; XCTAssertTrue(store.commitStagedChanges())
        await model.waitForSearch(); XCTAssertEqual(model.matches, [id])
        row.originalFilename = "plain.pdf"; XCTAssertTrue(store.commitStagedChanges())
        await model.waitForSearch(); XCTAssertEqual(model.matches, [])
    }

    func testOldSearchCompletionsCannotReplaceANewerStoreRevisionOrQuery() async throws {
        let old = try create("old", daysAgo: 0), new = try create("new", daysAgo: 0)
        var requests: [CheckedContinuation<Set<UUID>, Error>] = []
        let model = NotesLibraryModel(search: { _ in
            try await withCheckedThrowingContinuation { requests.append($0) }
        }, store: store)
        func waitForRequests(_ count: Int) async throws {
            for _ in 0..<100 {
                if requests.count >= count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("search did not start")
        }
        model.query = "quartz"; try await waitForRequests(1)
        _ = try create("Another", daysAgo: 0); try await waitForRequests(2)
        requests[1].resume(returning: [new]); await model.waitForSearch()
        let revision = model.matchedRevision
        requests[0].resume(returning: [old])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.matches, [new]); XCTAssertEqual(model.matchedRevision, revision)
        model.query = "granite"; try await waitForRequests(3)
        model.clearSearch(); requests[2].resume(returning: [old]); await model.waitForSearch()
        XCTAssertNil(model.matches); XCTAssertNil(model.matchedRevision); XCTAssertEqual(model.matchedQuery, "")
    }

    func testTimesReadAsTimeWeekdayOrDay() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = NotesLibraryModel.time(now.addingTimeInterval(-60), now: now, calendar: calendar)
        XCTAssertTrue(today.contains(":"), today)
        let week = NotesLibraryModel.time(now.addingTimeInterval(-2 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(week.contains(":"))
        XCTAssertLessThanOrEqual(week.count, 4, week)
    }

    func testKeyboardHighlightMovesThroughTheRows() async throws {
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



@MainActor
final class NotesTagSuggestionTests: XCTestCase {
    func testSuggestionsPreferPrefixesThenCountsAndOfferANewTag() async {
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

    func testTakingASuggestionUsesItsNameAsOneStep() async {
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

@MainActor
final class AtticNativeMenuTests: XCTestCase {
    func testItemsRunTheirCommandsAndShowSectionsChecksAndSubmenus() async throws {
        var ran: [String] = []
        let commands = [
            AtticMenuCommand("Insert", submenu: [AtticMenuCommand("Image…") { ran.append("image") }]),
            AtticMenuCommand("Pin to Top", startsSection: true, isChecked: true) { ran.append("pin") },
            AtticMenuCommand("Delete Note", isDestructive: true, startsSection: true, identifier: "delete") { ran.append("delete") }
        ]
        let menu = AtticNativeMenu.make(commands)
        XCTAssertEqual(menu.items.map(\.title), ["Insert", "", "Pin to Top", "", "Delete Note"])
        XCTAssertEqual(menu.items[2].state, .on)
        XCTAssertEqual(menu.items[0].submenu?.items.first?.title, "Image…")
        menu.performActionForItem(at: 4)
        menu.performActionForItem(at: 2)
        try XCTUnwrap(menu.items[0].submenu).performActionForItem(at: 0)
        XCTAssertEqual(ran, ["delete", "pin", "image"])
    }
}
