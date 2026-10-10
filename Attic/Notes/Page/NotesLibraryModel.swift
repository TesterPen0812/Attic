import SwiftData
import Combine
import Foundation
import SwiftUI

/// All notes: rows in date groups, an optional tag filter (the top line's
/// recent tags and More tags…), a search that reads away from the main
/// actor with loading and failure states, and the list's keyboard selection.
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
    @Published private(set) var matchedRevision: UInt64?
    @Published private(set) var searchState: SearchState = .idle
    /// A search running long enough to show that it is running.
    @Published private(set) var showsLoading = false
    /// The row the keyboard's ↑ ↓ are on.
    @Published var highlightedID: UUID?
    /// The tag All notes shows (nil: every note). A search looks inside it.
    /// It stays while the library is away and comes back with it, unless the
    /// note you come back from would be hidden (`reconcileFilter`).
    @Published var tagFilter: String? {
        didSet {
            guard tagFilter != oldValue else { return }
            highlightedID = nil
        }
    }

    /// Runs a search; tests inject failures and delays.
    var search: (String) async throws -> Set<UUID>
    /// The whole text of a never-saved failed draft (they are searched here,
    /// not in the store), so a highlighted draft that still matches stays.
    var failedDraftText: (UUID) -> String? = { _ in nil }
    private let now: () -> Date
    private let calendar: Calendar
    private var searchTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private weak var observedStore: NoteStore?
    private var storeSubscription: AnyCancellable?
    private var presentationSubscription: AnyCancellable?
    private var dateEnvironmentSubscription: AnyCancellable?
    private var storeRevision: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var cache: (key: RowsKey, groups: [Group])?
    /// Each stored note's preview body, read once per content identity,
    /// including fresh-context changes that keep the same revision token.
    private var proposalIDs: (revision: UInt64, ids: Set<UUID>)?
    private var failedProposalRevision: UInt64?
    private var bodies: [UUID: (content: Data?, plainText: String, body: NoteRowSummary.Body)] = [:]
    /// How many note bodies the rows decoded (a profiling seam: a rebuild
    /// after one save decodes that note only).
    private(set) var bodyDecodeCount = 0
    /// Every tag, most recently edited first, for the store revision it was read at.
    private var recentTagsCache: (revision: UInt64, tags: [String])?

    private struct RowsKey: Equatable {
        let revision: UInt64
        let matches: Set<UUID>?
        let attention: Set<UUID>
        let drafts: [UUID]
        let day: Int
        let dateEnvironment: DatePresentationEnvironment
        let tag: String?
    }

    init(search: @escaping (String) async throws -> Set<UUID>, store: NoteStore? = nil, controller: NotesPageController? = nil, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .autoupdatingCurrent) {
        self.search = search
        self.now = now
        self.calendar = calendar
        dateEnvironmentSubscription = Publishers.MergeMany(DatePresentationEnvironment.notifications.map {
            NotificationCenter.default.publisher(for: $0)
        }).sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache = nil
                self.objectWillChange.send()
            }
        }
        if let store { observeStore(store) }
        // Every exit route publishes here, including corner New Note and
        // Duplicate. Clear synchronously before hidden-editor autosaves.
        if let controller {
            presentationSubscription = controller.$isLibraryPresented.sink { [weak self, weak controller] shown in
                guard let self else { return }
                if !shown { self.clearSearch(); return }
                self.failedProposalRevision = nil
                // Before the list is built: a filter that would hide the
                // note you came from never shows for a frame.
                if let store = self.observedStore {
                    self.reconcileFilter(store: store, selected: controller?.librarySelectionID)
                }
            }
        }
    }

    private func observeStore(_ store: NoteStore) {
        guard observedStore !== store else { return }
        observedStore = store
        proposalIDs = nil
        failedProposalRevision = nil
        cache = nil
        storeRevision = store.revision
        storeSubscription = store.$revision.sink { [weak self] revision in
            guard let self, revision != self.storeRevision else { return }
            self.storeRevision = revision
            self.cache = nil
            if self.isSearching { self.scheduleSearch() }
        }
        if isSearching { scheduleSearch() }
    }

    func waitForSearch() async {
        var generation: UInt64
        repeat {
            generation = searchGeneration
            await searchTask?.value
        } while generation != searchGeneration
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Retry after "Couldn't search".
    func retry() {
        failedProposalRevision = nil
        scheduleSearch(immediately: true)
    }

    func clearSearch() { query = "" }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration, revision = storeRevision
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            loadingTask?.cancel()
            matches = nil
            matchedQuery = ""
            matchedRevision = nil
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
                guard !Task.isCancelled, let self, self.searchGeneration == generation,
                      self.storeRevision == revision,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                // A highlight on a row the results no longer show goes.
                if let highlighted = self.highlightedID, !found.contains(highlighted),
                   self.failedDraftText(highlighted)?.localizedStandardContains(text) != true {
                    self.highlightedID = nil
                }
                self.matches = found
                self.matchedQuery = text
                self.matchedRevision = revision
                self.searchState = .idle
            } catch {
                guard !Task.isCancelled, let self, self.searchGeneration == generation,
                      self.storeRevision == revision,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
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
        observeStore(store)
        let attention = Set(drafts.map(\.noteID))
        var unsaved = drafts.filter { store.note(withID: $0.noteID) == nil }
        let searching = isSearching
        let key = RowsKey(revision: store.revision, matches: searching ? matches : nil, attention: attention,
                          drafts: unsaved.map(\.noteID), day: calendar.ordinality(of: .day, in: .era, for: now()) ?? 0,
                          dateEnvironment: DatePresentationEnvironment(calendar: calendar),
                          tag: tagFilter)
        if let cache, cache.key == key, unsaved.isEmpty { return cache.groups }

        var notes = store.orderedNotes()
        // One consistent proposal snapshot for every row in this render.
        // A later row must not turn a partially failed read into cacheable rows.
        if !notes.isEmpty, proposalIDs?.revision != store.revision, failedProposalRevision != store.revision {
            do {
                let edits = try store.fetchAuxiliary(FetchDescriptor<NotePendingEdit>())
                proposalIDs = (store.revision, Set(edits.map(\.noteID)))
                failedProposalRevision = nil
            } catch {
                failedProposalRevision = store.revision
                store.reportProposalReadFailure(error)
            }
        }
        let allNotes = notes
        if let tag = tagFilter {
            notes = notes.filter { $0.tags.contains(tag) }
            unsaved = unsaved.filter { $0.engine.tags.contains(tag) }
        }
        if searching {
            // The earlier rows stay while a search runs, but only rows of
            // this filter (review S4-R2).
            guard let matches else { return cache.flatMap { $0.key.tag == tagFilter ? $0.groups : nil } ?? [] }
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
            // Deleted notes' bodies go (the full list was just read).
            if bodies.count > allNotes.count {
                let stored = Set(allNotes.map(\.id))
                bodies = bodies.filter { stored.contains($0.key) }
            }
            result = [
                Group(id: "pinned", title: String(localized: "Pinned"), rows: pinned),
                Group(id: "today", title: String(localized: "Today"), rows: todayRows),
                Group(id: "week", title: String(localized: "This week"), rows: week),
                Group(id: "earlier", title: String(localized: "Earlier"), rows: earlier)
            ].filter { !$0.rows.isEmpty }
        }
        // A failed proposal read is unknown, so neither its badge nor the
        // enclosing rows may be cached as a successful absence.
        cache = notes.isEmpty || proposalIDs?.revision == store.revision ? (key, result) : nil
        return result
    }

    // MARK: Tags

    /// Every tag in Notes, the most recently edited note's first (ties by
    /// name). Read once per store revision.
    func recentTags(store: NoteStore) -> [String] {
        observeStore(store)
        if let recentTagsCache, recentTagsCache.revision == store.revision { return recentTagsCache.tags }
        let tags = Self.recentTags(store.notes.lazy.filter { $0.deletedAt == nil }.map { ($0.tagsRaw, $0.updatedAt) })
        recentTagsCache = (store.revision, tags)
        return tags
    }

    /// Tags ordered by the latest edit of a note that carries them.
    static func recentTags(_ notes: some Sequence<(tagsRaw: String, updatedAt: Date)>) -> [String] {
        var latest: [String: Date] = [:]
        for note in notes where !note.tagsRaw.isEmpty {
            for tag in AtticTag.decode(note.tagsRaw) where latest[tag].map({ $0 < note.updatedAt }) ?? true {
                latest[tag] = note.updatedAt
            }
        }
        return latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map(\.key)
    }

    /// The top line's tags after "All notes": the active tag first (always
    /// shown), then the most recent others, up to `limit` in all.
    func tagTabs(store: NoteStore, limit: Int) -> [String] {
        let recent = recentTags(store: store)
        var tabs = tagFilter.map { [$0] } ?? []
        for tag in recent where tabs.count < limit && tag != tagFilter { tabs.append(tag) }
        return tabs
    }

    /// Clicking a tag: filter to it, or back to every note when it is the
    /// active one. A search in progress stays and now looks inside it.
    func toggleTag(_ tag: String) {
        tagFilter = tagFilter == tag ? nil : tag
    }

    /// Opening All notes keeps the earlier filter only when it still shows
    /// the note you came from (and still has a note); otherwise every note.
    func reconcileFilter(store: NoteStore, selected: UUID?) {
        guard let tag = tagFilter else { return }
        let carriers = store.notes.filter { $0.deletedAt == nil && $0.tags.contains(tag) }
        if carriers.isEmpty { tagFilter = nil; return }
        if let selected, let note = store.note(withID: selected), !note.tags.contains(tag) { tagFilter = nil }
    }

    // MARK: Words

    /// The search field's placeholder: the count, or the tag searched in.
    static func placeholder(count: Int, tag: String?) -> String {
        if let tag { return String(localized: "Search #\(tag)") }
        return count == 1 ? String(localized: "Search 1 note") : String(localized: "Search \(count) notes")
    }

    /// The line where the rows would be when a search finds nothing.
    static func noMatches(query: String, tag: String?) -> String {
        if let tag { return String(localized: "No notes match “\(query)” in #\(tag)") }
        return String(localized: "No notes match “\(query)”")
    }

    /// The filter's line when no note carries the tag (any more).
    static func emptyFilter(tag: String) -> String { String(localized: "No notes in #\(tag)") }

    /// The next step after no matches: a new note named for the search.
    static func newNoteTitle(query: String, tag: String?) -> String {
        if let tag { return String(localized: "New note “\(query)” in #\(tag)") }
        return String(localized: "New note “\(query)”")
    }

    /// The search that found nothing, when it finished for what the field
    /// holds now and did not fail: what "New note “…”" (and Return) would
    /// create. Nil otherwise (still searching, failed, or rows shown).
    func queryForNewNote(in groups: [Group]) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, groups.isEmpty, matches != nil, searchState == .idle, matchedQuery == text else { return nil }
        return text
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
        let summary = NoteRowSummary(note: note, attachments: store.attachments(for: note.id), body: body(of: note))
        let time = Self.time(note.updatedAt, now: now(), calendar: calendar)
        let hasProposal = proposalIDs?.ids.contains(note.id) == true
        return AtticNoteRowModel(
            id: note.id, title: summary.title, time: time, needsAttention: attention.contains(note.id), hasProposal: hasProposal,
            preview: summary.preview, checklist: summary.checklist, images: summary.images, files: summary.files,
            spoken: summary.spoken(time: time, needsAttention: attention.contains(note.id)) + (hasProposal ? ", proposal waiting" : "")
        )
    }

    private func body(of note: NoteItem) -> NoteRowSummary.Body {
        if let kept = bodies[note.id], kept.content == note.content, kept.plainText == note.plainText { return kept.body }
        let body = NoteRowSummary.body(of: note)
        bodyDecodeCount += 1
        bodies[note.id] = (note.content, note.plainText, body)
        return body
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

/// What a row says about a note. A note with only images or files takes its
/// first file's name as its title and says "1 file" or "2 images".
///
/// The preview is the note's text without its formatting, read from the
/// blocks' kinds and styles (a heading, a list item, a quote, Mono) and
/// never by stripping patterns from the text: `__init__` in Mono, a URL
/// with `/__v1__/` or a paragraph that starts with "- " read as typed
/// (review P3, `d5e2c0d`). Emphasis is a mark beside the text, so the text
/// has none to strip.
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

    /// One body line as a row reads it.
    struct Line: Equatable {
        enum Kind: Equatable { case text, listItem, checklist(checked: Bool), object }
        let text: String
        let kind: Kind

        /// A block's line: its text with no marker (the style says what it
        /// is); images, files, dividers and unsupported blocks are objects.
        init(_ block: NoteBlock) {
            switch block.kind {
            case .text:
                text = block.displayText.trimmingCharacters(in: .whitespaces)
                kind = block.style == "bullet" || block.style == "number" ? .listItem : .text
            case .checklist:
                text = block.displayText.trimmingCharacters(in: .whitespaces)
                kind = .checklist(checked: block.checked)
            case .table:
                // A table reads as its cells' text, in order.
                text = (block.table?.texts.flatMap { $0 } ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: ", ")
                kind = .text
            case .image, .file, .divider, .opaque:
                text = ""
                kind = .object
            }
        }

        /// A line of text with no document behind it (stored bytes this build cannot read): as written, apart from the
        /// derived text's object lines and `[ ]` / `[x]` checklist lines.
        init(plain line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[Image]" || trimmed.hasPrefix("[File: ") || trimmed == "[Unsupported content]" {
                text = ""
                kind = .object
            } else if trimmed.hasPrefix("[ ] ") || trimmed.hasPrefix("[x] ") {
                text = String(trimmed.dropFirst(4))
                kind = .checklist(checked: trimmed.hasPrefix("[x] "))
            } else {
                text = trimmed
                kind = .text
            }
        }
    }

    /// What the preview and the checklist count take from the body: the
    /// first parts (about one line's worth) and the counts over the whole
    /// note. Small; the library keeps one per note revision.
    struct Body {
        private(set) var parts: [(text: String, isListItem: Bool)] = []
        private(set) var done = 0
        private(set) var total = 0

        init(_ lines: some Sequence<Line>) {
            var length = 0
            for line in lines {
                if case let .checklist(checked) = line.kind {
                    total += 1
                    if checked { done += 1 }
                }
                guard line.kind != .object, !line.text.isEmpty, length <= 160 else { continue }
                let isListItem = switch line.kind { case .listItem, .checklist: true; default: false }
                parts.append((line.text, isListItem))
                length += line.text.count + 1
            }
        }
    }

    /// The body of a stored note: its document's blocks or an unreadable document's derived text.
    @MainActor
    static func body(of note: NoteItem) -> Body {
        if note.usesDocumentFormat, let data = note.content, let document = NoteContentCodec.decode(data).document {
            return Body(document.blocks.dropFirst().lazy.map(Line.init))
        }
        return Body(note.plainText.components(separatedBy: "\n").dropFirst().lazy.map { Line(plain: $0) })
    }

    @MainActor
    init(note: NoteItem, attachments: [NoteAttachment], body: Body? = nil) {
        let images = note.imageCount, files = note.fileCount
        let firstFile = note.firstFileName ?? attachments.sorted { $0.sortIndex < $1.sortIndex }.first?.originalFilename
        self.init(title: note.title, body: body ?? Self.body(of: note), images: images, files: files, firstFile: firstFile)
    }

    @MainActor
    init(document: NoteDocument, filename: (UUID) -> String?) {
        let images = document.blocks.filter { $0.kind == .image }.count
        let files = document.blocks.filter { $0.kind == .file }.count
        let firstFile = document.blocks.first { $0.kind == .file }?.filename
            ?? document.blocks.first { $0.kind == .image }?.attachmentID.flatMap(filename)
        self.init(title: document.title, body: Body(document.blocks.dropFirst().lazy.map(Line.init)),
                  images: images, files: files, firstFile: firstFile)
    }

    private init(title: String, body: Body, images: Int, files: Int, firstFile: String?) {
        let previewParts = body.parts
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileOnly = cleanTitle.isEmpty && previewParts.isEmpty && images + files > 0
        self.title = !cleanTitle.isEmpty ? cleanTitle
            : fileOnly ? (firstFile ?? String(localized: "Untitled note")) : String(localized: "Untitled note")
        if fileOnly {
            let parts = [files > 0 ? (files == 1 ? String(localized: "1 file") : String(localized: "\(files) files")) : nil,
                         images > 0 ? (images == 1 ? String(localized: "1 image") : String(localized: "\(images) images")) : nil]
            preview = parts.compactMap { $0 }.joined(separator: ", ")
        } else {
            // A list reads as "Oat milk, Lemons, Rice"; other lines run on.
            var joined = ""
            for (index, part) in previewParts.enumerated() {
                if index > 0 { joined += previewParts[index - 1].isListItem && part.isListItem ? ", " : " " }
                joined += part.text
            }
            preview = joined
        }
        checklist = body.total > 0 ? (body.done, body.total) : nil
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
