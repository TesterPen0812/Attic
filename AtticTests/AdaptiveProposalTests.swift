import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// N5, Idea B (Planning.md, Accepted "2026-11-01 · Adaptive picks"): an
/// agent's proposal is reviewed inside the note, with Accept and Reject on
/// each change. Data safety first: the note is built from the accepted
/// changes only, in one transaction; every decision can be undone; versions
/// are kept as before; a failed save rolls back; an edit made elsewhere
/// during review is never lost.
@MainActor
final class AdaptiveProposalTests: XCTestCase {
    private var gate: PersistenceGate!
    private var store: NoteStore!
    private var directory: URL!

    override func setUp() async throws {
        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        #endif
        gate = PersistenceGate()
        store = try makeTestNoteStore(persist: { [gate] in try gate!.save($0) },
                                      attachmentFileStore: makeTestAttachmentFileStore())
        directory = ownedTemporaryDirectory(prefix: "AtticProposalReview")
    }

    override func tearDown() async throws {
        #if DEBUG
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
        #endif
    }

    // MARK: Fixtures

    private static let current = NoteDocument(blocks: [
        .text("Boiler replacement"),
        .text("Landlord agreed to replace the boiler."),
        .text("Landlord prefers a combi boiler."),
        .text("Old unit is 14 years old."),
    ])
    /// Two changes: the third block rewritten, and a new last block.
    private static let proposed = NoteDocument(blocks: [
        .text("Boiler replacement"),
        .text("Landlord agreed to replace the boiler."),
        .text("Landlord prefers a combi boiler with a 10-year warranty."),
        .text("Old unit is 14 years old."),
        .text("Forward the final quote."),
    ])

    private func makeController() -> NotesPageController {
        NotesPageController(store: store, journal: NoteDraftJournal(directory: directory),
                            saveDelay: .seconds(60), pauseVersionDelay: .seconds(600))
    }

    private func reviewFixture(current: NoteDocument = current, proposed: NoteDocument = proposed)
        async throws -> (NotesPageController, NoteSession) {
        let controller = makeController()
        await controller.startAndWait()
        guard case let .success((id, revision)) = store.createDocumentNote(id: UUID(), document: current) else {
            throw NoteDocumentStoreError.saveFailed("fixture")
        }
        await XCTAssertTrueAsync(await controller.openDurably(noteID: id))
        let session = try XCTUnwrap(controller.active)
        guard case let .success(.pending(editID)) = store.agentWrite(noteID: id,
            baseRevisionToken: revision.uuidString, document: proposed,
            agentName: "Claude", disposition: store.agentWriteDisposition(id)) else {
            throw NoteDocumentStoreError.saveFailed("proposal fixture")
        }
        await XCTAssertTrueAsync(await controller.beginProposalReview(id: editID))
        XCTAssertEqual(controller.proposalReview?.changes?.changes.count, 2)
        return (controller, session)
    }

    private func storedTexts(_ noteID: UUID) -> [String] {
        store.loadDocument(noteID: noteID)?.content.document?.blocks.map(\.text) ?? []
    }

    // MARK: The changes

    func testChangeSetFindsEachChangeAndMergesOnlyTheAcceptedOnes() {
        let set = NoteProposalChangeSet(current: Self.current, proposed: Self.proposed)
        XCTAssertEqual(set.changes.map(\.removed), [2..<3, 4..<4])
        XCTAssertEqual(set.changes.map(\.added), [2..<3, 4..<5])
        let ids = set.changes.map(\.id)
        XCTAssertEqual(set.merged(accepting: []).blocks.map(\.text), Self.current.blocks.map(\.text))
        XCTAssertEqual(set.merged(accepting: Set(ids)).blocks.map(\.text), Self.proposed.blocks.map(\.text))
        XCTAssertEqual(set.merged(accepting: [ids[0]]).blocks.map(\.text), [
            "Boiler replacement", "Landlord agreed to replace the boiler.",
            "Landlord prefers a combi boiler with a 10-year warranty.", "Old unit is 14 years old.",
        ])
        XCTAssertEqual(set.merged(accepting: [ids[1]]).blocks.map(\.text),
                       Self.current.blocks.map(\.text) + ["Forward the final quote."])
    }

    func testChangesMatchBlocksWhoseOnlyDifferenceIsTheirID() {
        var proposed = Self.current
        proposed.blocks = proposed.blocks.map { var block = $0; block.id = UUID(); return block }
        XCTAssertTrue(NoteProposalChangeSet(current: Self.current, proposed: proposed).changes.isEmpty)
    }

    func testTheReviewShowsEachUndecidedChangeInPlaceAndDecidedOnesAsTheyWillRead() {
        let set = NoteProposalChangeSet(current: Self.current, proposed: Self.proposed)
        let open = set.display(decisions: [:])
        // Removed (struck through) above its replacement, both marked.
        XCTAssertEqual(open.document.blocks.map(\.text), [
            "Boiler replacement", "Landlord agreed to replace the boiler.",
            "Landlord prefers a combi boiler.", "Landlord prefers a combi boiler with a 10-year warranty.",
            "Old unit is 14 years old.", "Forward the final quote.",
        ])
        let first = set.changes[0].id, second = set.changes[1].id
        XCTAssertEqual(open.marks, [nil, nil, .removed(first), .added(first), nil, .added(second)])
        XCTAssertEqual(open.controls, [3: first, 5: second], "Accept and Reject sit on each change's last line")
        XCTAssertTrue(open.document.blocks[2].marks.contains { $0.kind == .strikethrough })
        let decided = set.display(decisions: [first: true, second: false])
        XCTAssertEqual(decided.document.blocks.map(\.text), set.merged(accepting: [first]).blocks.map(\.text))
        XCTAssertEqual(decided.marks, Array(repeating: nil, count: 4))
        XCTAssertTrue(decided.controls.isEmpty)
    }

    func testTheReviewEngineMarksEachChangedParagraph() {
        let set = NoteProposalChangeSet(current: Self.current, proposed: Self.proposed)
        let display = set.display(decisions: [:])
        let engine = NoteEditorEngine(noteID: UUID(), document: display.document, readOnly: true)
        engine.applyReviewMarks(display.marks)
        let text = engine.textStorage.string as NSString
        let starts = engine.reviewMarkOffsets.keys.sorted()
        XCTAssertEqual(starts.map { text.substring(with: text.paragraphRange(for: NSRange(location: $0, length: 0)))
            .trimmingCharacters(in: .newlines) },
            ["Landlord prefers a combi boiler.", "Landlord prefers a combi boiler with a 10-year warranty.",
             "Forward the final quote."])
        XCTAssertEqual(starts.map { engine.reviewMarkOffsets[$0] }, [.removed, .added, .added])
        XCTAssertEqual(engine.paragraphRanges(forBlocks: [3, 5]).count, 2)
    }

    // MARK: Per-change decisions

    func testPerChangeAcceptBuildsTheNoteFromTheAcceptedChangesOnlyAtomically() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        let versionsBefore = store.versions(noteID: session.noteID).count
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        // A decision is the review's own state: nothing is written yet.
        XCTAssertEqual(storedTexts(session.noteID), Self.current.blocks.map(\.text))
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 1)
        XCTAssertEqual(controller.remainingProposalChanges, 1)
        XCTAssertNotNil(controller.proposalReview)
        // The last decision writes the note, its version and the resolution together.
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[1].id, accept: false))
        XCTAssertNil(controller.proposalReview)
        XCTAssertEqual(storedTexts(session.noteID), [
            "Boiler replacement", "Landlord agreed to replace the boiler.",
            "Landlord prefers a combi boiler with a 10-year warranty.", "Old unit is 14 years old.",
        ])
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 0)
        XCTAssertEqual(store.note(withID: session.noteID)?.externalEditorName, "Claude")
        XCTAssertEqual(controller.active?.engine.document().blocks.map(\.text), storedTexts(session.noteID))
        // Versions as before: the agent's base and the text the review replaced.
        let versions = store.versions(noteID: session.noteID)
        XCTAssertEqual(versions.count, versionsBefore + 1)
        XCTAssertTrue(versions.contains { $0.reason == .beforeAgentEdit })
        XCTAssertTrue(versions.contains { $0.reason == .replacedByDraft && $0.title == "Boiler replacement"
            && $0.body.contains("Landlord prefers a combi boiler.") })
    }

    func testAcceptAllAndRejectAllDecideOnlyWhatIsLeft() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[1].id, accept: false))
        await XCTAssertTrueAsync(await controller.decideRemainingProposalChanges(accept: true))
        XCTAssertEqual(storedTexts(session.noteID), Array(Self.proposed.blocks.map(\.text).prefix(4)))
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 0)
    }

    func testRejectingEveryChangeLeavesTheNoteAndDiscardsTheProposal() async throws {
        let (controller, session) = try await reviewFixture()
        let versionsBefore = store.versions(noteID: session.noteID).count
        let revision = store.note(withID: session.noteID)?.revisionToken
        await XCTAssertTrueAsync(await controller.decideRemainingProposalChanges(accept: false))
        XCTAssertNil(controller.proposalReview)
        XCTAssertEqual(storedTexts(session.noteID), Self.current.blocks.map(\.text))
        XCTAssertEqual(store.note(withID: session.noteID)?.revisionToken, revision)
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 0)
        XCTAssertEqual(store.versions(noteID: session.noteID).count, versionsBefore)
    }

    // MARK: Undo

    func testEveryDecisionDuringReviewCanBeUndoneAndRedone() async throws {
        let (controller, _) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        XCTAssertFalse(controller.canUndoProposalDecision)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: false))
        XCTAssertEqual(controller.proposalDecisions, [changes[0].id: false])
        XCTAssertTrue(controller.undoProposalDecision())
        XCTAssertEqual(controller.proposalDecisions, [:])
        XCTAssertEqual(controller.remainingProposalChanges, 2)
        XCTAssertTrue(controller.redoProposalDecision())
        XCTAssertEqual(controller.proposalDecisions, [changes[0].id: false])
        // A new decision ends the redo trail.
        XCTAssertTrue(controller.undoProposalDecision())
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        XCTAssertFalse(controller.canRedoProposalDecision)
        XCTAssertFalse(controller.redoProposalDecision())
    }

    func testUndoAfterTheLastDecisionPutsTheNoteBackAndRedoAppliesItAgain() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[1].id, accept: true))
        XCTAssertEqual(storedTexts(session.noteID), Self.proposed.blocks.map(\.text))
        let editor = try XCTUnwrap(controller.active?.engine)
        XCTAssertTrue(editor.canUndoCommand, "⌘Z reaches the applied review")
        await XCTAssertTrueAsync(await controller.undoVersionRestoreDurably(expectedID: controller.versionRestoreUndoID))
        XCTAssertEqual(storedTexts(session.noteID), Self.current.blocks.map(\.text))
        XCTAssertEqual(controller.active?.engine.document().blocks.map(\.text), Self.current.blocks.map(\.text))
        await XCTAssertTrueAsync(await controller.redoVersionRestoreDurably())
        XCTAssertEqual(storedTexts(session.noteID), Self.proposed.blocks.map(\.text))
    }

    // MARK: Failure and concurrent edits

    func testAFailedSaveRollsBackAndKeepsTheReviewOpen() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        let versionsBefore = store.versions(noteID: session.noteID).count
        gate.shouldFail = true
        await XCTAssertFalseAsync(await controller.decideProposalChange(changes[1].id, accept: true))
        XCTAssertNotNil(controller.proposalReview)
        XCTAssertNotNil(controller.proposalReviewNotice)
        // The failed decision is not kept; the earlier one is.
        XCTAssertEqual(controller.proposalDecisions, [changes[0].id: true])
        XCTAssertEqual(storedTexts(session.noteID), Self.current.blocks.map(\.text))
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 1)
        XCTAssertEqual(store.versions(noteID: session.noteID).count, versionsBefore)
        XCTAssertFalse(store.modelContext.hasChanges, "the failed transaction rolled back")
        gate.shouldFail = false
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[1].id, accept: true))
        XCTAssertEqual(storedTexts(session.noteID), Self.proposed.blocks.map(\.text))
    }

    func testAnEditSavedDuringReviewIsNeverLost() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        // Another window saves an edit to a block the proposal didn't touch.
        var edited = Self.current
        edited.blocks[1] = .text("Landlord agreed in writing.")
        guard case .success = store.saveDocument(noteID: session.noteID, document: edited,
                                                 baseRevisionID: session.baseRevisionID) else { return XCTFail() }
        await XCTAssertFalseAsync(await controller.decideProposalChange(changes[1].id, accept: true))
        XCTAssertEqual(storedTexts(session.noteID), edited.blocks.map(\.text))
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 1)
        XCTAssertNotNil(controller.proposalReviewNotice)
        // The review now compares with the saved edit; the earlier decision carries over.
        let refreshed = try XCTUnwrap(controller.proposalReview?.changes)
        XCTAssertEqual(refreshed.current.blocks.map(\.text), edited.blocks.map(\.text))
        XCTAssertEqual(refreshed.changes.count, 3, "the proposal's older line shows as a change of its own")
        XCTAssertEqual(controller.remainingProposalChanges, 2)
        let revert = try XCTUnwrap(refreshed.changes.first { refreshed.proposed.blocks[$0.added].map(\.text) == ["Landlord agreed to replace the boiler."] })
        await XCTAssertTrueAsync(await controller.decideProposalChange(revert.id, accept: false))
        await XCTAssertTrueAsync(await controller.decideRemainingProposalChanges(accept: true))
        XCTAssertEqual(storedTexts(session.noteID), [
            "Boiler replacement", "Landlord agreed in writing.",
            "Landlord prefers a combi boiler with a 10-year warranty.", "Old unit is 14 years old.",
            "Forward the final quote.",
        ])
        XCTAssertTrue(store.versions(noteID: session.noteID).contains { $0.body.contains("Landlord agreed in writing.") })
    }

    /// The controls hold no state of their own, so any host (the top card,
    /// or the bottom row's pill) shows the same review: one action at a time.
    func testReviewActionsRunOneAtATimeThroughTheController() async throws {
        let (controller, _) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        var runs = 0
        controller.performProposalReviewAction {
            runs += 1
            return await controller.decideProposalChange(changes[0].id, accept: true)
        }
        XCTAssertTrue(controller.isProposalReviewBusy)
        XCTAssertFalse(controller.canUndoProposalDecision)
        controller.performProposalReviewAction { runs += 1; return true }
        while controller.isProposalReviewBusy { await Task.yield() }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(controller.proposalDecisions, [changes[0].id: true])
        XCTAssertTrue(controller.canUndoProposalDecision)
    }

    // MARK: Idea C: the pill grows into the review bar

    private func hasProposalStatus(_ controller: NotesPageController, _ session: NoteSession) -> Bool {
        controller.statusItems(for: session).contains { if case .proposal = $0 { true } else { false } }
    }

    private func barWidth(_ controller: NotesPageController, proposalID: UUID) -> CGFloat {
        let item = AtticStatusItem(id: "proposal", systemName: "sparkle", title: "Claude has changes")
        // The bar's own (ideal) width, as the bottom row lays it out.
        let host = NSHostingController(rootView: NoteProposalReviewBar(controller: controller, item: item, proposalID: proposalID)
            .environment(\.atticDesign, .default))
        return host.sizeThatFits(in: CGSize(width: 600, height: 60)).width
    }

    func testThePillGrowsIntoTheBarAndEscapeFoldsItBack() async throws {
        let (controller, session) = try await reviewFixture()
        let proposalID = try XCTUnwrap(controller.proposalReview?.id)
        XCTAssertTrue(controller.isReviewingProposalInPlace)
        let bar = barWidth(controller, proposalID: proposalID)
        // Esc: the review view's cancel key ends the review; the proposal waits.
        let page = NSHostingView(rootView: NoteProposalInPlaceReview(controller: controller,
            review: try XCTUnwrap(controller.proposalReview), changes: try XCTUnwrap(controller.proposalReview?.changes),
            columnInset: 16, topInset: 40, bottomInset: 40, design: .default))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.contentView = page
        page.layoutSubtreeIfNeeded()
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        if !page.performKeyEquivalent(with: escape) { window.sendEvent(escape) }
        XCTAssertFalse(controller.isReviewingProposalInPlace, "Esc folds the bar back into the pill")
        XCTAssertTrue(hasProposalStatus(controller, session), "the pill stays: the proposal waits")
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 1)
        let pill = barWidth(controller, proposalID: proposalID)
        XCTAssertGreaterThan(bar, pill + 40, "the bar adds •••, Reject and Accept at the pill's end (bar \(bar), pill \(pill))")
        // A 320 pt panel's row: 320 − 2 × 12 − Back and Aa (2 × 27) − 2 × 9.
        XCTAssertLessThanOrEqual(bar, 224, "the bar fits beside Back and Aa at 320 pt")
        // The pill opens the review again: pill → bar.
        await XCTAssertTrueAsync(await controller.beginProposalReview(id: proposalID))
        XCTAssertTrue(controller.isReviewingProposalInPlace)
        XCTAssertEqual(barWidth(controller, proposalID: proposalID), bar, accuracy: 0.5)
        window.contentView = nil
    }

    func testThePillGoesOnceTheLastChangeIsDecided() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        XCTAssertTrue(hasProposalStatus(controller, session))
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        XCTAssertTrue(hasProposalStatus(controller, session), "one change left: the bar stays")
        XCTAssertEqual(controller.remainingProposalChanges, 1)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[1].id, accept: false))
        XCTAssertFalse(controller.isReviewingProposalInPlace)
        let applied = try XCTUnwrap(controller.active)
        XCTAssertFalse(hasProposalStatus(controller, applied), "every change decided: the pill goes")
    }

    func testEndingTheReviewKeepsTheProposalForLater() async throws {
        let (controller, session) = try await reviewFixture()
        let changes = try XCTUnwrap(controller.proposalReview?.changes?.changes)
        await XCTAssertTrueAsync(await controller.decideProposalChange(changes[0].id, accept: true))
        controller.endProposalReview()
        XCTAssertEqual(controller.proposalDecisions, [:])
        XCTAssertEqual(storedTexts(session.noteID), Self.current.blocks.map(\.text))
        XCTAssertEqual(store.pendingEdits(noteID: session.noteID).count, 1)
    }
}
