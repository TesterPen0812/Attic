import Foundation
import SwiftData

/// "Attic Task Life" (`com.taha.Attic.preview.tasklife`, Phase 3 slice 1):
/// its fresh store opens on the task page's own samples plus one task for
/// each lifecycle state this slice adds. Written once, into the preview's
/// own empty store, in the forms the app itself writes (soft deletes with
/// their preservation records, the task-note storage form).
enum TaskNoteLifecyclePreviewSeed {
    static let bundleIdentifier = "com.taha.Attic.preview.tasklife"

    enum Sample: String, CaseIterable {
        /// Lines to try Make Subtask on: plain lines, a checked note
        /// checkbox, and a bold line that asks first.
        case makeSubtask
        /// The task works; its note is in Recently Deleted ("Write a new
        /// note" · Restore Note).
        case deletedNote
        /// The task is in Recently Deleted; its note is live (All notes
        /// opens the quiet "Task deleted · Restore" head).
        case deletedTask
        /// Two notes claim one task (S10: "Another note for this task ·
        /// Review").
        case alternateNote
        /// A note with earlier versions to preview and restore.
        case history
        /// Done today, with a note; and one already in the Done log.
        case doneToday, doneLogged
    }

    @MainActor
    @discardableResult
    static func seed(in container: ModelContainer, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) throws -> [Sample: UUID] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var order: Int64 = 2_000 * 1_024
        var ids: [Sample: UUID] = [:]
        func task(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none, tags: [String] = [],
                  parent: UUID? = nil, completed: Date? = nil) -> TaskItem {
            order -= 1_024
            let item = TaskItem(title: title, status: status, priority: priority, createdAt: now.addingTimeInterval(-3 * 86_400),
                                completedAt: status == .done ? (completed ?? now) : nil, manualOrder: order, parentID: parent)
            item.tags = tags
            item.listOrderVersion = TaskItem.currentListOrderVersion
            context.insert(item)
            return item
        }
        @discardableResult
        func note(for parent: TaskItem, body: [NoteBlock], created: Date = now) throws -> NoteItem {
            let row = NoteItem(id: UUID(), createdAt: created, updatedAt: created)
            row.taskID = parent.id
            let document = try NoteDocument(blocks: [.text(parent.title)] + body).taskSnapshot(title: parent.title)
            NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [row], timestamp: created,
                                           revision: 0, revisionID: UUID())
            context.insert(row)
            context.insert(TaskNoteAssociation(taskID: parent.id, noteID: row.id))
            return row
        }
        let yesterday = now.addingTimeInterval(-86_400)

        // Make Subtask (⌥⌘S).
        let demo = task("Prepare the launch demo", .inProgress, .medium, tags: ["launch"])
        _ = task("Book the meeting room", parent: demo.id)
        var bold = NoteBlock.text("Rehearse with the sales team")
        bold.marks = [NoteMark(.bold, offset: 0, length: 8)]
        try note(for: demo, body: [.text("Things to turn into subtasks:"), .text("Record a backup video"),
                                   .text("Print the handouts"), .checklist("Charge the clicker", checked: true), bold])
        ids[.makeSubtask] = demo.id

        // The note is in Recently Deleted.
        let offsite = task("Plan the team offsite", .todo, .none, tags: ["team"])
        _ = task("Pick three dates", parent: offsite.id)
        let deletedNote = try note(for: offsite, body: [.text("Venues near the coast; budget per head.")])
        deletedNote.deletedAt = yesterday
        ids[.deletedNote] = offsite.id

        // The task is in Recently Deleted, its note live.
        let old = task("Old pricing experiment", .todo, .low, tags: ["pricing"])
        let oldChild = task("Draft the variants", .done, parent: old.id, completed: yesterday)
        let family = [old, oldChild]
        let members = family.map(\.id.uuidString).sorted().joined(separator: " ")
        for row in family { row.deletedAt = yesterday; row.deletionRootID = old.id; row.deletionMembersRaw = members }
        try WorkspacePurge.stageDeletionCapture(rootID: old.id, rows: family, deletedAt: yesterday, in: context)
        try note(for: old, body: [.text("Results: the annual plan converted better. Keep these notes.")])
        ids[.deletedTask] = old.id

        // Two notes claim one task (S10).
        let venue = task("Venue shortlist", .todo, .none, tags: ["team"])
        try note(for: venue, body: [.text("Shortlist: the boathouse, the old mill.")], created: now.addingTimeInterval(-7_200))
        try note(for: venue, body: [.text("Written on the other Mac: the library hall is free in May.")])
        ids[.alternateNote] = venue.id

        // Earlier versions to preview and restore.
        let blog = task("Write the launch blog post", .inProgress, .high, tags: ["launch"])
        _ = task("Pick a hero image", parent: blog.id)
        let blogNote = try note(for: blog, body: [.text("Draft 3: Attic keeps your tasks and notes together."),
                                                  .text("Closing line still to write.")])
        for (index, text) in ["Draft 1: a short hello.", "Draft 2: tasks and notes, side by side."].enumerated() {
            let document = try NoteDocument(blocks: [.text(blog.title), .text(text)]).taskSnapshot(title: blog.title)
            let prepared = try PreparedNoteDocument(document)
            context.insert(NoteVersion(id: UUID(), noteID: blogNote.id,
                                       createdAt: now.addingTimeInterval(Double(index - 2) * 3_600), reason: .pause,
                                       content: prepared.content, contentFormat: document.format, title: prepared.title,
                                       body: prepared.body, attachmentIDs: [], sourceRevisionID: UUID()))
        }
        ids[.history] = blog.id

        // Done today, with a note; and one already in the Done log.
        let shipped = task("Send the beta invites", .done, .none, tags: ["launch"])
        _ = task("Write the invite email", .done, parent: shipped.id)
        try note(for: shipped, body: [.text("Sent to 40 people. Replies go to the beta inbox.")])
        ids[.doneToday] = shipped.id
        let logged = task("Order the banner", .done, .none, completed: now.addingTimeInterval(-2 * 86_400))
        logged.doneLoggedAt = yesterday
        try note(for: logged, body: [.text("Printed by Print Co., arrives Thursday.")])
        ids[.doneLogged] = logged.id

        try context.save()
        return ids
    }
}
