import AppKit
import CryptoKit
import SwiftData
import XCTest
@testable import Attic

/// Headless hunt: these tests never order a window or touch the general pasteboard.
@MainActor
final class PhaseXHunt1ReproTests: XCTestCase {
    private func engine(_ document: NoteDocument) -> NoteEditorEngine {
        NoteEditorEngine(noteID: UUID(), document: document)
    }

    private func create(_ document: NoteDocument, in store: NoteStore,
                        staged: [StagedNoteAttachment] = []) throws -> (UUID, UUID) {
        let result = try store.createDocumentNote(id: UUID(), document: document, staged: staged).get()
        return (result.noteID, result.revisionID)
    }

    private func decoded(_ data: Data?) throws -> NoteDocument {
        guard let data, case let .editable(document) = NoteContentCodec.decode(data) else {
            throw NoteDocumentStoreError.readOnly
        }
        return document
    }

    private func richDocument() -> (NoteDocument, [StagedNoteAttachment]) {
        let data = Data("owned test bytes".utf8)
        let staged = ["image.png", "brief.txt"].map {
            StagedNoteAttachment(id: UUID(), filename: $0,
                contentTypeIdentifier: $0.hasSuffix("png") ? "public.png" : "public.plain-text",
                byteCount: Int64(data.count), digest: NotePayloadDigest.sha256(data), data: data)
        }
        var heading = NoteBlock.text("Heading", style: "heading"); heading.level = 2
        var subheading = NoteBlock.text("Subheading", style: "heading"); subheading.level = 3
        var bullet = NoteBlock.text("Nested bullet", style: "bullet"); bullet.indent = 1
        var link = NoteBlock.text("A link and bold")
        // Stored marks use kind order; begin with the codec's canonical representation.
        link.marks = [NoteMark(.bold, offset: 11, length: 4),
                      NoteMark(.link, offset: 2, length: 4, url: "https://example.com/a")]
        var date = NoteBlock.text("Due \u{FFFC}.")
        date.inlines = [.init(id: UUID(), kind: .date(NoteDay(year: 2026, month: 10, day: 9)!))]
        var table = NoteTable(texts: [["Name", "Value"], ["a|b", "line\nbreak"]], headerRow: false,
                              alignments: [.center, .right])
        table.rows[1].cells[0].marks = [NoteMark(.italic, offset: 0, length: 3)]
        var document = NoteDocument(blocks: [.text("Round trip"), .text("Body"), heading, subheading,
            bullet, .text("Number", style: "number"), .text("Quote", style: "quote"),
            .text("let x = 1", style: "mono"), .checklist("Open"), .checklist("Done", checked: true),
            link, date, .divider(), .table(table),
            .image(attachmentID: staged[0].id, widthFraction: 0.75, pixelWidth: 20, pixelHeight: 10),
            .file(attachmentID: staged[1].id, filename: staged[1].filename,
                  contentTypeIdentifier: staged[1].contentTypeIdentifier, byteCount: staged[1].byteCount), .text("End")])
        document.refreshRequiredCapabilities()
        return (document, staged)
    }

    func testH2_02LinkDestinationLiteralEntitiesAndClosingParenthesesSurvive() throws {
        for url in ["https://example.com/?x=&amp;", "https://example.com/a)b", "https://example.com/a(b", "https://example.com/?x=&lt;br&gt;"] {
            var table = NoteTable(texts: [["Header"], ["link"]])
            table.rows[1].cells[0].marks = [NoteMark(.link, offset: 0, length: 4, url: url)]
            let imported = try XCTUnwrap(NoteTableText.parseMarkdown(NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText)))
            XCTAssertEqual(imported.rows[1].cells[0], table.rows[1].cells[0], url)
        }
    }

    func testAllBlockStylesObjectsLinksAndTagsSurviveLiveSaveReopenAndRestore() throws {
        let (document, staged) = richDocument()
        XCTAssertEqual(NoteTextKitRoundTrip.document(afterRoundTrip: document), document)
        let root = ownedTemporaryDirectory(prefix: "PhaseXRoundTrip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let files = makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("files"))
        let store = NoteStore(container: container, attachmentFileStore: files)
        addTeardownBlock { [weak store] in await store?.waitForAttachmentReconciliation() }
        let (id, revision) = try create(document, in: store, staged: staged)
        XCTAssertTrue(store.setTags(["uni", "notes"], for: try XCTUnwrap(store.note(withID: id))))
        XCTAssertTrue(store.recordVersion(noteID: id, reason: .leave))
        let version = try XCTUnwrap(store.versions(noteID: id).first)
        XCTAssertEqual(try decoded(store.note(withID: id)?.content), document)
        let reopened = try PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory: root)
        let saved = try XCTUnwrap(ModelContext(reopened).fetch(FetchDescriptor<NoteItem>()).first)
        XCTAssertEqual(try decoded(saved.content), document)
        XCTAssertEqual(Set(saved.tags), ["uni", "notes"])
        let reopenedAttachments = try ModelContext(reopened).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(reopenedAttachments.count, staged.count)
        for item in staged {
            let attachment = try XCTUnwrap(reopenedAttachments.first { $0.id == item.id })
            XCTAssertEqual(attachment.payload, item.data)
            XCTAssertEqual(attachment.contentDigest, item.digest)
            XCTAssertEqual(attachment.byteCount, item.byteCount)
        }
        _ = try store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Changed")]), baseRevisionID: revision).get()
        _ = try store.restoreVersion(version.id, noteID: id).get()
        XCTAssertEqual(try decoded(store.note(withID: id)?.content), document)
        XCTAssertEqual(Set(store.note(withID: id)?.tags ?? []), ["uni", "notes"])
        XCTAssertEqual(Set(store.attachments(for: id).map(\.id)), Set(staged.map(\.id)))
        XCTAssertEqual(engine(try decoded(store.note(withID: id)?.content)).document(), document)
    }

    func testSaveFailureRollsBackDocumentTagsVersionsAndEveryReplica() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let document = NoteDocument(blocks: [.text("Keep"), .text("Original")])
        let (id, revision) = try create(document, in: store)
        let duplicate = NoteItem(id: id, title: "Keep", body: "Original")
        duplicate.content = try NoteContentCodec.encode(document); duplicate.contentFormat = 1
        duplicate.revisionID = revision
        store.modelContext.insert(duplicate); try store.modelContext.save()
        let versionsBefore = store.versions(noteID: id).count
        gate.shouldFail = true
        guard case .failure = store.saveDocument(noteID: id, document: NoteDocument(blocks: [.text("Lose")]),
            baseRevisionID: revision, tags: ["changed"]) else { return XCTFail("Injected failure must refuse the save") }
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<NoteItem>())
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(try decoded(row.content), document)
            XCTAssertEqual(row.revisionID, revision)
            XCTAssertTrue(row.tags.isEmpty)
        }
        XCTAssertEqual(store.versions(noteID: id).count, versionsBefore)
        XCTAssertNotNil(store.lastErrorMessage)
    }

    func testGroupedEditsUndoOnceRedoExactlyAndNewEditClearsRedo() {
        let original = NoteDocument(blocks: [.text("Title"), .text("Body")])
        let editor = engine(original)
        editor.history.beginGroup()
        XCTAssertTrue(editor.performEdit(NSRange(location: 10, length: 0), with: NSAttributedString(string: " A"), name: "Group"))
        XCTAssertTrue(editor.performEdit(NSRange(location: 12, length: 0), with: NSAttributedString(string: " B"), name: "Group"))
        editor.history.endGroup()
        let after = editor.document()
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(editor.document(), original)
        XCTAssertFalse(editor.history.canUndo)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(editor.document(), after)
        XCTAssertTrue(editor.history.undo())
        XCTAssertTrue(editor.performEdit(NSRange(location: 10, length: 0), with: NSAttributedString(string: " new"), name: "New"))
        XCTAssertFalse(editor.history.canRedo)
    }

    func testLegacyMigrationIsVerifiedDurableAndReversibleWithoutChangingOriginalText() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Legacy e\u{301}", body: "first\r\nsecond\rthird\n"))
        let original = (note.title, note.body)
        let snapshot = try store.legacySnapshot(noteID: note.id).get()
        let plan = try LegacyNoteMigration.plan(snapshot).get()
        let verified = try LegacyNoteMigration.verify(plan, roundTrip: { NoteTextKitRoundTrip.document(afterRoundTrip: $0) }).get()
        _ = try store.commitMigration(verified).get()
        XCTAssertEqual(try decoded(store.note(withID: note.id)?.content), plan.document)
        let saved = try XCTUnwrap(ModelContext(store.container).fetch(FetchDescriptor<NoteItem>()).first)
        XCTAssertEqual(saved.title, original.0); XCTAssertEqual(saved.body, original.1)
        let version = try XCTUnwrap(store.versions(noteID: note.id).first { $0.reason == .beforeMigration })
        _ = try store.restoreVersion(version.id, noteID: note.id).get()
        XCTAssertEqual(store.note(withID: note.id)?.contentFormat, 0)
        XCTAssertEqual(store.note(withID: note.id)?.body, original.1)
    }

    func testLegacyImageAndFileMigrationPreservesPlacementPayloadsAndRollsBackFailedCommit() throws {
        let gate = PersistenceGate()
        let store = try makeTestNoteStore(persist: { try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore())
        let id = try XCTUnwrap(store.create(title: "Legacy attachments", body: "first\nsecond\n")).id
        let bytes = Data([1, 2, 3]), digest = NotePayloadDigest.sha256(bytes)
        let image = NoteAttachment(noteID: id, originalFilename: "old.png", contentTypeIdentifier: "public.png",
            byteCount: 3, sortIndex: 0, contentDigest: digest, payload: bytes)
        image.inlineOffset = 2
        let file = NoteAttachment(noteID: id, originalFilename: "old.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: 3, sortIndex: 1, contentDigest: digest, payload: bytes)
        file.inlineOffset = nil
        store.modelContext.insert(image); store.modelContext.insert(file); try store.modelContext.save()
        let imageID = image.id, fileID = file.id
        let attachmentIDs = Set([imageID, fileID])
        let snapshot = try store.legacySnapshot(noteID: id).get()
        let plan = try LegacyNoteMigration.plan(snapshot).get()
        let verified = try LegacyNoteMigration.verify(plan, roundTrip: { NoteTextKitRoundTrip.document(afterRoundTrip: $0) }).get()
        XCTAssertEqual(plan.document.blocks.map(\.kind), [.text, .image, .text, .text, .text, .file])
        XCTAssertEqual(Set(plan.document.attachmentIDs), attachmentIDs)
        gate.shouldFail = true
        guard case .failure(.saveFailed) = store.commitMigration(verified) else { return XCTFail("Migration save must fail") }
        XCTAssertEqual(store.note(withID: id)?.contentFormat, 0)
        XCTAssertEqual(store.note(withID: id)?.body, "first\nsecond\n")
        XCTAssertTrue(store.versions(noteID: id).isEmpty)
        gate.shouldFail = false
        _ = try store.commitMigration(verified).get()
        XCTAssertEqual(try decoded(store.note(withID: id)?.content), plan.document)
        let rows = try ModelContext(store.container).fetch(FetchDescriptor<NoteAttachment>())
        XCTAssertEqual(Set(rows.map(\.id)), attachmentIDs)
        XCTAssertTrue(rows.allSatisfy { $0.payload == bytes && $0.contentDigest == digest })
        XCTAssertEqual(rows.first { $0.id == imageID }?.inlineOffset, 2)
        XCTAssertNil(rows.first { $0.id == fileID }?.inlineOffset)
    }

    // Reproductions were run red before being marked by finding ID.
    func testH2_01MarkdownTableLiteralBreakTagSurvivesExportImport() throws {
        let table = NoteTable(texts: [["Header"], ["literal <br> text"], ["<br/> <br /> &lt;br&gt; &amp; &#10;"], ["line\nbreak | slash\\"]])
        let markdown = NoteTableText.markdown(table)
        XCTAssertTrue(markdown.contains("literal &lt;br&gt; text"))
        XCTAssertFalse(markdown.contains("literal &amp;lt;br&amp;gt; text"))
        let imported = try XCTUnwrap(NoteTableText.parseMarkdown(markdown))
        XCTAssertEqual(imported.texts, table.texts)
    }

    func testH2_02MarkdownTableInlineMarksSurviveExportImport() throws {
        var table = NoteTable(texts: [["Header"], ["bold link"]])
        table.rows[1].cells[0].marks = [NoteMark(.bold, offset: 0, length: 4),
            NoteMark(.link, offset: 5, length: 4, url: "https://example.com")]
        let markdown = NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText)
        let imported = try XCTUnwrap(NoteTablePaste.table(fromText: markdown))
        XCTAssertEqual(imported.texts, table.texts)
        XCTAssertEqual(imported.rows[1].cells[0].marks, table.rows[1].cells[0].marks)
    }

    func testH2_02EveryInlineMarkNestedUnicodeAndLiteralSyntaxSurvive() throws {
        for kind in NoteMark.Kind.allCases {
            var table = NoteTable(texts: [["Header"], ["😀 café"]])
            table.rows[1].cells[0].marks = [NoteMark(kind, offset: 0, length: 7,
                url: kind == .link ? "https://example.com/a_(b)?x=1&y=2" : nil)]
            let copy = try XCTUnwrap(NoteTableText.parseMarkdown(NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText)))
            XCTAssertEqual(copy.texts, table.texts, "\(kind)")
            XCTAssertEqual(copy.rows[1].cells[0].marks, table.rows[1].cells[0].marks, "\(kind)")
        }
        var table = NoteTable(texts: [["Header"], ["bold italic link"], ["**literal** [link](url) <u>raw</u> &lt;br&gt;"]])
        table.rows[1].cells[0].marks = [NoteMark(.bold, offset: 0, length: 11), NoteMark(.italic, offset: 5, length: 6),
            NoteMark(.link, offset: 12, length: 4, url: "https://example.com")]
        let copy = try XCTUnwrap(NoteTableText.parseMarkdown(NoteTableText.markdown(table, cellText: NoteEditorEngine.markdownCellText)))
        XCTAssertEqual(copy.texts, table.texts)
        XCTAssertEqual(copy.rows[1].cells[0].marks, table.rows[1].cells[0].marks)
        XCTAssertTrue(copy.rows[2].cells[0].marks.isEmpty)
    }

    func testH2_02MalformedNestedMarkupStaysLiteralAndBounded() {
        let text = String(repeating: "[", count: 2_000) + "unclosed"
        XCTAssertEqual(NoteTableText.inlineCell(text).text, text)
    }

    func testH2_03RestoreRejectsDivergentVersionReplicas() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let (id, _) = try create(NoteDocument(blocks: [.text("Current")]), in: store)
        let versionID = UUID()
        for title in ["Version A", "Version B"] {
            store.modelContext.insert(NoteVersion(id: versionID, noteID: id, createdAt: Date(), reason: .leave,
                content: try NoteContentCodec.encode(NoteDocument(blocks: [.text(title)])), contentFormat: 1,
                title: title, body: "", attachmentIDs: [], sourceRevisionID: UUID()))
        }
        try store.modelContext.save()
        let before = store.note(withID: id)?.content
        let result = store.restoreVersion(versionID, noteID: id)
        if case .success = result { XCTFail("Divergent history replicas must refuse restore") }
        XCTAssertEqual(store.note(withID: id)?.content, before)
    }

    func testH2_03HistoryRestoreRejectsDivergentFamilyAndKeepsPreview() async throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let (id, _) = try create(NoteDocument(blocks: [.text("Current")]), in: store)
        let versionID = UUID(), timestamp = Date(), revision = UUID()
        for title in ["Version A", "Version B"] {
            store.modelContext.insert(NoteVersion(id: versionID, noteID: id, createdAt: timestamp, reason: .leave,
                content: try NoteContentCodec.encode(NoteDocument(blocks: [.text(title)])), contentFormat: 1,
                title: title, body: "", attachmentIDs: [], sourceRevisionID: revision))
        }
        try store.modelContext.save()
        let controller = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: ownedTemporaryDirectory(prefix: "H203Browser")),
            saveDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await controller.startAndWait()
        XCTAssertTrue(controller.open(noteID: id))
        await XCTAssertTrueAsync(await controller.openHistoryDurably())
        let browser = try XCTUnwrap(controller.historyBrowser)
        let before = store.note(withID: id)?.content
        await XCTAssertFalseAsync(await controller.restoreHistoryVersionDurably())
        XCTAssertTrue(controller.historyBrowser === browser)
        XCTAssertNotNil(browser.failure)
        XCTAssertEqual(store.note(withID: id)?.content, before)
        XCTAssertNil(controller.versionRestoreUndoID)
        controller.closeHistory()
    }

    func testH2_03RestoreUsesRetentionCompleteFamilyAdmission() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let (id, _) = try create(NoteDocument(blocks: [.text("Current")]), in: store)
        let version = NoteVersion(noteID: id, createdAt: Date(), reason: .leave, content: nil,
            contentFormat: 0, title: "Unknown", body: "Keep unknown history", attachmentIDs: [], sourceRevisionID: nil)
        version.reasonRaw = "future-reason"
        store.modelContext.insert(version); try store.modelContext.save()
        XCTAssertFalse(NotePhysicalFamilyRetention.versionEligible([version], noteIDs: [id], proposalBases: [], recoveryBases: []))
        let before = store.note(withID: id)?.content
        if case .success = store.restoreVersion(version.id, noteID: id) { XCTFail("Unknown family must refuse restore") }
        XCTAssertEqual(store.note(withID: id)?.content, before)
    }

    func testH2_05RetentionAndPreservationKeepExactLegacySpellings() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Legacy", body: "caf\u{E9}"))
        let timestamp = Date(), versionID = UUID()
        var family: [NoteVersion] = []
        for body in ["caf\u{E9}", "cafe\u{301}"] {
            let version = NoteVersion(id: versionID, noteID: note.id, createdAt: timestamp, reason: .leave,
                content: nil, contentFormat: 0, title: "Legacy", body: body, attachmentIDs: [], sourceRevisionID: note.revisionID)
            store.modelContext.insert(version); family.append(version)
        }
        try store.modelContext.save()
        XCTAssertFalse(NotePhysicalFamilyRetention.versionEligible(family, noteIDs: [note.id], proposalBases: [], recoveryBases: []))
        let unversioned = try XCTUnwrap(store.create(title: "Another", body: "caf\u{E9}"))
        let copy = NoteItem(id: unversioned.id, title: "Another", body: "cafe\u{301}")
        copy.revisionID = unversioned.revisionID
        XCTAssertEqual(store.stageDisplacedReplicas([unversioned, copy], reason: .beforeRestore, timestamp: timestamp), 2)
    }

    func testH2_05ProposalAttributionIdentityIsExact() throws {
        let edit = NotePendingEdit(noteID: UUID(), baseRevisionToken: UUID().uuidString,
            proposedContent: try NoteContentCodec.encode(NoteDocument(blocks: [.text("Proposed")])),
            agentName: "caf\u{E9}", createdAt: Date())
        let signature = NoteProposalSignature(edit)
        edit.agentName = "cafe\u{301}"
        XCTAssertNotEqual(NoteProposalSignature(edit), signature)
        let copy = NotePendingEdit(id: edit.id, noteID: edit.noteID, baseRevisionToken: edit.baseRevisionToken,
            proposedContent: try XCTUnwrap(edit.proposedContent), agentName: "caf\u{E9}", createdAt: edit.createdAt)
        XCTAssertFalse(NotePhysicalFamilyRetention.proposalEligible([edit, copy], noteIDs: [edit.noteID]))
    }

    func testFix4TypingMarkUndoRedoKeepsOtherPendingMarks() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("Plain")]))
        let (_, view) = engine.makeView()
        let caret = NSRange(location: engine.textStorage.length, length: 0)
        view.setSelectedRange(caret)
        XCTAssertTrue(engine.perform(.mark(.bold)))
        XCTAssertTrue(engine.perform(.mark(.italic)))
        for _ in 0..<3 {
            XCTAssertTrue(engine.history.undo())
            XCTAssertEqual(view.selectedRange(), caret)
            let undone = try XCTUnwrap(view.typingAttributes[.font] as? NSFont)
            XCTAssertTrue(undone.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertFalse(undone.fontDescriptor.symbolicTraits.contains(.italic))
            XCTAssertTrue(engine.history.redo())
            XCTAssertEqual(view.selectedRange(), caret)
            let redone = try XCTUnwrap(view.typingAttributes[.font] as? NSFont)
            XCTAssertTrue(redone.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertTrue(redone.fontDescriptor.symbolicTraits.contains(.italic))
        }
    }

    func testH2_04UndoRedoRestoresExactSelection() {
        let editor = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
        let (scroll, view) = editor.makeView()
        defer { editor.detachView(); _ = scroll }
        let selected = NSRange(location: 7, length: 3)
        view.setSelectedRange(selected)
        view.insertText("X", replacementRange: selected)
        let after = editor.document(), afterSelection = view.selectedRange()
        XCTAssertTrue(editor.history.undo())
        XCTAssertEqual(view.selectedRange(), selected)
        XCTAssertTrue(editor.history.redo())
        XCTAssertEqual(editor.document(), after)
        XCTAssertEqual(view.selectedRange(), afterSelection)
    }

    func testH2_04SelectionsRoundTripAcrossEveryEditKind() throws {
        let cases: [(String, NSRange, (NoteEditorEngine, NoteEditorTextView) -> Void)] = [
            ("Typing", NSRange(location: 7, length: 3), { _, view in view.insertText("X", replacementRange: view.selectedRange()) }),
            ("Delete", NSRange(location: 7, length: 3), { _, view in view.deleteBackward(nil) }),
            ("Replace", NSRange(location: 7, length: 3), { editor, _ in
                XCTAssertTrue(editor.performEdit(NSRange(location: 7, length: 3), with: NSAttributedString(string: "XY"),
                    name: "Replace", selection: NSRange(location: 8, length: 1))) }),
            ("Inline", NSRange(location: 7, length: 3), { editor, view in XCTAssertTrue(editor.perform(.mark(.bold), selection: view.selectedRange())) }),
            ("Paragraph", NSRange(location: 7, length: 3), { editor, view in XCTAssertTrue(editor.perform(.paragraph(.bullet), selection: view.selectedRange())) }),
            ("Checklist", NSRange(location: 7, length: 3), { editor, view in XCTAssertTrue(editor.perform(.paragraph(.checklist), selection: view.selectedRange())) }),
            ("Date", NSRange(location: 7, length: 3), { editor, view in XCTAssertTrue(editor.insertDate(NoteDay(year: 2026, month: 10, day: 9)!, at: view.selectedRange())) }),
            ("Tags", NSRange(location: 7, length: 3), { editor, _ in editor.setTagsFromPicker(["work"]) }),
            ("Typing mark", NSRange(location: 7, length: 0), { editor, view in XCTAssertTrue(editor.perform(.mark(.italic), selection: view.selectedRange())) })
        ]
        for (label, beforeSelection, edit) in cases {
            let editor = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
            let (scroll, view) = editor.makeView()
            view.setSelectedRange(beforeSelection)
            let before = editor.document()
            edit(editor, view)
            let after = editor.document(), afterSelection = view.selectedRange()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            XCTAssertTrue(editor.history.undo(), label)
            XCTAssertEqual(editor.document(), before, label)
            XCTAssertEqual(view.selectedRange(), beforeSelection, label)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            XCTAssertTrue(editor.history.redo(), label)
            XCTAssertEqual(editor.document(), after, label)
            XCTAssertEqual(view.selectedRange(), afterSelection, label)
            editor.detachView(); _ = scroll
        }
    }

    func testH2_04GroupedAndCoalescedSelectionUsesEditEndpoints() {
        let editor = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
        let (scroll, view) = editor.makeView()
        defer { editor.detachView(); _ = scroll }
        let before = NSRange(location: 7, length: 3)
        view.setSelectedRange(before)
        view.insertText("X", replacementRange: before)
        view.insertText("Y", replacementRange: view.selectedRange())
        let after = view.selectedRange()
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), before)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), after)
        editor.history.beginGroup()
        let groupBefore = view.selectedRange()
        XCTAssertTrue(editor.performEdit(NSRange(location: 6, length: 0), with: NSAttributedString(string: "A"), name: "Group"))
        XCTAssertTrue(editor.performEdit(NSRange(location: 7, length: 0), with: NSAttributedString(string: "B"), name: "Group",
            selection: NSRange(location: 8, length: 2)))
        editor.history.endGroup()
        let groupAfter = view.selectedRange()
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), groupBefore)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), groupAfter)
    }

    func testH2_04TableEmptyParagraphCompositionAndCheckpointSelections() throws {
        let editor = engine(NoteDocument(blocks: [.text("Title"), .table(NoteTable(texts: [["a"], ["b"]])), .text("")]))
        let (scroll, view) = editor.makeView()
        defer { editor.detachView(); _ = scroll }
        let original = NSRange(location: 8, length: 0)
        view.setSelectedRange(original)
        XCTAssertTrue(editor.perform(.paragraph(.bullet), selection: original))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), original)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), original)
        let table = try XCTUnwrap(editor.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
        view.setSelectedRange(NSRange(location: 6, length: 1))
        let before = view.selectedRange()
        XCTAssertTrue(editor.changeTable(table, name: "Cell") { $0.rows[1].cells[0].text = "changed" })
        view.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), before)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), before)

        let composing = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
        let (composeScroll, composeView) = composing.makeView()
        defer { composing.detachView(); _ = composeScroll }
        let selected = NSRange(location: 7, length: 3)
        composeView.setSelectedRange(selected)
        composeView.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: selected)
        composeView.unmarkText()
        let after = composeView.selectedRange(), document = composing.document()
        let checkpoint = composing.history.checkpoint()
        XCTAssertTrue(composing.history.undo()); XCTAssertEqual(composeView.selectedRange(), selected)
        XCTAssertTrue(composing.history.redo()); XCTAssertEqual(composeView.selectedRange(), after)
        XCTAssertEqual(composing.document(), document)
        composing.history.rewind(to: checkpoint)
        XCTAssertTrue(composing.history.undo()); XCTAssertEqual(composeView.selectedRange(), selected)
    }

    func testH2_04CaretOnlyCommandsDoNotRewriteRecordedEndpoints() {
        let editor = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
        let (scroll, view) = editor.makeView()
        defer { editor.detachView(); _ = scroll }
        let before = NSRange(location: 7, length: 3)
        view.setSelectedRange(before)
        view.insertText("X", replacementRange: before)
        let after = view.selectedRange()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteBackward(nil) // No edit at the start of the document.
        XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), before)
        XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), after)
    }

    func testH2_04CaretCommandAfterSnapshotCannotChangeRedoSelection() {
        for tags in [true, false] {
            let editor = engine(NoteDocument(blocks: [.text("Title"), .text("abcdef")]))
            let (scroll, view) = editor.makeView()
            let selected = NSRange(location: 7, length: 0)
            view.setSelectedRange(selected)
            if tags { editor.setTagsFromPicker(["work"]) }
            else { XCTAssertTrue(editor.perform(.mark(.bold), selection: selected)) }
            // The same user-edit bracket used by a caret-only key command.
            editor.userEditDepth += 1
            view.setSelectedRange(NSRange(location: 0, length: 0))
            editor.userEditDepth -= 1
            XCTAssertTrue(editor.history.undo()); XCTAssertEqual(view.selectedRange(), selected)
            XCTAssertTrue(editor.history.redo()); XCTAssertEqual(view.selectedRange(), selected)
            editor.detachView(); _ = scroll
        }
    }

    func testH2_05MigrationRefusesCanonicallyEqualButByteDivergentReplicas() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Legacy", body: "caf\u{E9}"))
        let copy = NoteItem(id: note.id, title: note.title, body: "cafe\u{301}")
        copy.revisionID = note.revisionID
        store.modelContext.insert(copy); try store.modelContext.save()
        XCTAssertEqual(note.body, copy.body, "Swift's canonical equality masks the different UTF-16 spelling")
        XCTAssertNotEqual(Array(note.body.utf16), Array(copy.body.utf16))
        guard case .failure(.replicasDisagree) = store.legacySnapshot(noteID: note.id) else {
            return XCTFail("The migration gate must refuse byte-divergent legacy replicas")
        }
    }

    func testH2_05MigrationRefusesUnicodeSpellingChangeAfterVerification() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Legacy", body: "caf\u{E9}"))
        let snapshot = try store.legacySnapshot(noteID: note.id).get()
        let plan = try LegacyNoteMigration.plan(snapshot).get()
        let verified = try LegacyNoteMigration.verify(plan, roundTrip: { NoteTextKitRoundTrip.document(afterRoundTrip: $0) }).get()
        note.body = "cafe\u{301}"; try store.modelContext.save()
        guard case .failure(.changedSincePlanned) = store.commitMigration(verified) else {
            return XCTFail("A change of original UTF-16 spelling must invalidate the verified migration")
        }
    }

    func testDetachedEngineReleasesAndViewLifetimeMatchesStockTextKit() async throws {
        weak var weakEditor: NoteEditorEngine?
        weak var weakView: NoteEditorTextView?
        weak var stockView: NSTextView?
        autoreleasepool {
            let editor = engine(NoteDocument(blocks: [.text("Title"), .checklist("One"), .table(.blank())]))
            let (scroll, view) = editor.makeView()
            weakEditor = editor; weakView = view
            editor.detachView()
            _ = scroll
        }
        autoreleasepool {
            let storage = NSTextContentStorage()
            let manager = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
            manager.textContainer = container
            storage.addTextLayoutManager(manager); storage.primaryTextLayoutManager = manager
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 400), textContainer: container)
            let scroll = NSScrollView(frame: view.frame); scroll.documentView = view
            stockView = view
            storage.removeTextLayoutManager(manager)
        }
        // AppKit can retain a text view until queued text-checking/layout work
        // has finished. Immediate weak-reference checks are not a leak oracle.
        for _ in 0..<20 where weakView != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(weakEditor)
        print("PHASEX_LIFETIME noteViewRetained=\(weakView != nil) stockTK2ViewRetained=\(stockView != nil)")
        XCTAssertEqual(weakView == nil, stockView == nil, "Attic must not retain a detached view beyond the equivalent stock TextKit 2 control")
    }

    func testDelayedAttachmentPasteAfterDetachCannotEditOrStageBytes() async throws {
        let bytes = Data("delayed owned bytes".utf8)
        let item = StagedNoteAttachment(id: UUID(), filename: "brief.txt", contentTypeIdentifier: "public.plain-text",
            byteCount: Int64(bytes.count), digest: NotePayloadDigest.sha256(bytes), data: bytes)
        let provider = SuspendedHunt1Provider(item: item)
        let original = NoteDocument(blocks: [.text("Title"), .text("Body")])
        let editor = NoteEditorEngine(noteID: UUID(), document: original, imageProvider: provider)
        let (scroll, view) = editor.makeView()
        let selection = NSRange(location: 10, length: 0)
        view.setSelectedRange(selection)
        let fragment = NoteDocument(blocks: [.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)])
        let data = try NoteContentCodec.encode(fragment, context: .fragment)
        let paste = Task { await editor.pasteDurably(fragmentData: data, at: selection) }
        while provider.continuation == nil { await Task.yield() }
        editor.detachView()
        provider.continuation?.resume(returning: item); provider.continuation = nil
        await XCTAssertFalseAsync(await paste.value)
        XCTAssertEqual(editor.document(), original)
        XCTAssertTrue(editor.staged.isEmpty)
        XCTAssertFalse(editor.history.canUndo)
        _ = scroll
    }

    func testH2_05AttachmentPurgeKeepsCanonicallyEqualButExactDivergentMetadata() throws {
        let clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeTestNoteStore(now: { clock }, attachmentFileStore: makeTestAttachmentFileStore())
        let note = try XCTUnwrap(store.create(title: "Keep attachment family"))
        let id = UUID(), bytes = Data([1, 2, 3]), timestamp = clock.addingTimeInterval(-60 * 86_400)
        for name in ["caf\u{E9}.txt", "cafe\u{301}.txt"] {
            let row = NoteAttachment(id: id, noteID: note.id, originalFilename: name,
                contentTypeIdentifier: "public.plain-text", byteCount: 3, sortIndex: 0,
                contentDigest: NotePayloadDigest.sha256(bytes), payload: bytes)
            row.createdAt = timestamp; row.updatedAt = timestamp; row.deletedAt = timestamp
            store.modelContext.insert(row)
        }
        try store.modelContext.save()
        XCTAssertEqual(store.purgeRemovedAttachments(before: clock), 0)
        XCTAssertEqual(try ModelContext(store.container).fetch(FetchDescriptor<NoteAttachment>()).count, 2)
    }

    func testTableLayoutCacheRecomputesCellWrappingAfterWidthChange() throws {
        let table = NoteTable(texts: [["Header"], [String(repeating: "word ", count: 50)]])
        let editor = engine(NoteDocument(blocks: [.text("Title"), .table(table)]))
        let attachment = try XCTUnwrap(editor.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
        let wide = attachment.layout(width: 500)
        let narrow = attachment.layout(width: 180)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertEqual(attachment.layout(width: 500), wide)
        XCTAssertEqual(attachment.layout(width: 180), narrow)
    }
}

@MainActor
private final class SuspendedHunt1Provider: NoteImageProviding {
    let item: StagedNoteAttachment
    var continuation: CheckedContinuation<StagedNoteAttachment?, Never>?
    init(item: StagedNoteAttachment) { self.item = item }
    func fileURL(forAttachment id: UUID) async -> URL? { nil }
    func filename(forAttachment id: UUID) -> String? { item.filename }
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment? { nil }
    func verifiedBytes(forAttachment id: UUID) async -> StagedNoteAttachment? {
        await withCheckedContinuation { continuation = $0 }
    }
}
