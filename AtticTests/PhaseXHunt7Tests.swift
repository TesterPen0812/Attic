import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Only legal user commands: no competing facades, stale caller snapshots,
/// projection substitutions, or transforms of an unselected object.
@MainActor
final class PhaseXHunt7Tests: XCTestCase {
    private struct Step: CustomStringConvertible {
        let kind: Int
        let choice: Int
        var description: String { "\(kind):\(choice)" }
    }
    private struct Random {
        var state: UInt64
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upper))
        }
    }
    private struct TaskValue: Equatable {
        var title: String
        var status: TaskStatus
        var parent: UUID?
        var logged = false
    }
    private struct NoteValue: Equatable {
        var body = "alpha"
        var heading = false
        var tags: [String] = []
        var cell = "value"
    }

    /// Returns the first divergence so the same interpreter can shrink it.
    /// Expected text, statuses, visible sets, selections and history positions
    /// are value-only; product parsing/snapshots never calculate the oracle.
    private func replay(_ steps: [Step]) async throws -> (Int, String)? {
        let root = ownedTemporaryDirectory(prefix: "H9UserFlows")
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let clock = MutableNow(Date(timeIntervalSince1970: 1_791_633_600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tasks = TaskStore(container: container, now: { clock.value })
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
        let canvases = CanvasStore(container: container)
        let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
        let taskPage = TasksPageModel(library: library, services: .init(now: { clock.value }, calendar: { calendar }))
        let notePage = NotesPageController(store: notes,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("Recovery")),
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await notePage.startAndWait()
        let canvas = CanvasSession(store: canvases)
        let cleanup = DailyCleanupService(store: tasks, now: { clock.value }, calendar: { calendar })
        let suite = "H9Settings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let ui = PanelUIState()
        ui.loadPageContent()
        var expectedPage = PanelSection.tasks
        var expectedBuilt: Set<PanelPage> = [.tasks]
        var expectedFocus: UInt64 = 0
        var taskValues: [UUID: TaskValue] = [:]
        var roots: [UUID] = []
        // A third parent is reserved for subtask commands. Multi-completion
        // of the first two is the real menu route, without transient holds.
        for title in ["First", "Second", "Family"] {
            let row = try XCTUnwrap(library.createTasks([TaskDraft(title: title)])?.first)
            roots.append(row.id); taskValues[row.id] = .init(title: title, status: .todo)
        }
        let noteIDs = [UUID(), UUID()]
        var noteValues = [NoteValue(), NoteValue()]
        for (index, id) in noteIDs.enumerated() {
            _ = try notes.createDocumentNote(id: id, document: .init(blocks: [
                .text("Note \(index)"), .text("alpha"),
                .table(NoteTable(texts: [["header"], ["value"]]))
            ])).get()
        }
        var activeNote = 0
        guard await notePage.openDurably(noteID: noteIDs[0]) else { return (0, "initial note open refused") }
        var canvasCenters: [UUID: CanvasPoint] = [:]
        var canvasOrder: [UUID] = []
        var canvasUndo: [[UUID: CanvasPoint]] = [], canvasRedo: [[UUID: CanvasPoint]] = []
        var query = ""
        var taskSelection: Set<UUID> = []
        var expectedTab = TasksTab.now

        for (index, step) in steps.enumerated() {
            let label = "step \(index) \(step)"
            // Await the controller's durable Notes boundary; the separate
            // shell probe exercises synchronous prepareToLeave/present.
            let target: PanelSection = switch step.kind {
            case 0...8: .tasks
            case 9...15: .notes
            case 16...19: .canvas
            default: expectedPage
            }
            if target != expectedPage {
                if expectedPage == .notes, !(await notePage.prepareToLeaveDurably(.pageSwitch)) {
                    return (index, "\(label): Notes page switch refused")
                }
                expectedBuilt = Set(expectedBuilt.filter { $0 != .notes })
                expectedBuilt.insert(PanelPage(target))
                ui.switchPage(to: target, motion: .instant)
                expectedPage = target
                if target == .notes, !(await notePage.openDurably(noteID: noteIDs[activeNote])) {
                    return (index, "\(label): Notes return refused")
                }
            }
            switch step.kind {
            case 0: // Return in the add bar, Now/Later/Done.
                let tab = TasksTab.allCases[step.choice % 3]
                if tab != expectedTab { taskSelection = [] }; taskPage.select(tab: tab); expectedTab = tab
                let title = "Generated \(index)"
                taskPage.addBar = TaskAddBarText(text: title)
                guard let id = taskPage.submitAddBar() else { return (index, "\(label): add refused") }
                taskSelection = []
                roots.append(id)
                taskValues[id] = .init(title: title, status: tab == .backlog ? .backlog : .todo)
            case 1: // Right-click/multi-selection Complete/Reopen on two roots.
                let ids = Array(roots.prefix(2))
                let complete = taskValues[ids[0]]!.status != .done
                let tab: TasksTab = complete ? .now : .done
                taskPage.select(tab: tab); expectedTab = tab
                if tab == .done {
                    // Clear Find before selecting both visible Done rows.
                    taskPage.typeDoneSearch(""); taskPage.flushDoneSearchInput(); query = ""
                }
                taskPage.selectOnly(ids[0]); taskPage.click(ids[1], modifiers: .command, visible: ids)
                taskSelection = Set(ids)
                guard taskPage.toggleDone(ids).isApplied else { return (index, "\(label): completion refused") }
                for id in ids { taskValues[id]!.status = complete ? .done : .todo; taskValues[id]!.logged = false }
            case 2: // Move to Later, then Undo and Redo the same menu command.
                let choices = roots.dropFirst(3).filter { taskValues[$0]?.status == .todo }
                if let id = choices.first {
                    taskPage.select(tab: .now); expectedTab = .now
                    taskPage.selectOnly(id); taskSelection = [id]
                    guard taskPage.moveToBacklog([id]).isApplied,
                          taskPage.undo().isApplied, taskPage.redo().isApplied else {
                        return (index, "\(label): task move/undo/redo refused")
                    }
                    taskValues[id]!.status = .backlog; taskSelection.remove(id)
                }
            case 3:
                let choices = roots.dropFirst(3).filter { taskValues[$0]?.status == .backlog }
                if let id = choices.first {
                    taskPage.select(tab: .backlog); expectedTab = .backlog
                    taskPage.selectOnly(id); taskSelection = [id]
                    guard taskPage.moveToNow([id]).isApplied else { return (index, "\(label): move to Now refused") }
                    taskValues[id]!.status = .todo; taskSelection.remove(id)
                }
            case 4: // Add subtask through the inline entry and Return.
                let parent = roots[2]
                taskPage.select(tab: .now); expectedTab = .now
                taskPage.selectOnly(parent); taskSelection = [parent]
                taskPage.beginAddingSubtask(to: parent)
                let title = "Child \(index)"
                taskPage.newSubtaskTitle = title
                guard taskPage.commitNewSubtask() else { return (index, "\(label): subtask add refused") }
                let id = try XCTUnwrap(tasks.subtasks(of: parent).first { $0.title == title }?.id)
                taskValues[id] = .init(title: title, status: .todo, parent: parent)
                taskPage.cancelEditing()
            case 5:
                let children = taskValues.filter { $0.value.parent != nil }.keys.sorted { $0.uuidString < $1.uuidString }
                if let id = children.first {
                    taskPage.select(tab: .now); expectedTab = .now
                    taskPage.setExpanded(roots[2], true)
                    taskPage.selectOnly(roots[2]); taskSelection = [roots[2]]
                    guard taskPage.toggleSubtask(id).isApplied else { return (index, "\(label): subtask toggle refused") }
                    taskValues[id]!.status = taskValues[id]!.status == .done ? .todo : .done
                }
            case 6: // Day change/wake cleanup: same production command, fixed clock.
                clock.value += 86400
                _ = cleanup.performCleanup()
                for id in roots where taskValues[id]!.status == .done {
                    taskValues[id]!.logged = true
                }
                if expectedTab != .done { taskSelection = taskSelection.filter { taskValues[$0]?.logged == false } }
            case 7:
                taskPage.beginSearch(); expectedTab = .done; taskSelection = []
                query = step.choice % 2 == 0 ? "First" : ""
                taskPage.typeDoneSearch(query); taskPage.flushDoneSearchInput()
            case 8:
                let visible = roots.filter { !taskValues[$0]!.logged && taskValues[$0]!.status == .todo }
                taskPage.clearSelection(); taskPage.select(tab: .now); expectedTab = .now; taskSelection = []
                if let id = visible.first { taskPage.selectOnly(id); taskSelection = [id] }
                ui.requestPrimaryInputFocus(); expectedFocus &+= 1
            case 9: // User opens another existing note.
                activeNote = step.choice % noteIDs.count
                guard await notePage.openDurably(noteID: noteIDs[activeNote]) else { return (index, "\(label): open refused") }
            case 10: // Native typing's engine edit, preserving paragraph style.
                let engine = try XCTUnwrap(notePage.active?.engine)
                let value = "x"
                let start = "Note \(activeNote)".utf16.count + 1
                let end = start + noteValues[activeNote].body.utf16.count
                guard engine.performEdit(NSRange(location: end, length: 0),
                    with: NSAttributedString(string: value, attributes: engine.attributes(forParagraphAt: start)), name: "Typing") else {
                    return (index, "\(label): typing refused")
                }
                noteValues[activeNote].body += value
            case 11: // The exact router used by Aa and shortcuts.
                let engine = try XCTUnwrap(notePage.active?.engine)
                let router = NoteCommandRouter(engine: engine)
                let heading = !noteValues[activeNote].heading
                guard router.run(.paragraph(heading ? .heading(2) : .body),
                    from: step.choice % 2 == 0 ? .formatBar : .shortcut,
                    selection: NSRange(location: "Note \(activeNote)".utf16.count + 1, length: 0)) else {
                    return (index, "\(label): formatting refused")
                }
                noteValues[activeNote].heading = heading
            case 12:
                let tags = step.choice % 2 == 0 ? ["work"] : ["home"]
                notePage.active?.engine.setTagsFromPicker(tags)
                noteValues[activeNote].tags = tags
            case 13: // A cell edit uses the table's one engine/history route.
                let engine = try XCTUnwrap(notePage.active?.engine)
                let table = try XCTUnwrap(engine.objects().compactMap { $0.0 as? NoteTableAttachment }.first)
                guard engine.changeTable(table, name: "Cell", { $0.rows[1].cells[0].text += "c" }) else {
                    return (index, "\(label): table edit refused")
                }
                noteValues[activeNote].cell += "c"
            case 14: // Save, open history, close it: live note must stay editable.
                guard await notePage.openHistoryDurably() else { return (index, "\(label): history refused") }
                if notePage.historyBrowser?.current.title != "Note \(activeNote)" { return (index, "\(label): wrong history note") }
                notePage.closeHistory()
            case 15:
                guard await notePage.preserveAllDurably() else { return (index, "\(label): save refused") }
            case 16:
                let point = CanvasPoint(x: Double(step.choice % 100), y: Double(index))
                let end = CanvasPoint(x: point.x + 80, y: point.y + 60)
                let before = canvasCenters
                guard canvas.insertShape(.rectangle, from: point, to: end), let id = canvas.selectedSemanticObjectID else {
                    return (index, "\(label): shape insertion refused")
                }
                canvasCenters[id] = .init(x: point.x + 40, y: point.y + 30)
                canvasOrder.append(id); canvasUndo.append(before); canvasRedo = []
            case 17:
                let available = canvasOrder.filter { canvasCenters[$0] != nil }
                if !available.isEmpty {
                    let id = available[step.choice % available.count], before = canvasCenters
                    // Pointer selection precedes drag/nudge in the real surface.
                    canvas.selectSemanticObject(id)
                    guard canvas.nudgeSelectedSemanticObject(CGSize(width: 10, height: 0)) else {
                        return (index, "\(label): selected shape nudge refused")
                    }
                    canvasCenters[id]!.x += 10; canvasUndo.append(before); canvasRedo = []
                }
            case 18:
                let possible = !canvasUndo.isEmpty
                guard canvas.undo() == possible else { return (index, "\(label): undo availability disagrees") }
                if let previous = canvasUndo.popLast() { canvasRedo.append(canvasCenters); canvasCenters = previous }
            case 19:
                let possible = !canvasRedo.isEmpty
                guard canvas.redo() == possible else { return (index, "\(label): redo availability disagrees") }
                if let next = canvasRedo.popLast() { canvasUndo.append(canvasCenters); canvasCenters = next }
            default: // Settings changes persist without erasing other pages.
                let enabled = step.choice % 2 == 0
                settings.revealOnHover = enabled
                if AppSettings(defaults: defaults).revealOnHover != enabled { return (index, "\(label): setting did not persist") }
            }
            // Observe the next stable page turn after queued revision observers.
            // This drains the main queue, never AppKit events or window actions.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if ui.selectedSection != expectedPage || ui.builtPages != expectedBuilt || ui.primaryInputFocusRequest != expectedFocus {
                return (index, "\(label): page/built/focus request mismatch")
            }
            if taskPage.tab != expectedTab || taskPage.selection != taskSelection {
                return (index, "\(label): task tab/selection mismatch")
            }
            let actual = try ModelContext(container).fetch(FetchDescriptor<TaskItem>())
            let actualValues = Dictionary(uniqueKeysWithValues: actual.map { row in
                (row.id, TaskValue(title: row.title, status: row.status, parent: row.parentID, logged: row.doneLoggedAt != nil))
            })
            if actualValues != taskValues { return (index, "\(label): durable task values mismatch") }
            let nowIDs = Set(taskPage.rows(for: .now).filter { $0.status != .done }.map(\.id))
            let expectedNow = Set(taskValues.filter { $0.value.parent == nil && !$0.value.logged && [.todo, .inProgress].contains($0.value.status) }.keys)
            let laterIDs = Set(taskPage.rows(for: .backlog).map(\.id))
            let expectedLater = Set(taskValues.filter { $0.value.parent == nil && !$0.value.logged && $0.value.status == .backlog }.keys)
            if nowIDs != expectedNow || laterIDs != expectedLater { return (index, "\(label): visible task rows mismatch") }
            taskPage.loadDoneLogIfNeeded()
            let expectedDone = Set(taskValues.filter { $0.value.parent == nil && $0.value.logged && (query.isEmpty || $0.value.title.contains(query)) }.keys)
            if Set(taskPage.doneLogTasks.map(\.id)) != expectedDone { return (index, "\(label): Done query rows mismatch") }
            guard let session = notePage.active else { return (index, "\(label): expected Notes session missing") }
            let value = noteValues[activeNote], document = session.engine.document()
            guard document.blocks.count >= 2 else { return (index, "\(label): expected Notes body missing") }
            if session.noteID != noteIDs[activeNote] || document.title != "Note \(activeNote)" || document.blocks[1].text != value.body
                || (document.blocks[1].style == "heading") != value.heading || session.engine.tags != value.tags
                || document.blocks.first(where: { $0.kind == .table })?.table?.texts != [["header"], [value.cell]] {
                return (index, "\(label): visible note text/style/tags/table mismatch")
            }
            let actualCenters = Dictionary(uniqueKeysWithValues: canvas.semanticObjects.map { ($0.id, $0.transform.center) })
            if actualCenters != canvasCenters || canvas.canUndo != !canvasUndo.isEmpty || canvas.canRedo != !canvasRedo.isEmpty {
                return (index, "\(label): Canvas contents/history mismatch")
            }
            if canvas.selectedImageID != nil { return (index, "\(label): Canvas selected wrong object kind") }
            if let selected = canvas.selectedSemanticObjectID, canvasCenters[selected] == nil {
                return (index, "\(label): Canvas selected missing object")
            }
        }
        guard await notePage.preserveAllDurably() else { return (steps.count, "final preserve refused") }
        canvas.flushViewState()
        await notes.waitForAttachmentReconciliation()
        return nil
    }

    func testLongGeneratedReachableCommandsAgreeAfterEveryStep() async throws {
        for seed in 1...12 {
            var random = Random(state: UInt64(seed))
            let steps = (0..<192).map { index in Step(kind: index < 21 ? index : random.next(21), choice: random.next(10_000)) }
            if let failure = try await replay(steps) {
                var minimal = Array(steps.prefix(min(steps.count, failure.0 + 1)))
                var chunk = max(1, minimal.count / 2)
                while chunk > 0 {
                    var start = 0
                    while start < minimal.count {
                        var candidate = minimal
                        candidate.removeSubrange(start..<min(start + chunk, candidate.count))
                        if !candidate.isEmpty, (try await replay(candidate)) != nil { minimal = candidate; start = 0 }
                        else { start += chunk }
                    }
                    chunk = chunk == 1 ? 0 : max(1, chunk / 2)
                }
                XCTFail("seed=\(seed) \(failure.1), minimal=\(minimal)")
                return
            }
        }
    }

    func testRealShellSynchronousNotesLeaveAndReturnAcrossGeneratedNeighbours() async throws {
        for seed in 1...8 {
            let root = ownedTemporaryDirectory(prefix: "H9ShellFlows")
            let suite = "H9Shell." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let notes = NoteStore(container: container,
                attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            let tasks = TaskStore(container: container)
            let canvases = CanvasStore(container: container)
            let canvas = CanvasSession(store: canvases)
            let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
            let taskPage = TasksPageModel(library: library)
            let id = try notes.createDocumentNote(id: UUID(), document: .init(blocks: [.text("Shell"), .text("Body")])).get().noteID
            let facade = NoteDraftController(noteStore: notes, sessionDefaults: defaults,
                recoveryURL: root.appendingPathComponent("RecoveryAnchor"))
            await facade.pages.startAndWait()
            await XCTAssertTrueAsync(await facade.pages.openDurably(noteID: id))
            let ui = PanelUIState()
            ui.selectSection(.notes); ui.loadPageContent()
            let settings = AppSettings(defaults: defaults)
            settings.animations = .reduced
            let view = AtticPanelView(store: tasks, noteStore: notes, canvasSession: canvas,
                noteDraft: facade, chromeInteractionState: PanelChromeInteractionState(), uiState: ui,
                settings: settings, subtaskPanels: SubtaskPanelController(store: tasks, uiState: ui, settings: settings))
            var random = Random(state: UInt64(seed))
            var expectedBody = "Body", expectedTags: [String] = []
            var expectedBuilt: Set<PanelPage> = [.notes]
            var expectedPresentations = facade.pages.presentationCount
            var expectedTasks: Set<UUID> = []
            var expectedShapes: Set<UUID> = []
            for cycle in 0..<32 {
                let engine = try XCTUnwrap(facade.pages.active?.engine)
                let suffix = "x\(random.next(10))"
                XCTAssertTrue(engine.performEdit(NSRange(location: 6 + expectedBody.utf16.count, length: 0),
                    with: NSAttributedString(string: suffix, attributes: engine.attributes(forParagraphAt: 6)), name: "Typing"))
                expectedBody += suffix
                expectedTags = ["tag\(random.next(4))"]
                engine.setTagsFromPicker(expectedTags)
                XCTAssertEqual(engine.document().blocks.map(\.text), ["Shell", expectedBody])
                XCTAssertEqual(engine.tags, expectedTags)
                let target: PanelSection = random.next(2) == 0 ? .tasks : .canvas
                // Call the real shell entry, not a reproduced leave sequence.
                // This view is never installed in a window or rendered.
                view.selectSection(target)
                expectedBuilt.remove(.notes); expectedBuilt.insert(PanelPage(target))
                XCTAssertEqual(ui.selectedSection, target)
                XCTAssertEqual(ui.builtPages, expectedBuilt)
                XCTAssertEqual(ui.primaryInputFocusRequest, 0)
                XCTAssertEqual(facade.pages.presentationCount, expectedPresentations)
                XCTAssertEqual(facade.pages.active?.noteID, id)
                XCTAssertEqual(facade.pages.active?.engine.document().blocks.map(\.text), ["Shell", expectedBody])
                if target == .tasks {
                    taskPage.addBar = TaskAddBarText(text: "Shell neighbour \(cycle)")
                    let added = try XCTUnwrap(taskPage.submitAddBar())
                    expectedTasks.insert(added)
                    XCTAssertTrue(taskPage.toggleDone([added]).isApplied)
                    XCTAssertTrue(taskPage.toggleDone([added]).isApplied)
                    XCTAssertEqual(Set(taskPage.rows(for: .now).map(\.id)), expectedTasks)
                } else {
                    XCTAssertTrue(canvas.insertShape(.rectangle, from: .zero, to: .init(x: 80, y: 60)))
                    let added = try XCTUnwrap(canvas.selectedSemanticObjectID)
                    expectedShapes.insert(added)
                    XCTAssertTrue(canvas.undo()); XCTAssertTrue(canvas.redo())
                    XCTAssertEqual(Set(canvas.semanticObjects.map(\.id)), expectedShapes)
                }
                view.selectSection(.notes)
                expectedBuilt.insert(.notes); expectedPresentations += 1
                XCTAssertEqual(ui.selectedSection, .notes)
                XCTAssertEqual(ui.builtPages, expectedBuilt)
                XCTAssertEqual(ui.primaryInputFocusRequest, 0)
                XCTAssertEqual(facade.pages.presentationCount, expectedPresentations)
                XCTAssertEqual(facade.pages.active?.noteID, id)
                XCTAssertEqual(facade.pages.active?.engine.document().blocks.map(\.text), ["Shell", expectedBody])
                XCTAssertEqual(facade.pages.active?.engine.tags, expectedTags)
                XCTAssertNil(facade.pages.active?.notice, "seed=\(seed), cycle=\(cycle)")
            }
            await XCTAssertTrueAsync(await facade.pages.preserveAllDurably())
            let fresh = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
            XCTAssertEqual(fresh.content.flatMap { NoteContentCodec.decode($0).document }?.blocks.map(\.text), ["Shell", expectedBody])
            XCTAssertEqual(fresh.tags, expectedTags)
            await facade.pages.waitForRecoveryWork()
            await notes.waitForAttachmentReconciliation()
        }
    }

    func testReachableHistoryRestoreProposalAndCrossFeatureNeighbours() async throws {
        for seed in 1...8 {
            let root = ownedTemporaryDirectory(prefix: "H9ReviewFlows")
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let files = makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files"))
            let notes = NoteStore(container: container, attachmentFileStore: files)
            let tasks = TaskStore(container: container)
            let canvases = CanvasStore(container: container)
            let library = AtticLibrary(tasks: tasks, notes: notes, canvases: canvases)
            let taskPage = TasksPageModel(library: library)
            let canvas = CanvasSession(store: canvases)
            let initial = NoteDocument(blocks: [.text("Original"), .text("Body"),
                .table(NoteTable(texts: [["heading"], ["cell"]]))])
            let id = try notes.createDocumentNote(id: UUID(), document: initial).get().noteID
            XCTAssertTrue(notes.recordVersion(noteID: id, reason: .leave))
            let originalVersionID = try XCTUnwrap(notes.versions(noteID: id).first?.id)
            let page = NotesPageController(store: notes,
                journal: NoteDraftJournal(directory: root.appendingPathComponent("Recovery")),
                saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
            await page.startAndWait()
            await XCTAssertTrueAsync(await page.openDurably(noteID: id))
            var expectedBody = "Body"
            var random = Random(state: UInt64(seed))
            for cycle in 0..<12 {
                let engine = try XCTUnwrap(page.active?.engine)
                let suffix = "x\(random.next(10))"
                let range = NSRange(location: "Original".utf16.count + 1 + expectedBody.utf16.count, length: 0)
                XCTAssertTrue(engine.performEdit(range, with: NSAttributedString(string: suffix,
                    attributes: engine.attributes(forParagraphAt: "Original".utf16.count + 1)), name: "Typing"))
                expectedBody += suffix
                let tags = ["tag\(seed)", "cycle\(cycle)"].sorted()
                var expectedTags = tags
                engine.setTagsFromPicker(tags)
                await XCTAssertTrueAsync(await page.prepareToLeaveDurably(.pageSwitch))
                // Nearby Tasks/Canvas commands must not consume note history,
                // close its draft, or change its text/tags/table on return.
                taskPage.addBar = TaskAddBarText(text: "Neighbour \(cycle)")
                XCTAssertNotNil(taskPage.submitAddBar())
                XCTAssertTrue(canvas.insertShape(.rectangle, from: .zero, to: .init(x: 80, y: 60)))
                XCTAssertTrue(canvas.undo()); XCTAssertTrue(canvas.redo())
                await XCTAssertTrueAsync(await page.openDurably(noteID: id))
                XCTAssertEqual(page.active?.engine.document().blocks[1].text, expectedBody)
                XCTAssertEqual(page.active?.engine.tags, tags)
                XCTAssertEqual(page.active?.engine.document().blocks.first { $0.kind == .table }?.table?.texts,
                    [["heading"], ["cell"]])

                await XCTAssertTrueAsync(await page.openHistoryDurably())
                let browser = try XCTUnwrap(page.historyBrowser)
                let version = try XCTUnwrap(browser.entries.firstIndex { $0.id == originalVersionID })
                page.selectHistoryVersion(version)
                await XCTAssertTrueAsync(await page.restoreHistoryVersionDurably())
                XCTAssertNil(page.historyBrowser)
                XCTAssertEqual(page.active?.engine.document().blocks[1].text, "Body")
                XCTAssertEqual(page.active?.engine.tags, tags)
                await XCTAssertTrueAsync(await page.undoVersionRestoreDurably(expectedID: page.versionRestoreUndoID))
                XCTAssertEqual(page.active?.engine.document().blocks[1].text, expectedBody)
                XCTAssertEqual(page.active?.engine.tags, tags)

                let proposedBody = "Proposed \(seed) \(cycle)"
                var proposed = initial
                proposed.blocks[1].text = proposedBody
                let revision = try XCTUnwrap(notes.note(withID: id)).revisionToken
                guard case let .success(.pending(proposal)) = notes.agentWrite(noteID: id,
                    baseRevisionToken: revision, document: proposed, agentName: "Review fixture", disposition: .proposal) else {
                    return XCTFail("Could not create a valid incoming proposal")
                }
                await XCTAssertTrueAsync(await page.beginProposalReview(id: proposal))
                XCTAssertEqual(page.proposalReview?.current.blocks[1].text, expectedBody)
                XCTAssertEqual(page.proposalReview?.proposed.blocks[1].text, proposedBody)
                if random.next(2) == 0 {
                    XCTAssertTrue(page.discardReviewedProposal())
                } else {
                    // A real picker edit after review requires a refreshed
                    // comparison before acceptance. No stale snapshots passed.
                    let newerTags = (tags + ["reviewed"]).sorted()
                    expectedTags = newerTags
                    page.active?.engine.setTagsFromPicker(newerTags)
                    await XCTAssertFalseAsync(await page.acceptProposal())
                    XCTAssertNotNil(page.proposalReviewNotice)
                    XCTAssertEqual(page.active?.engine.document().blocks[1].text, expectedBody)
                    await XCTAssertTrueAsync(await page.acceptProposal())
                    expectedBody = proposedBody
                    XCTAssertEqual(page.active?.engine.tags, newerTags)
                }
                XCTAssertNil(page.proposalReview)
                XCTAssertNil(page.proposalReviewNotice)
                XCTAssertTrue(notes.pendingEdits(noteID: id).isEmpty)
                XCTAssertEqual(page.active?.engine.document().blocks[1].text, expectedBody)
                await XCTAssertTrueAsync(await page.preserveAllDurably())
                let readback = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<NoteItem>()).first { $0.id == id })
                XCTAssertEqual(readback.content.flatMap { NoteContentCodec.decode($0).document }?.blocks[1].text, expectedBody)
                XCTAssertEqual(readback.tags, expectedTags)
            }
            await notes.waitForAttachmentReconciliation()
        }
    }

    func testAUserChosenInvalidCanvasImageHasADismissibleErrorAndKeepsEditing() async throws {
        let store = try makeTestCanvasStore()
        let session = CanvasSession(store: store)
        let root = ownedTemporaryDirectory(prefix: "H9ImageError")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("broken.png")
        try Data("this image is damaged".utf8).write(to: url)
        await XCTAssertFalseAsync(await session.importImage(url: url, at: .zero))
        XCTAssertNotNil(session.lastErrorMessage)
        XCTAssertTrue(session.images.isEmpty)
        session.dismissErrorMessage()
        XCTAssertNil(session.lastErrorMessage)
        XCTAssertTrue(session.insertShape(.rectangle, from: .zero, to: .init(x: 80, y: 60)))
        XCTAssertEqual(session.semanticObjects.count, 1)
        XCTAssertNil(session.lastErrorMessage)
    }

    private func leaveUserDraftAfterFailedSave(_ root: URL, bytes: Data) async throws -> (UUID, UUID) {
        let container = try PersistenceController.makeContainer(cloudSyncEnabled: false,
            storeDirectory: root.appendingPathComponent("Store"))
        let gate = PersistenceGate()
        let store = NoteStore(container: container, persist: gate.save,
            attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
        let id = try store.createDocumentNote(id: UUID(),
            document: .init(blocks: [.text("Original"), .text("Saved")])).get().noteID
        let page = NotesPageController(store: store,
            journal: NoteDraftJournal(directory: root.appendingPathComponent("Recovery")),
            saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
        await page.startAndWait()
        await XCTAssertTrueAsync(await page.openDurably(noteID: id))
        let engine = try XCTUnwrap(page.active?.engine)
        let end = engine.textStorage.length
        XCTAssertTrue(engine.performEdit(NSRange(location: end, length: 0),
            with: NSAttributedString(string: " latest", attributes: engine.attributes(forParagraphAt: 9)), name: "Typing"))
        engine.setTagsFromPicker(["recovery"])
        let source = root.appendingPathComponent("source.txt")
        try bytes.write(to: source)
        gate.shouldFail = true
        page.importFiles([source], at: NSRange(location: engine.textStorage.length, length: 0))
        await page.waitForImportWork()
        let fileID = try XCTUnwrap(engine.document().attachmentIDs.first)
        // A real disk-write failure reaches this branch via the same save
        // callback. Do not call journal writes or pass captured snapshots.
        await XCTAssertTrueAsync(await page.prepareToLeaveDurably(.hide))
        XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks[1].text, "Saved")
        XCTAssertTrue(page.canSaveRecoveryCopy(page.active))
        let export = root.appendingPathComponent("Recovery export")
        page.recoveryCopyDestination = { _ in export }
        await XCTAssertTrueAsync(await page.saveRecoveryCopy())
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path))
        XCTAssertNotNil(page.active?.notice)
        await page.waitForRecoveryWork()
        await store.waitForAttachmentReconciliation()
        // Returning only IDs releases every presentation/controller/context;
        // the next phase reconstructs the ordinary services from disk.
        return (id, fileID)
    }

    func testReachableFailedSaveRecoveryRetainsTypedTextTagsAndImportedFileAcrossRestart() async throws {
        for _ in 0..<6 {
            let root = ownedTemporaryDirectory(prefix: "H9StartupRecovery")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = Data("the user's imported file".utf8)
            let (id, fileID) = try await leaveUserDraftAfterFailedSave(root, bytes: bytes)
            let container = try PersistenceController.makeContainer(cloudSyncEnabled: false,
                storeDirectory: root.appendingPathComponent("Store"))
            let store = NoteStore(container: container,
                attachmentFileStore: makeTestAttachmentFileStore(rootURL: root.appendingPathComponent("Files")))
            let page = NotesPageController(store: store,
                journal: NoteDraftJournal(directory: root.appendingPathComponent("Recovery")),
                saveDelay: .seconds(600), durabilityDelay: .seconds(600), pauseVersionDelay: .seconds(600))
            await page.startAndWait()
            await XCTAssertTrueAsync(await page.openDurably(noteID: id))
            let engine = try XCTUnwrap(page.active?.engine)
            XCTAssertEqual(engine.document().blocks[1].text, "Saved latest")
            XCTAssertEqual(engine.tags, ["recovery"])
            XCTAssertEqual(engine.document().attachmentIDs, [fileID])
            // Launch recovery saves an admissible draft before opening it.
            // Check the user-facing file lookup rather than transient staging.
            let attachment = try XCTUnwrap(store.attachmentFamily(fileID).first)
            XCTAssertEqual(attachment.noteID, id)
            let openedURL = await store.materializedURL(for: attachment)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(openedURL)), bytes)
            await XCTAssertTrueAsync(await page.preserveAllDurably())
            XCTAssertEqual(store.loadDocument(noteID: id)?.content.document?.blocks[1].text, "Saved latest")
            XCTAssertEqual(store.note(withID: id)?.tags, ["recovery"])
            XCTAssertEqual(store.attachmentFamily(fileID).first?.payload, bytes)
            await page.waitForRecoveryWork()
            await store.waitForAttachmentReconciliation()
            XCTAssertTrue(page.recoveryWarnings.isEmpty)
        }
    }
    func testUserTaskSaveFailuresKeepInputBlockLeavingAndRetryThroughTheSameCommand() throws {
        for iteration in 0..<12 {
            let gate = PersistenceGate()
            let store = try makeTestStore(persist: gate.save)
            let page = TasksPageModel(library: AtticLibrary(tasks: store))
            page.addBar = TaskAddBarText(text: "Keep my task \(iteration)")
            let before = page.addBar
            gate.shouldFail = true
            XCTAssertNil(page.submitAddBar())
            XCTAssertEqual(page.addBar, before)
            XCTAssertTrue(store.tasks.isEmpty)
            XCTAssertFalse(try XCTUnwrap(store.lastErrorMessage).isEmpty)
            gate.shouldFail = false
            let parent = try XCTUnwrap(page.submitAddBar())
            XCTAssertNil(store.lastErrorMessage)
            XCTAssertEqual(store.tasks.map(\.title), [before.text])
            page.beginAddingSubtask(to: parent)
            page.newSubtaskTitle = "Keep my child \(iteration)"
            gate.shouldFail = true
            XCTAssertFalse(page.commitNewSubtask())
            XCTAssertEqual(page.newSubtaskTitle, "Keep my child \(iteration)")
            XCTAssertTrue(page.hasUnsavedEdit)
            XCTAssertFalse(try XCTUnwrap(store.lastErrorMessage).isEmpty)
            page.select(tab: .backlog)
            XCTAssertEqual(page.tab, .now, "A failed save must keep the current editor")
            XCTAssertEqual(page.newSubtaskParentID, parent)
            XCTAssertTrue(store.subtasks(of: parent).isEmpty)
            gate.shouldFail = false
            page.select(tab: .backlog)
            XCTAssertEqual(page.tab, .backlog)
            XCTAssertFalse(page.hasUnsavedEdit)
            XCTAssertNil(store.lastErrorMessage)
            XCTAssertEqual(store.subtasks(of: parent).map(\.title), ["Keep my child \(iteration)"])
        }
    }

    func testReachableImageAndShapeSelectionNudgesUndoRedoAndFreshReadback() async throws {
        let root = ownedTemporaryDirectory(prefix: "H9CanvasUserFlow")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent("chosen.png")
        try bytes.write(to: url)
        for seed in 1...8 {
            let store = try makeTestCanvasStore()
            var session: CanvasSession? = CanvasSession(store: store)
            var expected: [UUID: CanvasPoint] = [:]
            var undo: [[UUID: CanvasPoint]] = [], redo: [[UUID: CanvasPoint]] = []
            await XCTAssertTrueAsync(await session!.importImage(url: url, at: .zero))
            let imageID = try XCTUnwrap(session!.selectedImageID)
            undo.append(expected); expected[imageID] = .zero
            XCTAssertTrue(session!.insertShape(.rectangle, from: .zero, to: .init(x: 80, y: 60)))
            let shapeID = try XCTUnwrap(session!.selectedSemanticObjectID)
            undo.append(expected); expected[shapeID] = .init(x: 40, y: 30)
            var random = Random(state: UInt64(seed))
            for step in 0..<64 {
                let live = try XCTUnwrap(session)
                XCTAssertEqual(live.viewport.scale, 1)
                switch random.next(4) {
                case 0 where expected[imageID] != nil:
                    // The real surface selects first, then nudges the selected image.
                    live.selectImage(imageID)
                    let before = expected
                    XCTAssertTrue(live.nudgeSelectedImage(viewDelta: .init(width: 5, height: 0)))
                    expected[imageID]!.x += 5; undo.append(before); redo = []
                case 1 where expected[shapeID] != nil:
                    live.selectSemanticObject(shapeID)
                    let before = expected
                    XCTAssertTrue(live.nudgeSelectedSemanticObject(.init(width: 10, height: 0)))
                    expected[shapeID]!.x += 10; undo.append(before); redo = []
                case 2:
                    XCTAssertEqual(live.undo(), !undo.isEmpty)
                    if let previous = undo.popLast() { redo.append(expected); expected = previous }
                case 3:
                    XCTAssertEqual(live.redo(), !redo.isEmpty)
                    if let next = redo.popLast() { undo.append(expected); expected = next }
                default: break // No object on screen to select; no command is sent.
                }
                let actual = Dictionary(uniqueKeysWithValues:
                    live.images.map { ($0.id, $0.transform.center) } + live.semanticObjects.map { ($0.id, $0.transform.center) })
                XCTAssertEqual(actual, expected, "seed=\(seed), step=\(step)")
                XCTAssertEqual(live.canUndo, !undo.isEmpty); XCTAssertEqual(live.canRedo, !redo.isEmpty)
                XCTAssertFalse(live.selectedImageID != nil && live.selectedSemanticObjectID != nil)
                if let id = live.selectedImageID { XCTAssertNotNil(expected[id]) }
                if let id = live.selectedSemanticObjectID { XCTAssertNotNil(expected[id]) }
                XCTAssertNil(live.lastErrorMessage)
            }
            session!.flushViewState()
            session = nil
            // Readback only: no mutation through a competing store facade.
            let reopened = CanvasSession(store: CanvasStore(container: store.container))
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:
                reopened.images.map { ($0.id, $0.transform.center) } + reopened.semanticObjects.map { ($0.id, $0.transform.center) }), expected)
        }
    }

}
