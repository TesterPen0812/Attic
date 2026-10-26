import Foundation

/// The New list style's main page, part 2 (council D2, owner 2026-10-26).
/// Every write is an existing producer through the write gate and history:
/// Edit Task (one step per field), Add Subtask (`createTasks`), Pick for Now
/// (`pickIntoNow`, one step), and the note's own edit for the writing.
extension TasksPageModel {
    /// Only the New list style draws the card, picking, the Due line and
    /// Find across lists.
    var isNewMainPage: Bool { listStyle.rawValue == "new" }

    private var mainPageToday: DueDay { DueDay(date: services.now(), calendar: services.calendar()) }

    // MARK: - The card in place (3A)

    /// ⓘ, ⌘I or a double-click on the title: the row grows into a card.
    /// One card at a time; an open title editor saves first.
    func openCard(_ id: UUID) {
        guard isNewMainPage, let task = store.listedTask(withID: id) ?? store.task(withID: id),
              task.parentID == nil else { return }
        if let open = mainPage.card {
            if open.taskID == id { return }
            closeCard()
        }
        guard finishEditing() else { return }
        clearJustPicked()
        mainPage.card = TasksCardPlace(taskID: id, tab: mainPage.find != nil ? resultTab(of: task) : tab)
        mainPage.cardWriting = nil
        selectOnly(id)
        loadCardWriting(id)
    }

    /// Esc, ⌘I again, or a click on the card's chevron: it closes and keeps
    /// what was done (every field already saved as it changed).
    func closeCard() {
        guard let card = mainPage.card else { return }
        mainPage.card = nil
        mainPage.cardWriting = nil
        mainPage.fullReturnAnchor = nil
        selectOnly(card.taskID)
        mainPage.requestScroll(to: card.taskID)
    }

    /// ⌘↩ or "Open full": the card fills the list area.
    func openCardFull() {
        guard var card = mainPage.card, !card.isFull else { return }
        card.isFull = true
        mainPage.fullReturnAnchor = card.taskID
        mainPage.card = card
    }

    /// ‹ Now (or the list's name) and Esc in full: back to the same row
    /// and scroll position, the card still open.
    func shrinkCard() {
        guard var card = mainPage.card, card.isFull else { return }
        card.isFull = false
        mainPage.card = card
        if let anchor = mainPage.fullReturnAnchor { mainPage.requestScroll(to: anchor) }
        mainPage.fullReturnAnchor = nil
    }

    /// Esc in the card: full shrinks first, then the card closes.
    func escapeCard() {
        guard let card = mainPage.card else { return }
        if card.isFull { shrinkCard() } else { closeCard() }
    }

    /// The card's title, committed on Return or when it loses focus.
    @discardableResult
    func commitCardTitle(_ title: String) -> CommandOutcome {
        guard let id = mainPage.card?.taskID, let task = store.task(withID: id) else { return .failed(.taskGone) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != task.title else { return .applied }
        return cardEdit(id) { $0.library.updateTask(id, title: trimmed) }
    }

    @discardableResult
    func setCardDue(_ day: DueDay?) -> CommandOutcome {
        guard let id = mainPage.card?.taskID else { return .failed(.taskGone) }
        return cardEdit(id) { $0.library.updateTask(id, dueDay: .some(day)) }
    }

    @discardableResult
    func setCardPriority(_ priority: TaskPriority) -> CommandOutcome {
        guard let id = mainPage.card?.taskID else { return .failed(.taskGone) }
        return cardEdit(id) { $0.library.updateTask(id, priority: priority) }
    }

    @discardableResult
    func setCardFlag(_ flagged: Bool) -> CommandOutcome {
        guard let id = mainPage.card?.taskID else { return .failed(.taskGone) }
        return cardEdit(id) { $0.library.updateTask(id, isFlagged: flagged) }
    }

    @discardableResult
    func setCardTags(_ tags: [String]) -> CommandOutcome {
        guard let id = mainPage.card?.taskID else { return .failed(.taskGone) }
        let normalized = AtticTag.normalizedSet(tags)
        return cardEdit(id) { $0.library.updateTask(id, tags: normalized) }
    }

    /// The link chip: an empty field removes the link.
    @discardableResult
    func setCardLink(_ url: String) -> CommandOutcome {
        guard let id = mainPage.card?.taskID else { return .failed(.taskGone) }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return cardEdit(id) { $0.library.updateTask(id, url: .some(trimmed.isEmpty ? nil : trimmed)) }
    }

    /// The Now/Later chip moves the task between the lists (one step). The
    /// card closes when its row leaves the list it was opened in.
    @discardableResult
    func setCardList(_ destination: TasksTab) -> CommandOutcome {
        guard let id = mainPage.card?.taskID, let task = store.task(withID: id), task.status != .done else { return .failed(.taskGone) }
        let target: TaskStatus = destination == .backlog ? .backlog : .todo
        guard (task.status == .backlog) != (target == .backlog) else { return .applied }
        let outcome = cardEdit(id) { $0.library.updateTask(id, status: target, allowingUnfinishedSubtasks: true) }
        if outcome.isApplied, mainPage.find == nil, let card = mainPage.card, card.tab != .done, card.tab != destination {
            mainPage.card = nil
            mainPage.cardWriting = nil
            showToast(destination == .backlog ? String(localized: "Moved to Later") : String(localized: "Moved to Now"))
        }
        return outcome
    }

    /// Add subtask in the card: Return adds it and keeps the field for the
    /// next one (the caller clears the text on true); Esc ends.
    @discardableResult
    func addCardSubtask(_ title: String) -> Bool {
        guard let parentID = mainPage.card?.taskID else { return false }
        guard let draft = TaskAddBarText(text: title).draft(parser: parser, status: .todo, parentID: parentID) else { return false }
        guard library.createTasks([draft]) != nil else {
            showToast(String(localized: "Subtask not saved"))
            return false
        }
        return true
    }

    /// The open card's subtasks, unfinished first, then done (one-item
    /// rule 5).
    func cardSubtasks() -> [TaskItem] {
        guard let id = mainPage.card?.taskID else { return [] }
        let all = store.subtasks(of: id)
        return all.filter { $0.status != .done } + all.filter { $0.status == .done }
    }

    private func cardEdit(_ id: UUID, _ change: @escaping (TasksPageModel) -> CommandOutcome) -> CommandOutcome {
        clearJustPicked()
        let retry: () -> CommandOutcome = { [weak self] in
            guard let self else { return .failed(.taskGone) }
            return change(self)
        }
        return report(change(self), on: id, retry: retry)
    }

    // MARK: Writing

    private func loadCardWriting(_ id: UUID) {
        guard let read = services.readWriting else { return }
        Task { @MainActor [weak self] in
            let snapshot = await read(id)
            guard let self, self.mainPage.card?.taskID == id else { return }
            self.mainPage.cardWriting = snapshot ?? TaskNoteWriting.Snapshot(text: "", isPlain: false)
        }
    }

    /// The card's writing, saved as the note's own edit when the field
    /// loses focus or the card closes. Rich writing is never written here.
    func commitCardWriting(_ text: String, for id: UUID) async -> Bool {
        guard let write = services.writeWriting else { return false }
        guard let shown = mainPage.cardWriting, mainPage.card?.taskID == id ? shown.isPlain : true else { return false }
        guard shown.text != text else { return true }
        let saved = await write(id, text)
        if saved, mainPage.card?.taskID == id {
            mainPage.cardWriting = TaskNoteWriting.Snapshot(text: text, isPlain: true)
        } else if !saved {
            showToast(String(localized: "Writing not saved"))
        }
        return saved
    }

    // MARK: - Pick your Now (D2)

    /// The Due line above Now: computed when the data changes or the day
    /// does, never per frame (cached on the store's revision and today).
    func dueLine() -> TasksDueLine {
        guard isNewMainPage else { return .none }
        let key = TasksMainPageState.DueKey(revision: store.revision, today: mainPageToday)
        if let cached = mainPage.dueCache, cached.key == key { return cached.line }
        let line = TasksDueLine.make(later: laterTasks(), today: key.today)
        mainPage.dueCache = (key, line)
        return line
    }

    private func laterTasks() -> [TaskItem] {
        store.snapshot(for: .backlog).sections.flatMap(\.tasks)
    }

    /// "Pick from Later · N waiting".
    var pickWaitingCount: Int { backlogCount }

    /// P, Pick on the Due line, or "Pick from Later": Later opens in pick
    /// mode, due tasks first.
    func beginPick() {
        guard isNewMainPage, mainPage.pick == nil else { return }
        guard finishEditing() else { return }
        if mainPage.card != nil { closeCard() }
        if mainPage.find != nil { endFind() }
        clearJustPicked()
        select(tab: .backlog)
        selectOnly(nil)
        mainPage.pick = TasksPickSession()
    }

    /// Pick mode's groups: DUE then LATER.
    func pickGroups() -> (due: [UUID], later: [UUID]) {
        let groups = TasksPickSession.groups(laterTasks(), today: mainPageToday)
        return (groups.due.map(\.id), groups.later.map(\.id))
    }

    /// A click on the ＋ ring, or Space on the selected task.
    func togglePick(_ id: UUID) {
        guard mainPage.pick != nil, store.task(withID: id)?.status == .backlog else { return }
        mainPage.pick?.toggle(id)
    }

    /// Done and Esc both return to Now and keep the picks: they join the
    /// end of Now in the order they were picked, as one step.
    @discardableResult
    func finishPick() -> CommandOutcome {
        guard let session = mainPage.pick else { return .applied }
        mainPage.pick = nil
        select(tab: .now)
        guard !session.picked.isEmpty else { return .applied }
        let outcome = library.pickIntoNow(session.picked)
        if outcome.isApplied {
            mainPage.justPicked = Set(session.picked)
            if let last = session.picked.last { mainPage.requestScroll(to: last) }
        } else {
            showToast(String(localized: "Picks not saved"))
        }
        return outcome
    }

    /// The light tint on just-picked tasks lasts until the next action.
    func clearJustPicked() {
        if !mainPage.justPicked.isEmpty { mainPage.justPicked = [] }
    }

    /// The row's Move: in Now every task is one you picked ("Back to
    /// Later"); in Later it is "Move to Now".
    func newStyleMoveTitle(in tab: TasksTab) -> String {
        tab == .backlog ? String(localized: "Move to Now") : String(localized: "Back to Later")
    }

    // MARK: - Capture (D2: nothing lands in Now by itself)

    /// The quick-capture hotkey opened the add bar: in the New style, what
    /// it adds files into Later. The add bar opened any other way adds to
    /// the list being viewed.
    func beginHotkeyCapture() {
        guard isNewMainPage else { return }
        mainPage.captureIntoLater = true
    }

    func endHotkeyCapture() {
        if mainPage.captureIntoLater { mainPage.captureIntoLater = false }
    }

    // MARK: - Find across every list

    /// ⌘F or the Find button: the header's tabs become the field.
    func beginFind(scrollAnchor: UUID?) {
        guard isNewMainPage else { return }
        if mainPage.find != nil { return }
        guard finishEditing() else { return }
        if mainPage.pick != nil { finishPick() }
        if mainPage.card != nil { closeCard() }
        mainPage.find = TasksFindSession(originTab: tab, originSelection: selection, originScrollAnchor: scrollAnchor)
    }

    func setFindQuery(_ query: String) {
        mainPage.find?.query = query
    }

    func setFindScope(_ scope: TasksFindSession.Scope) {
        mainPage.find?.scope = scope
    }

    /// ✕ or Esc: the tabs, the list, the scroll and the selection come back.
    /// Returns the scroll anchor to restore.
    @discardableResult
    func endFind() -> UUID? {
        guard let session = mainPage.find else { return nil }
        if mainPage.card != nil {
            mainPage.card = nil
            mainPage.cardWriting = nil
        }
        mainPage.find = nil
        mainPage.findCache = nil
        select(tab: session.originTab)
        let live = session.originSelection.filter { store.listedTask(withID: $0) != nil || store.task(withID: $0) != nil }
        selectAll(live)
        if let anchor = session.originScrollAnchor { mainPage.requestScroll(to: anchor) }
        return session.originScrollAnchor
    }

    /// The results, grouped by list: titles, tags, writing, subtasks and
    /// link (host and path) match. Cached on the store's revision.
    func findResults() -> TasksFindResults {
        guard let session = mainPage.find else { return TasksFindResults() }
        let query = session.trimmedQuery
        let key = TasksMainPageState.FindKey(revision: store.revision, query: query, scope: session.scope, origin: session.originTab)
        if let cached = mainPage.findCache, cached.key == key { return cached.results }
        var results = TasksFindResults()
        if !query.isEmpty {
            for tab in session.tabs {
                results.groups.append(.init(tab: tab, ids: findMatches(in: tab, query: query)))
            }
        }
        mainPage.findCache = (key, results)
        return results
    }

    private func findMatches(in tab: TasksTab, query: String) -> [UUID] {
        switch tab {
        case .now:
            return store.snapshot(for: .tasks).sections.filter { $0.status != .done }.flatMap(\.tasks)
                .filter { store.matchesItemSearch($0, query: query) }.map(\.id)
        case .backlog:
            return laterTasks().filter { store.matchesItemSearch($0, query: query) }.map(\.id)
        case .done:
            let today = store.doneTodayTasks().filter { store.matchesItemSearch($0, query: query) }.map(\.id)
            let log = store.indexedDoneLogPage(limit: Self.findDoneLimit, matching: query).tasks.map(\.id)
            var seen = Set<UUID>()
            return (today + log).filter { seen.insert($0).inserted }
        }
    }

    /// The Done group shows the most recent matches; Done's own search
    /// pages further.
    static let findDoneLimit = 50

    /// Which group a task shows in.
    private func resultTab(of task: TaskItem) -> TasksTab {
        switch task.status {
        case .done: .done
        case .backlog: .backlog
        case .todo, .inProgress: .now
        }
    }

    private func selectAll(_ ids: Set<UUID>) {
        if ids.count <= 1 {
            selectOnly(ids.first)
        } else {
            selectCopies(Array(ids))
        }
    }
}
