import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class DataSizeCostTests: XCTestCase {
    func milliseconds(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    #if ATTIC_GENERATED_TESTS
    func testP07DragWork() throws {
        for count in [500, 6000] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let context = ModelContext(container)
            for i in 0..<count { context.insert(TaskItem(title: "Row \(i)")) }
            try context.save()
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let page = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 344, height: 520)), addBarFocused: .constant(false))
            let group = model.rows(for: .now).map(\.id)
            XCTAssertEqual(group.count, count)
            TasksPage.dragHeightLookupVisits = 0
            var geometry: TasksDragGeometry?
            let setupMS = milliseconds { geometry = page.prepareDragGeometry(group: group, tab: .now) }
            TasksDragGeometry.comparisonCount = 0
            let ms = milliseconds {
                _ = TasksReorderCell<EmptyView, EmptyView>.target(start: 0, translation: 120, group: group, heights: { page.rowHeight($0, in: .now) }, geometry: geometry)
                _ = TasksReorderCell<EmptyView, EmptyView>.pushesPastGroup(start: 0, translation: 120, group: group, heights: { page.rowHeight($0, in: .now) }, geometry: geometry)
            }
            print("P2_DRAG size=\(count) lookup_visits=\(TasksPage.dragHeightLookupVisits) comparisons=\(TasksDragGeometry.comparisonCount) setup_ms=\(setupMS) update_ms=\(ms)")
            XCTAssertEqual(TasksPage.dragHeightLookupVisits, 0)
            XCTAssertEqual(TasksDragGeometry.comparisonCount, count == 500 ? 9 : 13)
        }
    }
    #endif
    #if !ATTIC_GENERATED_TESTS
    func testP07ScrollViewCache() throws {
        for count in [500, 6000] {
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 500))
            let scroll = NSScrollView(frame: page.bounds)
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 20000))
            for _ in 0..<count { document.addSubview(NSView(frame: .zero)) }
            scroll.documentView = document; page.addSubview(scroll)
            let window = NSWindow(contentRect: page.bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = page
            defer { window.close() }
            let session = TasksDragSession()
            let beforeMS = milliseconds {
                for _ in 0..<30 { session.cachedScrollView = nil; XCTAssertTrue(session.scrollView(at: CGPoint(x: 100, y: 100), in: page) === scroll) }
            }
            let visits = session.scrollViewVisitCount
            let afterMS = milliseconds {
                for _ in 0..<30 { XCTAssertTrue(session.scrollView(at: CGPoint(x: 100, y: 100), in: page) === scroll) }
            }
            print("P2_SCROLL size=\(count) uncached_visits=\(visits) cached_visits=\(session.scrollViewVisitCount - visits) uncached_ms=\(beforeMS) cached_ms=\(afterMS)")
            XCTAssertEqual(session.scrollViewVisitCount, visits)
            scroll.isHidden = true
            XCTAssertNil(session.scrollView(at: CGPoint(x: 100, y: 100), in: page))
            session.end(); XCTAssertNil(session.cachedScrollView)
        }
    }

    func testP07PrefixGeometryAgreesWithWalkingThresholds() {
        let group = (0..<17).map { _ in UUID() }
        let heights = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($0.element, CGFloat(34 + ($0.offset % 4) * 17)) })
        let geometry = TasksDragGeometry(group: group) { heights[$0]! }
        for start in group.indices {
            for translation in stride(from: CGFloat(-1500), through: 1500, by: 0.5) {
                let expected = TasksReorderCell<EmptyView, EmptyView>.target(start: start, translation: translation, group: group, heights: { heights[$0]! })
                XCTAssertEqual(geometry.target(start: start, translation: translation), expected)
                XCTAssertEqual(geometry.pushesPastGroup(start: start, translation: translation), TasksReorderCell<EmptyView, EmptyView>.pushesPastGroup(start: start, translation: translation, group: group, heights: { heights[$0]! }))
                var drag = TasksDrag(id: group[start], tab: .now, group: group, startIndex: start, targetIndex: expected)
                let landing = TasksLiftedCard.landing(of: drag, originY: 23, heights: { heights[$0]! })
                drag.geometry = geometry
                XCTAssertEqual(TasksLiftedCard.landing(of: drag, originY: 23, heights: { heights[$0]! }), landing)
            }
        }
    }
    #endif

    #if ATTIC_GENERATED_TESTS
    func testP09DonePagesAndReveal() throws {
        for count in [500, 5000] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let context = ModelContext(container)
            var lastID = UUID()
            for i in 0..<count {
                let task = TaskItem(title: "Finished \(i)")
                task.statusRaw = TaskStatus.done.rawValue
                task.completedAt = Date(timeIntervalSince1970: Double(count - i))
                task.doneLoggedAt = task.completedAt
                context.insert(task)
                let child = TaskItem(title: "Child \(i)"); child.parentID = task.id
                child.doneLoggedAt = task.completedAt; child.statusRaw = TaskStatus.done.rawValue
                context.insert(child)
                lastID = task.id
            }
            try context.save()
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            let reads = store.doneFamilyParentReadCount, pages = store.donePageReadCount
            let ms = milliseconds {
                model.loadDoneLogIfNeeded()
                while model.doneLogTasks.count < count, model.doneLogFailure == nil { model.loadMoreDoneLog() }
            }
            XCTAssertEqual(model.doneLogTasks.count, count)
            print("P2_DONE size=\(count) parents=\(store.doneFamilyParentReadCount - reads) pages=\(store.donePageReadCount - pages) ms=\(ms)")
            let reveal = TasksPageModel(library: AtticLibrary(tasks: store))
            let r = store.doneFamilyParentReadCount, p = store.donePageReadCount
            let revealMS = milliseconds { XCTAssertEqual(reveal.show(lastID), .shown) }
            print("P2_REVEAL size=\(count) parents=\(store.doneFamilyParentReadCount - r) pages=\(store.donePageReadCount - p) ms=\(revealMS)")
            XCTAssertTrue(reveal.selection.contains(lastID))
            XCTAssertEqual(store.doneFamilyParentReadCount - reads - (store.doneFamilyParentReadCount - r), count)
            XCTAssertEqual(store.doneFamilyParentReadCount - r, count)
            XCTAssertEqual(store.donePageReadCount - p, 2)
        }
    }
    #endif

    #if !ATTIC_GENERATED_TESTS
    func testP02WarmCodeRanges() {
        for count in [1000, 5000] {
            let blocks = [NoteBlock.text("Title")] + (0..<count).map { .text("let value\($0) = \($0)", style: "mono") }
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: blocks))
            let (_, view) = engine.makeView()
            var offsets: [Int] = []; var at = 6
            for i in 0..<count { offsets.append(at); at += "let value\(i) = \(i)\n".utf16.count }
            _ = engine.blockRange(at: offsets[count / 2])
            let before = engine.blockRangeParagraphVisits
            let ms = milliseconds { for offset in offsets[(count / 2)..<(count / 2 + 30)] { _ = engine.blockRange(at: offset) } }
            print("P2_CODE size=\(count) warm_visits=\(engine.blockRangeParagraphVisits - before) warm_ms=\(ms)")
            XCTAssertEqual(engine.blockRangeParagraphVisits - before, 0)
            view.setSelectedRange(NSRange(location: offsets[count / 2] + 4, length: 0))
            let editingVisits = engine.blockRangeParagraphVisits
            let editMS = milliseconds { view.insertText("x", replacementRange: view.selectedRange()) }
            let edited = engine.blockRangeParagraphVisits
            let nextMS = milliseconds { for offset in offsets[(count / 2)..<(count / 2 + 30)] { _ = engine.blockRange(at: offset + 1) } }
            print("P2_CODE_EDIT size=\(count) edit_visits=\(edited - editingVisits) next_frame_visits=\(engine.blockRangeParagraphVisits - edited) edit_ms=\(editMS) next_frame_ms=\(nextMS)")
            XCTAssertEqual(engine.blockRangeParagraphVisits - editingVisits, count - 1)
            engine.detachView()
        }
    }

    func testP02RunCacheTracksStyleSplitAndReplay() {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("T"), .text("first", style: "mono"), .text("middle", style: "mono"), .text("last", style: "mono"), .text("body")]))
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        func verify() {
            let at = (view.string as NSString).range(of: "middle").location
            let cached = engine.blockRange(at: at)
            engine.blockRunIntervals = []
            XCTAssertEqual(cached, engine.blockRange(at: at))
        }
        verify()
        let middle = (view.string as NSString).range(of: "middle")
        XCTAssertTrue(engine.perform(.paragraph(.body), selection: middle)); verify()
        XCTAssertTrue(engine.history.undo()); verify()
        XCTAssertTrue(engine.history.redo()); verify()
        XCTAssertTrue(engine.perform(.paragraph(.mono), selection: middle)); verify()
        view.setSelectedRange(NSRange(location: middle.location + 2, length: 0))
        view.insertText("\n", replacementRange: view.selectedRange())
        let at = (view.string as NSString).range(of: "first").location
        let cached = engine.blockRange(at: at)
        engine.blockRunIntervals = []
        XCTAssertEqual(cached, engine.blockRange(at: at))
    }

    func testP12FixedWidthTableEdit() throws {
        for rows in [100, 500] {
            var table = NoteTable(texts: (0..<rows).map { i in (0..<20).map { "Cell \(i) \($0)" } })
            for column in table.columns.indices { table.columns[column].width = 100 }
            let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Title"), .table(table)]))
            let attachment = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
            _ = attachment.layout(width: 340)
            let visits = NoteTableLayout.heightVisitCount
            let ms = milliseconds {
                XCTAssertTrue(engine.changeTable(attachment, name: "Typing", coalescing: .init(row: rows / 2, column: 3)) { $0[.init(row: rows / 2, column: 3)].text += " new wrapped words" })
                _ = attachment.layout(width: 340)
            }
            let editVisits = NoteTableLayout.heightVisitCount - visits
            XCTAssertEqual(editVisits, 1)
            let incremental = attachment.layout(width: 340)
            attachment.invalidateLayout()
            XCTAssertEqual(incremental, attachment.layout(width: 340))
            print("P2_TABLE rows=\(rows) columns=20 height_visits=\(editVisits) ms=\(ms)")
        }
    }
    #endif

    #if ATTIC_GENERATED_TESTS
    func testP10LibraryRemount() throws {
        for count in [30, 300] {
            let container = try PersistenceController.makeContainer(inMemory: true)
            let context = ModelContext(container)
            let document = NoteDocument(blocks: [.text("Title")] + (0..<1000).map { .text("Long line \($0) with enough text for a preview", style: $0 % 10 == 0 ? "checklist" : "body") })
            let bytes = try NoteContentCodec.encode(document)
            for i in 0..<count {
                let note = NoteItem(title: "Note \(i)"); note.content = bytes; note.plainText = NoteTextExport.plainText(document)
                note.revisionID = UUID(); context.insert(note)
            }
            try context.save()
            let store = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
            let controller = NotesPageController(store: store, journal: nil)
            let first = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
            var groups: [NotesLibraryModel.Group] = []
            let groupingMS = milliseconds { groups = first.groups(store: store, drafts: [], prepareSummaries: false) }
            XCTAssertEqual(first.bodyDecodeCount, 0)
            let demanded = Array(groups.flatMap(\.rows).prefix(12))
            var prepared: [AtticNoteRowModel] = []
            let demandMS = milliseconds { prepared = demanded.map { first.preparedRow($0, store: store) } }
            XCTAssertEqual(first.bodyDecodeCount, demanded.count)
            let second = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
            let remountGroups = second.groups(store: store, drafts: [], prepareSummaries: false)
            XCTAssertEqual(Array(remountGroups.flatMap(\.rows).prefix(12)).map { second.preparedRow($0, store: store) }, prepared)
            XCTAssertEqual(second.bodyDecodeCount, 0)
            print("P2_LIBRARY_DEMAND size=\(count) grouping_decodes=0 demand_decodes=\(first.bodyDecodeCount) remount_decodes=\(second.bodyDecodeCount) grouping_ms=\(groupingMS) demand_ms=\(demandMS)")
            let coldMS = milliseconds { groups = first.groups(store: store, drafts: []) }
            let remount = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
            let warmMS = milliseconds { XCTAssertEqual(remount.groups(store: store, drafts: []).flatMap(\.rows), groups.flatMap(\.rows)) }
            XCTAssertEqual(remount.bodyDecodeCount, 0)
            print("P2_LIBRARY size=\(count) cold_decodes=\(first.bodyDecodeCount) remount_decodes=\(remount.bodyDecodeCount) cold_ms=\(coldMS) remount_ms=\(warmMS)")
        }
    }
    #endif

    #if !ATTIC_GENERATED_TESTS
    func testP10DemandSummariesPreserveCountsAndRejectChangedContentWithSameToken() throws {
        let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
        let document = NoteDocument(blocks: [.text("Title"), .checklist("Checked", checked: true), .checklist("Open"), .text("Preview words")])
        let id = UUID()
        guard case .success = store.createDocumentNote(id: id, document: document) else { return XCTFail("fixture save") }
        let note = try XCTUnwrap(store.note(withID: id)); note.imageCount = 2; note.fileCount = 3
        let controller = NotesPageController(store: store, journal: nil)
        func row() throws -> (AtticNoteRowModel, NotesLibraryModel) {
            let library = NotesLibraryModel(search: { _ in [] }, store: store, controller: controller)
            let raw = try XCTUnwrap(library.groups(store: store, drafts: [], prepareSummaries: false).flatMap(\.rows).first)
            XCTAssertEqual(library.bodyDecodeCount, 0)
            return (library.preparedRow(raw, store: store), library)
        }
        let (first, model) = try row()
        XCTAssertEqual(model.bodyDecodeCount, 1)
        XCTAssertEqual(first.checklist?.done, 1); XCTAssertEqual(first.checklist?.total, 2)
        XCTAssertEqual(first.images, 2); XCTAssertEqual(first.files, 3)
        let (second, remount) = try row()
        XCTAssertEqual(first, second); XCTAssertEqual(remount.bodyDecodeCount, 0)
        XCTAssertEqual(first.spoken, second.spoken)
        let token = note.revisionID
        note.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Title"), .text("Changed preview")]))
        XCTAssertEqual(note.revisionID, token)
        let (changed, refreshed) = try row()
        XCTAssertEqual(refreshed.bodyDecodeCount, 1)
        XCTAssertNil(changed.checklist)
        XCTAssertTrue(changed.preview.contains("Changed preview"))
    }

    func testP05ProjectionAgreesWithFullCodecAcrossEditsAndReplay() throws {
        var special = NoteBlock.text("Keep identity")
        special.id = UUID(); special.extras["unknown"] = .string("retain")
        let document = NoteDocument(blocks: [.text("Title"), special, .text("Middle emoji 🪴 words", style: "bullet"), .text("Other body"), .text("Carriage\rseparated\u{2029}text"), .text("Tail")])
        let engine = NoteEditorEngine(noteID: UUID(), document: document)
        let (_, view) = engine.makeView()
        defer { engine.detachView() }
        func verify() throws {
            let actual = try NoteContentCodec.encode(engine.document())
            let expected = try NoteContentCodec.encode(NoteTextCodec.document(from: engine.textStorage, template: document))
            XCTAssertTrue(actual == expected, "partial projection must be byte-identical to a full extraction")
            XCTAssertTrue(try NoteContentCodec.encode(engine.checkpointDocument()) == expected)
        }
        try verify()
        func edit(_ text: String, at phrase: String, length: Int = 0) throws {
            let at = (view.string as NSString).range(of: phrase).location
            XCTAssertNotEqual(at, NSNotFound)
            view.setSelectedRange(NSRange(location: at, length: length))
            view.insertText(text, replacementRange: view.selectedRange())
        }
        try edit("α", at: "emoji"); try edit("β", at: "emoji"); try verify()
        try edit("x", at: "Middle"); try edit("y", at: "Other"); try verify()
        try edit("\n", at: "words"); try verify()
        XCTAssertTrue(engine.history.undo()); try verify()
        XCTAssertTrue(engine.history.redo()); try verify()
        let range = (view.string as NSString).range(of: "emoji")
        XCTAssertTrue(engine.perform(.mark(.bold), selection: range)); try verify()
        try edit("z", at: "emoji"); try verify()
        XCTAssertTrue(engine.history.undo()); try verify()
        XCTAssertTrue(engine.history.redo()); try verify()
        try edit("p", at: "emoji")
        let pendingMark = (view.string as NSString).range(of: "Other")
        XCTAssertTrue(engine.perform(.mark(.italic), selection: pendingMark)); try verify()
    }

    func testP05LateDecodeCannotReplaceNavigationOrChangedBytes() async throws {
        for changedBytes in [false, true] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let id = UUID()
            guard case .success = store.createDocumentNote(id: id, document: NoteDocument(blocks: [.text("Stored"), .text("Body")])) else { return XCTFail("fixture save") }
            let gate = OpenDecodeGate()
            let controller = NotesPageController(store: store, journal: nil, decodeOpenDocument: { bytes in await gate.decode(bytes) })
            let opening = Task { await controller.openDurably(noteID: id) }
            while !(await gate.waiting) { await Task.yield() }
            if changedBytes {
                // A fresh-context/import writer can retain the revision token.
                store.note(withID: id)?.content = try NoteContentCodec.encode(NoteDocument(blocks: [.text("Newer"), .text("Changed bytes")]))
            } else { XCTAssertTrue(controller.newNote()) }
            let activeID = controller.active?.id
            await gate.release()
            let opened = await opening.value
            XCTAssertFalse(opened)
            XCTAssertEqual(controller.active?.id, activeID)
        }
    }

    func testP05ColdDurableOpenDecodesOffMainAndKeepsExactBytes() async throws {
        for count in [1000, 5000] {
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let document = NoteDocument(blocks: [.text("Title")] + (0..<count).map { .text("Mixed line \($0)", style: $0 % 5 == 0 ? "bullet" : "body") })
            let id = UUID()
            guard case .success = store.createDocumentNote(id: id, document: document) else { return XCTFail("fixture save") }
            let bytes = try XCTUnwrap(store.note(withID: id)?.content)
            let controller = NotesPageController(store: store, journal: nil)
            let start = DispatchTime.now().uptimeNanoseconds
            let opened = await controller.openFromLibrary(noteID: id)
            XCTAssertTrue(opened)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            XCTAssertEqual(controller.coldDecodeCount, 1)
            XCTAssertEqual(controller.coldDecodeOnMainCount, 0)
            let session = try XCTUnwrap(controller.active)
            XCTAssertTrue(try NoteContentCodec.encode(session.engine.document()) == bytes)
            session.engine.onTextChange?()
            XCTAssertTrue(controller.save(session))
            XCTAssertEqual(store.note(withID: id)?.content, bytes)
            let reopened = await controller.openDurably(noteID: id)
            XCTAssertTrue(reopened); XCTAssertEqual(controller.coldDecodeCount, 1)
            print("P2_COLD_OPEN size=\(count) decodes=\(controller.coldDecodeCount) main_decodes=\(controller.coldDecodeOnMainCount) total_ms=\(ms)")
        }
    }
    #endif

    #if ATTIC_GENERATED_TESTS
    func testP05MiddleEditProjection() throws {
        for count in [1000, 5000] {
            var blocks: [NoteBlock] = [.text("Title")]
            for i in 0..<count { blocks.append(.text("Mixed line \(i) with more words", style: i % 5 == 0 ? "bullet" : "body")) }
            let document = NoteDocument(blocks: blocks)
            let bytes = try NoteContentCodec.encode(document)
            var decoded: NoteDocument?
            let decodeMS = milliseconds { decoded = NoteContentCodec.decode(bytes).document }
            XCTAssertEqual(try NoteContentCodec.encode(XCTUnwrap(decoded)), bytes)
            let engine = NoteEditorEngine(noteID: UUID(), document: document)
            let (_, view) = engine.makeView()
            XCTAssertEqual(try NoteContentCodec.encode(engine.document()), bytes)
            let middle = (engine.textStorage.string as NSString).range(of: "Mixed line \(count / 2) ").location + 12
            view.setSelectedRange(NSRange(location: middle, length: 0)); view.insertText("x", replacementRange: view.selectedRange())
            var projected = document
            var fullProjection: NoteDocument?
            let fullMS = milliseconds { fullProjection = NoteTextCodec.document(from: engine.textStorage, template: document) }
            let projectionUnits = engine.documentProjectionUTF16Count
            let extractionMS = milliseconds { projected = engine.document() }
            let extractedUnits = engine.documentProjectionUTF16Count - projectionUnits
            XCTAssertEqual(extractedUnits, engine.paragraphRange(at: middle).length)
            var prepared: PreparedNoteDocument?
            let prepareMS = try milliseconds { prepared = try PreparedNoteDocument(projected) }
            let store = try makeTestNoteStore(attachmentFileStore: makeTestAttachmentFileStore())
            let savedID = UUID()
            let commitMS = milliseconds {
                guard case .success = store.createDocumentNote(id: savedID, document: projected, prepared: prepared) else { return XCTFail("prepared commit") }
            }
            XCTAssertEqual(store.note(withID: savedID)?.content, prepared?.content)
            print("P2_SAVE size=\(count) decode_ms=\(decodeMS) full_utf16=\(engine.textStorage.length) full_extraction_ms=\(fullMS) projection_utf16=\(extractedUnits) extraction_ms=\(extractionMS) preparation_ms=\(prepareMS) commit_ms=\(commitMS)")
            XCTAssertTrue(projected == fullProjection)
            engine.detachView()
        }
    }
    #endif
}

private actor OpenDecodeGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func decode(_ bytes: Data) async -> (content: NoteContent, onMainThread: Bool) {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
        return (NoteContentCodec.decode(bytes), Thread.isMainThread)
    }
    func release() { continuation?.resume(); continuation = nil }
}
