#if DEBUG
import AppKit
import CryptoKit

/// Disposable data only: the person still opens the menu, compares, copies,
/// restores and undoes through the shipping controls. Never a normal store.
@MainActor
enum NoteHistoryCaptureScene {
    private static var didRun = false
    static func seedIfRequested(_ controller: NotesPageController) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1",
              NotesEditorSetting.isPreviewIdentity(Bundle.main.bundleIdentifier),
              environment["ATTIC_UI_TEST_NOTES_SCENE"]?.hasPrefix("history") == true,
              !didRun else { return }
        didRun = true
        await controller.startAndWait()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<160 { for y in 0..<64 {
            bitmap.setColor(x < 80 ? NSColor(deviceRed: 0.15, green: 0.4, blue: 0.8, alpha: 1)
                : NSColor(deviceRed: 0.1, green: 0.65, blue: 0.65, alpha: 1), atX: x, y: y)
        } }
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { return }
        let imageID = UUID()
        let staged = StagedNoteAttachment(id: imageID, filename: "Earlier image.png", contentTypeIdentifier: "public.png",
            byteCount: Int64(bytes.count), digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), data: bytes)
        let earlier = NoteDocument(blocks: [.text("History field notes"), .text("An earlier paragraph worth recovering."),
            .image(attachmentID: imageID, pixelWidth: 160, pixelHeight: 64),
            .text("let recovered = true", style: "mono"),
            .table(NoteTable(texts: [["Plan", "Status"], ["Earlier", "Kept"]]))])
        let store = controller.store
        guard case let .success(created) = store.createDocumentNote(id: UUID(), document: earlier, staged: [staged]) else { return }
        let first = NoteVersion(noteID: created.noteID, createdAt: Date().addingTimeInterval(-7200), reason: .pause,
            content: try? NoteContentCodec.encode(earlier), contentFormat: 1, title: earlier.title, body: "",
            attachmentIDs: earlier.attachmentIDs, sourceRevisionID: created.revisionID)
        store.modelContext.insert(first)
        var intermediate = earlier
        intermediate.blocks[1].text = "A revised paragraph from yesterday."
        store.modelContext.insert(NoteVersion(noteID: created.noteID, createdAt: Date().addingTimeInterval(-86_400),
            reason: .beforeWritingTools, content: try? NoteContentCodec.encode(intermediate), contentFormat: 1,
            title: intermediate.title, body: "", attachmentIDs: intermediate.attachmentIDs, sourceRevisionID: UUID()))
        guard store.commitStagedChanges() else { return }
        let current = NoteDocument(blocks: [.text("History field notes"), .text("The current paragraph."),
            .text("Student pricing: this paragraph was added later."), .text("let recovered = false", style: "mono"),
            .table(NoteTable(texts: [["Plan", "Status"], ["Current", "New"]]))])
        guard case .success = store.saveDocument(noteID: created.noteID, document: current, baseRevisionID: created.revisionID) else { return }
        _ = await controller.openDurably(noteID: created.noteID)
        if environment["ATTIC_UI_TEST_NOTES_SCENE"] == "history-failure" { store.s7FailNextRestoreForUITesting = true }
    }
}
#endif
