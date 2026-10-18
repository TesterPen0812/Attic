import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Round F5b (Air verification V1): a task released over its own row
/// (V-13) and a subtask's growing editor (V-12).
@MainActor
final class RoundF5bTests: XCTestCase {
    private func words(_ count: Int) -> String {
        (0..<count).map { String(format: "word%02d", $0) }.joined(separator: " ")
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A subtask field being edited in a window, sized as the row sizes it.
    private func editingField(_ text: String, width: CGFloat = 260) throws -> (NSTextField, NSTextView) {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = FlippedView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = container
        let field = AtticSubtaskTitleField.makeField()
        field.stringValue = text
        field.frame = CGRect(x: 20, y: 40, width: width, height: height(text, width: width))
        container.addSubview(field)
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(field))
        return (field, try XCTUnwrap(field.currentEditor() as? NSTextView))
    }

    private func height(_ text: String, width: CGFloat = 260) -> CGFloat {
        AtticSubtaskTitleField.height(of: text, width: width, font: AtticTextStyle.rowTitle.nsFont)
    }

    /// The text lines the field shows, in the field's space: each line the
    /// editor's clip shows at all, cut to what it shows. Nothing above the
    /// field clips its subviews, as in the row.
    private func shownLines(_ field: NSTextField, _ editor: NSTextView) throws -> [(line: CGRect, shown: CGRect)] {
        let layout = try XCTUnwrap(editor.layoutManager)
        let clip = try XCTUnwrap(editor.superview)
        let window = clip.convert(clip.bounds, to: field)
        var lines: [(CGRect, CGRect)] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            let line = editor.convert(rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y), to: field)
            let shown = line.intersection(window)
            if !shown.isNull, shown.height > 0.01 { lines.append((line, shown)) }
        }
        return lines
    }

    private func caret(_ field: NSTextField, _ editor: NSTextView) throws -> CGRect {
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        let end = (editor.string as NSString).length
        let glyph = layout.glyphIndexForCharacter(at: max(0, end - 1))
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let clip = try XCTUnwrap(editor.superview)
        let caret = editor.convert(rect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y), to: field)
        return caret.intersection(clip.convert(clip.bounds, to: field))
    }

    /// V-12: past six lines, whole lines only, at the start and at the end,
    /// and the caret (with the last words) in view at the end.
    func testV12ASubtaskEditorShowsWholeLinesAndTheCaretPastSixLines() throws {
        let text = words(100)
        let (field, editor) = try editingField(text)
        let line = AtticLineSnap.lineHeight(of: AtticTextStyle.rowTitle.nsFont)
        let most = CGFloat(AtticComposerMetrics.maxLines)
        for (place, location) in [("end", (text as NSString).length), ("start", 0)] {
            editor.setSelectedRange(NSRange(location: location, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            let lines = try shownLines(field, editor)
            XCTAssertEqual(lines.count, Int(most), "\(place): six lines")
            let clip = try XCTUnwrap(editor.superview)
            XCTAssertEqual(clip.frame.height, most * line, accuracy: 0.01, "\(place): the clip is six whole lines")
            XCTAssertTrue(field.bounds.contains(clip.frame.insetBy(dx: 3, dy: 0)), "\(place): inside the field")
            for entry in lines {
                XCTAssertEqual(entry.shown.height, line, accuracy: 0.01, "\(place): whole lines, never part of one (\(entry.line))")
            }
            if place == "end" {
                let caret = try caret(field, editor)
                XCTAssertEqual(caret.height, line, accuracy: 1, "end: the last words are in view")
            }
        }
    }

    /// V-12: typed in word by word, the field grows to six lines and the
    /// last words and caret stay in view, in whole lines, all the way.
    func testV12TypingPastSixLinesKeepsTheCaretInWholeLines() throws {
        let (field, editor) = try editingField("")
        let line = AtticLineSnap.lineHeight(of: AtticTextStyle.rowTitle.nsFont)
        for count in 1...100 {
            editor.insertText((count == 1 ? "" : " ") + String(format: "word%02d", count - 1), replacementRange: editor.selectedRange())
            field.setFrameSize(NSSize(width: field.frame.width, height: height(editor.string)))
            if count % 7 == 0 || count == 100 {
                for entry in try shownLines(field, editor) {
                    XCTAssertEqual(entry.shown.height, line, accuracy: 0.01, "\(count) words: whole lines (\(entry.line))")
                }
                XCTAssertEqual(try caret(field, editor).height, line, accuracy: 1, "\(count) words: the caret's line in view")
            }
        }
    }

    /// V-12: one line being edited lies exactly where it is drawn at rest.
    func testV12OneLineLiesWhereItIsDrawnAtRest() throws {
        let (field, editor) = try editingField("Write release notes")
        let lines = try shownLines(field, editor)
        XCTAssertEqual(lines.count, 1)
        let rest = AtticSubtaskTitleCell.textRect(forBounds: field.bounds, font: field.font)
        XCTAssertEqual(lines.first?.line.minY ?? -1, rest.minY, accuracy: 0.01, "editing does not move the text")
    }

    // MARK: - V-13 · a task over its own row, and imports that always end

    /// The drag of a task out of the panel reads as tasks, never as files to
    /// attach, so released over a row (its own, or any) it is refused: it
    /// springs home and nothing is imported.
    func testV13ATaskDragOutIsNeverFilesToAttach() throws {
        let reference = TaskImageReference(id: UUID(), filename: "Launch brief.pdf", digest: "unused",
                                           contentTypeIdentifier: UTType.pdf.identifier, byteCount: 1)
        let export = TasksTextExport(items: [.init(title: "Finalize launch checklist", files: [reference, reference])])
        let attachments = TasksDragOut.attachmentItems(for: export, files: .shared, frame: CGRect(x: 0, y: 0, width: 340, height: 74))
        let writers: [NSPasteboardWriting] = [export.dragWriter()] + attachments.compactMap { $0.item as? NSPasteboardWriting }
        let pasteboard = NSPasteboard(name: .init("AtticF5b-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(writers))
        let types = (pasteboard.pasteboardItems ?? []).flatMap(\.types).compactMap { UTType($0.rawValue) }
        let content = TaskDropContent.classify { wanted in types.contains { type in wanted.contains { type.conforms(to: $0) } } }
        XCTAssertEqual(content, .task, "a task, with its files, is not a file drop")
        XCTAssertFalse(TasksFileDropDelegate.takes(content), "no row (and not the add bar) takes it")
        XCTAssertEqual(TasksDragOut.operations(for: .withinApplication), [], "within Attic it offers nothing: a cancel")
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: .init(TaskDragPayload.internalTaskType.identifier)), Data(),
                       "the mark carries nothing of the task")
    }

    private func makeStore() throws -> (TaskStore, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AtticF5b-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container, taskImageFiles: TaskImageFiles(rootURL: root.appendingPathComponent("storage")))
        let task = try XCTUnwrap(store.create(title: "Finalize launch checklist"))
        return (store, task.id)
    }

    /// A provider that accepts a load and never answers (a promise whose
    /// drag was refused).
    private func silentProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { _ in
            Progress(totalUnitCount: 1)
        }
        return provider
    }

    private func file(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AtticF5b-\(UUID().uuidString)-\(name)")
        try Data("%PDF-1.4 fake".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Every import ends, and its busy state ("Attaching…") with it: on
    /// success, on failure, on an empty drop, when cancelled, and when a
    /// dropped item never arrives.
    func testV13AnImportAlwaysClearsItsBusyState() async throws {
        let (store, id) = try makeStore()
        let limit = TaskProviderLoadLimit.seconds
        TaskProviderLoadLimit.seconds = 0.3
        defer { TaskProviderLoadLimit.seconds = limit }

        let pdf = try file("Brief.pdf")
        let added = await store.attachStagedFiles(to: id) { try await TaskDroppedFiles.stage([NSItemProvider(object: pdf as NSURL)]) }
        XCTAssertEqual(added?.count, 1, "success")
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty, "success clears it")

        let failed = await store.attachStagedFiles(to: id) { throw CocoaError(.fileReadCorruptFile) }
        XCTAssertNil(failed)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty, "failure clears it")

        let empty = await store.attachStagedFiles(to: id) { try await TaskDroppedFiles.stage([]) }
        XCTAssertNil(empty)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty, "an empty drop clears it")

        let stalled = await store.attachStagedFiles(to: id) { try await TaskDroppedFiles.stage([self.silentProvider()]) }
        XCTAssertNil(stalled)
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty, "an item that never arrives clears it")
        XCTAssertEqual(store.lastErrorMessage, "Couldn’t attach files. A dropped item never arrived.")

        TaskProviderLoadLimit.seconds = 30
        let reported = store.lastErrorMessage
        let provider = silentProvider()
        let importing = Task { await store.attachStagedFiles(to: id) { try await TaskDroppedFiles.stage([provider]) } }
        let start = Date()
        while store.importingAttachmentTaskIDs.isEmpty, Date().timeIntervalSince(start) < 2 { await Task.yield() }
        XCTAssertFalse(store.importingAttachmentTaskIDs.isEmpty, "busy while it waits")
        importing.cancel()
        let cancelled = await importing.value
        XCTAssertNil(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "cancelling ends it at once, not at the limit")
        XCTAssertTrue(store.importingAttachmentTaskIDs.isEmpty, "cancellation clears it")
        XCTAssertEqual(store.lastErrorMessage, reported, "and is not reported as a failure")
        XCTAssertEqual(store.task(withID: id)?.attachments.count, 1, "nothing but the first file was attached")
    }

    // MARK: - V-09 · one card · K-04 · the file comes home from where it was let go

    /// V-09: a lifted card's drag shows no picture of the system's own (it
    /// shrank, gathered and moved it over destinations, beside the card
    /// resting at the pointer): the card is its one picture.
    func testV09TheSystemDrawsNoSecondCard() throws {
        let images = try XCTUnwrap(TasksDragOut.Card.Images(card: Color.gray.frame(height: 34), width: 300,
                                                            environment: EnvironmentValues(), scale: 2))
        let frame = CGRect(x: 12, y: 30, width: images.shadowed.size.width, height: images.shadowed.size.height)
        let card = TasksDragOut.Card(images: images, frame: frame, home: { nil }, reduceMotion: false, handOff: {})
        let export = TasksTextExport(items: [.init(title: "Finalize launch checklist", files: [])])
        let item = TasksDragOut.leadingItem(for: export, count: 1, at: CGPoint(x: 40, y: 50), card: card)
        XCTAssertEqual(item.draggingFrame, frame, "the drag still lies where the card does")
        let contents = try XCTUnwrap(item.imageComponents?.first?.contents as? NSImage)
        XCTAssertEqual(contents.size, images.shadowed.size)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(contents.tiffRepresentation)))
        var drawn = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { drawn += 1 }
        }
        XCTAssertEqual(drawn, 0, "the system's image is clear")
        // Without a card (a plain label), the system's picture is the drag's.
        let label = TasksDragOut.leadingItem(for: export, count: 1, at: CGPoint(x: 40, y: 50), card: nil)
        XCTAssertNotNil(label.imageComponents?.first?.contents)
    }

    /// K-04: a file row's picture lies at its component's offset from the
    /// row, read from the row's own frame (SwiftUI's global space), not the
    /// session's report (which put it at the screen's far left). Measured
    /// on the Air: the row at (84, 174, 336, 28) in a 696 pt window, its
    /// picture 156 × 38 at (90, −5) drew at (174, 489) in the window.
    func testK04AFilesPictureLiesOverItsRow() {
        let frame = AtticDragReturn.pictureFrame(dragged: CGRect(x: 84, y: 174, width: 336, height: 28),
                                                 component: CGRect(x: 90, y: -5, width: 156, height: 38), contentHeight: 696)
        XCTAssertEqual(frame, CGRect(x: 174, y: 489, width: 156, height: 38))
    }

    /// K-04: the file's picture comes home from exactly where it was let
    /// go, with springs only (no travel from the window's corner), and it
    /// never leaves the screen for a frame on the way.
    func testK04TheFileSpringsHomeFromTheReleasePointWithNoGap() throws {
        let image = NSImage(size: CGSize(width: 156, height: 38))
        let home = CGRect(x: -6_000, y: -6_000, width: 156, height: 38)
        let returning = AtticDragReturn(shadowed: nil, plain: image, home: { home }, level: .floating, reduceMotion: false)
        defer { returning.windowForTesting.orderOut(nil) }
        let release = CGRect(x: -5_850, y: -5_960, width: 156, height: 38)
        returning.moved(drawn: release)
        XCTAssertTrue(returning.isShown, "shown under the pointer before the release")
        returning.ended(operation: [], drawn: release, done: {})
        XCTAssertTrue(returning.isShown, "still shown as it starts home: no gap")
        XCTAssertEqual(returning.startOnScreen, release, "from the release point")
        let layer = try XCTUnwrap(returning.windowForTesting.contentView?.layer?.sublayers?.last)
        XCTAssertEqual(Set(layer.animationKeys() ?? []), ["position.x", "position.y", "bounds.size"], "springs only")
        let origin = returning.windowForTesting.frame.origin
        XCTAssertEqual((layer.animation(forKey: "position.x") as? CASpringAnimation)?.fromValue as? CGFloat, release.minX - origin.x)
    }
}
