import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Owner 10 October: actual layout and responder regressions, without
/// ordering a window on screen or touching the general pasteboard.
@MainActor
final class OwnerTasks1010Tests: XCTestCase {
    func testApplicationActivationPreservesThePanelPosition() throws {
        let suite = "OwnerTasks1010.position.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let controller = AtticPanelController(store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: AppSettings(defaults: defaults), uiState: PanelUIState())
        let panel = controller.panelForTesting
        let screen = try XCTUnwrap(controller.currentScreen)
        let frame = CGRect(x: screen.visibleFrame.midX - 170, y: screen.visibleFrame.midY - 240, width: 340, height: 480)
        panel.setVisibleContentFrame(frame, display: false)
        let beforeActivation = panel.visibleContentFrame
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        spin()
        XCTAssertEqual(panel.visibleContentFrame, beforeActivation, "presenting a picker must not reanchor the existing panel")
        XCTAssertFalse(panel.isVisible)
        withExtendedLifetime(controller) {}
    }

    func testAttachmentPickerFitsBesideItsOwner() throws {
        let screen = CGRect(x: -2560, y: 50, width: 2560, height: 1390)
        for owner in [CGRect(x: -352, y: 700, width: 340, height: 520),
                      CGRect(x: -2000, y: 400, width: 400, height: 620),
                      CGRect(x: -1400, y: 400, width: 400, height: 620)] {
            let placed = try XCTUnwrap(TaskAttachmentPickerSession.placement(size: CGSize(width: 1000, height: 600), beside: owner, in: screen))
            XCTAssertFalse(placed.intersects(owner))
            XCTAssertTrue(screen.contains(placed))
        }
    }

    func testResizeDoesNotInvalidateEveryUnchangedTaskRow() {
        let model = AtticTaskRowModel(title: "Unchanged", state: .todo, priority: .none)
        let a = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 340, height: 520))
        let b = PanelPageLayout(cornerSize: 52, panelSize: CGSize(width: 420, height: 650))
        XCTAssertEqual(a.chromeInsets, b.chromeInsets)
        let before = TasksRowKey(model: model, isSelected: false, selectionRun: .single, isExpanded: false,
                                 isDropTarget: false, isFocused: false, tab: .now, layout: a, isLive: false)
        let after = TasksRowKey(model: model, isSelected: false, selectionRun: .single, isExpanded: false,
                                isDropTarget: false, isFocused: false, tab: .now, layout: b, isLive: false)
        XCTAssertEqual(before, after, "resizing the native row frame must not rebuild its unchanged controls")
    }

    func testMeasuresHeadlessResizeLayoutCost() throws {
        final class Size: ObservableObject { @Published var value = CGSize(width: 340, height: 520) }
        struct Scene: View {
            @ObservedObject var size: Size
            let model: TasksPageModel
            let store: TaskStore
            var body: some View {
                TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size.value), addBarFocused: .constant(false))
                    .equatable().atticDesign(AtticDesignContext(mode: .light, reduceMotion: true))
            }
        }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        try TasksPagePreview.seedScale(in: container)
        let store = TaskStore(container: container)
        let model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        let size = Size()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size.value),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Scene(size: size, model: model, store: store))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        spin(1.5)
        var samples: [Double] = []
        let cpuStart = clock(), wallStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<120 {
            let start = DispatchTime.now().uptimeNanoseconds
            let delta = CGFloat(step < 60 ? step : 120 - step)
            size.value = CGSize(width: 340 + delta * 2, height: 520 + delta * 3)
            window.setContentSize(size.value)
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let sorted = samples.sorted()
        let report: [String: Any] = ["kind": "headless layout, not display frame times", "samples": samples,
            "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "max_ms": sorted.last!, "process_cpu_seconds": cpu, "wall_seconds": wall,
            "one_core_cpu_percent": cpu / wall * 100]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "resize-layout.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(samples.count, 120)
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testTableResizeEdgesKeepTheirCursorUnderTheEditors() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Before"), .table(NoteTable(texts: [["One", "Two"], ["Cell", "Text"]])), .text("After")]))
        let (scroll, textView) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 340, height: 520)
        textView.textContainerInset = CGSize(width: 28, height: 0)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        spin()
        let table = try XCTUnwrap(engine.tableViews().first)
        let edge = CGPoint(x: table.grid.columnWidths[0], y: table.grid.rowHeights[0] / 2)
        let point = table.canvas.convert(edge, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        let previous = NSCursor.current
        defer { previous.set() }
        NSCursor.iBeam.set()
        textView.mouseMoved(with: event)
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "the note's text view must not replace the table edge cursor")
        table.activate(.init(row: 0, column: 0))
        NSCursor.iBeam.set()
        table.editor.mouseMoved(with: event)
        XCTAssertTrue(NSCursor.current === NSCursor.resizeLeftRight, "an active cell editor must preserve the edge cursor too")
    }

    func testRendersCalendarMarksForPixelInspection() throws {
        final class Keys { var handler: ((NSEvent) -> Bool)? }
        let keys = Keys()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_GB")
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let host = NSHostingView(rootView: AtticDateCard(today: today, selected: selected, calendar: calendar, typed: .constant(""), onPick: { _ in })
            .environment(\.atticDropdownRegisterKeys, { keys.handler = $0 })
            .atticDesign(AtticDesignContext(mode: .light, reduceMotion: true))
            .frame(width: 220, height: 230, alignment: .top).background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: 220, height: 230)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 220, height: 230), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        spin()
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(try XCTUnwrap(keys.handler)(key))
        spin()
        let rep = try bitmap(host)
        try capture(rep, name: "calendar-marks.png")
        XCTAssertGreaterThan(rep.pixelsWide, 0)
    }

    private final class FileDrag: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation = CGPoint(x: 100, y: 100)
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("OwnerTasks1010.\(UUID().uuidString)"))
        var draggingSource: Any? { nil }
        @MainActor private static var nextSequence = 0
        let draggingSequenceNumber: Int
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
            var stop = ObjCBool(false)
            for (index, item) in (draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []).enumerated() {
                guard let writer = item as? NSPasteboardWriting else { continue }
                let dragging = NSDraggingItem(pasteboardWriter: writer)
                let point = view?.convert(draggingLocation, from: nil)
                    ?? draggingDestinationWindow?.convertPoint(toScreen: draggingLocation)
                    ?? draggingLocation
                dragging.draggingFrame = CGRect(origin: point, size: CGSize(width: 1, height: 1))
                block(dragging, index, &stop)
                if stop.boolValue { break }
            }
        }
        let fixtureURL: URL
        @MainActor init(fileURL: URL, transfersPDF: Bool = false) {
            fixtureURL = fileURL
            Self.nextSequence += 1
            draggingSequenceNumber = Self.nextSequence
            super.init()
            if transfersPDF {
                // NSURL payloads in a synthetic drag lack AppKit-issued sandbox
                // extensions. PDF data exercises the same file-drop path.
                let item = NSPasteboardItem()
                let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
                item.setData(NSView(frame: bounds).dataWithPDF(inside: bounds), forType: .pdf)
                draggingPasteboard.writeObjects([item])
            } else { draggingPasteboard.writeObjects([fileURL as NSURL]) }
        }
        deinit {
            draggingPasteboard.releaseGlobally()
            try? FileManager.default.trashItem(at: fixtureURL, resultingItemURL: nil)
        }
    }

    func testCancellingANativeFileDragClearsTheTaskTarget() throws {
        final class Target { var id: UUID? }
        let target = Target(), id = UUID()
        let host = NSHostingView(rootView: Color.white.frame(width: 340, height: 520)
            .tasksFileDrop(delegate: TasksFileDropDelegate(target: { _ in id }, canAccept: { _, _ in true }, setTargeted: { target.id = $0 }, perform: { _, _, _ in })))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        spin()
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let destination = try XCTUnwrap(views(host).first { !$0.registeredDraggedTypes.isEmpty })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerTasks1010-\(UUID().uuidString).txt")
        try Data("attachment fixture".utf8).write(to: file)
        let drag = FileDrag(fileURL: file)
        drag.draggingDestinationWindow = window
        XCTAssertEqual(destination.draggingEntered(drag), .copy)
        spin()
        XCTAssertEqual(target.id, id)
        destination.draggingEnded(drag)
        spin()
        XCTAssertNil(target.id, "a cancelled drag need not deliver dropExited or performDrop")
    }

    func testNativeFileDragExitAndDropClearTheTaskTarget() throws {
        final class Target { var id: UUID?; var drops = 0 }
        for complete in [false, true] {
            let target = Target(), id = UUID()
            let host = NSHostingView(rootView: Color.white.frame(width: 340, height: 520)
                .tasksFileDrop(delegate: TasksFileDropDelegate(target: { _ in id }, canAccept: { _, _ in true }, setTargeted: { target.id = $0 }, perform: { _, _, _ in target.drops += 1 })))
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            spin()
            func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
            let destination = try XCTUnwrap(views(host).first { !$0.registeredDraggedTypes.isEmpty })
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerTasks1010-\(UUID().uuidString).txt")
            try Data("attachment fixture".utf8).write(to: file)
            let drag = FileDrag(fileURL: file, transfersPDF: complete)
            drag.draggingDestinationWindow = window
            XCTAssertEqual(destination.draggingEntered(drag), .copy)
            spin()
            XCTAssertEqual(target.id, id)
            if complete {
                XCTAssertTrue(destination.prepareForDragOperation(drag))
                XCTAssertTrue(destination.performDragOperation(drag))
                destination.concludeDragOperation(drag)
                destination.draggingEnded(drag)
            } else { destination.draggingExited(drag) }
            spin()
            XCTAssertNil(target.id)
            XCTAssertEqual(target.drops, complete ? 1 : 0)
        }
    }

    func testEmptyEntryUndoPreservesADirtyPreviousRenameAndItsHistory() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.beginAddingSubtask(to: parent.id)
        XCTAssertTrue(hosted.model.backspaceEmptySubtask())
        let previous = try XCTUnwrap(hosted.model.renamingSubtaskID)
        let original = try XCTUnwrap(hosted.store.task(withID: previous)?.title)
        let step = hosted.model.library.undo.undoStepID(in: .tasks)
        hosted.model.subtaskRename = "Changed but not saved"
        XCTAssertFalse(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.model.subtaskRename, "Changed but not saved")
        XCTAssertEqual(hosted.store.task(withID: previous)?.title, original)
        XCTAssertEqual(hosted.model.library.undo.undoStepID(in: .tasks), step)
        hosted.model.subtaskRename = original
        XCTAssertTrue(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.model.newSubtaskParentID, parent.id)
        XCTAssertTrue(hosted.model.redo().isApplied)
        XCTAssertNil(hosted.model.newSubtaskParentID)
        XCTAssertEqual(hosted.model.renamingSubtaskID, previous)
    }

    func testOpenDropdownTracksItsMovingAncestor() throws {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 520))
        window.contentView = content
        let ancestor = NSView(frame: content.bounds)
        content.addSubview(ancestor)
        let anchor = NSView(frame: CGRect(x: 140, y: 340, width: 40, height: 24))
        ancestor.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.takesKeyboard = false
        presenter.contentHeight = 100
        presenter.content = AnyView(Text("Choice"))
        defer { presenter.close(restoreFocus: false, immediately: true); window.close() }
        presenter.present(from: anchor)
        spin()
        let before = try XCTUnwrap(presenter.host).frame
        ancestor.frame.origin.y -= 30
        spin()
        let after = try XCTUnwrap(presenter.host).frame
        XCTAssertEqual(after.minY, before.minY - 30, accuracy: 1, "the card follows the converted anchor, not just its local frame")
        presenter.close(restoreFocus: false, immediately: true)
        ancestor.frame.origin.y -= 20
        spin()
        XCTAssertFalse(presenter.isOpen)
        presenter.present(from: anchor)
        spin()
        XCTAssertEqual(try XCTUnwrap(presenter.host).frame.minY, after.minY - 20, accuracy: 1)
    }

    func testTheInlineNoteCheckboxUsesTheControlCursor() throws {
        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.checklist("Check this"), .text("Editable text")]))
        let (scroll, textView) = engine.makeView()
        scroll.frame = CGRect(x: 0, y: 0, width: 340, height: 520)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        engine.layoutManager?.ensureLayout(for: engine.contentStorage.documentRange)
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        spin()
        let rect = try XCTUnwrap(engine.rect(for: NSRange(location: 0, length: 1)))
        let local = CGPoint(x: rect.minX + NoteChecklistAttachment.boxSize / 2, y: rect.midY)
        XCTAssertNotNil(textView.checkboxLocation(at: local))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: textView.convert(local, to: nil), modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        let previous = NSCursor.current
        defer { previous.set() }
        NSCursor.iBeam.set()
        textView.mouseMoved(with: event)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }

    func testFamilyPanelEmptyEntryAndSavedChildBackspaceAreUndoable() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let parent = TaskItem(title: "Parent")
        let previous = TaskItem(title: "Previous", parentID: parent.id)
        let empty = TaskItem(title: "", parentID: parent.id)
        for task in [parent, previous, empty] { container.mainContext.insert(task) }
        try container.mainContext.save()
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let ui = PanelUIState()
        ui.activateSubtaskEntry(for: parent.id)
        ui.subtaskDrafts[parent.id] = "Keep this"
        XCTAssertFalse(ui.backspaceEmptySubtask(store: store, parentID: parent.id))
        ui.subtaskDrafts[parent.id] = ""
        XCTAssertTrue(ui.backspaceEmptySubtask(store: store, parentID: parent.id))
        XCTAssertFalse(ui.subtaskEntryActiveIDs.contains(parent.id))
        XCTAssertEqual(ui.editingTaskID, store.subtasks(of: parent.id).last?.id)
        XCTAssertTrue(ui.undoSubtaskEdit(store: store, nativeHasUndo: true))
        XCTAssertTrue(ui.subtaskEntryActiveIDs.contains(parent.id))
        XCTAssertTrue(ui.redoSubtaskEdit(store: store, nativeHasRedo: true))
        ui.beginEditing(empty)
        ui.editingDraftTitle = "Keep this"
        XCTAssertFalse(ui.backspaceEmptySubtask(store: store, parentID: parent.id, childID: empty.id))
        ui.editingDraftTitle = ""
        let order = store.subtasks(of: parent.id)
        let i = try XCTUnwrap(order.firstIndex { $0.id == empty.id })
        XCTAssertTrue(ui.backspaceEmptySubtask(store: store, parentID: parent.id, childID: empty.id))
        XCTAssertNil(store.task(withID: empty.id))
        XCTAssertEqual(ui.editingTaskID, i > 0 ? order[i - 1].id : nil)
        XCTAssertTrue(ui.undoSubtaskEdit(store: store, nativeHasUndo: true))
        XCTAssertEqual(store.task(withID: empty.id)?.title, "")
        withExtendedLifetime(library) {}
    }

    func testFamilyBackspaceBridgeIsScopedToItsEmptyField() throws {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 520))
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let editor = NSTextView(frame: CGRect(x: 30, y: 30, width: 220, height: 30))
        root.addSubview(editor)
        let bridge = SubtaskBackspace.Bridge(frame: editor.frame)
        root.addSubview(bridge)
        var removes = 0
        bridge.remove = { removes += 1; return true }
        bridge.text = { editor.string }
        XCTAssertTrue(window.makeFirstResponder(editor))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
        XCTAssertTrue(bridge.handle(event))
        XCTAssertEqual(removes, 1)
        editor.string = "Do not remove"
        XCTAssertFalse(bridge.handle(event))
        editor.string = ""
        bridge.frame.origin.y += 100
        XCTAssertFalse(bridge.handle(event))
        XCTAssertEqual(removes, 1)
    }

    func testFamilyEmptyEntryBackspacePreservesAnOlderDirtyRename() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let a = try XCTUnwrap(store.create(title: "First", parentID: parent.id))
        _ = try XCTUnwrap(store.create(title: "Last", parentID: parent.id))
        let ui = PanelUIState()
        ui.beginEditing(a)
        ui.editingDraftTitle = "Unsaved title"
        ui.activateSubtaskEntry(for: parent.id)
        XCTAssertTrue(ui.backspaceEmptySubtask(store: store, parentID: parent.id))
        XCTAssertFalse(ui.subtaskEntryActiveIDs.contains(parent.id))
        XCTAssertEqual(ui.editingTaskID, a.id)
        XCTAssertEqual(ui.editingDraftTitle, "Unsaved title")
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(ui.subtaskEntryActiveIDs.contains(parent.id))
        XCTAssertEqual(ui.editingDraftTitle, "Unsaved title")
    }

    func testFamilyEntryUndoLeavesOtherFamiliesDraftsAlone() throws {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let library = AtticLibrary(tasks: store)
        let a = try XCTUnwrap(store.create(title: "A"))
        let b = try XCTUnwrap(store.create(title: "B"))
        let ui = PanelUIState()
        ui.subtaskDrafts[a.id] = "Retained draft"
        ui.activateSubtaskEntry(for: b.id)
        XCTAssertTrue(ui.backspaceEmptySubtask(store: store, parentID: b.id))
        XCTAssertTrue(library.undo(in: .tasks).isApplied)
        XCTAssertTrue(ui.subtaskEntryActiveIDs.contains(b.id))
        XCTAssertEqual(ui.subtaskDrafts[a.id], "Retained draft")
    }

    func testAttachmentPickerRecoveryFromAnOffscreenOwnerStaysOnscreen() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for owner in [CGRect(x: -4000, y: 200, width: 340, height: 520), CGRect(x: 4000, y: 200, width: 340, height: 520),
                      CGRect(x: 500, y: 4000, width: 340, height: 520), CGRect(x: 500, y: -4000, width: 340, height: 520)] {
            let placed = try XCTUnwrap(TaskAttachmentPickerSession.placement(size: CGSize(width: 1000, height: 600), beside: owner, in: screen))
            XCTAssertTrue(screen.contains(placed))
            XCTAssertFalse(placed.intersects(owner))
        }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    func testBackspaceOnTheEmptyNewSubtaskRemovesItsLineAndUndoRestoresIt() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { !$0.subtasks.isEmpty || $0.model.subtasks != nil })
        hosted.model.beginAddingSubtask(to: parent.id)
        hosted.spin(0.3)
        let children = hosted.model.rows(for: .now).first { $0.id == parent.id }?.subtasks ?? []
        let previous = try XCTUnwrap(children.last)
        let field = try XCTUnwrap(fields(in: try XCTUnwrap(hosted.window.contentView)).first { $0.isEditable && $0.placeholderString == "Add subtask…" })
        let editor = NSTextView()
        editor.string = field.stringValue
        let consumed = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))) ?? false
        if field.stringValue.isEmpty { XCTAssertTrue(consumed) } else { XCTAssertFalse(consumed) }
        hosted.spin(0.3)
        XCTAssertNil(hosted.model.newSubtaskParentID, "Backspace removes the empty entry line")
        XCTAssertEqual(hosted.model.renamingSubtaskID, previous.id, "the previous subtask receives the caret")
        XCTAssertTrue(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.model.newSubtaskParentID, parent.id, "Undo restores the removed empty line")
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count, "the empty entry did not delete a saved subtask")
    }

    func testBackspaceOnAnEmptiedSubtaskDeletesOnlyItAndUndoRestoresIt() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.setExpanded(parent.id, true)
        let children = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }).subtasks
        let child = try XCTUnwrap(children.last)
        hosted.model.beginRenamingSubtask(child.id)
        hosted.model.subtaskRename = ""
        hosted.spin(0.3)
        let field = try XCTUnwrap(fields(in: try XCTUnwrap(hosted.window.contentView)).first { $0.isEditable && $0.accessibilityLabel() == "Rename subtask" && $0.stringValue.isEmpty })
        let editor = NSTextView()
        editor.string = field.stringValue
        let consumed = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))) ?? false
        if field.stringValue.isEmpty { XCTAssertTrue(consumed) } else { XCTAssertFalse(consumed) }
        hosted.spin(0.3)
        XCTAssertNil(hosted.store.task(withID: child.id), "Backspace removes the emptied subtask")
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count - 1)
        XCTAssertEqual(hosted.model.renamingSubtaskID, children.dropLast().last?.id)
        XCTAssertTrue(hosted.model.undo().isApplied)
        XCTAssertEqual(hosted.store.task(withID: child.id)?.title, child.title)
        XCTAssertEqual(hosted.store.subtasks(of: parent.id).count, children.count)
    }

    func testBackspaceInASubtaskWithTextKeepsTheSubtask() throws {
        let hosted = try Hosted(height: 520, keyWindow: false)
        defer { hosted.close() }
        let parent = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.model.subtasks != nil })
        hosted.model.setExpanded(parent.id, true)
        let child = try XCTUnwrap(hosted.model.rows(for: .now).first { $0.id == parent.id }?.subtasks.first)
        hosted.model.beginRenamingSubtask(child.id)
        hosted.spin(0.3)
        let field = try XCTUnwrap(fields(in: try XCTUnwrap(hosted.window.contentView)).first { $0.isEditable && $0.stringValue == child.title })
        let editor = NSTextView()
        editor.string = field.stringValue
        let consumed = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))) ?? false
        if field.stringValue.isEmpty { XCTAssertTrue(consumed) } else { XCTAssertFalse(consumed) }
        hosted.spin(0.3)
        XCTAssertNotNil(hosted.store.task(withID: child.id))
        XCTAssertEqual(hosted.model.renamingSubtaskID, child.id)
    }
    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func titleInkBounds(_ rep: NSBitmapImageRep) -> CGRect? {
        let scale = CGFloat(rep.pixelsWide) / 340
        var points: [CGPoint] = []
        for y in 0..<Int(24 * scale) {
            for x in Int(44 * scale)..<Int(150 * scale) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.redComponent + color.greenComponent + color.blueComponent < 1.5 else { continue }
                points.append(CGPoint(x: x, y: y))
            }
        }
        guard let x = points.map(\.x).min(), let y = points.map(\.y).min(),
              let maxX = points.map(\.x).max(), let maxY = points.map(\.y).max() else { return nil }
        return CGRect(x: x, y: y, width: maxX - x + 1, height: maxY - y + 1)
    }

    private func capture(_ rep: NSBitmapImageRep, name: String) throws {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A native text view has no SwiftUI first-text baseline. Replacing the
    /// title with it must not change the date's actual control frame.
    func testRenameKeepsTheDateAndDetailsInPlace() throws {
        final class State: ObservableObject {
            @Published var editing = false
            var title = "HHHHHH"
            var frames: [CGRect] = []
        }
        struct Scene: View {
            @ObservedObject var state: State
            var body: some View {
                AtticTaskRow(
                    model: .init(title: "HHHHHH", state: .todo, priority: .none, due: .init(text: "Tuesday"), tags: ["work"]),
                    actions: .init(toggleDone: {}, toggleWorking: {}, openPage: {}, moveToBacklog: {}, delete: {}, editTitle: {}),
                    onToggleExpanded: {}, onSelect: {},
                    titleEditing: state.editing ? .init(text: Binding(get: { state.title }, set: { state.title = $0 }),
                                                       commit: { true }, cancel: {},
                                                       tokens: .init(chips: [], dismissChip: { _ in }, edited: { _, _ in }, caretMoved: { _ in })) : nil,
                    meta: .init(onDate: {}, onTags: {}, datePresented: .constant(false), tagsPresented: .constant(false),
                                datePicker: { AnyView(EmptyView()) }, tagPicker: { AnyView(EmptyView()) })
                )
                .onPreferenceChange(AtticRowControlFramesKey.self) { frames in
                    MainActor.assumeIsolated { state.frames = frames }
                }
                .frame(width: 340, height: 48, alignment: .top)
                .background(Color.white)
                .atticDesign(AtticDesignContext(mode: .light))
            }
        }
        let state = State()
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 48),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Scene(state: state))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        spin()
        let before = try bitmap(host)
        let originalFrames = state.frames
        XCTAssertFalse(originalFrames.isEmpty)
        try capture(before, name: "rename-idle.png")
        state.editing = true
        spin()
        let during = try bitmap(host)
        try capture(during, name: "rename-editing.png")
        XCTAssertEqual(titleInkBounds(during), titleInkBounds(before), "the title glyphs also stay in place")
        XCTAssertEqual(state.frames, originalFrames, "date and tag controls must not move when rename begins")
        state.editing = false
        spin()
        _ = try bitmap(host)
        XCTAssertEqual(state.frames, originalFrames, "ending rename keeps the same geometry")
    }

    /// Run the real list modifier over coloured rows, rather than merely
    /// asserting a constant that the rendered list might never use.
    func testComposerStripExcludesRowsBehindItsPlainControls() throws {
        let stack = TasksBottomStackHeight()
        stack.height = TasksViewport.reservedStack
        let height: CGFloat = 520, inset: CGFloat = 16
        let host = NSHostingView(rootView:
            Color(red: 1, green: 0, blue: 0).tasksListEdges(.cleanCut, top: 80, listTop: 100, bottomInset: inset,
                                    bottomMargin: 48, bottomClearance: stack.height + inset + 16,
                                    stack: stack, mask: Color.white)
                .frame(width: 340, height: height).background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: height)
        spin()
        let rep = try bitmap(host)
        try capture(rep, name: "composer-list-mask.png")
        let scale = CGFloat(rep.pixelsHigh) / height
        let stripCentre = height - inset - stack.height + AtticControlSize.smallHeight / 2
        let pixel = try XCTUnwrap(rep.colorAt(x: Int(170 * scale), y: Int(stripCentre * scale))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pixel.greenComponent, 0.95, "rows must be invisible beneath Date / Tag / Priority")
        let above = try XCTUnwrap(rep.colorAt(x: Int(170 * scale), y: Int((stripCentre - 40) * scale))?.usingColorSpace(.sRGB))
        let reference = try XCTUnwrap(rep.colorAt(x: Int(170 * scale), y: Int((stripCentre - 80) * scale))?.usingColorSpace(.sRGB))
        XCTAssertEqual(above.greenComponent, reference.greenComponent, accuracy: 0.01, "rows above the strip retain the unmasked row colour")
    }

    func testOpenDropdownRefitsWhenItsWindowGetsShorter() throws {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 340, height: 520),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 520))
        window.contentView = content
        let anchor = NSView(frame: CGRect(x: 20, y: 180, width: 40, height: 24))
        content.addSubview(anchor)
        let presenter = AtticDropdownPresenter()
        presenter.design = AtticDesignContext(reduceMotion: true)
        presenter.takesKeyboard = false
        presenter.contentHeight = 220
        presenter.content = AnyView(VStack(spacing: 0) {
            ForEach(0..<12) { Text("Choice \($0)").frame(height: 28) }
        })
        defer { presenter.close(restoreFocus: false, immediately: true); window.close() }
        presenter.present(from: anchor)
        spin()
        window.setContentSize(CGSize(width: 340, height: 320))
        spin()
        let host = try XCTUnwrap(presenter.host)
        let space = try XCTUnwrap(AtticDropdownSpace(around: anchor))
        let card = AtticDropdownLayout.topDown(host.frame.insetBy(dx: host.contentInset, dy: host.contentInset), in: space.parent)
        XCTAssertGreaterThanOrEqual(card.minY, space.bounds.minY - 1)
        XCTAssertLessThanOrEqual(card.maxY, space.bounds.maxY + 1, "an already-open dropdown must fit the new panel height")
        XCTAssertLessThanOrEqual(card.height, 220)
        try capture(bitmap(host), name: "dropdown-short-panel.png")
        func scrolls(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
        XCTAssertTrue(scrolls(host).contains { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 }, "the limited dropdown scrolls its full contents internally")
    }
}
