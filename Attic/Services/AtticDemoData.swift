import AppKit
import Foundation
import SwiftData

/// Realistic content for preview builds (owner, 2026-10-01), so a fresh
/// preview identity opens on something to look at: Now, Later and Done
/// with subtasks, tags, dates (overdue, today, future), every priority and a
/// task in progress; a few Done days; and notes with formatting, a
/// checklist, an image and a file.
///
/// Only ever written into a `com.taha.Attic.preview.*` identity's own store
/// (its own sandbox container): on its first launch while that store is
/// empty, or through the menu's preview-only Load Demo Data. Never under
/// `com.taha.Attic`, never into an in-memory, UI-test, performance or
/// gallery store. Every item has a fixed id, so loading twice adds nothing
/// twice (a demo item already there is left as it is).
@MainActor
enum AtticDemoData {
    static let officialBundleIdentifier = "com.taha.Attic"
    static let previewPrefix = "com.taha.Attic.preview."
    /// Set in the preview identity's own defaults once it has been seeded
    /// on first launch (Load Demo Data still works afterwards).
    static let seededKey = "AtticPreviewDemoDataSeeded"

    /// A preview identity, and nothing else: not the official identity, not
    /// another Attic identity, whatever its arguments.
    nonisolated static func isAllowed(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, bundleIdentifier != officialBundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix(previewPrefix) && bundleIdentifier.count > previewPrefix.count
    }

    // MARK: Ids

    /// The demo items' fixed ids (`A771C0DE-…-index`).
    nonisolated static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "A771C0DE-0000-4000-8000-%012X", index))!
    }

    nonisolated static func isDemo(_ id: UUID) -> Bool {
        id.uuidString.hasPrefix("A771C0DE-0000-4000-8000-")
    }

    // MARK: Seeding

    /// Whether the store holds no task and no note yet (first launch).
    static func storeIsEmpty(_ container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        let tasks = (try? context.fetchCount(FetchDescriptor<TaskItem>())) ?? 1
        let notes = (try? context.fetchCount(FetchDescriptor<NoteItem>())) ?? 1
        return tasks == 0 && notes == 0
    }

    /// Inserts the demo tasks and notes that are not there yet, in one save.
    /// Returns how many items were added.
    @discardableResult
    static func seed(into container: ModelContainer, bundleIdentifier: String?, now: Date = Date(),
                     calendar: Calendar = .autoupdatingCurrent) throws -> Int {
        guard isAllowed(bundleIdentifier: bundleIdentifier) else { return 0 }
        let context = ModelContext(container)
        let existingTasks = Set(try context.fetch(FetchDescriptor<TaskItem>()).map(\.id))
        let existingNotes = Set(try context.fetch(FetchDescriptor<NoteItem>()).map(\.id))
        var added = 0
        var order: Int64 = 200 * 1_024
        var index = 0
        func day(_ offset: Int) -> DueDay? {
            calendar.date(byAdding: .day, value: offset, to: now).map { DueDay(date: $0, calendar: calendar) }
        }
        @discardableResult
        func task(_ title: String, _ status: TaskStatus = .todo, _ priority: TaskPriority = .none, due: DueDay? = nil,
                  tags: [String] = [], parent: UUID? = nil, completed: Date? = nil, logged: Bool = false) -> UUID {
            index += 1
            order -= 1_024
            let id = Self.id(index)
            guard !existingTasks.contains(id) else { return id }
            let item = TaskItem(id: id, title: title, status: status, priority: priority,
                                createdAt: now.addingTimeInterval(-86_400 * 4), completedAt: completed,
                                manualOrder: order, parentID: parent)
            item.dueDay = due
            item.tags = AtticTag.normalizedSet(tags)
            item.listOrderVersion = TaskItem.currentListOrderVersion
            if logged { item.doneLoggedAt = completed ?? now }
            context.insert(item)
            added += 1
            return id
        }

        // Now: one in progress, every priority, overdue, today and later.
        let launch = task("Finalize launch checklist", .inProgress, .high, due: day(0), tags: ["launch"])
        task("Freeze strings", .done, parent: launch, completed: now)
        task("Write release notes", parent: launch)
        task("Tag the build", parent: launch)
        let ship = task("Ship the appearance PR", .todo, .high, tags: ["work"])
        task("Review contrast", .done, parent: ship, completed: now)
        task("Record the preview", .done, parent: ship, completed: now)
        task("Fix the tint slider test", parent: ship)
        task("Merge", parent: ship)
        task("Pay the electricity bill", .todo, .medium, due: day(-2), tags: ["home"])
        task("Email beta testers", .todo, .medium, due: day(3), tags: ["launch"])
        task("Book dentist", .todo, .low, due: day(1))
        let roadmap = task("Draft the Q4 roadmap", .todo, .none, due: day(9), tags: ["work", "planning"])
        task("Collect team goals", parent: roadmap)
        task("Size the big bets", parent: roadmap)
        task("Share a first draft", parent: roadmap)
        task("Call the plumber")
        task("Renew passport", .todo, .low, due: day(12), tags: ["errands"])
        task("Renew the domain", .done, completed: now.addingTimeInterval(-3_600))

        // Later.
        let lisbon = task("Plan the Lisbon trip", .backlog, .medium, tags: ["travel"])
        task("Pick the dates", parent: lisbon)
        task("Find a flat near Alfama", parent: lisbon)
        task("Research note templates", .backlog, tags: ["notes"])
        task("Try the paper sketch idea", .backlog, .low)
        task("Order printer ink", .backlog)

        // Done, over a few days.
        for (offset, title, priority) in [(1, "Send the invoice", TaskPriority.none), (1, "Water the plants", .none),
                                          (2, "Call the bank", .high), (2, "Return the library books", .low),
                                          (6, "Pay rent", .medium), (40, "Renew car insurance", .none)] {
            let completed = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
            task(title, .done, priority, completed: completed, logged: true)
        }

        // Notes.
        func note(_ index: Int, _ title: String, _ body: String, age: TimeInterval) {
            let id = Self.id(1_000 + index)
            guard !existingNotes.contains(id) else { return }
            let created = now.addingTimeInterval(-age)
            context.insert(NoteItem(id: id, title: title, body: body, createdAt: created, updatedAt: created))
            added += 1
        }
        note(1, "Pricing page", Self.pricingNote, age: 3_600)
        note(2, "Moodboard", Self.moodboardNote, age: 86_400)
        note(3, "Weekend", "Farmers' market on Saturday morning.\nBike the river path if it's dry.\nCall Mum on Sunday.", age: 86_400 * 2)

        if added > 0 { try context.save() }
        return added
    }

    /// The note that carries the demo image and file.
    nonisolated static var attachmentsNoteID: UUID { id(1_002) }

    /// Imports the demo image and file into the Moodboard note, if it is
    /// there and has no attachments yet (through the note store, which
    /// copies them into its own attachment storage).
    static func attachFiles(to notes: NoteStore, bundleIdentifier: String?) async {
        guard isAllowed(bundleIdentifier: bundleIdentifier),
              notes.note(withID: attachmentsNoteID) != nil,
              notes.attachments(for: attachmentsNoteID).isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AtticDemo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent("Palette.png")
            try demoImage().write(to: image, options: .atomic)
            let file = folder.appendingPathComponent("Type specimen.txt")
            try Data(typeSpecimen.utf8).write(to: file, options: .atomic)
            _ = await notes.importAttachments(NoteAttachmentImportRequest(
                editorSession: NoteEditorSession(noteID: attachmentsNoteID, generation: 0),
                origin: .note(attachmentsNoteID),
                urls: [image, file]
            ))
        } catch {
            NSLog("Attic demo data: %@", error.localizedDescription)
        }
    }

    // MARK: Content

    static let pricingNote = """
    # Before launch
    - [x] Final copy from Sam
    - [ ] One screenshot per plan
    - [ ] Check the annual price on every page

    ## Open questions
    1. Talk to three customers
    2. Draft the **FAQ**
    - Annual plan: *two months* free?
    - Student pricing

    Simple beats clever.

        price = base * seats

    Say the same thing three ways before choosing one. The page should be read in under a minute.
    """

    static let moodboardNote = """
    Warm greys, one accent, lots of air.
    The palette and the type specimen are attached.
    """

    static let typeSpecimen = """
    SF Pro Rounded — the task list
    SF Pro — the header and Settings
    Aa Bb Cc 0123456789
    """

    /// A small palette image (four soft swatches).
    static func demoImage() throws -> Data {
        let size = 320
        guard let context = CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let swatches: [(CGFloat, CGFloat, CGFloat)] = [(0.93, 0.91, 0.88), (0.80, 0.77, 0.73), (0.55, 0.53, 0.50), (0.85, 0.45, 0.30)]
        for (index, colour) in swatches.enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(CGRect(x: index * size / 4, y: 0, width: size / 4, height: size / 2))
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
