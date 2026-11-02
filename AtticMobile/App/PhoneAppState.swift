import Foundation
import SwiftData
import SwiftUI

/// Screens use the shared transaction services, so a failed save never leaves
/// a speculative row in the interface. Every refresh opens new read contexts.
@MainActor
final class PhoneAppState: ObservableObject {
    @Published private(set) var tasks: [PhoneLibrary.TaskRow] = []
    @Published private(set) var notes: [PhoneLibrary.NoteRow] = []
    @Published private(set) var canvases: [DrawCanvas] = []
    @Published private(set) var loaded = false
    @Published var errorMessage: String?

    let library: PhoneLibrary
    let draw: DrawPersistentStore

    init(container: ModelContainer) {
        library = PhoneLibrary(container: container)
        draw = DrawPersistentStore(container: container)
        refresh()
    }

    func refresh() {
        do {
            let newTasks = try library.tasks()
            let newNotes = try library.notes()
            let newCanvases = try draw.library()
            tasks = newTasks
            notes = newNotes
            canvases = newCanvases
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
            loaded = true
        }
    }

    @discardableResult
    func change(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createTask(_ title: String, priority: TaskPriority = .none, dueDay: DueDay? = nil,
                    status: TaskStatus = .todo, tags: [String] = []) -> Bool {
        change { _ = try library.createTask(title: title, priority: priority, status: status,
                                            dueDay: dueDay, tags: tags) }
    }

    @discardableResult
    func createNote(_ title: String, body: String, pinned: Bool = false, tags: [String] = []) -> Bool {
        change { _ = try library.createNote(title: title, body: body, tags: tags, pinned: pinned) }
    }
}

/// Test and demonstration content is installed only in the owner's dedicated
/// overnight Simulator. Other devices begin with their own empty local store.
enum PhoneSampleSeed {
    static let markerKey = "AtticOvernightSyntheticSeed.v1"

    @MainActor
    static func installIfNeeded(container: ModelContainer, enabled: Bool,
                                defaults: UserDefaults = .standard, clock: Date = Date()) throws {
        guard enabled && !defaults.bool(forKey: markerKey) else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // A crash after saving the rows, before marking them as seeded, must
        // never double-import the examples into a persistent store.
        guard try context.fetch(FetchDescriptor<TaskItem>()).isEmpty,
              try context.fetch(FetchDescriptor<NoteItem>()).isEmpty else {
            defaults.set(true, forKey: markerKey)
            return
        }

        let calendar = Calendar.autoupdatingCurrent
        func date(_ offset: Int) -> DueDay? {
            calendar.date(byAdding: .day, value: offset, to: clock).map { DueDay(date: $0, calendar: calendar) }
        }
        let examples: [(String, Int?, TaskPriority, TaskStatus, [String])] = [
            ("Review the prototype", -1, .high, .todo, ["project"]),
            ("Check the iPhone layout", 0, .high, .todo, ["project"]),
            ("Prepare sprint notes", 0, .none, .todo, ["project"]),
            ("Send feedback", 1, .medium, .todo, ["team"]),
            ("Plan the next release", 3, .none, .todo, ["project"]),
            ("Organise design references", nil, .none, .todo, ["design"]),
            ("Read about SwiftUI", nil, .none, .backlog, ["learning"]),
            ("Set up the test project", -2, .none, .done, ["project"])
        ]
        for (index, example) in examples.enumerated() {
            let stamp = clock.addingTimeInterval(Double(-examples.count + index) * 300)
            let row = TaskItem(title: example.0, status: example.3, priority: example.2,
                               createdAt: stamp, completedAt: example.3 == .done ? stamp : nil)
            row.manualOrder = Int64(examples.count - index) * 1024
            row.dueDay = example.1.flatMap(date)
            row.tags = example.4
            context.insert(row)
        }
        for (index, item) in [
            ("A few ideas", "Keep the interface simple and let the content lead.", true, ["design"]),
            ("Release checklist", "Test on the dedicated iPhone Simulator.\nReview tasks and notes.\nCompare light and dark appearance.", true, ["project"]),
            ("Morning review", "Look through the latest build and record the differences.", false, ["project"]),
            ("Reading list", "Native iOS interaction patterns\nTextKit 2 editing\nAccessibility", false, ["learning"])
        ].enumerated() {
            let stamp = clock.addingTimeInterval(Double(-index) * 1800)
            let note = NoteItem(title: item.0, body: item.1, createdAt: stamp)
            note.pinnedAt = item.2 ? stamp : nil
            note.tags = item.3
            context.insert(note)
        }
        try context.save()
        defaults.set(true, forKey: markerKey)
    }
}
