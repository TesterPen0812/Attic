import SwiftData
import XCTest
@testable import Attic

/// Durable drafts per note (critique finding 1): saves within the coalescing
/// delay, save-or-checkpoint before navigation, "Only in memory" when both
/// fail, recovery first on reopen, versions on leave, pending agent edits
/// applied on leave.
@MainActor
final class NotesPageControllerTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!

    override func setUp() async throws {
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AtticNoteDrafts-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(journal: NoteDraftJournaling? = nil, delay: Duration = .seconds(60)) -> NotesPageController {
        NotesPageController(store: store, journal: journal ?? NoteDraftJournal(directory: directory),
                            saveDelay: delay, pauseVersionDelay: .seconds(600))
    }

    private func type(_ text: String, into session: NoteSession) {
        let engine = session.engine
        engine.performEdit(NSRange(location: engine.textStorage.length, length: 0),
                           with: NSAttributedString(string: text), name: "Typing")
    }

    func testANewDraftIsSavedOnlyOnceItHasContent() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        XCTAssertFalse(session.isPersisted)
        XCTAssertTrue(controller.newNote(), "an untouched draft stays")
        XCTAssertTrue(controller.preserveAll())
        XCTAssertTrue(store.notes.isEmpty, "an empty draft is never saved")
        type("Groceries", into: session)
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(store.notes.map(\.title), ["Groceries"])
        XCTAssertTrue(session.isPersisted)
    }

    func testTypingIsSavedWithinTheCoalescingDelay() async throws {
        let controller = makeController(delay: .milliseconds(50))
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Quick", into: session)
        XCTAssertTrue(store.notes.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.notes.first?.title, "Quick")
        XCTAssertFalse(session.isDirty)
    }

    func testFailedSaveIsCheckpointedBeforeNavigationAndRetrySavesIt() throws {
        let controller = makeController()
        controller.start()
        let first = try XCTUnwrap(controller.active)
        type("Draft one", into: first)
        gate.shouldFail = true
        XCTAssertTrue(controller.newNote(), "a checkpoint lets navigation go on")
        guard case .notSaved = first.problem else { return XCTFail("slot says Not saved") }
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertEqual(try NoteDraftJournal(directory: directory).entries().count, 1)

        gate.shouldFail = false
        XCTAssertTrue(controller.preserve(first), "Retry")
        XCTAssertNil(first.problem)
        XCTAssertEqual(store.notes.map(\.title), ["Draft one"])
        XCTAssertTrue(try NoteDraftJournal(directory: directory).entries().isEmpty, "the checkpoint goes once saved")
    }

    func testWhenStoreAndCheckpointBothFailTheDraftStaysAndNavigationIsRefused() throws {
        let journal = FailingJournal()
        let controller = makeController(journal: journal)
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Precious", into: session)
        gate.shouldFail = true
        XCTAssertFalse(controller.newNote())
        XCTAssertTrue(controller.active === session, "the session is never replaced")
        guard case .onlyInMemory = session.problem else { return XCTFail("slot says Only in memory") }
        XCTAssertFalse(controller.preserveAll(), "hide and quit are refused")
        XCTAssertTrue(session.engine.plainText.contains("Precious"))
        gate.shouldFail = false
        controller.retry()
        XCTAssertNil(session.problem)
        XCTAssertTrue(controller.newNote())
    }

    func testRecoveredDraftOpensFirstAndIsSaved() throws {
        let existing = makeController()
        existing.start()
        let session = try XCTUnwrap(existing.active)
        type("Saved text", into: session)
        XCTAssertTrue(existing.preserveAll())
        let noteID = session.noteID
        type(" and more", into: session)
        gate.shouldFail = true
        XCTAssertTrue(existing.preserveAll())   // checkpointed
        gate.shouldFail = false

        // Relaunch.
        let relaunched = makeController()
        relaunched.start()
        let recovered = try XCTUnwrap(relaunched.active)
        XCTAssertEqual(recovered.noteID, noteID)
        XCTAssertEqual(recovered.notice, "Restored unsaved text.")
        XCTAssertNil(recovered.problem)
        XCTAssertEqual(store.note(withID: noteID)?.title, "Saved text and more")
        XCTAssertTrue(try NoteDraftJournal(directory: directory).entries().isEmpty)
    }

    func testLeavingANoteKeepsAVersionAndAppliesAWaitingAgentEdit() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Plan", into: session)
        XCTAssertTrue(controller.preserveAll())
        let id = session.noteID
        XCTAssertEqual(store.openDocumentNoteIDs(), [id])
        let token = try XCTUnwrap(store.note(withID: id)).revisionToken
        guard case .success(.pending) = store.agentWrite(noteID: id, baseRevisionToken: token,
                                                         document: NoteDocument(blocks: [.text("Agent plan")]),
                                                         agentName: "Claude", noteIsOpen: store.openDocumentNoteIDs().contains(id)) else {
            return XCTFail()
        }
        XCTAssertTrue(controller.newNote())
        XCTAssertEqual(store.note(withID: id)?.title, "Agent plan")
        XCTAssertTrue(store.versions(noteID: id).contains { $0.reason == .leave })
        XCTAssertTrue(controller.open(noteID: id))
        XCTAssertEqual(controller.active?.engine.document().title, "Agent plan", "the reopened note shows the applied edit")
    }

    func testStagedImageIsCommittedWithTheSaveThatShowsIt() throws {
        let controller = makeController()
        controller.start()
        let session = try XCTUnwrap(controller.active)
        type("Pics", into: session)
        let item = StagedNoteAttachment(id: UUID(), filename: "a.png", contentTypeIdentifier: "public.png", byteCount: 3,
                                        digest: String(repeating: "b", count: 64), data: Data([1, 2, 3]))
        session.engine.insertImage(item, pixelSize: CGSize(width: 10, height: 10))
        XCTAssertTrue(controller.preserveAll())
        XCTAssertEqual(try store.attachmentRows(forNoteID: session.noteID).map(\.id), [item.id])
        XCTAssertTrue(session.engine.staged.isEmpty)
    }
}

@MainActor
private final class FailingJournal: NoteDraftJournaling {
    struct Failure: Error {}
    func write(_ entry: NoteDraftJournalEntry, staged: [StagedNoteAttachment]) throws { throw Failure() }
    func remove(noteID: UUID) throws {}
    func entries() throws -> [(NoteDraftJournalEntry, [StagedNoteAttachment])] { [] }
}
