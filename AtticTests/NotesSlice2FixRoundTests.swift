import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The slice 2 fix round (Astra's check): stale library targets (M1),
/// Duplicate behind the activity gate (M2), recovery keeping unchanged tags
/// (M3), deletion with a recovery copy that can't be removed (M4), and the
/// should-fix items.
@MainActor
final class NotesSlice2FixRoundTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticFixRound-\(UUID().uuidString)")
        suiteName = "AtticFixRound-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeController(journal: NoteDraftJournaling? = nil,
                                imageLoader: (@Sendable (URL) async -> (StagedNoteAttachment, CGSize?)?)? = nil) -> NotesPageController {
        if let imageLoader {
            return NotesPageController(store: store, journal: journal ?? NoteDraftJournal(directory: directory),
                                       defaults: defaults, saveDelay: .seconds(60), pauseVersionDelay: .seconds(600),
                                       imageLoader: imageLoader)
        }
        return NotesPageController(store: store, journal: journal ?? NoteDraftJournal(directory: directory),
                                   defaults: defaults, saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
    }

    private func create(_ blocks: [NoteBlock], tags: [String] = []) throws -> UUID {
        guard case let .success((id, _)) = store.createDocumentNote(id: UUID(), document: NoteDocument(blocks: blocks),
                                                                   tags: tags.isEmpty ? nil : tags) else {
            throw NSError(domain: "create", code: 1)
        }
        return id
    }

    private func type(_ text: String, into session: NoteSession) {
        let engine = session.engine
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: text), name: "Typing")
    }

    private func attach(_ session: NoteSession) -> NoteEditorTextView {
        let (scroll, textView) = session.engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        return textView
    }

    // MARK: M1 — the library never acts on a row it no longer shows

    func testAStaleHighlightNeitherOpensNorDeletesAfterTheQueryChanges() async throws {
        let a = try create([.text("Alpha")])
        _ = try create([.text("Beta")])
        let library = NotesLibraryModel(search: { query in query == "alpha" ? [a] : [] })
        let all = library.groups(store: store, drafts: [])
        library.moveHighlight(by: 1, in: all, from: nil)
        library.moveHighlight(by: 1, in: all, from: nil)
        XCTAssertEqual(library.highlightedID, a, "Alpha, second in the list, is highlighted")
        library.query = "zzz"
        XCTAssertNil(library.highlightedID, "a new query starts the keyboard's row again")
        for _ in 0..<100 where library.matches == nil { try await Task.sleep(for: .milliseconds(10)) }
        let none = library.groups(store: store, drafts: [])
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(library.openTarget(in: none))
        XCTAssertNil(library.deleteTarget(in: none, selected: a, inField: false), "⌘⌫ never deletes a note not shown")
        XCTAssertNil(library.deleteTarget(in: none, selected: a, inField: true))
        XCTAssertNotNil(store.note(withID: a))
    }

    func testAHighlightOnARowTheResultsDropIsIgnoredEvenIfItSurvived() async throws {
        let a = try create([.text("Alpha")])
        let b = try create([.text("Beta")])
        var answer: Set<UUID> = [a, b]
        let library = NotesLibraryModel(search: { _ in answer })
        library.query = "a"
        for _ in 0..<100 where library.matches == nil { try await Task.sleep(for: .milliseconds(10)) }
        library.highlightedID = b
        answer = [a]
        library.retry()
        for _ in 0..<100 where library.matches != [a] { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.highlightedID, "the results no longer show Beta")
        // Even a highlight set behind the model's back is checked against the rows.
        library.highlightedID = b
        let groups = library.groups(store: store, drafts: [])
        XCTAssertNil(library.openTarget(in: groups))
        XCTAssertNil(library.deleteTarget(in: groups, selected: nil, inField: false))
        library.highlightedID = nil
        XCTAssertEqual(library.openTarget(in: groups), a, "Return opens the first result while searching")
        XCTAssertNil(library.deleteTarget(in: groups, selected: b, inField: false), "the selection is not shown")
        XCTAssertEqual(library.deleteTarget(in: groups, selected: a, inField: false), a)
    }

    // MARK: M2 — Duplicate goes through the gates first

    func testDuplicateIsRefusedWhileComposingAndCreatesNothing() async throws {
        let id = try create([.text("Source"), .text("Body")])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        let textView = attach(session)
        textView.setSelectedRange(NSRange(location: session.engine.textStorage.length, length: 0))
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = store.notes.count
        XCTAssertFalse(controller.duplicateNote(noteID: id))
        XCTAssertEqual(store.notes.count, before, "no provisional copy")
        XCTAssertTrue(controller.active === session)
        XCTAssertNotNil(session.notice)
        textView.unmarkText()
    }

    func testDuplicateIsRefusedDuringWritingToolsAndWhileImagesLoad() async throws {
        let id = try create([.text("Source")])
        let controller = makeController(imageLoader: { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        })
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        _ = attach(session)
        let before = store.notes.count
        session.engine.writingToolsWillBegin()
        XCTAssertNotEqual(session.engine.activity, .idle)
        XCTAssertFalse(controller.duplicateNote(noteID: id))
        XCTAssertEqual(store.notes.count, before)
        session.engine.writingToolsDidEnd()
        controller.importImages([URL(fileURLWithPath: "/tmp/slow.png")])
        XCTAssertTrue(session.isImporting)
        XCTAssertFalse(controller.duplicateNote(noteID: id))
        XCTAssertEqual(store.notes.count, before)
        controller.cancelActiveImport()
    }

    func testDuplicateIsRefusedWhenTheNoteOnScreenCannotBeLeftAndCreatesNothing() async throws {
        let source = try create([.text("Source")])
        let failing = RefusingJournal(directory: directory)
        failing.failWrites = true
        let controller = makeController(journal: failing)
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Unsaved", into: draft)
        gate.shouldFail = true
        let before = store.notes.count
        XCTAssertFalse(controller.duplicateNote(noteID: source), "leaving an only-in-memory draft is refused")
        gate.shouldFail = false
        XCTAssertEqual(store.notes.count, before, "zero copies")
        XCTAssertTrue(controller.active === draft)
    }

    func testASuccessfulDuplicateCreatesAndOpensExactlyOneCompleteCopy() async throws {
        let id = try create([.text("Source"), .text("Body")], tags: ["launch"])
        let controller = makeController()
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" latest", into: session)
        let before = store.notes.count
        XCTAssertTrue(controller.duplicateNote(noteID: id))
        XCTAssertEqual(store.notes.count, before + 1, "exactly one copy")
        let copy = try XCTUnwrap(controller.active)
        XCTAssertNotEqual(copy.noteID, id)
        XCTAssertEqual(copy.state, .clean)
        let stored = try XCTUnwrap(store.loadDocument(noteID: copy.noteID)?.content.document)
        XCTAssertEqual(stored.blocks.map(\.text), ["Source copy", "Body latest"], "the latest text")
        XCTAssertEqual(store.note(withID: copy.noteID)?.tags, ["launch"])
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks.last?.text, "Body latest",
                       "the source was saved when it was left")
    }

    // MARK: M3 — recovery keeps unchanged tags

    func testRecoveryKeepsUnchangedTagsWhenTheNoteWasDeletedElsewhere() async throws {
        let id = try create([.text("Trip")], tags: ["kyoto", "travel"])
        let first = makeController()
        await XCTAssertTrueAsync(await first.openDurably(noteID: id))
        let session = try XCTUnwrap(first.active)
        type(" plans", into: session)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))), "deleted elsewhere")
        await XCTAssertTrueAsync(await first.preserveDurably(session))
        XCTAssertEqual(session.state, .conflict(.deleted))
        let entry = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
        XCTAssertEqual(entry.tags, ["kyoto", "travel"], "the full tag set is kept")
        XCTAssertEqual(entry.tagsChanged, false, "and not marked as a change")

        let relaunched = makeController()
        await relaunched.recoverAtLaunchAndWait()
        await relaunched.startAndWait()
        let recovered = try XCTUnwrap(relaunched.active)
        XCTAssertEqual(recovered.state, .conflict(.deleted))
        XCTAssertEqual(recovered.engine.tags, ["kyoto", "travel"])
        await XCTAssertTrueAsync(await relaunched.keepAsNewNoteDurably())
        let kept = try XCTUnwrap(relaunched.active)
        XCTAssertEqual(store.note(withID: kept.noteID)?.tags, ["kyoto", "travel"], "Keep as new note keeps the tags")
    }

    func testRecoveryDoesNotWriteUnchangedTagsOverTagsSetMeanwhile() async throws {
        let id = try create([.text("Trip")], tags: ["old"])
        let first = makeController()
        await XCTAssertTrueAsync(await first.openDurably(noteID: id))
        let session = try XCTUnwrap(first.active)
        type(" plans", into: session)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await first.preserveDurably(session))
        gate.shouldFail = false
        XCTAssertTrue(store.setTags(["new"], for: try XCTUnwrap(store.note(withID: id))), "an agent retags it")
        let relaunched = makeController()
        await relaunched.recoverAtLaunchAndWait()
        XCTAssertEqual(store.note(withID: id)?.tags, ["new"], "unchanged draft tags never overwrite live ones")
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.title, "Trip plans")
    }

    func testAnOlderRecoveryFileStillReadsItsTagsAsAChange() async throws {
        let entry = NoteDraftJournalEntry(noteID: UUID(), isPersisted: true, baseRevisionID: nil, content: Data(),
                                          selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date(),
                                          tags: ["a"], tagsChanged: nil)
        XCTAssertEqual(entry.changedTags, ["a"])
        let unchanged = NoteDraftJournalEntry(noteID: UUID(), isPersisted: true, baseRevisionID: nil, content: Data(),
                                              selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date(),
                                              tags: ["a"], tagsChanged: false)
        XCTAssertNil(unchanged.changedTags)
    }

    // MARK: M4 — deletion with a recovery copy that can't be removed

    func testDeleteRetiresAnUnremovableRecoveryCopySoItNeverComesBackAsAConflict() async throws {
        let id = try create([.text("Doomed")])
        let journal = RefusingJournal(directory: directory)
        let controller = makeController(journal: journal)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        type(" draft", into: session)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(session), "a recovery copy exists")
        gate.shouldFail = false
        journal.failRemovals = true
        await XCTAssertTrueAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertNil(store.note(withID: id))

        let relaunched = makeController(journal: NoteDraftJournal(directory: directory))
        await relaunched.recoverAtLaunchAndWait()
        await relaunched.startAndWait()
        XCTAssertTrue(relaunched.failedDrafts.isEmpty, "never 'Deleted elsewhere'")
        XCTAssertNotEqual(relaunched.active?.noteID, id)
        await XCTAssertTrueAsync(try await NoteDraftJournal(directory: directory).entriesDurably().isEmpty, "the copy is retired")
        XCTAssertTrue(store.recentlyDeletedNotes().contains { $0.ref.id == id }, "the text is in Recently Deleted")
        XCTAssertEqual(try store.replicasIncludingDeleted(of: id).first?.content.flatMap { NoteContentCodec.decode($0).document }?.title,
                       "Doomed draft")
    }

    func testDeleteIsRefusedWhenARecoveryCopyCanBeNeitherRemovedNorReplaced() async throws {
        let id = try create([.text("Kept")])
        let journal = RefusingJournal(directory: directory)
        let controller = makeController(journal: journal)
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        // A real checkpoint is required: absent recovery needs no retirement.
        try await journal.base.writeDurably(NoteDraftJournalEntry(noteID: id, isPersisted: true,
            baseRevisionID: session.baseRevisionID, content: try NoteContentCodec.encode(session.engine.document()),
            selectionLocation: 0, selectionLength: 0, staged: [], savedAt: Date()), staged: [])
        journal.failRemovals = true
        journal.failWrites = true
        await XCTAssertFalseAsync(await controller.deleteNoteDurably(noteID: id))
        XCTAssertNotNil(store.note(withID: id), "nothing deleted")
        XCTAssertTrue(controller.active === session, "the note stays on screen")
        XCTAssertNotNil(session.notice, "and says why")
    }

    // MARK: Recheck — a tag-only change survives an external delete

    /// Opens a tagged note, changes only its tags, deletes the note
    /// elsewhere, checkpoints, optionally rewrites the recovery file in the
    /// older JSON format, relaunches and keeps the draft as a new note.
    private func tagOnlyChangeSurvivesExternalDelete(from original: [String], to changed: [String],
                                                     olderFormat: Bool) async throws {
        let id = try create([.text("Trip"), .text("Body")], tags: original)
        let first = makeController()
        await XCTAssertTrueAsync(await first.openDurably(noteID: id))
        let session = try XCTUnwrap(first.active)
        session.engine.setTags(changed)
        XCTAssertEqual(session.state, .dirty)
        XCTAssertTrue(store.delete(try XCTUnwrap(store.note(withID: id))), "deleted elsewhere")
        await XCTAssertTrueAsync(await first.preserveDurably(session))
        XCTAssertEqual(session.state, .conflict(.deleted))
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        if olderFormat {
            // The format before `tagsChanged`: `tags` present only for a change.
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertNotNil(json.removeValue(forKey: "tagsChanged"))
            try JSONSerialization.data(withJSONObject: json).write(to: file)
            let decoded = try await XCTUnwrapAsync(try await NoteDraftJournal(directory: directory).entriesDurably().first?.0)
            XCTAssertNil(decoded.tagsChanged, "decoded from the older format")
            XCTAssertEqual(decoded.changedTags, AtticTag.normalizedSet(changed))
        }
        let relaunched = makeController()
        await relaunched.recoverAtLaunchAndWait()
        await relaunched.startAndWait()
        let recovered = try XCTUnwrap(relaunched.active, "the draft is recovered, not dropped")
        XCTAssertEqual(recovered.noteID, id)
        XCTAssertEqual(recovered.state, .conflict(.deleted))
        XCTAssertEqual(recovered.engine.tags, AtticTag.normalizedSet(changed))
        await XCTAssertTrueAsync(await relaunched.keepAsNewNoteDurably())
        let kept = try XCTUnwrap(relaunched.active)
        XCTAssertNotEqual(kept.noteID, id)
        XCTAssertEqual(store.note(withID: kept.noteID)?.tags ?? [], AtticTag.normalizedSet(changed),
                       "Keep as new note keeps the changed tags")
        XCTAssertEqual(store.loadDocument(noteID: kept.noteID)?.content.document?.title, "Trip")
    }

    func testAnAddedTagSurvivesAnExternalDeleteAndRelaunch() async throws {
        try await tagOnlyChangeSurvivesExternalDelete(from: ["travel"], to: ["travel", "kyoto"], olderFormat: false)
    }

    func testARemovedTagSurvivesAnExternalDeleteAndRelaunch() async throws {
        try await tagOnlyChangeSurvivesExternalDelete(from: ["travel", "kyoto"], to: ["travel"], olderFormat: false)
    }

    func testAnAddedTagInAnOlderRecoveryFileSurvivesAnExternalDelete() async throws {
        try await tagOnlyChangeSurvivesExternalDelete(from: ["travel"], to: ["travel", "kyoto"], olderFormat: true)
    }

    func testARemovedTagInAnOlderRecoveryFileSurvivesAnExternalDelete() async throws {
        try await tagOnlyChangeSurvivesExternalDelete(from: ["travel", "kyoto"], to: [], olderFormat: true)
    }

    func testAHighlightedFailedDraftStaysHighlightedWhileItStillMatches() async throws {
        let draftID = UUID()
        let library = NotesLibraryModel(search: { _ in [] })
        library.failedDraftText = { $0 == draftID ? "Draft\nhidden kyoto detail" : nil }
        library.query = "kyo"
        for _ in 0..<100 where library.matches == nil { try await Task.sleep(for: .milliseconds(10)) }
        library.highlightedID = draftID
        library.retry()
        for _ in 0..<100 where library.searchState != .idle { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(library.highlightedID, draftID, "the draft still matches")
        library.failedDraftText = { _ in nil }
        library.retry()
        for _ in 0..<100 where library.highlightedID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.highlightedID, "a draft that no longer matches loses the highlight")
    }

    // MARK: Should fix

    func testReturnInTheTagEditorActsOnlyOnWhatWasTyped() async {
        let tags = [AtticNoteTagList.Tag(name: "launch-october", count: 3, isOn: true),
                    AtticNoteTagList.Tag(name: "launch", count: 5, isOn: false)]
        XCTAssertEqual(AtticNoteTagList.submitAction(query: "launch", tags: tags, create: nil), .toggle("launch"),
                       "the exact tag, not the owned one listed first")
        XCTAssertNil(AtticNoteTagList.submitAction(query: "", tags: tags, create: nil), "an empty field does nothing")
        XCTAssertNil(AtticNoteTagList.submitAction(query: "laun", tags: tags, create: nil), "nor does a partial word")
        XCTAssertEqual(AtticNoteTagList.submitAction(query: "#Kyoto", tags: [], create: "kyoto"), .create("kyoto"))
    }

    func testUndoKeepsAnAlreadyOwnedHashtagLiteral() async throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Plan")]), tags: ["launch"])
        let session = NoteSessionStub(engine: engine)
        let textView = attach(session)
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        for character in " #launch " { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertEqual(engine.document().title, "Plan ")
        XCTAssertEqual(engine.tags, ["launch"])
        XCTAssertTrue(engine.history.undo())
        XCTAssertEqual(engine.document().title, "Plan #launch")
        XCTAssertEqual(engine.tags, ["launch"], "the note keeps the tag it already had")
        XCTAssertTrue(engine.history.redo(), "redo of the shorthand")
        XCTAssertEqual(engine.document().title, "Plan ")
        XCTAssertEqual(engine.tags, ["launch"])
        XCTAssertTrue(engine.history.undo())
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        textView.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(engine.document().title, "Plan #launch ", "after Undo the hashtag stays text")
        XCTAssertEqual(engine.tags, ["launch"])
    }

    func testEscFromTheNoteHidesThePanelOnlyWhenNothingElseTakesIt() async throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("Body")]))
        let textView = attach(NoteSessionStub(engine: engine))
        var hides = 0
        textView.escapeFallback = { hides += 1 }
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        textView.cancelOperation(nil)
        XCTAssertEqual(hides, 1, "a focused note with nothing open: Esc hides the panel")

        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.cancelOperation(nil)
        XCTAssertEqual(hides, 1, "a composition keeps Esc")
        textView.unmarkText()

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        for character in " #idea" { textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        textView.cancelOperation(nil)
        XCTAssertEqual(hides, 1, "Esc first keeps the hashtag as text")
        textView.cancelOperation(nil)
        XCTAssertEqual(hides, 2, "then hides")

        let show = NSMenuItem()
        show.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(show)
        if textView.enclosingScrollView?.isFindBarVisible == true {
            textView.cancelOperation(nil)
            XCTAssertEqual(hides, 2, "Esc closes Find first")
            XCTAssertEqual(textView.enclosingScrollView?.isFindBarVisible, false)
        }
    }

    func testRowCountsReadTheWholeNoteAndDraftsAreSearchedThroughAllTheirText() async throws {
        let long = String(repeating: "A long opening paragraph that fills the preview. ", count: 8)
        let summary = NoteRowSummary(document: NoteDocument(blocks: [
            .text("List"), .text(long), .checklist("One", checked: true), .checklist("Two"), .checklist("Three", checked: true)
        ]), filename: { _ in nil })
        XCTAssertEqual(summary.checklist?.done, 2)
        XCTAssertEqual(summary.checklist?.total, 3, "items after a long preview are still counted")

        // A never-saved draft whose store save failed, found by text far down.
        let journal = NoteDraftJournal(directory: directory)
        let controller = makeController(journal: journal)
        await controller.startAndWait()
        let draft = try XCTUnwrap(controller.active)
        type("Draft\n" + long + "\nhidden kyoto detail", into: draft)
        gate.shouldFail = true
        await XCTAssertTrueAsync(await controller.preserveDurably(draft))
        gate.shouldFail = false
        XCTAssertEqual(controller.failedDrafts.count, 1)
        let library = NotesLibraryModel(search: { _ in [] })
        library.query = "kyoto"
        for _ in 0..<100 where library.matches == nil { try await Task.sleep(for: .milliseconds(10)) }
        let groups = library.groups(store: store, drafts: controller.failedDrafts)
        XCTAssertEqual(groups.first?.rows.map(\.id), [draft.noteID])
    }
}

/// A session-like holder so engine-only tests can attach a view.
@MainActor
private final class NoteSessionStub {
    let engine: NoteEditorEngine
    init(engine: NoteEditorEngine) { self.engine = engine }
}

@MainActor
private extension NotesSlice2FixRoundTests {
    func attach(_ stub: NoteSessionStub) -> NoteEditorTextView {
        let (scroll, textView) = stub.engine.makeView()
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        windows.append(window)
        return textView
    }
}

/// A journal whose writes or removals fail on request.
@MainActor
private final class RefusingJournal: NoteDraftJournaling {
    struct Failure: Error {}
    let base: NoteDraftJournal
    private let fileManager = UnlinkFailingFileManager()
    var failWrites = false
    /// Checkpoint unlinks fail, so the journal falls back to a retired
    /// marker; with `failWrites` too, retirement fails outright.
    var failRemovals: Bool {
        get { fileManager.failCheckpointRemovals }
        set { fileManager.failCheckpointRemovals = newValue }
    }
    init(directory: URL) { base = NoteDraftJournal(directory: directory, fileManagerFactory: { [fileManager] in fileManager }) }
    func writeDurably(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment],
               replacing claim: NoteRecoveryClaim?) async throws -> NoteRecoveryClaim {
        if failWrites { throw Failure() }
        return try await base.writeDurably(entry, staged: staged, replacing: claim)
    }
    func retireDurably(noteID: UUID, claim: NoteRecoveryClaim?, saved: NoteRecoverySavedState?) async throws {
        if failRemovals && failWrites { throw Failure() }
        try await base.retireDurably(noteID: noteID, claim: claim, saved: saved)
    }
    func recoveryEntries() throws -> [NoteDraftRecoveryEntry] { try base.recoveryEntries() }

    var requiresAsyncIO: Bool { true }
    func readRecoveryEntries() async throws -> [NoteDraftRecoveryEntry] { try await base.readRecoveryEntries() }
    func discardOwnedDurably(noteID: UUID, claim: NoteRecoveryClaim) async throws { try await base.discardOwnedDurably(noteID: noteID, claim: claim) }
}
