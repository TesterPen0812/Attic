import Foundation
import SwiftData

/// The preview's seeded entry point for a task's note (Phase 3 slice 0b): a
/// developer/test entry confined to the in-memory UI-testing store. It is not
/// a production entry point (those ship in slice 1).
///
/// `ATTIC_UI_TESTING=1 ATTIC_UI_TEST_SEED=tasknote` seeds the fixtures;
/// `ATTIC_UI_TEST_TASK_NOTE=<scenario>` opens one over the Notes page.
enum TaskNotePreviewSeed {
    enum Scenario: String, CaseIterable {
        /// `p3-21`: a two-line title with !!, a date and two tags; ten
        /// subtasks, four done; a research paragraph.
        case heavy
        /// `p3-20` 2b: two subtasks, then two paragraphs.
        case boundary
        /// The long seeded prose note (5,000 lines) with three subtasks.
        case long
        /// The long prose note with 50 subtasks, unfolded.
        case fifty
        /// A task with no note: opening it creates nothing.
        case nonote
    }

    /// The seeded task of each scenario (this process).
    nonisolated(unsafe) private(set) static var seeded: [Scenario: UUID] = [:]

    /// The scenario a UI-testing launch asks to open.
    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Scenario? {
        guard environment["ATTIC_UI_TESTING"] == "1" else { return nil }
        return environment["ATTIC_UI_TEST_TASK_NOTE"].flatMap(Scenario.init(rawValue:))
    }

    /// The long prose note's lines: the same shape as the engine's 5,000-line
    /// stress note, so the composed and plain measurements compare like for
    /// like.
    static func longProse(lines: Int = 5_000) -> [NoteBlock] {
        (0..<lines).map { .text("Line \($0) with some ordinary words to wrap a little in a narrow panel.") }
    }

    @MainActor
    static func seedAll(in container: ModelContainer, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws {
        for scenario in Scenario.allCases { seeded[scenario] = try seed(scenario, in: container, now: now, calendar: calendar) }
        // The 50-subtask scenario is measured unfolded.
        if let fifty = seeded[.fifty] { UserDefaults.standard.set(false, forKey: TaskNotePageModel.foldKey(fifty)) }
    }

    /// Writes one scenario's task, subtasks and (except `nonote`) its own
    /// note in the stored task-note form (§ 2.12: block 0 is the title
    /// snapshot, `requires` holds `taskNote`). Returns the task's id.
    @MainActor
    @discardableResult
    static func seed(_ scenario: Scenario, in container: ModelContainer, now: Date = Date(),
                     calendar: Calendar = .autoupdatingCurrent) throws -> UUID {
        let context = ModelContext(container)
        var order: Int64 = 1_000 * 1_024
        func task(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none, due: DueDay? = nil,
                  tags: [String] = [], parent: UUID? = nil) -> TaskItem {
            order -= 1_024
            let item = TaskItem(title: title, status: status, priority: priority, createdAt: now.addingTimeInterval(-86_400),
                                completedAt: status == .done ? now : nil, manualOrder: order, parentID: parent)
            item.dueDay = due
            item.tags = tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
            return item
        }
        let today = DueDay(date: now, calendar: calendar)
        let parent: TaskItem
        var body: [NoteBlock] = []
        switch scenario {
        case .heavy:
            let friday = calendar.date(byAdding: .day, value: 4, to: now).map { DueDay(date: $0, calendar: calendar) }
            parent = task("Launch the new website and blog", .inProgress, .high, due: friday, tags: ["launch", "web"])
            let titles = ["Freeze the homepage copy", "Pick the hosting plan", "Point DNS at the new host", "Export the blog posts",
                          "Migrate images", "Redirect old URLs", "Security review", "Accessibility pass",
                          "Load test the checkout", "Announce the launch"]
            for (index, title) in titles.enumerated() { _ = task(title, index < 4 ? .done : .todo, parent: parent.id) }
            var heading = NoteBlock.text("Research")
            heading.style = "heading"
            heading.level = 2
            body = [heading, .text("Static hosting wins on cost: about €9 a month against €40 for the current server. The redirect map covers all 212 old posts; Sam has the export.")]
        case .boundary:
            parent = task("Finalize launch checklist", .inProgress, .high, due: today, tags: ["launch"])
            _ = task("Freeze strings", .done, parent: parent.id)
            _ = task("Write release notes", parent: parent.id)
            body = [.text("Everything that has to be true before 1.0 goes out."),
                    .text("Sam owns the pricing page; I take the checklist.")]
        case .long:
            parent = task("Read the long note", .todo, .medium, tags: ["long"])
            for index in 1...3 { _ = task("Subtask \(index)", parent: parent.id) }
            body = longProse()
        case .fifty:
            parent = task("Fifty subtasks over a long note", .todo, .none, tags: ["stress"])
            for index in 1...50 { _ = task("Subtask \(index) with a few words", index % 5 == 0 ? .done : .todo, parent: parent.id) }
            body = longProse()
        case .nonote:
            parent = task("A task with no note yet", .todo, .none)
            _ = task("One subtask", parent: parent.id)
        }
        if scenario != .nonote {
            let note = NoteItem(id: UUID())
            note.taskID = parent.id
            let document = try NoteDocument(blocks: [.text(parent.title)] + body).taskSnapshot(title: parent.title)
            NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: now,
                                           revision: 0, revisionID: UUID())
            context.insert(note)
            context.insert(TaskNoteAssociation(taskID: parent.id, noteID: note.id))
        }
        try context.save()
        return parent.id
    }
}
