import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class NoteInlineCardsTests: XCTestCase {
    func testPlacementReorderingResizingAndBodyEditsPersistTogether() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let note = NoteItem(title: "Images", body: "First\nSecond\nThird")
        context.insert(note)
        let first = NoteAttachment(noteID: note.id, originalFilename: "First.png", byteCount: 0, sortIndex: 0, contentDigest: "")
        let second = NoteAttachment(noteID: note.id, originalFilename: "Second.png", byteCount: 0, sortIndex: 1, contentDigest: "")
        context.insert(first); context.insert(second)
        try context.save()
        let store = NoteStore(container: container)
        XCTAssertTrue(store.placeAttachment(second.id, in: note.id, offset: 6, before: first.id,
                                             size: CGSize(width: 240, height: 180)))
        let restored = NoteStore(container: container)
        XCTAssertEqual(restored.attachments(for: note.id).map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.attachments(for: note.id)[0].inlineOffset, 6)
        XCTAssertEqual(restored.attachments(for: note.id)[0].displayHeight, 180)
        XCTAssertTrue(restored.update(try XCTUnwrap(restored.notes.first), body: "New\nFirst\nSecond\nThird"))
        let edited = NoteStore(container: container)
        XCTAssertEqual(edited.attachments(for: note.id)[0].inlineOffset, 10)
        XCTAssertTrue(edited.placeAttachment(second.id, in: note.id, offset: nil, size: CGSize(width: 260, height: 56)))
        let compact = NoteStore(container: container).attachments(for: note.id).first { $0.id == second.id }
        XCTAssertNil(compact?.inlineOffset)
        XCTAssertEqual(compact?.displayHeight, 56)
    }

    func testInlineCardReservesSpaceBetweenParagraphsWithoutChangingText() throws {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        textView.font = .systemFont(ofSize: 13)
        textView.string = "First paragraph\nSecond paragraph\nThird paragraph"
        let body = textView.string
        let id = UUID(), layout = NoteInlineCardsLayout()
        layout.update([NoteInlineCard(id: id, offset: 16, height: 56, content: AnyView(Text("Image.png")))], in: textView)
        layout.layout(in: textView)
        let manager = try XCTUnwrap(textView.layoutManager), container = try XCTUnwrap(textView.textContainer)
        let first = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let second = manager.boundingRect(forGlyphRange: NSRange(location: 16, length: 1), in: container)
        let card = try XCTUnwrap(layout.frames[id])
        XCTAssertGreaterThanOrEqual(card.minY, first.maxY)
        XCTAssertLessThanOrEqual(card.maxY, second.minY + textView.textContainerOrigin.y)
        XCTAssertEqual(card.height, 56)
        XCTAssertEqual(textView.string, body)
        // Reopening a plain NSTextView can replace attributes without changing
        // its string. Presentation spacing must be repaired independently.
        textView.textStorage?.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: (body as NSString).length))
        XCTAssertTrue(layout.reserveSpace(in: textView))
        layout.layout(in: textView)
        XCTAssertEqual(layout.frames[id], card)
        layout.update([], in: textView)
        layout.layout(in: textView)
        XCTAssertTrue(layout.frames.isEmpty)
        XCTAssertEqual(textView.string, body)
    }

    func testInlineCardIsAHitTestableDocumentSibling() throws {
        let text = AttachmentAcceptingTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        text.string = "First\nSecond"
        text.font = .systemFont(ofSize: 13)
        let document = NoteEditorDocumentView(textView: text)
        document.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: document.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = document
        defer { window.close() }
        let id = UUID()
        document.inlineLayout.update([NoteInlineCard(id: id, offset: 6, height: 56,
            content: AnyView(Button("Image") {}))], in: text)
        document.layoutDocument(viewport: CGSize(width: 300, height: 400))
        document.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let card = try XCTUnwrap(document.inlineLayout.frames[id])
        let parentPoint = document.convert(CGPoint(x: card.midX, y: card.midY), to: document.superview)
        let hit = try XCTUnwrap(document.hitTest(parentPoint))
        XCTAssertFalse(hit === text || hit.isDescendant(of: text), "Card controls must receive their own mouse/AX routing: frame=\(card), hit=\(type(of: hit))")
    }

    func testAnchorsFollowTextInsertionsDeletionAndUnicode() {
        let old = "First\nSecond\nThird"
        XCTAssertEqual(NoteInlineAnchor.moved(6, from: old, to: "New\n" + old), 10)
        XCTAssertEqual(NoteInlineAnchor.moved(6, from: old, to: "Second\nThird"), 0)
        XCTAssertEqual(NoteInlineAnchor.moved(6, from: old, to: ""), 0)
        XCTAssertEqual(NoteInlineAnchor.paragraphStart(4, in: "😀\nNext"), 3)
        XCTAssertEqual(NoteInlineAnchor.paragraphStart(500, in: "abc"), 3)
    }

    /// R-01: one save carrying disjoint edits on both sides of an inline
    /// attachment's paragraph must keep the card on the paragraph that
    /// survived — not collapse the stored anchor to the first edit.
    func testOneSaveWithEditsOnBothSidesKeepsTheCardOnItsParagraph() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        // UTF-16 paragraphs: "one\n" [0,4), "two\n" [4,8), "three\n" [8,14),
        // "four" [14,18). The card is anchored at the start of "three".
        let note = NoteItem(title: "Card", body: "one\ntwo\nthree\nfour")
        context.insert(note)
        let attachment = NoteAttachment(noteID: note.id, originalFilename: "Card.png",
                                        byteCount: 0, sortIndex: 0, contentDigest: "")
        context.insert(attachment)
        try context.save()
        let store = NoteStore(container: container)
        XCTAssertTrue(store.placeAttachment(attachment.id, in: note.id, offset: 8))
        XCTAssertEqual(store.attachments(for: note.id).first?.inlineOffset, 8)
        // One update delivers both inserts: "!" after "one" (old offset 3) and
        // after "four" (old offset 18). "two" and "three" are untouched.
        XCTAssertTrue(store.update(try XCTUnwrap(store.note(withID: note.id)),
                                   body: "one!\ntwo\nthree\nfour!"))
        XCTAssertEqual(store.attachmentAnchorFallbackDerivations, 1,
                       "A body-only save derives one list, not one diff per attachment")
        let persisted = NoteStore(container: container)
        // New UTF-16 offsets: "one!\n" [0,5), "two\n" [5,9), "three\n" [9,15),
        // "four!" [15,20) — "three" now starts at 9, not at the first edit.
        XCTAssertEqual(persisted.attachments(for: note.id).first?.inlineOffset, 9,
                       "The anchor must follow the surviving paragraph, not collapse to the first edit")
    }

    /// Whole-body anchoring must also hold when a save touches every
    /// paragraph except the anchored one.
    func testDisjointEditsAroundAParagraphKeepItsAnchor() {
        let old = "one\ntwo\nthree\nfour"
        let new = "one!\ntwo\nthree\nfour!"
        XCTAssertEqual(NoteInlineAnchor.moved(0, from: old, to: new), 0,
                       "An anchor inside the edited paragraph stays at its start")
        XCTAssertEqual(NoteInlineAnchor.moved(4, from: old, to: new), 5,
                       "\"two\" survives and shifts by the first edit's delta")
        XCTAssertEqual(NoteInlineAnchor.moved(8, from: old, to: new), 9,
                       "\"three\" survives between both edits")
        XCTAssertEqual(NoteInlineAnchor.moved(14, from: old, to: new), 15,
                       "\"four\" keeps its own paragraph start, not the first edit's")
    }

    func testCanonicalUnicodeNormalizationStillRebasesUTF16Anchor() {
        let decomposed = "e\u{301}\nA"
        let precomposed = "é\nA"
        XCTAssertEqual(decomposed, precomposed, "Swift equality is intentionally canonical")
        XCTAssertFalse(NoteTextReplacement.utf16Equal(decomposed, precomposed))
        XCTAssertEqual(decomposed.utf16.count, 4)
        XCTAssertEqual(precomposed.utf16.count, 3)
        XCTAssertEqual(NoteInlineAnchor.moved(3, from: decomposed, to: precomposed), 2)
    }

    func testExactDuplicateParagraphBatchPersistsEveryAttachmentReplica() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let context = ModelContext(container)
        let note = NoteItem(title: "Repeated", body: "A\nA\nB")
        let attachmentID = UUID()
        context.insert(note)
        for _ in 0..<2 {
            let replica = NoteAttachment(
                id: attachmentID,
                noteID: note.id,
                originalFilename: "Repeated.png",
                byteCount: 0,
                sortIndex: 0,
                contentDigest: ""
            )
            replica.inlineOffset = 2
            context.insert(replica)
        }
        try context.save()

        let store = NoteStore(container: container)
        let old = "A\nA\nB", new = "A\nA\nA\nB"
        let batch = NoteBodyEditBatch(
            baseText: old,
            resultText: new,
            edits: [NoteTextReplacement(location: 0, oldLength: 0, newLength: 2)]
        )
        XCTAssertTrue(store.update(
            try XCTUnwrap(store.note(withID: note.id)),
            body: new,
            bodyEditBatch: batch
        ))
        XCTAssertEqual(store.attachmentAnchorFallbackDerivations, 0)

        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<NoteAttachment>())
            .filter { $0.id == attachmentID }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.inlineOffset), [4, 4])
    }

    func testFailedSaveRetainsExactBatchForRetry() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let gate = PersistenceGate()
        let store = NoteStore(container: container, persist: gate.save)
        let note = try XCTUnwrap(store.create(body: "A\nA\nB"))
        let context = ModelContext(container)
        let attachment = NoteAttachment(
            noteID: note.id,
            originalFilename: "Repeated.png",
            byteCount: 0,
            sortIndex: 0,
            contentDigest: ""
        )
        attachment.inlineOffset = 2
        context.insert(attachment)
        try context.save()
        store.refresh()

        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(try XCTUnwrap(store.note(withID: note.id))))
        let updated = "A\nA\nA\nB"
        draft.bodyEditLedger.record(
            NoteTextReplacement(location: 0, oldLength: 0, newLength: 2),
            resulting: updated
        )
        draft.body = updated

        gate.shouldFail = true
        XCTAssertFalse(draft.flush())
        XCTAssertEqual(store.note(withID: note.id)?.body, "A\nA\nB")
        XCTAssertEqual(store.attachments(for: note.id).first?.inlineOffset, 2)
        XCTAssertTrue(draft.isDirty)

        gate.shouldFail = false
        XCTAssertTrue(draft.flush())
        XCTAssertEqual(store.note(withID: note.id)?.body, updated)
        XCTAssertEqual(store.attachments(for: note.id).first?.inlineOffset, 4)
        XCTAssertEqual(store.attachmentAnchorFallbackDerivations, 0)
    }
}


/// PERF-12 / PERF-14 / NOTES-013 / PERF-008 scaling gates, plus the anchor
/// equivalence the incremental rebase must preserve.
@MainActor
final class NoteInlineCardsPerformanceTests: XCTestCase {
    /// ~52 KB of body text in 720 paragraphs.
    static let largeBody: String = {
        let paragraph = String(repeating: "The quiet shelf keeps the thought. ", count: 2)
        return (0..<720).map { "\($0) \(paragraph)" }.joined(separator: "\n")
    }()

    static func cardOffsets(in text: String) -> [Int] {
        let value = text as NSString
        return (1...5).map { index in
            NoteInlineAnchor.paragraphStart(value.length * index / 6, in: text)
        }
    }

    /// Successive single-character insertions in the middle of the note.
    static func keystrokeBodies(from base: String, count: Int) -> [String] {
        let cursor = (base as NSString).length / 2
        var bodies: [String] = []
        var current = base
        for step in 0..<count {
            current = (current as NSString).replacingCharacters(
                in: NSRange(location: cursor + step, length: 0), with: "x"
            )
            bodies.append(current)
        }
        return bodies
    }

    // MARK: - Correctness of the incremental rebase

    /// The recorded stream must rebase anchors exactly like applying each real
    /// edit in order — the audit's R-02 counterexample is one instance of this.
    func testRecordedEditsRebaseAnchorsExactlyInOrder() {
        var base = "Alpha\nBravo\nCharlie\nDelta\nEcho"
        // Deterministic pseudo-random edit streams.
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return bound <= 0 ? 0 : Int(seed >> 33) % bound
        }
        for trial in 0..<200 {
            base = "Alpha\nBravo\nCharlie\nDelta\nEcho"
            let ledger = NoteBodyEditLedger()
            _ = ledger.edits(from: base, to: base)
            var current = base
            let anchor = NoteInlineAnchor.paragraphStart(next((base as NSString).length), in: base)
            // Ground truth: the same anchor folded through the real edits.
            var expected = anchor
            for _ in 0...(trial % 4) {
                let length = (current as NSString).length
                let location = next(length + 1)
                let removal = min(next(3), length - location)
                let insertion = String(UnicodeScalar(UInt8(97 + next(26)))) // a-z
                let edit = NoteTextReplacement(
                    location: location, oldLength: removal, newLength: (insertion as NSString).length
                )
                let updated = (current as NSString).replacingCharacters(
                    in: NSRange(location: location, length: removal), with: insertion
                )
                ledger.record(edit, resulting: updated)
                expected = edit.rebasing(expected)
                current = updated
            }
            let incremental = NoteInlineAnchor.moved(
                anchor, by: ledger.edits(from: base, to: current), in: current
            )
            XCTAssertEqual(
                incremental, NoteInlineAnchor.paragraphStart(expected, in: current),
                "Ordered recorded edits must rebase like the real edit stream, not a composed span"
            )
        }
    }

    /// R-02: disjoint edits recorded in one batch must not collapse the
    /// unchanged gap between them into a replaced span.
    func testDisjointRecordedEditsKeepTheAnchorOnItsParagraph() {
        // UTF-16 paragraphs: "Alpha\n" [0,6), "Bravo\n" [6,12),
        // "Charlie\n" [12,20), "Delta" [20,25).
        let base = "Alpha\nBravo\nCharlie\nDelta"
        let ledger = NoteBodyEditLedger()
        _ = ledger.edits(from: base, to: base)
        // Insert "!" inside "Alpha" at 2, then "!" after "Delta" at 26 in the
        // intermediate text — one batch, as a multi-part edit would deliver.
        let newBody = "Al!pha\nBravo\nCharlie\nDelta!"
        ledger.record([
            NoteTextReplacement(location: 2, oldLength: 0, newLength: 1),
            NoteTextReplacement(location: 26, oldLength: 0, newLength: 1),
        ], resulting: newBody)
        let edits = ledger.edits(from: base, to: newBody)
        // The "Bravo" anchor shifts by the first edit only.
        XCTAssertEqual(NoteInlineAnchor.moved(6, by: edits, in: newBody), 7)
        XCTAssertEqual(NoteInlineAnchor.moved(0, by: edits, in: newBody), 0)
        XCTAssertEqual(NoteInlineAnchor.moved(12, by: edits, in: newBody), 13)
        XCTAssertEqual(NoteInlineAnchor.moved(20, by: edits, in: newBody), 21)
        // Anchors on surviving paragraphs agree with the whole-body diff.
        for anchor in [0, 6, 12, 20] {
            XCTAssertEqual(
                NoteInlineAnchor.moved(anchor, by: edits, in: newBody),
                NoteInlineAnchor.moved(anchor, from: base, to: newBody),
                "anchor \(anchor)"
            )
        }
    }

    /// R-02's audited counterexample: a 30-unit body, inserts (10,0,5) then
    /// (30,0,5); the anchor at 12 must rebase to 17, not collapse to 10.
    func testOrderedLedgerEditsMatchSequentialRebasing() {
        // Paragraph 1 = 11 x's + "\n" [0,12); paragraph 2 = 17 y's + "\n" [12,30).
        let base = String(repeating: "x", count: 11) + "\n"
            + String(repeating: "y", count: 17) + "\n"
        var intermediate = base as NSString
        intermediate = intermediate.replacingCharacters(
            in: NSRange(location: 10, length: 0), with: "12345") as NSString
        let newBody = intermediate.replacingCharacters(
            in: NSRange(location: 30, length: 0), with: "67890")
        XCTAssertEqual(newBody.utf16.count, 40)
        let ledger = NoteBodyEditLedger()
        _ = ledger.edits(from: base, to: base)
        ledger.record(
            NoteTextReplacement(location: 10, oldLength: 0, newLength: 5),
            resulting: intermediate as String
        )
        ledger.record(
            NoteTextReplacement(location: 30, oldLength: 0, newLength: 5),
            resulting: newBody as String
        )
        let edits = ledger.edits(from: base, to: newBody as String)
        XCTAssertEqual(NoteInlineAnchor.moved(12, by: edits, in: newBody as String), 17,
                       "Sequential rebasing lands the anchor on the y-paragraph's new start")
    }

    func testGroupedTextStorageTransactionUsesPreCoalescingEdits() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "one\ntwo\nthree\nfour"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(note))
        let editor = AttachmentAwareTextEditor(
            text: Binding(get: { draft.body }, set: { draft.body = $0 }),
            isFileTargeted: .constant(false),
            isFocused: true,
            session: draft.editorSession,
            onFocusChange: { _ in },
            onImportFiles: { _, _ in },
            onImportError: { _ in },
            bodyEditLedger: draft.bodyEditLedger
        )
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        _ = coordinator.synchronize(parent: editor, textView: textView)
        _ = draft.bodyEditLedger.edits(from: note.body, to: draft.body)

        XCTAssertTrue(coordinator.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: NSRange(location: 3, length: 0)),
                                       NSValue(range: NSRange(location: 18, length: 0))],
            replacementStrings: ["!", "!"]
        ))
        let storage = try XCTUnwrap(textView.textStorage)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "!")
        storage.replaceCharacters(in: NSRange(location: 19, length: 0), with: "!")
        storage.endEditing()
        if draft.body != textView.string {
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        XCTAssertEqual(draft.body, "one!\ntwo\nthree\nfour!")
        let edits = draft.bodyEditLedger.edits(from: note.body, to: draft.body)
        XCTAssertEqual(edits, [
            NoteTextReplacement(location: 18, oldLength: 0, newLength: 1),
            NoteTextReplacement(location: 3, oldLength: 0, newLength: 1),
        ])
        XCTAssertEqual(NoteInlineAnchor.moved(8, by: edits, in: draft.body), 9)
    }

    func testUndoEditSequenceRestoresOriginalAnchor() {
        let base = "A\nA\nB"
        let inserted = "A\nA\nA\nB"
        let ledger = NoteBodyEditLedger()
        ledger.reset(to: base)
        ledger.record(
            NoteTextReplacement(location: 0, oldLength: 0, newLength: 2),
            resulting: inserted
        )
        ledger.record(
            NoteTextReplacement(location: 0, oldLength: 2, newLength: 0),
            resulting: base
        )
        let edits = ledger.edits(from: base, to: base)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(NoteInlineAnchor.moved(2, by: edits, in: base), 2)
    }

    func testEditorSwitchAndRemoteReplacementResetStaleEdits() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let first = try XCTUnwrap(store.create(body: "A\nA\nB"))
        let second = try XCTUnwrap(store.create(body: "Second body"))
        let draft = NoteDraftController(noteStore: store, autosaveDelay: .seconds(60))
        XCTAssertTrue(draft.beginEditing(first))
        draft.bodyEditLedger.record(
            NoteTextReplacement(location: 0, oldLength: 0, newLength: 2),
            resulting: "A\nA\nA\nB"
        )
        draft.discardDraft()
        XCTAssertTrue(draft.beginEditing(second))
        XCTAssertEqual(
            draft.bodyEditLedger.batch(from: second.body, to: second.body).edits,
            [],
            "A new editor session must not inherit the prior note's edit batch"
        )

        XCTAssertTrue(store.update(second, body: "Remote body"))
        XCTAssertTrue(draft.reconcileWithStore())
        XCTAssertEqual(draft.body, "Remote body")
        XCTAssertEqual(
            draft.bodyEditLedger.batch(from: "Remote body", to: "Remote body").edits,
            [],
            "Adopting a remote body must reset the old session's edit batch"
        )
    }

    /// A dirty-draft card between disjoint edits resolves through the ordered
    /// recorded edits, not through a single composed span.
    func testResolverRebasesCardsThroughOrderedRecordedEdits() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "one\ntwo\nthree\nfour"))
        let context = ModelContext(container)
        let card = NoteAttachment(noteID: note.id, originalFilename: "Card.png",
                                  byteCount: 0, sortIndex: 0, contentDigest: "")
        context.insert(card)
        try context.save()
        store.refresh()
        XCTAssertTrue(store.placeAttachment(card.id, in: note.id, offset: 8))
        let draft = NoteDraftController(noteStore: store)
        XCTAssertTrue(draft.beginEditing(try XCTUnwrap(store.note(withID: note.id))))
        let resolver = NoteInlineCardResolver()
        _ = draft.bodyEditLedger.edits(from: "one\ntwo\nthree\nfour", to: "one\ntwo\nthree\nfour")
        draft.body = "one!\ntwo\nthree\nfour!"
        draft.bodyEditLedger.record([
            NoteTextReplacement(location: 3, oldLength: 0, newLength: 1),
            NoteTextReplacement(location: 19, oldLength: 0, newLength: 1),
        ], resulting: draft.body)
        let resolution = resolver.resolve(noteStore: store, noteDraft: draft)
        XCTAssertEqual(resolution.cards.map(\.id), [card.id])
        XCTAssertEqual(resolution.cards.first?.offset, 9,
                       "The display anchor must stay on the surviving \"three\" paragraph")
        XCTAssertTrue(resolution.trayAttachments.isEmpty)
    }

    func testSingleRecordedEditMatchesTheWholeBodyDiffExactly() {
        let base = "Alpha\nBravo\nCharlie\nDelta\nEcho"
        for location in 0...(base as NSString).length {
            let updated = (base as NSString).replacingCharacters(
                in: NSRange(location: location, length: 0), with: "#"
            )
            let ledger = NoteBodyEditLedger()
            _ = ledger.edits(from: base, to: base)
            ledger.record(
                NoteTextReplacement(location: location, oldLength: 0, newLength: 1), resulting: updated
            )
            let edits = ledger.edits(from: base, to: updated)
            for anchor in 0...(base as NSString).length {
                XCTAssertEqual(
                    NoteInlineAnchor.moved(anchor, by: edits, in: updated),
                    NoteInlineAnchor.moved(anchor, from: base, to: updated),
                    "anchor \(anchor) after inserting at \(location)"
                )
            }
        }
    }

    func testLedgerFallsBackToAFullDiffWhenTheRecordedHistoryDoesNotFit() {
        let base = "Alpha\nBravo"
        let ledger = NoteBodyEditLedger()
        _ = ledger.edits(from: base, to: base)
        // A delta whose resulting length disagrees with the text is refused.
        ledger.record(
            NoteTextReplacement(location: 0, oldLength: 0, newLength: 5), resulting: "Alpha\nBravo\nCharlie"
        )
        let diffs = ledger.fullDiffs
        let edits = ledger.edits(from: base, to: "Alpha\nBravo\nCharlie")
        XCTAssertEqual(ledger.fullDiffs, diffs + 1, "A refused delta must re-diff, never guess")
        XCTAssertEqual(edits, NoteTextReplacement.edits(from: base, to: "Alpha\nBravo\nCharlie"))
    }

    func testExternalReplacementInvalidationRestoresTheDiffPath() {
        let base = "Alpha\nBravo"
        let ledger = NoteBodyEditLedger()
        _ = ledger.edits(from: base, to: base)
        ledger.invalidate()
        let diffs = ledger.fullDiffs
        _ = ledger.edits(from: base, to: "Zulu\n" + base)
        XCTAssertEqual(ledger.fullDiffs, diffs + 1)
    }

    // MARK: - PERF-12: per-keystroke work is O(edit), not O(document)

    func testTypingBeyondEveryCardRestylesNoParagraphAndReplacesNoRootView() throws {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        textView.font = .systemFont(ofSize: 13)
        textView.string = Self.largeBody
        let layout = NoteInlineCardsLayout()
        let cards = Self.cardOffsets(in: Self.largeBody).map {
            NoteInlineCard(id: UUID(), offset: $0, height: 56, content: AnyView(Color.clear))
        }
        layout.update(cards, in: textView)
        XCTAssertEqual(layout.rootViewReplacementCount, cards.count, "One host per card, built once")
        let restyled = layout.restyledParagraphCount
        let replacements = layout.rootViewReplacementCount
        for _ in 0..<20 {
            let end = (textView.string as NSString).length
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: end, length: 0), with: "x"
            )
            layout.update(cards, in: textView)
        }
        XCTAssertEqual(layout.restyledParagraphCount, restyled,
                       "Typing past every card must not rewrite paragraph styles")
        XCTAssertEqual(layout.rootViewReplacementCount, replacements,
                       "Typing must not re-render any card's SwiftUI subtree")
    }

    func testEditingOneCardParagraphRestylesOnlyThatParagraph() throws {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        textView.font = .systemFont(ofSize: 13)
        textView.string = Self.largeBody
        let layout = NoteInlineCardsLayout()
        let offsets = Self.cardOffsets(in: Self.largeBody)
        let ids = offsets.map { _ in UUID() }
        func cards(at offsets: [Int]) -> [NoteInlineCard] {
            zip(ids, offsets).map {
                NoteInlineCard(id: $0, offset: $1, height: 56, content: AnyView(Color.clear))
            }
        }
        layout.update(cards(at: offsets), in: textView)
        let restyled = layout.restyledParagraphCount
        let replacements = layout.rootViewReplacementCount
        // Type inside the last card's own paragraph: no other anchor moves.
        let last = try XCTUnwrap(offsets.last)
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: last + 1, length: 0), with: "x"
        )
        layout.update(cards(at: offsets), in: textView)
        XCTAssertLessThanOrEqual(layout.restyledParagraphCount - restyled, 2,
                                 "Only the changed paragraph may be stripped and re-styled")
        XCTAssertEqual(layout.rootViewReplacementCount, replacements)
    }

    func testChangedCardIdentityDoesReplaceItsRootView() {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        textView.string = "First\nSecond\nThird"
        let layout = NoteInlineCardsLayout()
        let id = UUID()
        let card = NoteInlineCard(id: id, offset: 6, height: 56,
                                  revision: NoteInlineCardRevision(displayHeight: 56),
                                  content: AnyView(Color.clear))
        layout.update([card], in: textView)
        XCTAssertEqual(layout.rootViewReplacementCount, 1)
        layout.update([card], in: textView)
        XCTAssertEqual(layout.rootViewReplacementCount, 1, "An unchanged card keeps its host")
        layout.update([NoteInlineCard(id: id, offset: 6, height: 220,
                                      revision: NoteInlineCardRevision(displayHeight: 220),
                                      content: AnyView(Color.clear))], in: textView)
        XCTAssertEqual(layout.rootViewReplacementCount, 2, "A resized card must re-render")
    }

    func testLedgerRebasePerKeystrokeOnLargeNote() {
        let base = Self.largeBody
        let offsets = Self.cardOffsets(in: base)
        let cursor = (base as NSString).length / 2
        let bodies = Self.keystrokeBodies(from: base, count: 20)
        measure(metrics: [XCTClockMetric()]) {
            let ledger = NoteBodyEditLedger()
            _ = ledger.edits(from: base, to: base)
            for (step, body) in bodies.enumerated() {
                ledger.record(
                    NoteTextReplacement(location: cursor + step, oldLength: 0, newLength: 1),
                    resulting: body
                )
                let edits = ledger.edits(from: base, to: body)
                for offset in offsets {
                    _ = NoteInlineAnchor.moved(offset, by: edits, in: body)
                }
            }
        }
    }

    func testReserveSpacePerKeystrokeOnLargeNote() {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        textView.font = .systemFont(ofSize: 13)
        textView.string = Self.largeBody
        let layout = NoteInlineCardsLayout()
        let cards = Self.cardOffsets(in: Self.largeBody).map {
            NoteInlineCard(id: UUID(), offset: $0, height: 56, content: AnyView(Color.clear))
        }
        layout.update(cards, in: textView)
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<20 {
                let end = (textView.string as NSString).length
                textView.textStorage?.replaceCharacters(
                    in: NSRange(location: end, length: 0), with: "x"
                )
                layout.update(cards, in: textView)
            }
        }
    }

    // MARK: - PERF-14 / PERF-008: bounded library work

    func testOrderedNotesMemoizesPerRevision() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let origin = Date(timeIntervalSinceReferenceDate: 0)
        for index in 0..<2000 {
            context.insert(NoteItem(
                title: "Note \(index)",
                body: "Body \(index)",
                createdAt: origin.addingTimeInterval(Double(index))
            ))
        }
        try context.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        XCTAssertEqual(store.notes.count, 2000)
        let first = store.orderedNotes()
        XCTAssertEqual(first.map(\.id), store.orderedNotes().map(\.id))
        XCTAssertEqual(first.first?.title, "Note 1999", "Newest first")
        XCTAssertEqual(store.note(withID: try XCTUnwrap(first.first).id)?.title, "Note 1999")
        XCTAssertNil(store.note(withID: UUID()))
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<200 { _ = store.orderedNotes() }
        }
    }

    func testOrderedNotesRefreshesAfterEveryMutation() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let first = try XCTUnwrap(store.create(body: "First"))
        XCTAssertEqual(store.orderedNotes().map(\.id), [first.id])
        let second = try XCTUnwrap(store.create(body: "Second"))
        XCTAssertEqual(store.orderedNotes().map(\.id), [second.id, first.id])
        XCTAssertTrue(store.update(first, body: "First again"))
        XCTAssertEqual(store.orderedNotes().map(\.id), [first.id, second.id])
        XCTAssertEqual(store.note(withID: first.id)?.body, "First again")
        XCTAssertTrue(store.delete(second))
        XCTAssertEqual(store.orderedNotes().map(\.id), [first.id])
        XCTAssertNil(store.note(withID: second.id))
        store.refresh()
        XCTAssertEqual(store.orderedNotes().map(\.id), [first.id])
    }

    func testUnrelatedNoteEditsDoNotReReconcileTheAttachmentIndex() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let note = NoteItem(body: "Note")
        context.insert(note)
        context.insert(NoteAttachment(noteID: note.id, originalFilename: "attached.txt",
                                      byteCount: 8, sortIndex: 0, contentDigest: "abc"))
        try context.save()
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let afterLoad = store.attachmentReconciliationPasses
        XCTAssertEqual(afterLoad, 1, "The first load always reconciles")
        let visible = try XCTUnwrap(store.note(withID: note.id))
        for index in 0..<10 {
            XCTAssertTrue(store.update(visible, body: "Note \(index)"))
        }
        store.refresh()
        XCTAssertEqual(store.attachmentReconciliationPasses, afterLoad,
                       "Body edits leave the attachment set unchanged")
        XCTAssertTrue(store.removeAttachment(try XCTUnwrap(store.attachments(for: note.id).first)))
        store.refresh()
        XCTAssertEqual(store.attachmentReconciliationPasses, afterLoad + 1,
                       "A changed attachment set must reconcile again")
    }

    // MARK: - PERF-12d: the composer resolves inline cards once per change

    func testInlineCardResolverMemoizesAndSplitsTrayFromInlineCards() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let store = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(body: "First\nSecond\nThird"))
        let context = ModelContext(container)
        let inline = NoteAttachment(noteID: note.id, originalFilename: "Inline.png",
                                    byteCount: 0, sortIndex: 0, contentDigest: "")
        let trayed = NoteAttachment(noteID: note.id, originalFilename: "Tray.png",
                                    byteCount: 0, sortIndex: 1, contentDigest: "")
        context.insert(inline)
        context.insert(trayed)
        try context.save()
        store.refresh()
        XCTAssertTrue(store.placeAttachment(inline.id, in: note.id, offset: 6))
        let draft = NoteDraftController(noteStore: store)
        XCTAssertTrue(draft.beginEditing(try XCTUnwrap(store.note(withID: note.id))))

        let resolver = NoteInlineCardResolver()
        let resolution = resolver.resolve(noteStore: store, noteDraft: draft)
        XCTAssertEqual(resolution.cards.map(\.id), [inline.id])
        XCTAssertEqual(resolution.cards.first?.offset, 6)
        XCTAssertEqual(resolution.cards.first?.height, NoteInlineCard.compactHeight,
                       "A new attachment starts as a compact card")
        XCTAssertEqual(resolution.trayAttachments.map(\.id), [trayed.id])
        let rebuilds = resolver.rebuilds
        for _ in 0..<50 { _ = resolver.resolve(noteStore: store, noteDraft: draft) }
        XCTAssertEqual(resolver.rebuilds, rebuilds, "Unrelated publishes must not rebuild the cards")

        draft.body = "New\nFirst\nSecond\nThird"
        let moved = resolver.resolve(noteStore: store, noteDraft: draft)
        XCTAssertEqual(resolver.rebuilds, rebuilds + 1)
        XCTAssertEqual(moved.cards.first?.offset, 10, "The anchor follows the inserted paragraph")

        store.reportAttachmentFailure(inline.id, message: "The original file is missing.")
        let broken = resolver.resolve(noteStore: store, noteDraft: draft)
        XCTAssertEqual(broken.cards.first?.revision.failure, "The original file is missing.")
        XCTAssertEqual(broken.cards.first?.height,
                       NoteInlineCard.compactHeight + NoteInlineCard.recoveryRowHeight,
                       "A broken card reserves room for its recovery line")
    }
}
