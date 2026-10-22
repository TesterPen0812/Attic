import Foundation
import SwiftData

/// "Attic Task Files" (`com.taha.Attic.preview.taskfiles`, Phase 3 slice 2):
/// its fresh store holds legacy-attachment tasks shaped like existing ones
/// (removed files, child-held files, a refused family), so the first launch
/// shows the migration's result and Earlier files. The legacy lists and
/// originals are written in the forms older builds wrote them; the
/// migration then runs exactly as it would on a real store.
@MainActor
enum TaskFilesPreviewSeed {
    static let bundleIdentifier = "com.taha.Attic.preview.taskfiles"

    enum Sample: String, CaseIterable {
        /// Two screenshots and two PDFs shown, one file removed; no note yet.
        case homepage
        /// A note with writing; a file on the task and one held by a subtask.
        case venue
        /// 21 files: the note would exceed 20 (refused, Earlier files).
        case taxes
        /// Two copies of the task disagree about its files (refused).
        case kitchen
    }

    nonisolated(unsafe) private(set) static var seeded: [Sample: UUID] = [:]
    /// The seed in flight: the launch run waits for it, so the first launch
    /// migrates what it wrote.
    static var pending: Task<Void, Never>?

    static func seed(tasks: TaskStore, now: Date = Date()) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AtticTaskFiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            func originals(_ names: [String]) async throws -> [TaskImageReference] {
                var urls: [URL] = []
                for name in names {
                    let url = folder.appendingPathComponent(name)
                    if name.hasSuffix(".png") { try AtticDemoData.demoImage().write(to: url, options: .atomic) }
                    else if name.hasSuffix(".pdf") { try TaskNotePreviewSeed.pdf(name).write(to: url, options: .atomic) }
                    else { try Data("\(name)\n".utf8).write(to: url, options: .atomic) }
                    urls.append(url)
                }
                return try await tasks.taskImageFiles.importAttachments(urls, existing: [])
            }
            let homepage = try await originals(["homepage-v3.png", "blog-index.png", "hosting-quote.pdf", "redirect-map.pdf", "old-logo.png"])
            let venue = try await originals(["floor-plan.png", "quote-mill.pdf"])
            let taxes = try await originals((1...11).map { "receipt-\($0).pdf" }) + originals((12...21).map { "receipt-\($0).pdf" })
            let kitchen = try await originals(["tiles.png", "budget.txt"])

            let context = ModelContext(tasks.container)
            context.autosaveEnabled = false
            var order: Int64 = 3_000 * 1_024
            func task(_ title: String, priority: TaskPriority = .none, parent: UUID? = nil, id: UUID = UUID()) -> TaskItem {
                order -= 1_024
                let item = TaskItem(id: id, title: title, priority: priority, createdAt: now.addingTimeInterval(-5 * 86_400),
                                    manualOrder: order, parentID: parent)
                item.listOrderVersion = TaskItem.currentListOrderVersion
                context.insert(item)
                return item
            }
            let encoder = JSONEncoder()
            let home = task("Homepage redesign", priority: .high)
            home.imageReferencesData = try encoder.encode(Array(homepage.prefix(4)))
            home.removedAttachmentsData = try encoder.encode([RemovedTaskAttachment(reference: homepage[4], removedAt: now.addingTimeInterval(-3 * 86_400))])

            let book = task("Book the venue")
            book.imageReferencesData = try encoder.encode([venue[0]])
            let quotes = task("Get quotes", parent: book.id)
            quotes.imageReferencesData = try encoder.encode([venue[1]])
            _ = task("Visit on Saturday", parent: book.id)
            let note = NoteItem(id: UUID(), createdAt: now.addingTimeInterval(-4 * 86_400), updatedAt: now.addingTimeInterval(-4 * 86_400))
            note.taskID = book.id
            let document = try NoteDocument(blocks: [.text(book.title), .text("Shortlist: the Old Mill and Riverside Hall."),
                                                     .text("Both hold 80; the Mill has parking.")]).taskSnapshot(title: book.title)
            NoteStore.stageDocumentContent(try PreparedNoteDocument(document), format: 1, on: [note], timestamp: note.createdAt,
                                           revision: 0, revisionID: UUID())
            context.insert(note)
            context.insert(TaskNoteAssociation(taskID: book.id, noteID: note.id))

            let tax = task("Tax return 2025")
            tax.imageReferencesData = try encoder.encode(taxes)

            // Two copies of one task (as sync once left them), disagreeing.
            let kitchenID = UUID()
            let first = task("Kitchen renovation", id: kitchenID)
            first.imageReferencesData = try encoder.encode(kitchen)
            let second = task("Kitchen renovation", id: kitchenID)
            second.manualOrder = first.manualOrder
            second.imageReferencesData = try encoder.encode([kitchen[0]])
            try context.save()
            seeded = [.homepage: home.id, .venue: book.id, .taxes: tax.id, .kitchen: kitchenID]
            tasks.refresh()
        } catch {
            NSLog("Attic task files preview: %@", error.localizedDescription)
        }
    }
}
