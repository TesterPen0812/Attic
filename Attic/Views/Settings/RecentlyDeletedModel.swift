import Combine
import Foundation
import SwiftUI

/// One line of Recently Deleted: an item a delete hid (a task with its
/// subtasks, a note with its attachments, a canvas) or an attachment
/// removed on its own.
struct RecentlyDeletedEntry: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case task, note, canvas, attachment

        /// Sections are titled by kind, in this order.
        var sectionTitle: String {
            switch self {
            case .task: String(localized: "Tasks")
            case .note: String(localized: "Notes")
            case .canvas: String(localized: "Canvases")
            case .attachment: String(localized: "Attachments")
            }
        }

        /// What VoiceOver calls one of them.
        var noun: String {
            switch self {
            case .task: String(localized: "Task")
            case .note: String(localized: "Note")
            case .canvas: String(localized: "Canvas")
            case .attachment: String(localized: "Attachment")
            }
        }

        var systemImage: String {
            switch self {
            case .task: "checkmark.circle"
            case .note: "note.text"
            case .canvas: "scribble.variable"
            case .attachment: "paperclip"
            }
        }
    }

    enum Source: Equatable {
        case item(DeletedItemSummary)
        case attachment(DeletedAttachmentSummary)
    }

    let kind: Kind
    let title: String
    let detail: String
    let deletedAt: Date
    /// The attachment's task or note, so a search for it finds its files.
    let ownerTitle: String?
    let source: Source

    var id: String {
        switch source {
        case let .item(item): "\(item.ref.kind.rawValue)-\(item.ref.id.uuidString)"
        case let .attachment(attachment): "attachment-\(attachment.attachmentID.uuidString)"
        }
    }
}

/// The page's words and grouping, pure so they are unit-tested.
enum RecentlyDeletedPresentation {
    struct Section: Equatable {
        let kind: RecentlyDeletedEntry.Kind
        let entries: [RecentlyDeletedEntry]
    }

    static func entries(
        items: [DeletedItemSummary],
        attachments: [DeletedAttachmentSummary],
        ownerTitle: (AtticItemRef) -> String?,
        now: Date,
        calendar: Calendar
    ) -> [RecentlyDeletedEntry] {
        let itemEntries = items.map { item -> RecentlyDeletedEntry in
            let kind: RecentlyDeletedEntry.Kind = switch item.ref.kind {
            case .task: .task
            case .note: .note
            case .canvas: .canvas
            }
            var parts = [deletedPhrase(item.deletedAt, now: now, calendar: calendar)]
            if let included = includedPhrase(kind: kind, count: item.includedCount) { parts.append(included) }
            return RecentlyDeletedEntry(
                kind: kind,
                title: displayTitle(item.title, kind: kind),
                detail: parts.joined(separator: " · "),
                deletedAt: item.deletedAt,
                ownerTitle: nil,
                source: .item(item)
            )
        }
        let attachmentEntries = attachments.map { attachment -> RecentlyDeletedEntry in
            let owner = ownerTitle(attachment.owner).map { displayTitle($0, kind: attachment.owner.kind == .note ? .note : .task) }
            var parts: [String] = []
            if let owner { parts.append(String(localized: "From “\(owner)”")) }
            parts.append(deletedPhrase(attachment.deletedAt, now: now, calendar: calendar))
            return RecentlyDeletedEntry(
                kind: .attachment,
                title: attachment.filename.isEmpty ? String(localized: "Untitled file") : attachment.filename,
                detail: parts.joined(separator: " · "),
                deletedAt: attachment.deletedAt,
                ownerTitle: owner,
                source: .attachment(attachment)
            )
        }
        return itemEntries + attachmentEntries
    }

    /// Sections by kind (tasks, notes, canvases, attachments), newest
    /// deletion first in each, holding only what matches `query` (the
    /// title, or an attachment's task or note).
    static func sections(_ entries: [RecentlyDeletedEntry], query: String) -> [Section] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? entries : entries.filter {
            $0.title.localizedStandardContains(needle) || ($0.ownerTitle?.localizedStandardContains(needle) ?? false)
        }
        return RecentlyDeletedEntry.Kind.allCases.compactMap { kind in
            let rows = matching
                .filter { $0.kind == kind }
                .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.id < $1.id }
            return rows.isEmpty ? nil : Section(kind: kind, entries: rows)
        }
    }

    static func deletedPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return String(localized: "Deleted today")
        case 1: return String(localized: "Deleted yesterday")
        default: return String(localized: "Deleted \(days) days ago")
        }
    }

    static func includedPhrase(kind: RecentlyDeletedEntry.Kind, count: Int) -> String? {
        guard count > 0 else { return nil }
        switch kind {
        case .task: return count == 1 ? String(localized: "with 1 subtask") : String(localized: "with \(count) subtasks")
        case .note: return count == 1 ? String(localized: "with 1 attachment") : String(localized: "with \(count) attachments")
        case .canvas, .attachment: return nil
        }
    }

    static func displayTitle(_ title: String, kind: RecentlyDeletedEntry.Kind) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        switch kind {
        case .task: return String(localized: "Untitled task")
        case .note: return String(localized: "Untitled note")
        case .canvas: return String(localized: "Untitled canvas")
        case .attachment: return String(localized: "Untitled file")
        }
    }

    static func countPhrase(_ count: Int) -> String {
        count == 1 ? String(localized: "1 item") : String(localized: "\(count) items")
    }

    /// The selection's line: "3 selected".
    static func selectedPhrase(_ count: Int) -> String {
        String(localized: "\(count) selected")
    }

    static func restoredPhrase(_ count: Int) -> String {
        count == 1 ? String(localized: "Restored 1 item") : String(localized: "Restored \(count) items")
    }

    /// A row's commands, counted when they act on several.
    static func restoreTitle(count: Int) -> String {
        count == 1 ? String(localized: "Restore") : String(localized: "Restore \(count) Items")
    }

    static func deleteTitle(count: Int) -> String {
        count == 1 ? String(localized: "Delete Permanently…") : String(localized: "Delete \(count) Items Permanently…")
    }

    static func deleteConfirmationTitle(count: Int) -> String {
        count == 1 ? String(localized: "Delete Permanently?") : String(localized: "Delete \(count) Items Permanently?")
    }

    /// Why some of a Restore Selected stayed.
    static func restoreFailure(count: Int, reason: String) -> String {
        count == 1
            ? String(localized: "1 item couldn’t be restored: \(reason)")
            : String(localized: "\(count) items couldn’t be restored. The first: \(reason)")
    }

    /// The confirmation's words: what goes, and that it can't come back.
    static func emptyConfirmation(count: Int) -> String {
        count == 1
            ? String(localized: "1 item will be removed for good. You can’t undo this.")
            : String(localized: "\(count) items will be removed for good. You can’t undo this.")
    }

    /// After emptying: nothing to say when everything went; otherwise why
    /// some items stayed.
    static func keptMessage(kept: Int) -> String? {
        guard kept > 0 else { return nil }
        return kept == 1
            ? String(localized: "1 item was kept: its copies don’t match yet, so it can’t be removed safely. Try again later.")
            : String(localized: "\(kept) items were kept: their copies don’t match yet, so they can’t be removed safely. Try again later.")
    }
}

/// Recently Deleted as the Settings page sees it. It reads the store API
/// only while the page is shown, follows the stores' changes then, and
/// sends every change (restore, empty) through `AtticLibrary`, so a
/// restore is one undoable step and a purge follows the replica rules.
@MainActor
final class RecentlyDeletedModel: ObservableObject {
    struct Message: Equatable {
        let text: String
        let tone: AtticGroupMessage.Tone
    }

    /// What a permanent-deletion confirmation shows and, if confirmed,
    /// removes: exactly the entries it counted when it was asked for, never
    /// more. Empty All… counts everything here; Delete Permanently… the
    /// selected entries (control audit item 11).
    struct EmptyRequest: Equatable {
        enum Scope: Equatable { case all, selected }
        let selection: RecentlyDeletedSelection
        var scope: Scope = .all
        var count: Int { selection.count }
        var title: String {
            scope == .all ? String(localized: "Empty Recently Deleted?") : RecentlyDeletedPresentation.deleteConfirmationTitle(count: count)
        }
        var confirmTitle: String { scope == .all ? String(localized: "Empty") : String(localized: "Delete Permanently") }
        var confirmationText: String { RecentlyDeletedPresentation.emptyConfirmation(count: count) }
    }

    @Published private(set) var entries: [RecentlyDeletedEntry] = [] {
        didSet { pruneSelection() }
    }
    @Published var query = "" {
        didSet { if query != oldValue { pruneSelection() } }
    }
    @Published private(set) var message: Message?
    /// Set while a permanent-deletion confirmation is shown.
    @Published private(set) var emptyRequest: EmptyRequest?
    /// The selected entries' ids (control audit item 11): only listed
    /// entries stay selected, so a search never hides what an action
    /// would touch.
    @Published private(set) var selection: Set<String> = []
    /// Where ⇧-click and ⇧↑ ⇧↓ grow the selection from.
    private var selectionAnchor: String?
    /// The entry the keyboard's ↑ ↓ are on (the list keeps it in view).
    @Published private(set) var cursor: String?

    let library: AtticLibrary?
    private let now: () -> Date
    private let calendar: Calendar
    private var observation: AnyCancellable?

    init(library: AtticLibrary?, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.library = library
        self.now = now
        self.calendar = calendar
    }

    var sections: [RecentlyDeletedPresentation.Section] {
        RecentlyDeletedPresentation.sections(entries, query: query)
    }

    /// The listed entries, in the order the page shows them.
    var listedEntries: [RecentlyDeletedEntry] { sections.flatMap(\.entries) }

    /// The selected entries, in list order.
    var selectedEntries: [RecentlyDeletedEntry] { listedEntries.filter { selection.contains($0.id) } }

    // MARK: - Selection (control audit item 11)

    /// A click on a row: it alone; ⌘-click adds or removes it; ⇧-click
    /// selects the run from the anchor to it.
    func click(_ entry: RecentlyDeletedEntry, command: Bool = false, shift: Bool = false) {
        let listed = listedEntries.map(\.id)
        if shift, let anchor = selectionAnchor, let from = listed.firstIndex(of: anchor), let to = listed.firstIndex(of: entry.id) {
            let run = Set(listed[min(from, to)...max(from, to)])
            selection = command ? selection.union(run) : run
        } else if command {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            selectionAnchor = entry.id
        } else {
            selection = [entry.id]
            selectionAnchor = entry.id
        }
        cursor = entry.id
    }

    /// VoiceOver's Select and Deselect: adds or removes one entry.
    func toggleSelection(_ entry: RecentlyDeletedEntry) {
        click(entry, command: true)
        AccessibilityNotification.Announcement(RecentlyDeletedPresentation.selectedPhrase(selection.count)).post()
    }

    /// ⌘A: every listed entry.
    func selectAll() {
        let listed = listedEntries.map(\.id)
        selection = Set(listed)
        selectionAnchor = listed.first
        cursor = listed.first
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// ↑ ↓ move the selection to the next entry; with ⇧ they grow it from
    /// the anchor.
    func moveCursor(by step: Int, extending: Bool = false) {
        let listed = listedEntries
        guard !listed.isEmpty else { return }
        let index: Int
        if let cursor, let current = listed.firstIndex(where: { $0.id == cursor }) {
            index = min(max(current + step, 0), listed.count - 1)
        } else {
            index = step >= 0 ? 0 : listed.count - 1
        }
        let entry = listed[index]
        if extending, selectionAnchor != nil {
            click(entry, shift: true)
        } else {
            click(entry)
        }
    }

    /// What a row's command acts on: the selection when the row is part of
    /// it, otherwise the row alone (the selection is left as it is).
    func targets(for entry: RecentlyDeletedEntry) -> [RecentlyDeletedEntry] {
        selection.count > 1 && selection.contains(entry.id) ? selectedEntries : [entry]
    }

    private func pruneSelection() {
        let listed = Set(listedEntries.map(\.id))
        let kept = selection.intersection(listed)
        if kept != selection { selection = kept }
        if let anchor = selectionAnchor, !listed.contains(anchor) { selectionAnchor = nil }
        if let cursor, !listed.contains(cursor) { self.cursor = nil }
    }

    /// ⌘Z on the page undoes only a restore made here (the library history
    /// also holds other steps, such as an agent's settings change).
    var canUndo: Bool {
        guard let name = library?.undo.undoName(in: .library) else { return false }
        return name.hasPrefix("Restore")
    }

    /// Starts following the stores (the page appeared).
    func start() {
        reload()
        guard observation == nil, let library else { return }
        var publishers: [AnyPublisher<Void, Never>] = [
            library.tasks.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ]
        if let notes = library.notes { publishers.append(notes.objectWillChange.map { _ in () }.eraseToAnyPublisher()) }
        if let canvases = library.canvases { publishers.append(canvases.objectWillChange.map { _ in () }.eraseToAnyPublisher()) }
        observation = Publishers.MergeMany(publishers)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
    }

    /// Stops following them (the page went away): nothing is read while
    /// the page is not shown.
    func stop() {
        observation = nil
    }

    func reload() {
        guard let library else {
            entries = []
            return
        }
        entries = RecentlyDeletedPresentation.entries(
            items: library.recentlyDeleted(),
            attachments: library.recentlyDeletedAttachments(),
            ownerTitle: { library.title(of: $0) },
            now: now(),
            calendar: calendar
        )
    }

    func restore(_ entry: RecentlyDeletedEntry) {
        guard let library else { return }
        let restored: Bool = switch entry.source {
        case let .item(item): library.restore(item.ref)
        case let .attachment(attachment): library.restoreAttachment(attachment)
        }
        message = restored
            ? nil
            : Message(
                text: String(localized: "“\(entry.title)” couldn’t be restored: \(library.lastErrorMessage ?? String(localized: "Unknown error."))"),
                tone: .error
            )
        reload()
    }

    /// Restore (one entry) or Restore Selected (several, ⌘R): several come
    /// back as one step, so one ⌘Z sends them all back. Whatever could not
    /// come back stays listed (and selected), with the reason.
    func restore(_ targets: [RecentlyDeletedEntry]) {
        guard let library, !targets.isEmpty else { return }
        guard targets.count > 1 else { return restore(targets[0]) }
        let report = library.restoreRecentlyDeleted(
            items: targets.compactMap { if case let .item(item) = $0.source { item.ref } else { nil } },
            attachments: targets.compactMap { if case let .attachment(attachment) = $0.source { attachment } else { nil } }
        )
        message = report.failures.first.map { failure in
            Message(text: RecentlyDeletedPresentation.restoreFailure(count: report.failures.count, reason: failure.message), tone: .error)
        }
        reload()
        if report.restored > 0 {
            AccessibilityNotification.Announcement(RecentlyDeletedPresentation.restoredPhrase(report.restored)).post()
        }
    }

    /// ⌘R and the selection's Restore.
    func restoreSelected() {
        restore(selectedEntries)
    }

    /// Empty All…: captures exactly what the page holds now (listed or
    /// not), for the confirmation to show and, if confirmed, to remove.
    func requestEmpty() {
        emptyRequest = request(for: entries, scope: .all)
    }

    /// Delete Permanently… (the selection's, a row's menu, ⌘⌫): the
    /// confirmation counts exactly these entries.
    func requestDelete(_ targets: [RecentlyDeletedEntry]) {
        emptyRequest = request(for: targets, scope: .selected)
    }

    func requestDeleteSelected() {
        requestDelete(selectedEntries)
    }

    private func request(for targets: [RecentlyDeletedEntry], scope: EmptyRequest.Scope) -> EmptyRequest? {
        let selection = RecentlyDeletedSelection(
            items: targets.compactMap { if case let .item(item) = $0.source { item } else { nil } },
            attachments: targets.compactMap { if case let .attachment(attachment) = $0.source { attachment } else { nil } }
        )
        return selection.isEmpty ? nil : EmptyRequest(selection: selection, scope: scope)
    }

    func cancelEmpty() {
        emptyRequest = nil
    }

    /// The person confirmed: removes for good exactly the deletions the
    /// confirmation listed (anything deleted since stays), then says what
    /// was kept, if anything.
    func confirmEmpty() {
        guard let request = emptyRequest else { return }
        emptyRequest = nil
        guard let library else { return }
        library.emptyRecentlyDeleted(request.selection)
        reload()
        let kept = entries.filter { entry in
            switch entry.source {
            case let .item(item): request.selection.contains(item: item.ref, deletedAt: item.deletedAt)
            case let .attachment(attachment): request.selection.contains(attachment: attachment.attachmentID, removedAt: attachment.deletedAt)
            }
        }.count
        message = RecentlyDeletedPresentation.keptMessage(kept: kept).map { Message(text: $0, tone: .warning) }
    }

    /// ⌘Z on the page: undoes the last restore (it goes back to Recently
    /// Deleted).
    func undo() {
        guard let library, canUndo, library.undo.undo(in: .library) else { return }
        message = nil
        reload()
    }

    func dismissMessage() {
        message = nil
    }
}
