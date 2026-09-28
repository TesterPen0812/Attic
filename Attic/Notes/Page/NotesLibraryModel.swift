import Foundation
import SwiftUI

/// All notes, plain (slice 2; the filters and More tags… are slice 4):
/// rows in date groups, a search that reads away from the main actor with
/// loading and failure states, and the list's keyboard selection.
@MainActor
final class NotesLibraryModel: ObservableObject {
    enum SearchState: Equatable {
        case idle
        /// A search is running (shown only once it takes long enough to notice).
        case loading
        case failed(String)
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let rows: [AtticNoteRowModel]
    }

    /// What the search field holds.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Other rows are about to show: the keyboard's row starts again.
            highlightedID = nil
            scheduleSearch()
        }
    }
    /// The notes the last finished search found; nil while not searching.
    @Published private(set) var matches: Set<UUID>?
    /// The query `matches` answers.
    @Published private(set) var matchedQuery = ""
    @Published private(set) var searchState: SearchState = .idle
    /// A search running long enough to show that it is running.
    @Published private(set) var showsLoading = false
    /// The row the keyboard's ↑ ↓ are on.
    @Published var highlightedID: UUID?

    /// Runs a search; tests inject failures and delays.
    var search: (String) async throws -> Set<UUID>
    /// The whole text of a never-saved failed draft (they are searched here,
    /// not in the store), so a highlighted draft that still matches stays.
    var failedDraftText: (UUID) -> String? = { _ in nil }
    private let now: () -> Date
    private let calendar: Calendar
    private var searchTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var cache: (key: RowsKey, groups: [Group])?

    private struct RowsKey: Equatable {
        let revision: UInt64
        let matches: Set<UUID>?
        let attention: Set<UUID>
        let drafts: [UUID]
        let day: Int
    }

    init(search: @escaping (String) async throws -> Set<UUID>, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .autoupdatingCurrent) {
        self.search = search
        self.now = now
        self.calendar = calendar
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Retry after "Couldn't search".
    func retry() { scheduleSearch(immediately: true) }

    func clearSearch() { query = "" }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            loadingTask?.cancel()
            matches = nil
            matchedQuery = ""
            searchState = .idle
            showsLoading = false
            return
        }
        searchState = .loading
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            // Earlier results stay; a spinner only for a search you'd notice.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.searchState == .loading else { return }
            self.showsLoading = true
        }
        let run = search
        searchTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled else { return }
            do {
                let found = try await run(text)
                guard !Task.isCancelled, let self else { return }
                // A highlight on a row the results no longer show goes.
                if let highlighted = self.highlightedID, !found.contains(highlighted),
                   self.failedDraftText(highlighted)?.localizedStandardContains(text) != true {
                    self.highlightedID = nil
                }
                self.matches = found
                self.matchedQuery = text
                self.searchState = .idle
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.searchState = .failed(error.localizedDescription)
            }
            self?.loadingTask?.cancel()
            self?.showsLoading = false
        }
    }

    // MARK: Rows

    /// The groups to show: Pinned, Today, This week, Earlier (by last edit;
    /// "This week" is the six days before today), or one group of results
    /// while searching. Drafts that were never saved (a failed first save)
    /// lead the list with their warning.
    func groups(store: NoteStore, drafts: [NoteSession]) -> [Group] {
        let attention = Set(drafts.map(\.noteID))
        let unsaved = drafts.filter { store.note(withID: $0.noteID) == nil }
        let searching = isSearching
        let key = RowsKey(revision: store.revision, matches: searching ? matches : nil, attention: attention,
                          drafts: unsaved.map(\.noteID), day: calendar.ordinality(of: .day, in: .era, for: now()) ?? 0)
        if let cache, cache.key == key, unsaved.isEmpty { return cache.groups }

        var notes = store.orderedNotes()
        if searching {
            guard let matches else { return cache?.groups ?? [] }
            notes = notes.filter { matches.contains($0.id) }
        }
        let draftRows = unsaved.map { draftRow($0) }
        let result: [Group]
        if searching {
            // Never-saved drafts are searched through their whole text.
            let matchingDrafts = unsaved.filter { NoteTextExport.plainText($0.engine.document()).localizedStandardContains(matchedQuery) }
            let rows = matchingDrafts.map { draftRow($0) } + notes.map { row($0, store: store, attention: attention) }
            let count = rows.count
            result = rows.isEmpty ? [] : [Group(id: "results", title: count == 1 ? String(localized: "1 note") : String(localized: "\(count) notes"), rows: rows)]
        } else {
            let today = calendar.startOfDay(for: now())
            let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            var pinned: [AtticNoteRowModel] = [], todayRows: [AtticNoteRowModel] = draftRows
            var week: [AtticNoteRowModel] = [], earlier: [AtticNoteRowModel] = []
            for note in notes {
                let model = row(note, store: store, attention: attention)
                if note.isPinned { pinned.append(model) }
                else if note.updatedAt >= today { todayRows.append(model) }
                else if note.updatedAt >= weekStart { week.append(model) }
                else { earlier.append(model) }
            }
            result = [
                Group(id: "pinned", title: String(localized: "Pinned"), rows: pinned),
                Group(id: "today", title: String(localized: "Today"), rows: todayRows),
                Group(id: "week", title: String(localized: "This week"), rows: week),
                Group(id: "earlier", title: String(localized: "Earlier"), rows: earlier)
            ].filter { !$0.rows.isEmpty }
        }
        cache = (key, result)
        return result
    }

    /// The rows in list order, for ↑ ↓.
    func orderedIDs(_ groups: [Group]) -> [UUID] { groups.flatMap { $0.rows.map(\.id) } }

    /// What Return opens: the keyboard's row, or while searching the first
    /// result, and only ever a row the list shows now.
    func openTarget(in groups: [Group]) -> UUID? {
        let visible = orderedIDs(groups)
        if let highlightedID { return visible.contains(highlightedID) ? highlightedID : nil }
        return isSearching ? visible.first : nil
    }

    /// What ⌘⌫ deletes: the keyboard's row, or (outside the search field)
    /// the selected note, and only ever a row the list shows now.
    func deleteTarget(in groups: [Group], selected: UUID?, inField: Bool) -> UUID? {
        let visible = Set(orderedIDs(groups))
        if let highlightedID { return visible.contains(highlightedID) ? highlightedID : nil }
        guard !inField, let selected, visible.contains(selected) else { return nil }
        return selected
    }

    /// The row the library's actions (⇧⌘I, ⌘D, ⌥⇧⌘C, ⌘Z) act on: the
    /// keyboard's row, else the selected note, and only ever a row the list
    /// shows now. Unlike ⌘⌫ this also works with the search field focused
    /// (those chords are not text editing), so it never depends on focus.
    func commandTarget(in groups: [Group], selected: UUID?) -> UUID? {
        let visible = Set(orderedIDs(groups))
        if let highlightedID { return visible.contains(highlightedID) ? highlightedID : nil }
        guard let selected, visible.contains(selected) else { return nil }
        return selected
    }

    func moveHighlight(by step: Int, in groups: [Group], from selected: UUID?) {
        let ids = orderedIDs(groups)
        guard !ids.isEmpty else { return }
        let current = highlightedID.flatMap(ids.firstIndex(of:)) ?? selected.flatMap(ids.firstIndex(of:))
        let next = current.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        highlightedID = ids[next]
    }

    private func row(_ note: NoteItem, store: NoteStore, attention: Set<UUID>) -> AtticNoteRowModel {
        let summary = NoteRowSummary(note: note, attachments: store.attachments(for: note.id))
        let time = Self.time(note.updatedAt, now: now(), calendar: calendar)
        return AtticNoteRowModel(
            id: note.id, title: summary.title, time: time, needsAttention: attention.contains(note.id),
            preview: summary.preview, checklist: summary.checklist, images: summary.images, files: summary.files,
            spoken: summary.spoken(time: time, needsAttention: attention.contains(note.id))
        )
    }

    private func draftRow(_ session: NoteSession) -> AtticNoteRowModel {
        let document = session.engine.document()
        let summary = NoteRowSummary(document: document, filename: { _ in nil })
        let time = Self.time(session.lastEditAt ?? now(), now: now(), calendar: calendar)
        return AtticNoteRowModel(id: session.noteID, title: summary.title, time: time, needsAttention: true,
                                 preview: summary.preview, checklist: summary.checklist, images: summary.images,
                                 files: summary.files, spoken: summary.spoken(time: time, needsAttention: true))
    }

    /// Today "09:40", this week "Mon", then "12 Sep" (and the year when it
    /// is not this year).
    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        if date >= today {
            style = style.hour().minute()
        } else if let weekStart = calendar.date(byAdding: .day, value: -6, to: today), date >= weekStart {
            style = style.weekday(.abbreviated)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            style = style.day().month(.abbreviated)
        } else {
            style = style.day().month(.abbreviated).year()
        }
        return date.formatted(style)
    }
}

/// What a row says about a note, from its derived text (cheap: no document
/// decode). A note with only images or files takes its first file's name as
/// its title and says "1 file" or "2 images".
struct NoteRowSummary: Equatable {
    var title: String
    var preview: String
    var checklist: (done: Int, total: Int)?
    var images: Int
    var files: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.preview == rhs.preview && lhs.images == rhs.images && lhs.files == rhs.files
            && lhs.checklist?.done == rhs.checklist?.done && lhs.checklist?.total == rhs.checklist?.total
    }

    @MainActor
    init(note: NoteItem, attachments: [NoteAttachment]) {
        var lines = note.plainText.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        var images = 0
        var files = 0
        if note.usesDocumentFormat {
            images = lines.filter { $0 == "[Image]" }.count
        } else {
            for attachment in attachments {
                if attachment.isImage { images += 1 } else { files += 1 }
            }
        }
        let firstFile = attachments.sorted { $0.sortIndex < $1.sortIndex }.first?.originalFilename
        self.init(title: note.title, bodyLines: lines, images: images, files: files, firstFile: firstFile)
    }

    @MainActor
    init(document: NoteDocument, filename: (UUID) -> String?) {
        let lines = document.blocks.dropFirst().map(NoteTextExport.plainLine)
        let images = document.blocks.filter { $0.kind == .image }.count
        let firstFile = document.blocks.first { $0.kind == .image }?.attachmentID.flatMap(filename)
        self.init(title: document.title, bodyLines: lines, images: images, files: 0, firstFile: firstFile)
    }

    private init(title: String, bodyLines: [String], images: Int, files: Int, firstFile: String?) {
        var done = 0
        var total = 0
        var previewParts: [String] = []
        var listLike = false
        // Counts read the whole note; only the preview stops early (it
        // shows one line).
        var previewLength = 0
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "[Image]" || trimmed == "[Unsupported content]" { continue }
            let isChecklist = trimmed.hasPrefix("[ ] ") || trimmed.hasPrefix("[x] ")
            if isChecklist {
                total += 1
                if trimmed.hasPrefix("[x] ") { done += 1 }
            }
            guard previewLength <= 160 else { continue }
            if isChecklist, previewParts.isEmpty { listLike = true }
            let part = isChecklist ? String(trimmed.dropFirst(4)) : trimmed
            previewParts.append(part)
            previewLength += part.count + 1
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileOnly = cleanTitle.isEmpty && previewParts.isEmpty && images + files > 0
        self.title = !cleanTitle.isEmpty ? cleanTitle
            : fileOnly ? (firstFile ?? String(localized: "Untitled note")) : String(localized: "Untitled note")
        if fileOnly {
            let parts = [files > 0 ? (files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")) : nil,
                         images > 0 ? (images == 1 ? String(localized: "1 image") : String(localized: "\(images) images")) : nil]
            preview = parts.compactMap { $0 }.joined(separator: ", ")
        } else {
            preview = previewParts.joined(separator: listLike ? ", " : " ")
        }
        checklist = total > 0 ? (done, total) : nil
        self.images = images
        self.files = files
    }

    /// "Pricing page, edited 09:40, not saved, 1 of 3 checked, 1 image".
    func spoken(time: String, needsAttention: Bool) -> String {
        var parts = [title, String(localized: "edited \(time)")]
        if needsAttention { parts.append(String(localized: "not saved")) }
        if let checklist { parts.append(String(localized: "\(checklist.done) of \(checklist.total) checked")) }
        if images > 0 { parts.append(images == 1 ? String(localized: "1 image") : String(localized: "\(images) images")) }
        if files > 0 { parts.append(files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")) }
        if !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }
}
