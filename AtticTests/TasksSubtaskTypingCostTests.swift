import AppKit
import SwiftUI
import Combine
import SwiftData
import XCTest
@testable import Attic

@MainActor
final class TasksSubtaskTypingCostTests: XCTestCase {
    func testSubtaskDraftPublicationWorkOnPerformanceSeed() throws {
        let container = try PersistenceController.makeContainer(inMemory: true)
        let root = ownedTemporaryDirectory(prefix: "AtticP1Seed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try PerformanceSeed.generate(in: container, root: root, includeDoneHistory: false)
        for count in [500, 5000] {
            if count > 500 {
                let context = ModelContext(container)
                for i in 500..<count { context.insert(TaskItem(title: "Extra task \(i)")) }
                try context.save()
            }
            let store = TaskStore(container: container)
            let model = TasksPageModel(library: AtticLibrary(tasks: store))
            // The second sample also retains the child committed in the first.
            print("P1_SUBTASK_FIXTURE seed_limit=\(count) actual_tasks=\(store.tasks.count)")
            let parent = try XCTUnwrap(store.tasks.first { $0.parentID == nil && $0.status != .done })
            model.beginAddingSubtask(to: parent.id)
            let revision = store.revision
            var page = 0, cells = 0
            let observation = model.objectWillChange.sink { page += 1 }
            let cellObservation = model.cellUpdates.objectWillChange.sink { cells += 1 }
            let start = DispatchTime.now().uptimeNanoseconds
            let keys = "twenty five ordinary keys"
            for key in keys { model.newSubtaskTitle.append(key) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print("P1_SUBTASK size=\(count) keys=\(keys.count) page_publications=\(page) all_cells_publications=\(cells) typing_ms=\(ms)")
            XCTAssertEqual(page, 0)
            XCTAssertEqual(cells, 0)
            XCTAssertEqual(store.revision, revision)
            observation.cancel(); cellObservation.cancel()
            XCTAssertTrue(model.commitNewSubtask())
            XCTAssertTrue(store.tasks.contains { $0.parentID == parent.id && $0.title == keys })
            model.newSubtaskTitle = "cancelled draft"; model.cancelEditing()
            XCTAssertFalse(store.tasks.contains { $0.title == "cancelled draft" })
            let child = try XCTUnwrap(store.tasks.first { $0.parentID == parent.id && $0.title == keys })
            model.beginRenamingSubtask(child.id)
            let renameRevision = store.revision
            page = 0; cells = 0
            let renameObservation = model.objectWillChange.sink { page += 1 }
            let renameCellObservation = model.cellUpdates.objectWillChange.sink { cells += 1 }
            let renameStart = DispatchTime.now().uptimeNanoseconds
            for key in keys { model.subtaskRename.append(key) }
            let renameMS = Double(DispatchTime.now().uptimeNanoseconds - renameStart) / 1_000_000
            print("P1_SUBTASK_RENAME size=\(count) keys=\(keys.count) page_publications=\(page) all_cells_publications=\(cells) typing_ms=\(renameMS)")
            XCTAssertEqual(page, 0)
            XCTAssertEqual(cells, 0)
            XCTAssertEqual(store.revision, renameRevision)
            renameObservation.cancel(); renameCellObservation.cancel()
            XCTAssertTrue(model.commitSubtaskRename())
            XCTAssertEqual(store.task(withID: child.id)?.title, keys + keys)
            model.beginRenamingSubtask(child.id); model.subtaskRename = "cancelled rename"; model.cancelSubtaskRename()
            XCTAssertEqual(store.task(withID: child.id)?.title, keys + keys)
        }
    }
    func testActiveQuickLookObservesDraftAndClearsFieldAfterCommit() throws {
        let store = try makeTestStore()
        let parent = try XCTUnwrap(store.create(title: "Parent"))
        let model = TasksPageModel(library: AtticLibrary(tasks: store))
        let size = CGSize(width: 344, height: 520)
        let host = NSHostingView(rootView: TasksPage(model: model, store: store,
            layout: PanelPageLayout(cornerSize: 52, panelSize: size), addBarFocused: .constant(false))
            .frame(width: size.width, height: size.height).atticDesign(.default))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func update() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityLabel() == "New subtask of Parent" { return field }
            for child in view.subviews { if let found = field(in: child) { return found } }
            return nil
        }
        update()
        model.beginAddingSubtask(to: parent.id); update()
        let input = try XCTUnwrap(field(in: host))
        model.newSubtaskTitle = "Draft words"; update()
        XCTAssertEqual(input.stringValue, "Draft words")
        XCTAssertTrue(model.commitNewSubtask()); update()
        XCTAssertEqual(try XCTUnwrap(field(in: host)).stringValue, "")
        model.newSubtaskTitle = "Cancelled"; model.cancelEditing(); update()
        XCTAssertNil(field(in: host))
        XCTAssertFalse(store.tasks.contains { $0.title == "Cancelled" })
    }

}
