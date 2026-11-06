import Combine
import Foundation

/// How far the agent may go on its own. The composer's Mode picker writes it.
enum AgentChatMode: String, CaseIterable, Identifiable, Sendable {
    case auto, askFirst, readOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .askFirst: String(localized: "Ask first")
        case .readOnly: String(localized: "Read only")
        }
    }
}

/// What the ✦ button says while the chat is closed. Plain states: no thinking
/// look, here or anywhere (Accepted 2026-11-06).
enum AgentChatBarState: Equatable {
    case idle
    case working(step: Int?, of: Int?)
    case needsYou
    case changes(Int)
    case done

    var label: String? {
        switch self {
        case .idle: nil
        case let .working(step?, total?) where total > 1: String(localized: "Working \(step) of \(total)")
        case .working: String(localized: "Working")
        case .needsYou: String(localized: "Needs you")
        case let .changes(count): count == 1 ? String(localized: "1 change") : String(localized: "\(count) changes")
        case .done: String(localized: "Done")
        }
    }
}

/// The little the shell watches: the ✦ button and whether the chat is open.
/// Kept apart from the model so a word arriving never touches the bar.
@MainActor
final class AgentChatBar: ObservableObject {
    @Published fileprivate(set) var state: AgentChatBarState = .idle
    @Published fileprivate(set) var isChatOpen = false
}

/// Where a run is, for the view. `waiting` is the gap before the first text or
/// step: nothing special shows in it (`AgentChatWaitingSlot`).
enum AgentChatPhase: Equatable {
    case idle, waiting, acting, needsYou
}

struct AgentChatWeekDay: Equatable, Identifiable {
    var day: Date
    /// One entry per bar: where it starts and how tall it is, 0...1 of the day.
    var bars: [ClosedRange<Double>]
    var id: Date { day }
}

struct AgentChatWeek: Equatable {
    var days: [AgentChatWeekDay]
    /// The day moved tasks land on.
    var target: Date?
    /// How many dots the target day holds, and how many have landed.
    var dots = 0
    var landed = 0
    /// Whether the agent has finished reading it (the target slot lights up).
    var read = false
}

/// A reply as written, with `**key words**` left in. `wordTimes[i]` is when
/// word i starts to show; it lives here so a reopened thread never replays.
struct AgentChatReply: Equatable {
    var raw = ""
    var wordTimes: [Date] = []
    /// When the underlines start: set once the reply is complete.
    var marksStart: Date?
}

struct AgentChatChange: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var isDelete = false

    static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.detail == b.detail && a.isDelete == b.isDelete }
}

struct AgentChatChanges: Equatable {
    enum State: Equatable { case ready, undoing, undone }

    var set: AgentChangeSet
    var items: [AgentChatChange]
    /// The steps behind it, so Undo can run their motion backwards.
    var steps: [UUID]
    var state: State = .ready
    var isExpanded = false
}

struct AgentChatEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case asked(String)
        case step(AgentStep)
        case week(AgentChatWeek)
        case reply(AgentChatReply)
        case changes(AgentChatChanges)
        case note(String)
    }

    let id: UUID
    var content: Content

    init(id: UUID = UUID(), _ content: Content) {
        self.id = id
        self.content = content
    }
}

/// What the view's motion needs to hear. Sent only while the chat is open:
/// closed, the run works without touching the page.
enum AgentChatEffect: Equatable {
    case sent(UUID)
    case reading(AgentStep)
    case moving(AgentStep, week: UUID?)
    case deleting(AgentStep)
    case approvalAllowed
    case approvalDenied
    case changesLanded(UUID)
    case undoing(AgentChatChanges)
}

/// How fast a reply writes itself. The HTML's values; tests use `.instant`.
struct AgentChatPacing: Equatable, Sendable {
    var word: TimeInterval = 0.036
    var comma: TimeInterval = 0.1
    var sentence: TimeInterval = 0.19
    /// A word's own fade, and the wait after the last word before what
    /// follows the reply appears.
    var settle: TimeInterval = 0.3
    /// The gap between dots leaving the week strip on Undo.
    var dotRetreat: TimeInterval = 0.11

    static let instant = AgentChatPacing(word: 0, comma: 0, sentence: 0, settle: 0, dotRetreat: 0)
}

/// A reply split into words for the writing motion.
enum AgentChatWords {
    struct Word: Equatable {
        var text: String
        /// Words of one `**key phrase**` share a key; nil for the rest.
        var key: Int?
    }

    /// Paragraphs of words, in order. `**` marks a key phrase and never
    /// shows; an unclosed one runs to the end, so a stream can stop anywhere.
    static func paragraphs(_ raw: String) -> [[Word]] {
        var key = 0
        var inKey = false
        return raw.components(separatedBy: "\n\n").compactMap { paragraph in
            var words: [Word] = []
            for (index, part) in paragraph.components(separatedBy: "**").enumerated() {
                if index > 0 {
                    inKey.toggle()
                    if inKey { key += 1 }
                }
                let pieces = part.split(whereSeparator: \.isWhitespace).map(String.init)
                words += pieces.map { Word(text: $0, key: inKey ? key : nil) }
            }
            return words.isEmpty ? nil : words
        }
    }

    static func count(_ raw: String) -> Int { paragraphs(raw).reduce(0) { $0 + $1.count } }

    /// The pause a word earns after it: longer at the end of a sentence.
    static func gap(after word: String, pacing: AgentChatPacing) -> TimeInterval {
        guard let last = word.last else { return pacing.word }
        if ".!?:".contains(last) { return pacing.sentence }
        return last == "," ? pacing.comma : pacing.word
    }
}

/// The floating chat's state: the thread, the run, and what the ✦ says. It
/// outlives the panel's views, so closing the chat or hiding the panel leaves
/// the run going and reopening shows the whole thread. It knows the run only
/// through `AgentRunning`; `connect` is the one place a runner comes in.
@MainActor
final class AgentChatModel: ObservableObject {
    @Published private(set) var entries: [AgentChatEntry] = []
    @Published private(set) var approval: AgentApproval?
    @Published private(set) var phase: AgentChatPhase = .idle
    @Published var draft = ""
    @Published var mode: AgentChatMode = .askFirst

    /// Bumped on every effect, so a view can follow them through `effects`.
    let effects = PassthroughSubject<AgentChatEffect, Never>()
    let bar = AgentChatBar()

    /// The page on show, and how to go to one while watching. Set by the shell.
    var currentPage: () -> AgentPage? = { nil }
    var openPage: ((AgentPage) -> Void)?
    /// What the week strip shows, for the week holding a day.
    var weekDays: (Date) -> [AgentChatWeekDay] = { AgentChatModel.emptyWeek(holding: $0) }
    /// Told when the pages with a dot change.
    var onDotsChanged: ((Set<AgentPage>) -> Void)?
    var pacing = AgentChatPacing()
    var now: () -> Date = Date.init
    /// Reduce Motion: replies show at once and nothing waits for them.
    var reducesMotion: () -> Bool = { false }

    private(set) var dots: Set<AgentPage> = [] {
        didSet { if dots != oldValue { onDotsChanged?(dots) } }
    }

    private var runner: AgentRunning?
    private var runTask: Task<Void, Never>?
    private var progress: (done: Int, total: Int)?
    private var isRunning = false
    /// Finished while closed and not yet seen.
    private var unread = false
    private var runChangeCount = 0
    private var pendingItems: [AgentChatChange] = []
    private var pendingSteps: [UUID] = []
    /// The page the agent itself is going to: arriving there keeps the chat open.
    private var agentGoingTo: AgentPage?
    /// Entries already drawn once: a reopened thread does not replay them.
    private var presented: Set<UUID> = []
    private var nextWordTime: Date?
    private var replyEnds: Date?

    /// True only while `panelDidHide` closes the chat.
    private(set) var closedAtOnce = false

    var isOpen: Bool { bar.isChatOpen }
    var isConnected: Bool { runner != nil }
    var isBusy: Bool { isRunning }

    /// The one place a runner comes in. `AppCoordinator` calls it.
    func connect(_ runner: AgentRunning) { self.runner = runner }

    // MARK: Open and close

    func open() {
        guard !isOpen else { return }
        bar.isChatOpen = true
        unread = false
        runner?.setWatching(true)
        refreshBar()
    }

    /// Closing never stops the run: it carries on, without touching the page.
    func close() {
        guard isOpen else { return }
        bar.isChatOpen = false
        runner?.setWatching(false)
        refreshBar()
    }

    func toggle() { isOpen ? close() : open() }

    /// The panel has gone: the chat goes with no motion, and the run carries on.
    func panelDidHide() {
        guard isOpen else { return }
        closedAtOnce = true
        close()
        closedAtOnce = false
    }

    /// Whether an entry has been on screen: a reopened thread never replays.
    func wasShown(_ id: UUID) -> Bool { presented.contains(id) }
    func noteShown(_ id: UUID) { presented.insert(id) }

    /// The panel is on `page`: its dot goes, and a page the person went to
    /// (never one the agent opened) closes the chat.
    func pageChanged(to page: AgentPage?) {
        if let page { dots.remove(page) }
        defer { agentGoingTo = nil }
        if isOpen, page != agentGoingTo { close() }
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning, let runner else { return }
        draft = ""
        let entry = AgentChatEntry(.asked(text))
        entries.append(entry)
        isRunning = true
        unread = false
        runChangeCount = 0
        progress = nil
        nextWordTime = nil
        replyEnds = nil
        phase = .waiting
        refreshBar()
        if isOpen { effects.send(.sent(entry.id)) }
        let stream = runner.send(text, watching: isOpen)
        runTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.waitForReply(before: event)
                self.apply(event)
            }
            self?.runEnded()
        }
    }

    func stop() {
        guard isRunning else { return }
        runner?.cancel()
    }

    func resolveApproval(allow: Bool) {
        guard let approval else { return }
        self.approval = nil
        phase = .acting
        if isOpen { effects.send(allow ? .approvalAllowed : .approvalDenied) }
        refreshBar()
        runner?.resolve(approval: approval.id, allow: allow)
    }

    /// Starts over. A run still going is stopped first.
    func newChat() {
        if isRunning { runner?.cancel() }
        runTask?.cancel()
        runTask = nil
        isRunning = false
        entries = []
        approval = nil
        phase = .idle
        progress = nil
        unread = false
        presented = []
        pendingItems = []
        pendingSteps = []
        refreshBar()
    }

    func toggleChanges(_ id: UUID) {
        update(id) { if case var .changes(changes) = $0 { changes.isExpanded.toggle(); $0 = .changes(changes) } }
    }

    func undo(_ id: UUID) {
        guard let runner, let entry = entries.first(where: { $0.id == id }),
              case var .changes(changes) = entry.content, changes.state == .ready else { return }
        changes.state = .undoing
        changes.isExpanded = false
        update(id) { $0 = .changes(changes) }
        if isOpen { effects.send(.undoing(changes)) }
        dots = []
        retreatDots()
        Task { [weak self] in
            do {
                try await runner.undo(changeSet: changes.set.id)
                self?.undoFinished(id, failure: nil)
            } catch {
                self?.undoFinished(id, failure: error.localizedDescription)
            }
        }
    }

    private func undoFinished(_ id: UUID, failure: String?) {
        update(id) {
            guard case var .changes(changes) = $0 else { return }
            changes.state = failure == nil ? .undone : .ready
            $0 = .changes(changes)
        }
        if let failure { entries.append(AgentChatEntry(.note(failure))) }
    }

    /// A dot landed on the week strip (or, with no motion, all of them).
    func dotLanded(week id: UUID) {
        update(id) {
            guard case var .week(week) = $0, week.landed < week.dots else { return }
            week.landed += 1
            $0 = .week(week)
        }
    }

    private func retreatDots() {
        guard let index = entries.lastIndex(where: { if case .week = $0.content { true } else { false } }),
              case let .week(week) = entries[index].content, week.landed > 0 else { return }
        let id = entries[index].id
        let gap = reducesMotion() || !isOpen ? 0 : pacing.dotRetreat
        Task { [weak self] in
            for _ in 0..<week.landed {
                self?.update(id) {
                    guard case var .week(week) = $0 else { return }
                    week.landed = max(0, week.landed - 1)
                    $0 = .week(week)
                }
                if gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            }
        }
    }

    // MARK: Events

    /// What follows a reply waits for it to finish writing itself.
    private func waitForReply(before event: AgentEvent) async {
        switch event {
        case .textDelta, .progress: return
        default: closeReply()
        }
        guard isOpen, !reducesMotion(), let replyEnds else { return }
        let wait = replyEnds.timeIntervalSince(now())
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    func apply(_ event: AgentEvent) {
        switch event {
        case let .textDelta(text): appendText(text)
        case let .stepStarted(step): stepStarted(step)
        case let .stepFinished(step): stepFinished(step)
        case let .progress(done, total):
            progress = (done, total)
            refreshBar()
        case let .approvalNeeded(request):
            approval = request
            phase = .needsYou
            refreshBar()
        case let .changes(set): changesArrived(set)
        case .finished: runEnded()
        case let .failed(message):
            entries.append(AgentChatEntry(.note(message)))
            runEnded()
        }
    }

    private func appendText(_ text: String) {
        phase = .acting
        let time = now()
        var reply = AgentChatReply()
        var id: UUID?
        if let last = entries.last, case let .reply(current) = last.content, current.marksStart == nil {
            reply = current
            id = last.id
        }
        reply.raw += text
        let words = AgentChatWords.paragraphs(reply.raw).flatMap { $0 }
        // Closed, or with Reduce Motion: already written when it is next seen.
        let writes = isOpen && !reducesMotion()
        var next = writes ? max(nextWordTime ?? time, time) : time
        while reply.wordTimes.count < words.count {
            let word = words[reply.wordTimes.count]
            reply.wordTimes.append(writes ? next : .distantPast)
            next += AgentChatWords.gap(after: word.text, pacing: pacing)
        }
        nextWordTime = next
        replyEnds = next.addingTimeInterval(pacing.settle)
        if let id {
            update(id) { $0 = .reply(reply) }
        } else {
            entries.append(AgentChatEntry(.reply(reply)))
        }
    }

    /// The reply is complete: its underlines may start.
    private func closeReply() {
        guard let last = entries.last, case var .reply(reply) = last.content, reply.marksStart == nil else { return }
        reply.marksStart = isOpen && !reducesMotion()
            ? (replyEnds?.addingTimeInterval(-pacing.settle) ?? now()) : .distantPast
        update(last.id) { $0 = .reply(reply) }
    }

    private func stepStarted(_ step: AgentStep) {
        phase = .acting
        if step.kind == .openPage {
            if isOpen, let page = step.targets.first?.page, page != currentPage() {
                agentGoingTo = page
                openPage?(page)
            }
            return
        }
        entries.append(AgentChatEntry(id: step.id, .step(step)))
        var weekID: UUID?
        if case let .move(day?) = step.kind {
            weekID = showWeek(holding: day, target: day, dots: step.targets.count)
        } else if step.kind == .read, step.targets.contains(where: { $0.page == .calendar }) {
            weekID = showWeek(holding: now(), target: nil, dots: 0)
        }
        guard isOpen else {
            if let weekID, case .move = step.kind { update(weekID) { Self.landAll(&$0) } }
            return
        }
        switch step.kind {
        case .read: if step.targets.contains(where: { $0.page == .tasks }) { effects.send(.reading(step)) }
        case .move: effects.send(.moving(step, week: weekID))
        case .delete: effects.send(.deleting(step))
        default: break
        }
    }

    private func stepFinished(_ step: AgentStep) {
        update(step.id) { $0 = .step(step) }
        if step.kind == .read, step.targets.contains(where: { $0.page == .calendar }) {
            updateWeek { $0.read = true }
        }
        guard step.state == .done, Self.changesSomething(step.kind) else { return }
        let here = currentPage()
        for target in step.targets {
            if target.page != here { dots.insert(target.page) }
            guard let title = target.title else { continue }
            pendingItems.append(AgentChatChange(title: title, detail: Self.detail(step.kind),
                                                isDelete: step.kind == .delete))
        }
        pendingSteps.append(step.id)
    }

    private func changesArrived(_ set: AgentChangeSet) {
        runChangeCount += set.count
        let entry = AgentChatEntry(.changes(AgentChatChanges(set: set, items: pendingItems, steps: pendingSteps)))
        pendingItems = []
        pendingSteps = []
        entries.append(entry)
        if isOpen { effects.send(.changesLanded(entry.id)) }
    }

    private func runEnded() {
        guard isRunning else { return }
        closeReply()
        isRunning = false
        approval = nil
        phase = .idle
        for entry in entries {
            guard case var .step(step) = entry.content, step.state == .running else { continue }
            step.title = String(localized: "Stopped")
            step.state = .failed("")
            update(entry.id) { $0 = .step(step) }
        }
        unread = !isOpen
        refreshBar()
    }

    private func refreshBar() {
        let state: AgentChatBarState
        if approval != nil {
            state = .needsYou
        } else if isRunning {
            state = .working(step: progress.map { min($0.done + 1, $0.total) }, of: progress?.total)
        } else if unread {
            state = runChangeCount > 0 ? .changes(runChangeCount) : .done
        } else {
            state = .idle
        }
        if bar.state != state { bar.state = state }
    }

    // MARK: The week strip

    private func showWeek(holding day: Date, target: Date?, dots: Int) -> UUID {
        if let entry = entries.last(where: { if case .week = $0.content { true } else { false } }) {
            update(entry.id) {
                guard case var .week(week) = $0 else { return }
                week.target = target ?? week.target
                week.dots = max(week.dots, dots)
                $0 = .week(week)
            }
            return entry.id
        }
        let entry = AgentChatEntry(.week(AgentChatWeek(days: weekDays(day), target: target, dots: dots)))
        entries.append(entry)
        return entry.id
    }

    private func updateWeek(_ change: (inout AgentChatWeek) -> Void) {
        guard let entry = entries.last(where: { if case .week = $0.content { true } else { false } }) else { return }
        update(entry.id) {
            guard case var .week(week) = $0 else { return }
            change(&week)
            $0 = .week(week)
        }
    }

    private static func landAll(_ content: inout AgentChatEntry.Content) {
        guard case var .week(week) = content else { return }
        week.landed = week.dots
        content = .week(week)
    }

    /// Seven empty days, Monday first, for a build with no provider.
    static func emptyWeek(holding day: Date, calendar: Calendar = .autoupdatingCurrent) -> [AgentChatWeekDay] {
        var monday = calendar.startOfDay(for: day)
        while calendar.component(.weekday, from: monday) != 2 {
            monday = calendar.date(byAdding: .day, value: -1, to: monday) ?? monday
        }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
            .map { AgentChatWeekDay(day: $0, bars: []) }
    }

    /// The week holding `day`, one short bar per task due (three at most).
    /// Events join when the chat can read the calendar.
    static func week(holding day: Date, dueDays: [DueDay], calendar: Calendar = .autoupdatingCurrent) -> [AgentChatWeekDay] {
        emptyWeek(holding: day, calendar: calendar).map { entry in
            let parts = calendar.dateComponents([.year, .month, .day], from: entry.day)
            let due = dueDays.filter { $0.year == parts.year && $0.month == parts.month && $0.day == parts.day }.count
            let bars = (0..<min(3, due)).map { index -> ClosedRange<Double> in
                let top = 0.06 + Double(index) * 0.3
                return top...(top + 0.24)
            }
            return AgentChatWeekDay(day: entry.day, bars: bars)
        }
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout AgentChatEntry.Content) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index].content)
    }

    private static func changesSomething(_ kind: AgentStepKind) -> Bool {
        switch kind {
        case .read, .openPage: false
        case .create, .update, .move, .delete: true
        }
    }

    private static func detail(_ kind: AgentStepKind) -> String {
        switch kind {
        case let .move(day?): day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .move: String(localized: "Moved")
        case .delete: String(localized: "Deleted")
        case .create: String(localized: "Added")
        default: String(localized: "Edited")
        }
    }
}

/// The floating chat's run lives on the panel's state, which outlives every view.
extension AgentPage {
    init?(_ page: PanelPage) {
        switch page {
        case .tasks: self = .tasks
        case .notes: self = .notes
        case .calendar: self = .calendar
        case .canvas: self = .draw
        }
    }

    var panelPage: PanelPage {
        switch self {
        case .tasks: .tasks
        case .notes: .notes
        case .calendar: .calendar
        case .draw: .canvas
        }
    }
}
