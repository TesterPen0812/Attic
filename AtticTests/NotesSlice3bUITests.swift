import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Attic

/// Slice 3b's files and images UI on the engine's command layer: the faces
/// drawn on objects, the menus, clicks on drawn actions, the drop boundary,
/// the ring, the status slot's wording, the damaged-recovery exit and the
/// Notes toast (control audit 16).
@MainActor
final class NotesSlice3bUITests: XCTestCase {
    private func staged(_ name: String = "plan.pdf", type: String = "com.adobe.pdf") -> StagedNoteAttachment {
        let data = Data("file bytes".utf8)
        return StagedNoteAttachment(id: UUID(), filename: name, contentTypeIdentifier: type,
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
    }

    private func pngStaged() throws -> StagedNoteAttachment {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        return StagedNoteAttachment(id: UUID(), filename: "photo.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(data.count), digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            data: data)
    }

    private struct Fixture {
        let engine: NoteEditorEngine
        let failed: UUID, missing: UUID, ready: UUID
    }

    /// A note with an import-failed file, a file whose original is missing
    /// and a ready file.
    private func fixture(readOnly: Bool = false) -> Fixture {
        let failed = NoteBlock.file(filename: "too-big.pdf", contentTypeIdentifier: "com.adobe.pdf",
            byteCount: 16 * 1024 * 1024, importFailure: "The file is larger than 15 MB.")
        let missing = NoteBlock.file(attachmentID: UUID(), filename: "lost.pdf",
            contentTypeIdentifier: "com.adobe.pdf", byteCount: 8)
        let item = staged()
        let ready = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), failed, missing, ready]),
            readOnly: readOnly, stagedAttachments: [item])
        return Fixture(engine: engine, failed: failed.id!, missing: missing.id!, ready: ready.id!)
    }

    private func object(_ id: UUID, in engine: NoteEditorEngine) throws -> NoteObjectAttachment {
        try XCTUnwrap(engine.objectPlacement(id)?.0)
    }

    private func hosted(_ engine: NoteEditorEngine) -> (NSWindow, NoteEditorTextView, NoteObjectControls) {
        let (scrollView, textView) = engine.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView.frame = window.contentView!.bounds
        window.contentView?.addSubview(scrollView)
        textView.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        textView.layoutSubtreeIfNeeded()
        let controls = NoteObjectControls(engine: engine, textView: textView)
        engine.refreshObjectFaces()
        return (window, textView, controls)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ condition: () -> Bool) {
        for _ in 0..<100 where !condition() { spin(0.02) }
    }

    // MARK: Faces: the three failures, each on its object

    func testEachFailureIsDrawnOnItsObjectWithItsActions() throws {
        let f = fixture()
        let failed = try XCTUnwrap(f.engine.objectFace(for: object(f.failed, in: f.engine)))
        XCTAssertEqual(failed.detail, "Import failed")
        XCTAssertEqual(failed.tone, .failure)
        XCTAssertEqual(failed.actions, ["Retry", "Remove"])
        let missing = try XCTUnwrap(f.engine.objectFace(for: object(f.missing, in: f.engine)))
        XCTAssertEqual(missing.detail, "Original missing")
        XCTAssertEqual(missing.actions, ["Locate…", "Remove"])
        let ready = try XCTUnwrap(f.engine.objectFace(for: object(f.ready, in: f.engine)))
        XCTAssertEqual(ready.name, "plan.pdf")
        XCTAssertEqual(ready.tone, .normal)
        XCTAssertTrue(ready.actions.isEmpty, "a ready file draws its size, no actions")
        XCTAssertEqual(ready.systemImage, "doc.richtext")
        f.engine.markPreviewUnavailable(f.ready)
        let preview = try XCTUnwrap(f.engine.objectFace(for: object(f.ready, in: f.engine)))
        XCTAssertEqual(preview.detail, "Preview unavailable")
        XCTAssertEqual(preview.tone, .quiet, "the bytes are safe: said quietly")
        XCTAssertEqual(preview.actions, ["Quick Look", "Export Copy…", "Remove"])
    }

    func testAReadOnlyNoteDrawsOnlyActionsThatCanRun() throws {
        let f = fixture(readOnly: true)
        XCTAssertEqual(f.engine.objectFace(for: try object(f.failed, in: f.engine))?.actions, [])
        XCTAssertEqual(f.engine.objectFace(for: try object(f.missing, in: f.engine))?.actions, [])
    }

    func testTheRenderedCardIsTheColumnsWidthAndCarriesItsState() throws {
        let f = fixture()
        let (_, _, controls) = hosted(f.engine)
        defer { controls.invalidate() }
        let failed = try object(f.failed, in: f.engine)
        let image = try XCTUnwrap(failed.renderedImage)
        XCTAssertEqual(image.size.width, min(300, f.engine.objectColumnWidth), accuracy: 0.5,
                       "the card is drawn at its bounds' width, never stretched")
        XCTAssertEqual(image.size.height, NoteFileAttachment.cardHeight)
    }

    // MARK: Layout: a drawn action is hit where it is drawn

    func testDrawnActionsAreHitWhereDrawnAndOnlyThoseThatFitAreDrawn() {
        let face = AtticNoteObjectFace(kind: .file, name: "too-big.pdf", detail: "Import failed", tone: .failure,
                                       systemImage: "exclamationmark.circle", actions: ["Retry", "Remove"])
        let size = CGSize(width: 264, height: NoteFileAttachment.cardHeight)
        let placement = AtticNoteObjectLayout.placement(of: face, in: size)
        XCTAssertEqual(placement.chips.count, 2)
        for (index, chip) in placement.chips.enumerated() {
            XCTAssertLessThanOrEqual(chip.maxX, size.width - AtticNoteObjectMetrics.cardPadding)
            XCTAssertEqual(AtticNoteObjectLayout.action(at: CGPoint(x: chip.midX, y: chip.midY), face: face, size: size), index)
        }
        XCTAssertNil(AtticNoteObjectLayout.action(at: CGPoint(x: 20, y: 18), face: face, size: size), "the name is not an action")
        XCTAssertLessThan(placement.message.maxX, placement.chips[0].minX, "the message comes first")
        let narrow = AtticNoteObjectLayout.placement(of: face, in: CGSize(width: 140, height: size.height))
        XCTAssertLessThan(narrow.chips.count, 2, "what does not fit is left to the menu, never overlapped")
        let wide = AtticNoteObjectFace(kind: .image, name: "photo.png", detail: "Preview unavailable", tone: .quiet,
                                       systemImage: "eye.slash", actions: ["Quick Look", "Export Copy…", "Remove"])
        let stacked = AtticNoteObjectLayout.placement(of: wide, in: CGSize(width: 264, height: 132))
        XCTAssertNotNil(stacked.glyph, "a tall space stacks glyph, message and actions")
        XCTAssertEqual(stacked.chips.count, 3)
        XCTAssertGreaterThan(stacked.chips[0].minY, stacked.message.maxY)
    }

    // MARK: Menus from the command layer

    func testObjectMenusListThePlansCommandsFromTheCommandLayer() throws {
        let f = fixture()
        var ran: [NoteObjectCommand] = []
        func titles(_ id: UUID) -> [String] {
            NoteObjectMenu.commands(for: id, engine: f.engine, run: { ran.append($0) }, chooseApplication: {}).map(\.title)
        }
        XCTAssertEqual(titles(f.ready), ["Quick Look", "Open With", "Copy File", "Export Copy…", "Show in Finder", "Open", "Delete File"])
        XCTAssertEqual(titles(f.failed), ["The file is larger than 15 MB.", "Retry", "Remove"], "the reason heads the menu")
        XCTAssertEqual(titles(f.missing), ["Locate…", "Remove"])
        f.engine.markPreviewUnavailable(f.ready)
        XCTAssertEqual(titles(f.ready), ["Quick Look", "Export Copy…", "Retry Preview", "Remove"])
        let menu = NoteObjectMenu.commands(for: f.failed, engine: f.engine, run: { ran.append($0) }, chooseApplication: {})
        XCTAssertTrue(menu[0].isHeader)
        menu.first { $0.title == "Retry" }?.action()
        menu.first { $0.title == "Remove" }?.action()
        XCTAssertEqual(ran, [.retry, .delete])
        XCTAssertTrue(menu.first { $0.title == "Remove" }?.isDestructive == true)
    }

    func testAnImagesMenuHasSizePresetsWithTheCurrentOneTicked() throws {
        let item = try pngStaged()
        let block = NoteBlock.image(attachmentID: item.id, widthFraction: 0.5, pixelWidth: 400, pixelHeight: 200)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), block]),
                                      stagedAttachments: [item])
        var ran: [NoteObjectCommand] = []
        let menu = NoteObjectMenu.commands(for: block.id!, engine: engine, run: { ran.append($0) }, chooseApplication: {})
        XCTAssertEqual(menu.map(\.title), ["Quick Look", "Open With", "Copy Image", "Export Copy…", "Show in Finder",
                                           "Size", "Delete Image"])
        let size = try XCTUnwrap(menu.first { $0.title == "Size" })
        XCTAssertEqual(size.children.map(\.title), ["Small", "Medium", "Full"])
        XCTAssertEqual(size.children.map(\.state), [.off, .on, .off])
        size.children[2].action()
        XCTAssertEqual(ran, [.sizePreset(.full)])
        XCTAssertEqual(menu.first { $0.title == "Quick Look" }?.shortcut?.key, .space)
    }

    func testTheNotesMenuOffersTheSelectedObjectsCommands() throws {
        let f = fixture()
        let (_, textView, controls) = hosted(f.engine)
        defer { controls.invalidate() }
        XCTAssertNil(NoteObjectMenu.selectedObjectSubmenu(engine: f.engine, run: { _, _ in }, chooseApplication: { _ in }))
        let range = try XCTUnwrap(f.engine.objectPlacement(f.ready)?.1)
        textView.setSelectedRange(range)
        let submenu = try XCTUnwrap(NoteObjectMenu.selectedObjectSubmenu(engine: f.engine, run: { _, _ in },
                                                                         chooseApplication: { _ in }))
        XCTAssertEqual(submenu.title, "File")
        XCTAssertTrue(submenu.children.contains { $0.title == "Quick Look" })
    }

    // MARK: Clicks and the ring

    func testAClickOnADrawnActionRunsItsCommand() throws {
        let f = fixture()
        let (window, textView, controls) = hosted(f.engine)
        defer { controls.invalidate() }
        var requests: [NoteObjectSourceRequest] = []
        controls.requestSource = { requests.append($0) }
        func click(_ title: String, on id: UUID) throws {
            let (object, range) = try XCTUnwrap(f.engine.objectPlacement(id))
            let rect = try XCTUnwrap(f.engine.rect(for: range))
            let face = try XCTUnwrap(f.engine.objectFace(for: object))
            let index = try XCTUnwrap(face.actions.firstIndex(of: title))
            let chip = AtticNoteObjectLayout.placement(of: face, in: rect.size).chips[index]
            let point = NSPoint(x: rect.minX + chip.midX, y: rect.minY + chip.midY)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: textView.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            XCTAssertTrue(controls.handleMouseDown(event), "\(title) was hit")
        }
        try click("Retry", on: f.failed)
        waitFor { !requests.isEmpty }
        XCTAssertEqual(requests, [.retry(f.failed)], "Retry opens the page's source picker for that object")
        try click("Locate…", on: f.missing)
        waitFor { requests.count == 2 }
        XCTAssertEqual(requests.last, .locate(f.missing))
        try click("Remove", on: f.failed)
        waitFor { f.engine.objectPlacement(f.failed) == nil }
        XCTAssertNil(f.engine.objectPlacement(f.failed), "Remove deleted the failed file through the command layer")
        f.engine.history.undo()
        XCTAssertNotNil(f.engine.objectPlacement(f.failed), "and Undo brings it back")
    }

    func testAClickSelectsAnObjectAndTheRingFollowsWithoutRebuildingTheEditor() throws {
        let item = try pngStaged()
        let block = NoteBlock.image(attachmentID: item.id, widthFraction: 0.5, pixelWidth: 400, pixelHeight: 200)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), block, .text("after")]),
                                      stagedAttachments: [item])
        let (window, textView, controls) = hosted(engine)
        defer { controls.invalidate() }
        let range = try XCTUnwrap(engine.objectPlacement(block.id!)?.1)
        let rect = try XCTUnwrap(engine.rect(for: range))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let before = textView
        XCTAssertTrue(controls.handleMouseDown(event))
        XCTAssertEqual(textView.selectedRange(), range, "a click selects the image")
        XCTAssertTrue(controls.isRingShown)
        XCTAssertTrue(controls.isResizeCornerShown, "an editable image shows its resize corner")
        XCTAssertTrue(controls.ringFrame.contains(rect), "the ring surrounds the image")
        XCTAssertTrue(engine.textView === before, "the editor is never rebuilt for a selection")
        let updates = controls.ringUpdateCount
        textView.setSelectedRange(NSRange(location: engine.textStorage.length, length: 0))
        spin(0.4)
        XCTAssertFalse(controls.isRingShown, "the ring leaves with the selection")
        textView.insertText("typed", replacementRange: textView.selectedRange())
        XCTAssertEqual(controls.ringUpdateCount, updates, "typing with no object selected never touches the ring")
    }

    // MARK: Drop: a line between lines, never in an object or the title

    func testTheDropBoundaryIsAParagraphBoundaryBelowTheTitle() throws {
        let item = staged()
        let file = NoteBlock.file(attachmentID: item.id, filename: item.filename,
            contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount)
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .text("first"), file,
                                                                                   .text("second")]),
                                      stagedAttachments: [item])
        let (_, textView, controls) = hosted(engine)
        defer { controls.invalidate() }
        let string = engine.textStorage.string as NSString
        let titleEnd = NSMaxRange(engine.paragraphRange(at: 0))
        let titleRect = try XCTUnwrap(engine.rect(for: NSRange(location: 0, length: 5)))
        XCTAssertEqual(NoteObjectControls.dropBoundary(at: NSPoint(x: 10, y: titleRect.minY + 1), engine: engine,
                                                       textView: textView), titleEnd, "never in or above the title")
        let fileRange = try XCTUnwrap(engine.objectPlacement(file.id!)?.1)
        let fileRect = try XCTUnwrap(engine.rect(for: fileRange))
        let upper = NoteObjectControls.dropBoundary(at: NSPoint(x: 10, y: fileRect.minY + 2), engine: engine, textView: textView)
        let lower = NoteObjectControls.dropBoundary(at: NSPoint(x: 10, y: fileRect.maxY - 2), engine: engine, textView: textView)
        XCTAssertEqual(upper, fileRange.location, "the upper half of an object: before it")
        XCTAssertEqual(lower, NSMaxRange(engine.paragraphRange(at: fileRange.location)), "the lower half: after it")
        for boundary in [upper, lower, titleEnd] {
            XCTAssertTrue(boundary == 0 || boundary == string.length || string.character(at: boundary - 1) == 0x0A,
                          "\(boundary) is between lines")
        }
    }

    // MARK: Status slot

    func testImportProgressReadsAsTheFileBeingAddedAndItsDetails() {
        let progress = NoteImportProgress(batchID: UUID(), noteID: UUID(), completed: 1, total: 5, copiedBytes: 2_000_000,
                                          names: ["a.pdf", "b.png", "c.key", "d.txt", "e.zip"])
        XCTAssertEqual(NoteStatusPresentation.importLabel(progress), "Adding 2 of 5")
        XCTAssertEqual(NoteStatusPresentation.importLabel(nil), "Adding a file")
        let done = NoteImportProgress(batchID: UUID(), noteID: UUID(), completed: 5, total: 5, copiedBytes: 0, names: [])
        XCTAssertEqual(NoteStatusPresentation.importLabel(done), "Adding 5 of 5")
        let details = NoteStatusPresentation.importExplanation(progress)
        XCTAssertTrue(details.contains("a.pdf, b.png and 3 more"))
        XCTAssertTrue(details.contains("1 of 5 ready"))
    }

    func testPendingGuidanceIsProgressAndTryAgainIsKeptForUnfinishedActions() {
        XCTAssertTrue(NoteStatusPresentation.isProgress("Recovery data is still being saved."))
        XCTAssertTrue(NoteStatusPresentation.isProgress("Saving recovery data…"))
        XCTAssertTrue(NoteStatusPresentation.isProgress("Attachment data is still being read."))
        XCTAssertFalse(NoteStatusPresentation.isProgress("Recovery data is still being saved. Try again when saving finishes."))
        XCTAssertEqual(NoteStatusPresentation.notice("Recovery data is damaged: A.json. Other.", removingDamaged: ["A.json"]),
                       "Other.")
        XCTAssertNil(NoteStatusPresentation.notice("Recovery data is damaged: A.json.", removingDamaged: ["A.json"]))
    }

    // MARK: Damaged recovery exit

    func testDiscardingDamagedRecoveryNeedsExplicitConfirmationAndPassesItsToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S3BUI-\(UUID())"), id = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let checkpoint = root.appendingPathComponent("\(id.uuidString).json")
        try Data("{damaged".utf8).write(to: checkpoint)
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let controller = NotesPageController(store: store, journal: NoteDraftJournal(directory: root))
        var sent: [String] = []
        let exit = NoteDamagedRecoveryExit(perform: { command in
            switch command {
            case .listDamagedRecovery: sent.append("list")
            case .damagedRecoveryDetails: sent.append("details")
            case .saveDamagedRecoveryCopy: sent.append("save")
            case .discardDamagedRecovery: sent.append("discard")
            }
            return await controller.perform(command)
        })
        await exit.refresh()
        let details = try XCTUnwrap(exit.entries.first)
        XCTAssertEqual(details.title, "Recovery data is damaged")
        XCTAssertTrue(details.confirmation.canDiscard)

        var asked = 0
        exit.confirmDiscard = { _ in asked += 1; return false }
        let declined = await exit.discard(details)
        XCTAssertEqual(declined, .cancelled)
        XCTAssertEqual(asked, 1, "the discard always asks first")
        XCTAssertFalse(sent.contains("discard"), "a declined confirmation sends nothing")
        XCTAssertEqual(try Data(contentsOf: checkpoint), Data("{damaged".utf8), "and the data stays exactly as it was")

        exit.chooseFolder = { root.appendingPathComponent("copy") }
        let saved = await exit.saveCopy(details)
        guard case .saved = saved else { return XCTFail("Save Recovery Copy archives a copy: \(saved)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path), "a copy leaves the active data in place")

        var confirmed: NoteDamagedRecoveryDetails?
        exit.confirmDiscard = { confirmed = $0; return true }
        let discarded = await exit.discard(details)
        XCTAssertEqual(discarded, .discarded)
        XCTAssertEqual(confirmed?.confirmation, details.confirmation, "the details' token is the one sent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path), "moved to quarantine")
        XCTAssertTrue(exit.entries.isEmpty, "the exit is gone once resolved")
    }

    // MARK: Print

    func testFilePrintInTheMenuBarGoesToTheNoteAndReplacesTheViewPrint() {
        let main = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Print…", action: #selector(NSView.printView(_:)), keyEquivalent: "p"))
        fileItem.submenu = file
        main.addItem(fileItem)
        NoteFormatMenuBar.installPrint(in: main)
        NoteFormatMenuBar.installPrint(in: main)
        XCTAssertEqual(file.items.count, 1, "the system's view print is replaced, once")
        XCTAssertEqual(file.items.first?.action, #selector(NoteEditorTextView.printNote(_:)))
        XCTAssertEqual(file.items.first?.keyEquivalent, "p")
        XCTAssertEqual(file.items.first?.keyEquivalentModifierMask, .command)
    }

    // MARK: Off-screen renders for the owner's first look

    /// Writes the new faces, Light and Dark, to the temporary directory's
    /// `s3b-shots` (read by the report's capture step). Nothing on screen.
    func testRenderTheObjectFacesOffScreen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("s3b-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let faces: [(String, AtticNoteObjectFace)] = [
            ("file-ready", .init(kind: .file, name: "pricing-v2.pdf", detail: "1.2 MB", systemImage: "doc.richtext")),
            ("file-import-failed", .init(kind: .file, name: "too-big.mov", detail: "Import failed", tone: .failure,
                                         systemImage: "exclamationmark.circle", actions: ["Retry", "Remove"])),
            ("file-original-missing", .init(kind: .file, name: "plan.key", detail: "Original missing", tone: .failure,
                                            systemImage: "exclamationmark.circle", actions: ["Locate…", "Remove"])),
            ("file-preview-unavailable", .init(kind: .file, name: "scan.heic", detail: "Preview unavailable", tone: .quiet,
                                               systemImage: "eye.slash", actions: ["Quick Look", "Export Copy…", "Remove"]))
        ]
        for mode in [AtticDesignContext.Mode.light, .dark] {
            var design = AtticDesignContext.default
            design.mode = mode
            let suffix = mode == .light ? "light" : "dark"
            func write<V: View>(_ view: V, _ name: String) throws {
                let renderer = ImageRenderer(content: view.padding(12).background(design.tokens.panel.base.color).atticDesign(design))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                let data = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?
                    .representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("\(name)-\(suffix).png"))
            }
            for (name, face) in faces { try write(AtticNoteFileCard(face: face, width: 264), name) }
            let failed = AtticNoteObjectFace(kind: .image, name: "photo.png", detail: "Preview unavailable", tone: .quiet,
                                             systemImage: "eye.slash", actions: ["Quick Look", "Export Copy…", "Remove"])
            try write(AtticNoteImageFailure(face: failed, size: CGSize(width: 264, height: 132)), "image-preview-unavailable")
            let missing = AtticNoteObjectFace(kind: .image, name: "photo.png", detail: "Original missing", tone: .failure,
                                              systemImage: "exclamationmark.circle", actions: ["Locate…", "Remove"])
            try write(AtticNoteImageFailure(face: missing, size: CGSize(width: 264, height: 48)), "image-original-missing-short")
            try write(AtticNoteCarryCard(name: "pricing-v2.pdf", systemImage: "doc.richtext", more: 2), "carry-card")
        }
        print("S3B-SHOTS \(folder.path)")
    }

    // MARK: Toast parity (control audit 16)

    func testTheNotesToastWaitsForItsOutcomeAndOffersRetryOnlyWhileItCanHelp() async {
        let toasts = PanelToastCenter()
        var outcomes: [CommandOutcome] = [.failed(CommandFailure("The note could not be restored.")), .applied]
        var runs = 0
        toasts.show("Note deleted", answersUndoKey: false, performingAsync: {
            runs += 1
            return outcomes.removeFirst()
        })
        XCTAssertEqual(toasts.current?.answersUndoKey, false, "B2: the Notes toast never owns ⌘Z")
        let first = await toasts.performActionAsync()
        XCTAssertEqual(first, .failed(CommandFailure("The note could not be restored.")))
        XCTAssertEqual(toasts.current?.isFailure, true, "the failure stays, with its reason")
        XCTAssertEqual(toasts.current?.actionTitle, "Retry")
        XCTAssertEqual(toasts.current?.message, "The note could not be restored.")
        XCTAssertFalse(toasts.hasPendingDismissalForTesting, "a problem never expires on its own")
        let second = await toasts.performActionAsync()
        XCTAssertEqual(second, .applied)
        XCTAssertEqual(runs, 2, "Retry ran the same restore again")
        XCTAssertNil(toasts.current, "and the toast goes once it worked")

        toasts.show("Note deleted", answersUndoKey: false, performingAsync: {
            .failed(CommandFailure("This note can no longer be restored here.", canRetry: false))
        })
        _ = await toasts.performActionAsync()
        XCTAssertEqual(toasts.current?.actionTitle, "OK", "no Retry when retrying cannot help")
        let none = await toasts.performActionAsync()
        XCTAssertNil(none, "OK only dismisses")
    }

    func testFocusAndVoiceOverHoldTheNotesToast() {
        let toasts = PanelToastCenter()
        toasts.holdDuration = 0.05
        toasts.show("Note deleted", answersUndoKey: false, performingAsync: { .applied })
        toasts.hold(.keyboard, true)
        spin(0.2)
        XCTAssertNotNil(toasts.current, "keyboard focus holds it")
        toasts.hold(.keyboard, false)
        toasts.hold(.accessibility, true)
        spin(0.2)
        XCTAssertNotNil(toasts.current, "VoiceOver holds it")
        toasts.hold(.accessibility, false)
        waitFor { toasts.current == nil }
        XCTAssertNil(toasts.current, "it expires once nothing holds it")
    }

    func testAPressWhileTheUndoRunsDoesNothing() async {
        let toasts = PanelToastCenter()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        toasts.show("Note deleted", answersUndoKey: false, performingAsync: {
            runs += 1
            await withCheckedContinuation { release = $0 }
            return .applied
        })
        let first = Task { await toasts.performActionAsync() }
        while release == nil { await Task.yield() }
        XCTAssertTrue(toasts.isPerforming)
        let second = await toasts.performActionAsync()
        XCTAssertNil(second, "a second press waits for the first")
        release?.resume()
        _ = await first.value
        XCTAssertEqual(runs, 1)
        XCTAssertNil(toasts.current)
    }
}
