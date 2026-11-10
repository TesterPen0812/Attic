import Foundation

/// A stand-in for the real runner, so the chat's motion can be watched before
/// the model connection exists. It follows the design's `SCRIPTS` and makes
/// real changes on the local store through `AgentTaskTools.call`, the route
/// every agent change takes, so undo and Recently Deleted behave as they will.
///
/// The real runner replaces it with one line: `AppCoordinator`'s
/// `agentChat.connect(...)`. Calendar and Draw have no tools yet, so "book" adds
/// a dated task and nothing here touches Calendar or Draw data.
@MainActor
final class ScriptedAgentRunner: AgentRunning {
    enum Script: Equatable {
        case tidy, plan, week, note, book, all
    }

    private struct OpenTask {
        let id: UUID
        let title: String
        let due: String?

        var target: AgentTarget { AgentTarget(page: .tasks, itemID: id, title: title) }
    }

    /// One tool call that puts a change back, or a restore of its own.
    private struct Inverse {
        var tool = ""
        var arguments: [String: Any] = [:]
        var restore: (() -> Bool)?
    }

    private let tools: AgentTaskTools
    private let mode: () -> AgentChatMode
    private let now: () -> Date
    private let calendar: Calendar
    /// 1 is the design's timing; 0 runs a script with no waits (tests).
    private let pace: Double

    private var isWatching = false
    private var run: Task<Void, Never>?
    private var output: AsyncStream<AgentEvent>.Continuation?
    private var approvalID: UUID?
    private var approvalWaiter: CheckedContinuation<Bool, Never>?
    private var undoLog: [UUID: [Inverse]] = [:]
    private var inverses: [Inverse] = []
    private var changedPages: Set<AgentPage> = []
    private var changeCount = 0
    /// The chat history, kept in memory: what was asked and answered.
    private var thread: [AgentThreadEntry] = []
    private var threadID = UUID()
    private var threadUpdated = Date()
    private var past: [(summary: AgentChatSummary, entries: [AgentThreadEntry])] = []

    init(tools: AgentTaskTools, mode: @escaping () -> AgentChatMode = { .askFirst },
         now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent, pace: Double = 1) {
        self.tools = tools
        self.mode = mode
        self.now = now
        self.calendar = calendar
        self.pace = pace
    }

    // MARK: AgentRunning

    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent> {
        cancel()
        thread.append(AgentThreadEntry(id: UUID(), role: "user", text: text))
        threadUpdated = now()
        isWatching = watching
        inverses = []
        changedPages = []
        changeCount = 0
        return AsyncStream { continuation in
            output = continuation
            run = Task { [weak self] in
                await self?.perform(Self.script(for: text))
                self?.output?.finish()
                self?.output = nil
            }
        }
    }

    func setWatching(_ watching: Bool) { isWatching = watching }

    func resolve(approval id: UUID, allow: Bool) {
        guard id == approvalID else { return }
        approvalID = nil
        approvalWaiter?.resume(returning: allow)
        approvalWaiter = nil
    }

    func undo(changeSet id: UUID) async throws {
        guard let log = undoLog.removeValue(forKey: id) else { return }
        for inverse in log.reversed() {
            if let restore = inverse.restore {
                guard restore() else { throw AgentActionsError.invalid("The note has changed since, so it was kept.") }
            } else {
                _ = try tools.call(name: inverse.tool, arguments: inverse.arguments)
            }
        }
    }

    func threadSnapshot() -> AgentThreadSnapshot {
        AgentThreadSnapshot(entries: thread, events: [], isRunning: false)
    }

    func forgetThread() {
        if let summary = summary { past.append((summary, thread)) }
        thread = []
        threadID = UUID()
    }

    func chats() -> [AgentChatSummary] {
        (past.map(\.summary) + [summary].compactMap { $0 }).sorted { $0.updated > $1.updated }
    }

    func reopen(chat id: UUID) -> Bool {
        if id == threadID { return true }
        guard output == nil, let index = past.firstIndex(where: { $0.summary.id == id }) else { return false }
        let chosen = past.remove(at: index)
        if let summary { past.append((summary, thread)) }
        thread = chosen.entries
        threadID = chosen.summary.id
        threadUpdated = chosen.summary.updated
        return true
    }

    private var summary: AgentChatSummary? {
        guard let first = thread.first(where: { $0.role == "user" }) else { return nil }
        return AgentChatSummary(id: threadID, title: first.text, updated: threadUpdated)
    }

    #if DEBUG
    /// UI-testing seam (`ATTIC_UI_TEST_CHAT=history`): two earlier chats, as
    /// the design's list has them, so the clock has something to show.
    func seedHistoryForUITesting() {
        let day: TimeInterval = 86_400
        for (title, reply, age) in [("Boiler quotes", "Three quotes so far. The **Friday** one is cheapest.", 6 * day),
                                    ("Plan the move", "I added **12 tasks** for the move, spread over two weeks.", 22 * day)] {
            past.append((AgentChatSummary(id: UUID(), title: title, updated: now().addingTimeInterval(-age)),
                         [AgentThreadEntry(id: UUID(), role: "user", text: title),
                          AgentThreadEntry(id: UUID(), role: "assistant", text: reply)]))
        }
    }
    #endif

    func cancel() {
        run?.cancel()
        run = nil
        approvalID = nil
        approvalWaiter?.resume(returning: false)
        approvalWaiter = nil
        output?.finish()
        output = nil
    }

    /// The design's `pickScript`, less the sketch it has no tool for.
    static func script(for text: String) -> Script {
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
        if has("everything|launch ready|ready for|all pages") { return .all }
        if has("note|write|checklist") { return .note }
        if has("calendar|dentist|book|friday") { return .book }
        if has("plan|today") { return .plan }
        if has("week|coming") { return .week }
        return .tidy
    }

    // MARK: Scripts

    private func perform(_ script: Script) async {
        do {
            try await wait(2.0)
            switch script {
            case .tidy: try await tidy()
            case .plan: try await plan()
            case .week: try await week()
            case .note: try await note()
            case .book: try await book()
            case .all: try await everything()
            }
        } catch is CancellationError {
            return
        } catch {
            emit(.failed(error.localizedDescription))
            return
        }
        finishChanges()
        emit(.finished)
    }

    private func tidy() async throws {
        let open = try openTasks()
        let overdue = open.filter { ($0.due ?? "9999") < iso(now()) }
        let pool = overdue.isEmpty ? open : overdue
        let label = overdue.isEmpty ? "tasks" : "overdue tasks"
        let readOnly = mode() == .readOnly

        emit(.progress(done: 0, total: 3))
        try await showTasks()
        try await step("Reading \(pool.count) \(label)", done: "Read \(pool.count) \(label)", kind: .read,
                       targets: pool.map(\.target), seconds: 1.56)
        emit(.progress(done: 1, total: 3))
        try await wait(0.75)
        try await step("Checking your calendar", done: "Checked your calendar", kind: .read,
                       targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)], seconds: 1.3)
        emit(.progress(done: 2, total: 3))
        try await wait(0.75)

        let friday = nextFriday()
        let toRemove = Array(pool.filter { $0.title == "New Reminder" }.prefix(2))
        // A task already on the day has nothing to move, so it is no change.
        let moved = Array(pool.filter { task in task.due != iso(friday) && !toRemove.contains { $0.id == task.id } }.prefix(3))
        let toDelete = toRemove.isEmpty ? Array(pool.filter { task in !moved.contains { $0.id == task.id } }.prefix(2)) : toRemove
        if !readOnly, !moved.isEmpty { try await move(moved, to: friday) }
        emit(.progress(done: 3, total: 3))

        var deleted = 0
        if !readOnly, !toDelete.isEmpty {
            var allowed = mode() == .auto
            if !allowed { allowed = try await asks("Delete \(toDelete.count) \(toDelete.count == 1 ? "task" : "tasks")?", toDelete) }
            if allowed {
                deleted = try await delete(toDelete)
            } else {
                try await step("Kept \(toDelete.count) \(toDelete.count == 1 ? "task" : "tasks")",
                               done: "Kept \(toDelete.count) \(toDelete.count == 1 ? "task" : "tasks")",
                               kind: .read, targets: [], seconds: 0)
            }
        }
        try await wait(0.65)

        var answer: String
        if moved.isEmpty || readOnly {
            answer = deleted == 0 ? "Nothing has been changed." : "\(count(deleted)) \(deleted == 1 ? "is" : "are") gone."
        } else {
            answer = "\(count(moved.count)) now on **Friday**, your first free afternoon."
            if deleted > 0 { answer += " The \(deleted == 1 ? "other one is" : "other \(deleted) are") gone." }
        }
        if let next = pool.first(where: { task in !moved.contains { $0.id == task.id } && !toDelete.contains { $0.id == task.id } }) {
            answer += "\n\n**\(next.title)** is the one I’d do today."
        }
        try await write(answer)
    }

    private func plan() async throws {
        let open = try openTasks()
        emit(.progress(done: 0, total: 2))
        try await showTasks()
        try await step("Reading today’s tasks", done: "Read today’s tasks", kind: .read,
                       targets: open.map(\.target), seconds: 1.56)
        emit(.progress(done: 1, total: 2))
        try await wait(0.75)
        try await step("Checking your calendar", done: "Checked your calendar", kind: .read,
                       targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)], seconds: 1.3)
        emit(.progress(done: 2, total: 2))
        try await wait(0.65)
        let top = open.first?.title ?? "your first task"
        try await write("You’re free until **15:00**, so **\(top)** fits this morning.\n\nNothing has been changed.")
    }

    private func week() async throws {
        let open = try openTasks()
        try await step("Reading this week’s tasks and events", done: "Read this week’s tasks and events", kind: .read,
                       targets: [AgentTarget(page: .calendar, itemID: nil, title: nil)] + open.map(\.target), seconds: 1.3)
        try await wait(0.65)
        try await write("\(count(open.count)) open. **Friday** is the only free afternoon.")
    }

    private func note() async throws {
        emit(.progress(done: 0, total: 1))
        guard mode() != .readOnly else { return try await write("I can’t write in **Read only**. Nothing has been changed.") }
        let edited = try await addChecklist()
        emit(.progress(done: 1, total: 1))
        try await wait(0.65)
        try await write(edited ? "Your blog post note now ends with a four-line **checklist**. The dates come from your launch sketch."
                               : "Your new note has a four-line **checklist**.")
    }

    private func book() async throws {
        emit(.progress(done: 0, total: 1))
        guard mode() != .readOnly else { return try await write("I can’t add it in **Read only**. Nothing has been changed.") }
        try await addDentist()
        emit(.progress(done: 1, total: 1))
        try await wait(0.65)
        try await write("Dentist is on **Friday**, as a task. I can’t reach your calendar yet.")
    }

    private func everything() async throws {
        let open = try openTasks()
        emit(.progress(done: 0, total: 3))
        try await showTasks()
        try await step("Reading \(open.count) tasks", done: "Read \(open.count) tasks", kind: .read,
                       targets: open.map(\.target), seconds: 1.56)
        emit(.progress(done: 1, total: 3))
        try await wait(0.75)
        guard mode() != .readOnly else { return try await write("I can’t change anything in **Read only**.") }
        try await addDentist()
        emit(.progress(done: 2, total: 3))
        try await wait(0.75)
        let edited = try await addChecklist()
        emit(.progress(done: 3, total: 3))
        try await wait(0.65)
        try await write(edited ? "Done in **two places**: Friday has the dentist, and your blog post note has a checklist."
                               : "Done in **two places**: Friday has the dentist, and a new note has a checklist.")
    }

    // MARK: Steps

    /// Watching, the Tasks page comes forward so its rows can be read.
    private func showTasks() async throws {
        guard isWatching else { return }
        let step = AgentStep(id: UUID(), title: "Opening Tasks", kind: .openPage,
                             targets: [AgentTarget(page: .tasks, itemID: nil, title: nil)], state: .running)
        emit(.stepStarted(step))
        try await wait(0.56)
    }

    private func move(_ tasks: [OpenTask], to day: Date) async throws {
        let label = "\(tasks.count) \(tasks.count == 1 ? "task" : "tasks") to Friday"
        try await step("Moving \(label)", done: "Moved \(label)", kind: .move(toDay: day),
                       targets: tasks.map { AgentTarget(page: .tasks, itemID: $0.id, title: $0.title) }, seconds: 0) {
            // Each row leaves as its chip does: the design's 240 ms apart.
            for task in tasks {
                try await self.wait(0.24)
                _ = try self.tools.call(name: "update_task", arguments: ["id": task.id.uuidString, "due": self.iso(day)])
                self.inverses.append(Inverse(tool: "update_task",
                                             arguments: ["id": task.id.uuidString, "due": task.due ?? NSNull()]))
                self.note(page: .tasks)
            }
            try await self.wait(max(0, 1.5 - 0.24 * Double(tasks.count)))
        }
    }

    private func asks(_ title: String, _ tasks: [OpenTask]) async throws -> Bool {
        let approval = AgentApproval(id: UUID(), title: title, targets: tasks.map(\.target))
        approvalID = approval.id
        emit(.approvalNeeded(approval))
        let allowed = await withCheckedContinuation { approvalWaiter = $0 }
        try Task.checkCancellation()
        return allowed
    }

    private func delete(_ tasks: [OpenTask]) async throws -> Int {
        var deleted = 0
        let label = "\(tasks.count) \(tasks.count == 1 ? "task" : "tasks")"
        try await step("Deleting \(label)", done: "Deleted \(label)", kind: .delete, targets: tasks.map(\.target), seconds: 0) {
            try await self.wait(0.12)
            for task in tasks {
                _ = try self.tools.call(name: "delete_task", arguments: ["id": task.id.uuidString])
                self.inverses.append(Inverse(tool: "restore_item", arguments: ["kind": "task", "id": task.id.uuidString]))
                self.note(page: .tasks)
                deleted += 1
            }
            try await self.wait(0.8)
        }
        return deleted
    }

    private func addDentist() async throws {
        try await step("Adding Dentist to Friday", done: "Added Dentist to Friday", kind: .create,
                       targets: [AgentTarget(page: .tasks, itemID: nil, title: "Dentist")], seconds: 0) {
            try await self.wait(1.0)
            let result = try self.call("create_task", ["title": "Dentist", "due": self.iso(self.nextFriday())])
            if let id = (result["task"] as? [String: Any])?["id"] as? String {
                self.inverses.append(Inverse(tool: "delete_task", arguments: ["id": id]))
            }
            self.note(page: .tasks)
        }
    }

    /// The design's `noteAct`: a checklist at the end of the blog post note
    /// (or the latest note). With no note at all, a new one has it.
    @discardableResult
    private func addChecklist() async throws -> Bool {
        guard let store = tools.noteStore, let note = Self.noteToWriteIn(store),
              let load = store.loadDocument(noteID: note.id), case let .editable(before) = load.content else {
            try await createChecklist()
            return false
        }
        let id = note.id
        try await step("Writing in your note", done: "Added a checklist to your note", kind: .update,
                       targets: [AgentTarget(page: .notes, itemID: id, title: note.title)], seconds: 0) {
            try await self.wait(0.3)
            let body = NoteTextExport.agentBody(before)
            let add = "Launch checklist\n– Final copy by Thursday\n– Visuals by Friday\n– Press kit to Mira"
            let result = try self.call("update_note", ["id": id.uuidString, "base_revision": note.revisionToken,
                                                       "body": body.isEmpty ? add : body + "\n\n" + add])
            guard result["status"] as? String == "applied",
                  let revision = (result["note"] as? [String: Any])?["revision"] as? String else { return }
            self.inverses.append(Inverse(restore: { [weak store] in
                store?.agentRestore(noteID: id, document: before, revision: revision) == true
            }))
            self.note(page: .notes)
        }
        return true
    }

    static func noteToWriteIn(_ store: NoteStore) -> NoteItem? {
        let notes = store.notes.filter { $0.deletedAt == nil && $0.taskID == nil && $0.usesDocumentFormat }
        return notes.first { $0.title.localizedCaseInsensitiveContains("blog post") }
            ?? notes.max { $0.updatedAt < $1.updatedAt }
    }

    private func createChecklist() async throws {
        try await step("Writing in your note", done: "Added a checklist to your note", kind: .create,
                       targets: [AgentTarget(page: .notes, itemID: nil, title: "Launch checklist")], seconds: 0) {
            try await self.wait(1.4)
            let body = "- Write the post\n- Check the links\n- Schedule it\n- Tell the list"
            let result = try self.call("create_note", ["title": "Launch checklist", "body": body])
            if let note = result["note"] as? [String: Any], let id = note["id"] as? String {
                self.inverses.append(Inverse(tool: "delete_note", arguments: ["id": id, "base_revision": note["revision"] ?? ""]))
            }
            self.note(page: .notes)
        }
    }

    /// One tool row: started, the work, finished. A tool failing fails the
    /// step and the run goes on.
    private func step(_ title: String, done: String, kind: AgentStepKind, targets: [AgentTarget], seconds: TimeInterval,
                      work: (() async throws -> Void)? = nil) async throws {
        var step = AgentStep(id: UUID(), title: title, kind: kind, targets: targets, state: .running)
        emit(.stepStarted(step))
        do {
            try await work?()
            try await wait(seconds)
            step.title = done
            step.state = .done
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            step.state = .failed(error.localizedDescription)
        }
        emit(.stepFinished(step))
    }

    /// The reply, a few words at a time, as a model streams it.
    private func write(_ text: String) async throws {
        var rest = Substring(text)
        while !rest.isEmpty {
            let cut = rest.index(rest.startIndex, offsetBy: min(12, rest.count))
            emit(.textDelta(String(rest[..<cut])))
            rest = rest[cut...]
            try await wait(0.03)
        }
    }

    private func note(page: AgentPage) {
        changedPages.insert(page)
        changeCount += 1
    }

    private func finishChanges() {
        guard changeCount > 0 else { return }
        let set = AgentChangeSet(id: UUID(), title: "Changes", pages: changedPages, count: changeCount)
        undoLog[set.id] = inverses
        emit(.changes(set))
    }

    // MARK: Helpers

    private func emit(_ event: AgentEvent) {
        if case let .textDelta(text) = event {
            if let last = thread.indices.last, thread[last].role == "assistant" { thread[last].text += text }
            else { thread.append(AgentThreadEntry(id: UUID(), role: "assistant", text: text)) }
        }
        output?.yield(event)
    }

    private func wait(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        guard pace > 0, seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds * pace))
    }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let text = try tools.call(name: name, arguments: arguments)
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// Main tasks on Now, in list order: the rows the chat can light.
    private func openTasks() throws -> [OpenTask] {
        let tasks = try call("list_tasks", [:])["tasks"] as? [[String: Any]] ?? []
        return tasks.compactMap { task in
            guard task["parent_id"] == nil, let status = task["status"] as? String,
                  status != TaskStatus.done.rawValue, status != TaskStatus.backlog.rawValue,
                  let id = (task["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let title = task["title"] as? String else { return nil }
            return OpenTask(id: id, title: title, due: task["due"] as? String)
        }
    }

    private func nextFriday() -> Date {
        calendar.nextDate(after: now(), matching: DateComponents(weekday: 6), matchingPolicy: .nextTime) ?? now()
    }

    private func iso(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func count(_ tasks: Int) -> String { tasks == 1 ? "One task" : "\(tasks) tasks" }
}
