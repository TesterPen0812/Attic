import AppKit
import CryptoKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

/// O-01/O-02: exercise the actual shell without ever ordering its window.
@MainActor
final class NotesEditorIsolationTests: XCTestCase {
    private var controller: AtticPanelController!
    private var panel: AtticPanel!
    private var host: NSView!
    private var defaults: UserDefaults!
    private var suite: String!
    private var oldFlag: Any?
    private var settings: AppSettings!
    private var ui: PanelUIState!
    private var drafts: NoteDraftController!
    private var notes: NoteStore!
    private var legacyID: UUID!
    private let gate = PersistenceGate()

    override func setUp() async throws {
        oldFlag = UserDefaults.standard.object(forKey: NotesEditorSetting.defaultsKey)
        UserDefaults.standard.set(true, forKey: NotesEditorSetting.defaultsKey)
        suite = "NotesEditorIsolationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        notes = trackAttachmentReconciliation(of: NoteStore(container: persistence,
            persist: { [gate] in try gate.save($0) }, attachmentFileStore: makeTestAttachmentFileStore()))
        let note = try XCTUnwrap(notes.create(title: "Moodboard", body: "Warm greys, one accent, lots of air.\nThe palette and the type specimen are attached."))
        legacyID = note.id
        XCTAssertTrue(notes.setTags(["mood"], for: note))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for (index, name) in ["Palette.png", "Type specimen.txt"].enumerated() {
            let payload = index == 0 ? png : Data("Type specimen".utf8)
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            notes.modelContext.insert(NoteAttachment(noteID: note.id, originalFilename: name,
                contentTypeIdentifier: index == 0 ? "public.png" : "public.plain-text", byteCount: Int64(payload.count),
                sortIndex: Int64(index), contentDigest: digest, payload: payload))
        }
        try notes.modelContext.save()
        notes.refresh()
        await notes.waitForAttachmentReconciliation()
        defaults.set(note.id.uuidString, forKey: "notes.lastViewedNote.v2")
        drafts = NoteDraftController(noteStore: notes, sessionDefaults: defaults)
        defaults.set(460.0, forKey: "panelHeight")
        settings = AppSettings(defaults: defaults)
        ui = PanelUIState()
        ui.selectSection(.notes)
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        controller = AtticPanelController(store: TaskStore(container: persistence), noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)), noteDraft: drafts,
            settings: settings, uiState: ui)
        panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !before.contains(ObjectIdentifier($0)) })
        host = try XCTUnwrap((panel.contentView as? AtticPanelContentContainer)?.hostingView)
        controller.preparePagesForReveal()
        settle()
    }

    override func tearDown() async throws {
        XCTAssertFalse(panel.isVisible)
        panel.contentView = nil
        panel.close()
        controller = nil
        host = nil
        defaults.removePersistentDomain(forName: suite)
        if let oldFlag { UserDefaults.standard.set(oldFlag, forKey: NotesEditorSetting.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: NotesEditorSetting.defaultsKey) }
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        controller.preparePagesForReveal()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.isVisible, "headless: no window may be ordered")
    }

    private func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    private func assertIsolated(_ route: String, file: StaticString = #filePath, line: UInt = #line) {
        let descendants = views(host)
        XCTAssertFalse(descendants.contains { $0 is AttachmentAcceptingTextView }, "legacy text editor mounted: \(route)", file: file, line: line)
        XCTAssertFalse(descendants.contains { $0 is NoteAttachmentDragView }, "legacy attachment handle mounted: \(route)", file: file, line: line)
        let boundaries = descendants.compactMap { $0 as? NotesRenderBoundary.BoundaryView }
        let identifiers = boundaries.map(\.boundaryID)
        let rows = boundaries.filter { $0.boundaryID.contains("bottom-row") }
        print("O01_ROUTE \(route): \(rows.map { ($0.boundaryID, $0.convert($0.bounds, to: host)) })")
        for legacy in ["legacy-note-composer", "legacy-notes-bottom-row"] {
            XCTAssertFalse(identifiers.contains(legacy), "legacy UI \(legacy): \(route)", file: file, line: line)
        }
        XCTAssertEqual(identifiers.filter { $0 == "notes-v2-bottom-row" }.count, 1, route, file: file, line: line)
        XCTAssertEqual(descendants.filter { $0 is NoteEditorTextView }.count, 1, "new text editor: \(route)", file: file, line: line)
    }

    func testLegacyNoteNeverMountsOldComposerInsideNewPageOnAnyRoute() throws {
        assertIsolated("launch restore")
        XCTAssertTrue(drafts.pages.showLibrary())
        settle()
        XCTAssertTrue(drafts.pages.open(noteID: legacyID))
        drafts.pages.dismissLibrary()
        settle()
        assertIsolated("All notes open")
        for corner in [ScreenCorner.topLeft, .topRight] {
            settings.corner = corner
            settle()
            XCTAssertTrue(drafts.pages.open(noteID: legacyID))
            settle()
            assertIsolated("corner \(corner)")
        }
        settings.panelCornerSize = 89
        settle()
        assertIsolated("corner size 89")
        for width in [420.0, 320.0] {
            settings.panelContentSize = width
            settle()
            assertIsolated("size \(width)")
        }
        for _ in 0..<2 {
            ui.switchPage(to: .tasks, motion: PanelPageMotion.current(reduceMotion: false)) {}
            settle(0.02)
            ui.switchPage(to: .notes, motion: PanelPageMotion.current(reduceMotion: false)) {}
            settle(0.02)
            assertIsolated("mid-transition")
            settle(0.8)
            assertIsolated("page switch settled")
        }
        XCTAssertTrue(drafts.pages.newNote())
        settle()
        assertIsolated("new note")
    }

    func testFlagToggleAndAnExitCapturedBeforeToggleCannotReopenOldUI() throws {
        UserDefaults.standard.set(false, forKey: NotesEditorSetting.defaultsKey)
        let note = try XCTUnwrap(notes.note(withID: legacyID))
        XCTAssertTrue(drafts.beginEditing(note))
        ui.beginEditingNote(note)
        settle()
        XCTAssertTrue(views(host).contains { $0 is AttachmentAcceptingTextView })
        let page = NotesPageHost(noteStore: notes, noteDraft: drafts, uiState: ui,
            layout: PanelPageLayout(cornerSize: 89, panelSize: CGSize(width: 320, height: 460)), hasRestoredSession: true)
        let exit = try XCTUnwrap(page.legacyExitAction)
        UserDefaults.standard.set(true, forKey: NotesEditorSetting.defaultsKey)
        settle()
        assertIsolated("flag on")
        exit()
        settle()
        XCTAssertEqual(drafts.activeNoteID, legacyID, "a stale exit cannot discard the original draft")
        assertIsolated("stale exitToOldPage")
        XCTAssertNil(page.legacyExitAction)
    }

    func testLegacyPreviewIsReadOnlyAndConversionIsExplicitVerifiedAndEditable() throws {
        let note = try XCTUnwrap(notes.note(withID: legacyID))
        let body = note.body
        let rows = notes.attachments(for: legacyID).map(\.id)
        let preview = try drafts.pages.legacyPreview(noteID: legacyID).get()
        XCTAssertTrue(preview.isReadOnly)
        XCTAssertEqual(preview.engine.tags, ["mood"])
        XCTAssertEqual(preview.engine.document().title, "Moodboard")
        XCTAssertEqual(Set(preview.engine.document().attachmentIDs), Set(rows))
        XCTAssertEqual(note.contentFormat, 0, "previewing never converts")
        XCTAssertNil(note.content)
        try drafts.pages.convertLegacyForEditing(noteID: legacyID).get()
        settle()
        XCTAssertEqual(notes.note(withID: legacyID)?.body, body)
        XCTAssertEqual(notes.attachments(for: legacyID).map(\.id), rows)
        XCTAssertTrue(notes.versions(noteID: legacyID).contains { $0.reason == .beforeMigration && $0.body == body })
        let session = try XCTUnwrap(drafts.pages.active)
        XCTAssertFalse(session.isReadOnly)
        XCTAssertEqual(Set(session.engine.document().attachmentIDs), Set(rows))
        let text = try XCTUnwrap(session.engine.textView)
        let location = (session.engine.textStorage.string as NSString).range(of: "Warm greys").location
        text.insertText("Very ", replacementRange: NSRange(location: location, length: 0))
        XCTAssertTrue(drafts.pages.save(session))
        let saved = try XCTUnwrap(notes.loadDocument(noteID: legacyID)?.content.document)
        XCTAssertTrue(saved.blocks.contains { $0.text.hasPrefix("Very Warm") })
        assertIsolated("converted and edited")
    }

    func testRefusedConversionKeepsAllOriginalBytes() throws {
        let refused = NoteItem(title: "Two\nlines", body: "Original")
        notes.modelContext.insert(refused)
        try notes.modelContext.save()
        notes.refresh()
        XCTAssertTrue(drafts.pages.open(noteID: refused.id))
        guard case .failure(.titleHasLineBreak) = drafts.pages.legacyPreview(noteID: refused.id),
              case .failure(.titleHasLineBreak) = drafts.pages.convertLegacyForEditing(noteID: refused.id)
        else { return XCTFail("unsafe conversion must be refused") }
        XCTAssertEqual(refused.contentFormat, 0)
        XCTAssertNil(refused.content)
        XCTAssertEqual(refused.title, "Two\nlines")
        XCTAssertEqual(refused.body, "Original")
        settle()
        XCTAssertFalse(views(host).contains { $0 is AttachmentAcceptingTextView })
    }

    func testConversionSaveFailureRollsBackEveryReplicaAndRetryPreservesAttachments() throws {
        let original = try XCTUnwrap(notes.note(withID: legacyID))
        let replica = NoteItem(id: original.id, title: original.title, body: original.body,
                              createdAt: original.createdAt, updatedAt: original.updatedAt)
        replica.revisionID = original.revisionID
        replica.revision = original.revision
        notes.modelContext.insert(replica)
        try notes.modelContext.save()
        notes.refresh()
        let attachments = Set(notes.attachments(for: legacyID).map(\.id))
        gate.shouldFail = true
        guard case .failure(.saveFailed) = drafts.pages.convertLegacyForEditing(noteID: legacyID)
        else { return XCTFail("injected save failure must refuse conversion") }
        for row in [original, replica] {
            XCTAssertEqual(row.contentFormat, 0)
            XCTAssertNil(row.content)
            XCTAssertEqual(row.title, "Moodboard")
        }
        XCTAssertFalse(notes.versions(noteID: legacyID).contains { $0.reason == .beforeMigration })
        settle()
        assertIsolated("failed conversion")
        gate.shouldFail = false
        try drafts.pages.convertLegacyForEditing(noteID: legacyID).get()
        let freshReplicas = try notes.modelContext.fetch(FetchDescriptor<NoteItem>()).filter { $0.id == legacyID }
        XCTAssertEqual(freshReplicas.count, 2)
        XCTAssertTrue(freshReplicas.allSatisfy { $0.contentFormat == 1 })
        XCTAssertEqual(freshReplicas[0].content, freshReplicas[1].content)
        XCTAssertEqual(Set(try XCTUnwrap(drafts.pages.active).engine.document().attachmentIDs), attachments)
    }

    func testLegacyPreviewRefreshesAttachmentsAddedAfterTheNoteOpens() async throws {
        func renderedAttachmentIDs() throws -> Set<UUID> {
            let text = try XCTUnwrap(views(host).compactMap { $0 as? NoteEditorTextView }.first)
            return Set(NoteTextCodec.document(from: try XCTUnwrap(text.textStorage)).attachmentIDs)
        }
        XCTAssertEqual(try renderedAttachmentIDs().count, 2)
        let existingTextView = try XCTUnwrap(views(host).compactMap { $0 as? NoteEditorTextView }.first)
        notes.refresh()
        settle()
        XCTAssertTrue(views(host).compactMap { $0 as? NoteEditorTextView }.first === existingTextView,
                      "unchanged metadata must retain the preview instead of re-reading payloads")
        let payload = Data("Later attachment".utf8)
        let added = NoteAttachment(noteID: legacyID, originalFilename: "Later.txt",
            contentTypeIdentifier: "public.plain-text", byteCount: Int64(payload.count), sortIndex: 2,
            contentDigest: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(), payload: payload)
        notes.modelContext.insert(added)
        try notes.modelContext.save()
        notes.refresh()
        await notes.waitForAttachmentReconciliation()
        settle()
        XCTAssertEqual(try renderedAttachmentIDs(), Set(notes.attachments(for: legacyID).map(\.id)),
                       "async demo imports must appear even when the note's text revision did not change")
        XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 0)
    }

    func testConversionChecksLegacyLeaveOnlyBeforeCommit() throws {
        var checks = 0
        drafts.pages.leaveLegacyNote = { _ in checks += 1; return checks == 1 }
        try drafts.pages.convertLegacyForEditing(noteID: legacyID).get()
        XCTAssertEqual(checks, 1, "a committed conversion must not be reported as a refused second leave")
        XCTAssertNil(drafts.pages.legacyNoteID)
        XCTAssertEqual(drafts.pages.active?.noteID, legacyID)
        XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 1)
    }

    func testRefusedLegacyLeaveDoesNotConvertOrClaimTheNoteChanged() throws {
        drafts.pages.leaveLegacyNote = { _ in false }
        guard case .failure(.leaveRefused) = drafts.pages.convertLegacyForEditing(noteID: legacyID) else {
            return XCTFail("a refused leave must report its own reason")
        }
        XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 0)
        XCTAssertFalse(notes.versions(noteID: legacyID).contains { $0.reason == .beforeMigration })
        assertIsolated("refused conversion leave")
    }

    func testPreMigrationHistoryRestoreUndoRedoKeepsTheRightEditorAndAttachments() async throws {
        try drafts.pages.convertLegacyForEditing(noteID: legacyID).get()
        let original = try XCTUnwrap(drafts.pages.active)
        let version = try XCTUnwrap(notes.versions(noteID: legacyID).first { $0.reason == .beforeMigration })
        await XCTAssertTrueAsync(await drafts.pages.openHistoryDurably())
        let browser = try XCTUnwrap(drafts.pages.historyBrowser)
        let index = try XCTUnwrap(browser.entries.firstIndex { $0.id == version.id })
        drafts.pages.selectHistoryVersion(index)
        await XCTAssertTrueAsync(await drafts.pages.restoreHistoryVersionDurably())
        for _ in 0..<2 {
            settle(0.8)
            XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 0)
            assertIsolated("pre-migration version restored")
            await XCTAssertTrueAsync(await drafts.pages.undoVersionRestoreDurably(expectedID: drafts.pages.versionRestoreUndoID))
            settle(0.8)
            XCTAssertTrue(drafts.pages.active === original)
            XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 1)
            assertIsolated("undo legacy restore")
            await XCTAssertTrueAsync(await drafts.pages.redoVersionRestoreDurably())
        }
        settle(0.8)
        XCTAssertEqual(notes.attachments(for: legacyID).count, 2)
        assertIsolated("redo legacy restore")
    }

    func testNativeUndoAfterPreMigrationRestoreReturnsToTheEditableDocument() async throws {
        try drafts.pages.convertLegacyForEditing(noteID: legacyID).get()
        let original = try XCTUnwrap(drafts.pages.active)
        let version = try XCTUnwrap(notes.versions(noteID: legacyID).first { $0.reason == .beforeMigration })
        await XCTAssertTrueAsync(await drafts.pages.openHistoryDurably())
        let browser = try XCTUnwrap(drafts.pages.historyBrowser)
        drafts.pages.selectHistoryVersion(try XCTUnwrap(browser.entries.firstIndex { $0.id == version.id }))
        await XCTAssertTrueAsync(await drafts.pages.restoreHistoryVersionDurably())
        settle(0.8)
        let text = try XCTUnwrap(views(host).compactMap { $0 as? NoteEditorTextView }.first)
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(text.validateUserInterfaceItem(undoItem), "native Undo must validate on the read-only preview")
        text.undo(nil)
        await drafts.pages.versionHistoryCommandTask?.value
        XCTAssertTrue(drafts.pages.active === original, "native Undo must reach the durable version route from a legacy preview")
        XCTAssertEqual(notes.note(withID: legacyID)?.contentFormat, 1)
    }

    func testEnablingNewEditorDuringAnOutgoingLegacyPageTransitionRemovesLegacyViews() throws {
        UserDefaults.standard.set(false, forKey: NotesEditorSetting.defaultsKey)
        XCTAssertTrue(drafts.beginEditing(try XCTUnwrap(notes.note(withID: legacyID))))
        ui.beginEditingNote(try XCTUnwrap(notes.note(withID: legacyID)))
        settle()
        XCTAssertTrue(views(host).contains { $0 is AttachmentAcceptingTextView })
        ui.switchPage(to: .tasks, motion: .current(reduceMotion: false)) {}
        settle(0.02)
        UserDefaults.standard.set(true, forKey: NotesEditorSetting.defaultsKey)
        ui.switchPage(to: .notes, motion: .current(reduceMotion: false)) {}
        settle(0.02)
        assertIsolated("enabled during outgoing legacy transition")
        settle(0.8)
        assertIsolated("flag transition settled")
    }

    func testDeletingLegacyPreviewShowsLibraryAndUndoReopensIt() throws {
        XCTAssertTrue(drafts.pages.deleteNote(noteID: legacyID))
        settle()
        XCTAssertTrue(drafts.pages.isLibraryPresented, "deleting a preview must leave a usable page")
        XCTAssertTrue(drafts.pages.undoLibrary())
        // The spring retains the outgoing new preview during the library
        // slide; assert the settled tree, as with the page-switch routes.
        settle(0.8)
        XCTAssertFalse(drafts.pages.isLibraryPresented)
        XCTAssertEqual(drafts.pages.legacyNoteID, legacyID)
        assertIsolated("delete then Undo")
    }
}

/// Notes v2, round 1: chrome B (32 pt corner controls 16 pt from the
/// panel's edges, in Notes and Tasks) and the panel always fitting its
/// window (owner, 2026-10-08: the corner buttons were cut off at the left and
/// right edges).
@MainActor
final class NotesV2ChromeTests: XCTestCase {
    private let defaultCorner = PanelCornerSize.defaultValue

    // MARK: Tokens

    func testChromeBTokens() {
        XCTAssertEqual(AtticControlSize.headerControl, 32)
        XCTAssertEqual(AtticControlSize.panelButton, CGSize(width: 32, height: 32))
        XCTAssertEqual(AtticControlSize.addBarHeight, 32)
        XCTAssertEqual(AtticControlSize.sendButton, CGSize(width: 24, height: 24))
        XCTAssertEqual(AtticStyle.chromeMinimumInset, 16)
        XCTAssertEqual(AtticRadius.control(height: AtticControlSize.headerControl), 13.5, "the 42 % rule")
        XCTAssertEqual(AtticPageButtonMetrics.segment, 24)
        XCTAssertEqual(AtticNoteFormatMetrics.rowCellHeight, 24)
        XCTAssertEqual(AtticNoteMetrics.pillHeight, 32)
        XCTAssertEqual(AtticNoteMetrics.formatButtonGap, 6)
        XCTAssertEqual(AtticControlSize.raisedGlyph, 13)
    }

    /// Every control keeps at least a 28 pt target: the 32 pt buttons by
    /// their size, the 24 pt chips and cells by reaching 2 pt past their edge.
    func testHitTargetsStayAtLeast28() {
        let minimum = AtticControlSize.minimumHitTarget
        XCTAssertGreaterThanOrEqual(AtticControlSize.panelButton.height, minimum)
        XCTAssertGreaterThanOrEqual(AtticControlSize.addBarHeight, minimum)
        for side in [AtticPageButtonMetrics.segment, AtticNoteFormatMetrics.rowCellHeight, AtticControlSize.sendButton.height] {
            XCTAssertEqual(side + 2 * AtticControlSize.hitOutset(for: side), minimum, "side \(side)")
        }
        XCTAssertEqual(AtticControlSize.hitOutset(for: 32), 0)
    }

    // MARK: Lines

    /// The controls sit 16 in; the content line (the note's column, the
    /// Tasks circles and tabs) stays at 28, and the add bar's plus on the
    /// circles' centre line (36).
    func testContentLineStaysAt28AndTheAddBarPlusOnTheCircles() {
        let layout = PanelPageLayout(cornerSize: defaultCorner, panelSize: CGSize(width: 320, height: 520))
        XCTAssertEqual(layout.chromeInsets.leading, 16)
        XCTAssertEqual(layout.headerBottom, 48)
        XCTAssertEqual(layout.chromeInsets.leading + AtticNoteMetrics.columnInset, 28, "the note's column")
        let tasksPageEdge = layout.chromeInsets.leading + AtticLayout.contentFromChrome - AtticLayout.circleX
        XCTAssertEqual(tasksPageEdge + AtticLayout.circleX, 28, "the Tasks circles")
        let plusCentre = layout.chromeInsets.leading + AtticAddBarMetrics.leadingPadding + AtticAddBarMetrics.iconSlot / 2
        XCTAssertEqual(plusCentre, 28 + AtticControlSize.statusCircle / 2, "the plus on the circles' centre line")
        XCTAssertEqual(plusCentre + AtticAddBarMetrics.iconSlot / 2 + AtticAddBarMetrics.gap, 56, "the text on the titles' line")
        // The draft (v2-04): the title's first line at 64, the last line 12
        // above the bottom row (whose top is 48 from the bottom).
        XCTAssertEqual(layout.headerBottom + AtticNoteMetrics.titleTopGap, 64)
        XCTAssertEqual(layout.chromeInsets.bottom + AtticControlSize.panelButton.height + AtticSpacing.s12, 60)
    }

    /// Larger corners push the controls and the content line in together.
    func testLargerCornersMoveTheControlsAndTheContentLineTogether() {
        let size = CGSize(width: 320, height: 520)
        var last: CGFloat = 0
        for corner in PanelCornerSize.allCases.map(\.rawValue) {
            let insets = PanelGeometry.chromeInsets(cornerSize: corner, panelSize: size)
            XCTAssertGreaterThanOrEqual(insets.leading, 16)
            XCTAssertGreaterThanOrEqual(insets.leading, last)
            last = insets.leading
        }
    }

    // MARK: The bottom row never outgrows the panel

    /// The status pill takes only the room the bottom row leaves, so the
    /// row (All notes, the pill, Aa, New note) fits every panel width the
    /// settings allow and every corner size. Before, 176 pt of pill plus
    /// three 36 pt buttons needed 364 pt in a 320 pt panel: the row grew
    /// past the panel and was centred, cutting both corner buttons off.
    func testBottomRowFitsEveryPanelWidthAndCorner() {
        let widths = PanelContentSize.allCases.map(\.rawValue) + [PanelGeometry.minimumPanelSize.width, 333, 500]
        for width in widths {
            for corner in PanelCornerSize.allCases.map(\.rawValue) {
                let layout = PanelPageLayout(cornerSize: corner, panelSize: CGSize(width: width, height: 520))
                for showsFormat in [true, false] {
                    let pill = AtticNoteMetrics.pillMaxWidth(panelWidth: width, chromeInset: layout.chromeInsets.leading,
                                                             showsFormat: showsFormat)
                    let buttons = AtticControlSize.panelButton.width * (showsFormat ? 3 : 2)
                        + (showsFormat ? AtticNoteMetrics.formatButtonGap : 0)
                    let row = layout.chromeInsets.leading * 2 + buttons + AtticSpacing.s12 * 2 + pill
                    XCTAssertLessThanOrEqual(row, width + 0.001, "width \(width), corner \(corner), Aa \(showsFormat)")
                    XCTAssertLessThanOrEqual(pill, AtticNoteMetrics.pillMaxWidth)
                }
            }
        }
        // The default 320 pt panel: 162 pt for the pill beside Aa.
        XCTAssertEqual(AtticNoteMetrics.pillMaxWidth(panelWidth: 320, chromeInset: 16, showsFormat: true), 162)
    }

    // MARK: The root fills its window, whatever its content asks

    func testRootLayoutPlacesOverwideContentAtTheWindowsSizeFromItsOrigin() throws {
        for width in [320, 360, 380, 341.5] as [CGFloat] {
            let host = NSHostingView(rootView: PanelRootLayout {
                ZStack {
                    // A child far wider than the panel (an overflowing row).
                    Color.clear.frame(width: 900, height: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 520)
            host.layoutSubtreeIfNeeded()
            let placed = try XCTUnwrap(PanelRootLayout.lastPlacedSize)
            XCTAssertEqual(placed.width, width, accuracy: 0.001)
            XCTAssertEqual(placed.height, 520, accuracy: 0.001)
            XCTAssertEqual(host.frame.size, CGSize(width: width, height: 520), "the content never resizes the host")
        }
    }

    /// The real panel, hidden: for every width and height the settings
    /// allow, and for every frame of a live resize between them, the
    /// window's visible frame, the hosting view, the page layout's size and
    /// the size SwiftUI lays the root out at are the same.
    func testPanelWindowAlwaysFitsItsContentForEveryPanelSize() throws {
        let suite = "NotesV2ChromeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let settings = AppSettings(defaults: defaults)
        let uiState = PanelUIState()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(panel.isVisible, "This regression must not display a test window")

        func assertFits(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            container.layoutSubtreeIfNeeded()
            container.hostingView.layoutSubtreeIfNeeded()
            let visible = panel.visibleContentFrame.size
            XCTAssertEqual(container.hostingView.frame.size.width, visible.width, accuracy: 0.01, label, file: file, line: line)
            XCTAssertEqual(container.hostingView.frame.size.height, visible.height, accuracy: 0.01, label, file: file, line: line)
            XCTAssertEqual(uiState.panelSize.width, visible.width, accuracy: 0.5, label, file: file, line: line)
            guard let placed = PanelRootLayout.lastPlacedSize else {
                return XCTFail("the root was never laid out: \(label)", file: file, line: line)
            }
            XCTAssertEqual(placed.width, visible.width, accuracy: 0.01, "SwiftUI's root, \(label)", file: file, line: line)
            XCTAssertEqual(placed.height, visible.height, accuracy: 0.01, "SwiftUI's root, \(label)", file: file, line: line)
        }

        // Every width setting, there and back (the slider is live).
        let sizes = PanelContentSize.allCases.map(\.rawValue)
        for width in sizes + sizes.reversed() {
            settings.panelContentSize = width
            assertFits("width setting \(width)")
        }
        // Every corner size at every width: the frame stays, the content follows.
        for corner in PanelCornerSize.allCases.map(\.rawValue) {
            settings.panelCornerSize = corner
            for width in sizes {
                settings.panelContentSize = width
                assertFits("corner \(corner), width \(width)")
            }
        }
        settings.panelCornerSize = PanelCornerSize.defaultValue
        // A live resize: every intermediate frame, wider and narrower.
        let start = panel.visibleContentFrame
        for step in stride(from: 0, through: 60, by: 7.5) {
            for delta in [step, -step] where start.width + delta >= PanelGeometry.minimumPanelSize.width {
                var frame = start
                frame.size.width += delta
                frame.size.height += delta / 2
                panel.setVisibleContentFrame(frame, display: false)
                assertFits("live resize to \(frame.size)")
            }
        }
        withExtendedLifetime(controller) {}
    }

    /// A39 F08, the owner's repro: a note with a table is open and Settings
    /// changes the panel's width (420 → 320 → 420). The note editor and every
    /// page that is built fill the panel's content rect at once, every time,
    /// and again after switching pages. Nothing keeps its old width or is cut
    /// by the window's edge. The real panel, hidden.
    func testNotesFollowsAWidthChangeAndPageSwitchesWithoutClipping() throws {
        let suite = "NotesV2ChromeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let settings = AppSettings(defaults: defaults)
        settings.panelContentSize = 420
        let uiState = PanelUIState()
        let drafts = NoteDraftController(noteStore: notes)
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: drafts, settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(panel.isVisible, "This regression must not display a test window")

        uiState.selectSection(.notes)
        controller.preparePagesForReveal()
        drafts.pages.start()
        XCTAssertTrue(drafts.pages.newNote())
        let session = try XCTUnwrap(drafts.pages.active)
        let table = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                      ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        _ = session.engine.insertTable(table, replacing: NSRange(location: session.engine.textStorage.length, length: 0),
                                       name: "Insert Table", entering: false)

        func spin() {
            for _ in 0..<4 {
                container.layoutSubtreeIfNeeded()
                container.hostingView.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        func editor() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.documentView is NoteEditorTextView { return scroll }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(container.hostingView)
        }
        func assertFills(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            spin()
            let visible = panel.visibleContentFrame.size
            guard let scroll = editor() else { return XCTFail("no note editor: \(label)", file: file, line: line) }
            let frame = scroll.convert(scroll.bounds, to: container.hostingView)
            XCTAssertEqual(frame.width, visible.width, accuracy: 0.5, "the note fills the panel's width, \(label)", file: file, line: line)
            XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "from the panel's edge, \(label)", file: file, line: line)
            let placed = PanelRootLayout.lastPlacedSize
            XCTAssertEqual(placed?.width ?? -1, visible.width, accuracy: 0.5, "the root, \(label)", file: file, line: line)
        }

        // The page restores its session on the next turns.
        let deadline = Date().addingTimeInterval(3)
        while editor() == nil, Date() < deadline { spin() }
        assertFills("at 420")
        for width in [320, 420, 360, 320, 380, 420] as [Double] {
            settings.panelContentSize = width
            assertFills("width \(width)")
        }
        // Switching pages after the change (Notes stays built behind Tasks).
        settings.panelContentSize = 320
        for section in [PanelSection.tasks, .notes, .tasks, .notes] {
            uiState.selectSection(section)
            if section == .notes {
                let wait = Date().addingTimeInterval(3)
                while editor() == nil, Date() < wait { spin() }
                assertFills("320, after switching to \(section)")
            } else {
                spin()
            }
        }
        settings.panelContentSize = 420
        uiState.selectSection(.tasks)
        settings.panelContentSize = 320
        uiState.selectSection(.notes)
        let wait = Date().addingTimeInterval(3)
        while editor() == nil, Date() < wait { spin() }
        assertFills("narrowed while Notes was behind another page")
        withExtendedLifetime(controller) {}
    }
}
