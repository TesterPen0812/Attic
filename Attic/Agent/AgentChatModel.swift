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

    var description: String {
        switch self {
        case .auto: String(localized: "Just do it")
        case .askFirst: String(localized: "Deletes and Calendar")
        case .readOnly: String(localized: "Changes nothing")
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
    enum State: Equatable { case ready, undoing, undone, recovered }

    var set: AgentChangeSet
    var items: [AgentChatChange]
    /// The steps behind it, so Undo can run their motion backwards.
    var steps: [UUID]
    /// The run's week strip, whose dots Undo takes back.
    var week: UUID?
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
    /// A watched note edit's writing point, in window coordinates; `star`
    /// lets a star go from it.
    case writing(CGPoint, star: Bool)
    /// The chat is back from a note it wrote in.
    case wroteInNote
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
        /// Written straight after the word before, with no space: the comma in
        /// `**Friday**,` is a word of its own so the underline stops at Friday.
        var joinsPrevious = false
    }

    /// Paragraphs of words, in order. `**` marks a key phrase and never
    /// shows; an unclosed one runs to the end, so a stream can stop anywhere.
    static func paragraphs(_ raw: String) -> [[Word]] {
        var key = 0
        var inKey = false
        return raw.components(separatedBy: "\n\n").compactMap { paragraph in
            var words: [Word] = []
            // Whether the text so far runs right up to this `**`, with no space.
            var touching = false
            for (index, part) in paragraph.components(separatedBy: "**").enumerated() {
                if index > 0 {
                    inKey.toggle()
                    if inKey { key += 1 }
                }
                guard let first = part.first, let last = part.last else { continue }
                let pieces = part.split(whereSeparator: \.isWhitespace).map(String.init)
                for (position, piece) in pieces.enumerated() {
                    words.append(Word(text: piece, key: inKey ? key : nil,
                                      joinsPrevious: position == 0 && touching && !first.isWhitespace))
                }
                touching = !last.isWhitespace
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
    @Published var mode: AgentChatMode = .askFirst {
        didSet {
            runner?.setMode(mode)
            if mode == .readOnly {
                approval = nil
                queuedApprovals.removeAll()
                if phase == .needsYou { phase = .acting }
                refreshBar()
            }
        }
    }
    /// While a watched run writes in a note: the label over the composer.
    /// The chat steps aside for it (the blur and the thread go).
    @Published private(set) var writingLabel: String?

    // MARK: The composer's controls

    /// Who answers the next message: the same setting as Settings → In-app
    /// agent → Agent. A change never touches a run already going.
    @Published var agent: AgentBackend = .claude {
        didSet { if agent != oldValue { agentChanged?(agent) } }
    }
    var agentChanged: ((AgentBackend) -> Void)?
    /// Why an agent can't answer, in Settings' words ("Not installed"); absent when it can.
    @Published var agentUnavailable: [AgentBackend: String] = [:]
    /// Asks which agents are installed and signed in. Set by the shell.
    var checkAgents: (() -> Void)?
    private var lastAgentCheck: Date?

    /// The page chip: while on, each request carries the page on show and
    /// its open or selected item. × turns it off; This page turns it back on.
    @Published private(set) var includesPage = true
    /// The page the chip names: the one on show.
    @Published private(set) var chipPage: AgentPage?
    /// Tasks, notes and files added with + for the next message.
    @Published private(set) var attachments: [AgentChatAttachment] = []
    /// Why File… refused the last file.
    @Published private(set) var attachmentRefusal: String?
    /// Task or note…: the field is a search for one until it picks or goes back.
    @Published var pickingItem = false
    #if DEBUG
    /// UI-testing seam: text typed into Task or note….
    @Published var uiTestQuery: String?
    #endif
    /// Saved chats, newest first, for the clock's list.
    @Published private(set) var history: [AgentChatSummary] = []
    /// The page's open note, selected task or canvas. Set by the shell.
    var currentItem: () -> AgentTarget? = { nil }
    /// Tasks and notes matching a search, for Task or note…. Set by the shell.
    var searchItems: (String) -> [AgentTarget] = { _ in [] }

    /// Bumped on every effect, so a view can follow them through `effects`.
    let effects = PassthroughSubject<AgentChatEffect, Never>()
    let bar = AgentChatBar()

    /// The page on show, and how to go to one while watching. Set by the shell.
    var currentPage: () -> AgentPage? = { nil }
    var openPage: ((AgentPage) -> Void)?
    /// A note the agent has just written in, shown being written: Notes
    /// forward on it, the text written in, then back. Nil when there is
    /// nothing to show. Set by the shell; asked only while watching.
    var writeInNote: ((UUID) -> (() async -> Void)?)?
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
    private var queuedApprovals: [AgentApproval] = []
    private var progress: (done: Int, total: Int)?
    private var isRunning = false
    /// Finished while closed and not yet seen.
    private var unread = false
    private var runChangeCount = 0
    private var pendingItems: [AgentChatChange] = []
    private var pendingSteps: [UUID] = []
    /// This run's week strip. Each run has its own, so an earlier one stays as it was.
    private(set) var runWeek: UUID?
    /// The page the agent itself is going to: arriving there keeps the chat open.
    private var agentGoingTo: AgentPage?
    /// Entries already drawn once: a reopened thread does not replay them.
    private var presented: Set<UUID> = []
    private var nextWordTime: Date?
    private var replyEnds: Date?
    /// While a saved thread is put back: its words are already written.
    private var restoring = false

    /// True only while `panelDidHide` closes the chat.
    private(set) var closedAtOnce = false

    var isOpen: Bool { bar.isChatOpen }
    var isConnected: Bool { runner != nil }
    var isBusy: Bool { isRunning }

    /// The one place a runner comes in. `AppCoordinator` calls it.
    func connect(_ runner: AgentRunning) {
        runTask?.cancel()
        self.runner = runner
        runner.setMode(mode)
        approval = nil
        queuedApprovals.removeAll()
        guard runner.retainsThread else { return }
        let snapshot = runner.threadSnapshot()
        // The active turn is replayed from real events. Its archived text and
        // tool titles would otherwise appear twice when observe() reattaches.
        let activeStart = snapshot.isRunning
            ? snapshot.entries.lastIndex(where: { $0.role == "user" })
            : nil
        let archived = activeStart.map { Array(snapshot.entries[..<$0]) } ?? snapshot.entries
        restore(archived)
        refreshHistory()
        guard snapshot.isRunning else { return }
        if let activeStart { entries.append(AgentChatEntry(.asked(snapshot.entries[activeStart].text))) }
        isRunning = true
        phase = .waiting
        snapshot.events.forEach(apply)
        refreshBar()
        listen(to: runner.observe(), skipping: snapshot.events.count)
    }

    /// A saved thread, drawn as it ended: nothing in it plays again.
    private func restore(_ archived: [AgentThreadEntry]) {
        restoring = true
        // Putting a reply back is not the agent acting.
        let resting = phase
        defer { restoring = false; phase = resting }
        entries = []
        for message in archived {
            switch message.role {
            case "user": entries.append(AgentChatEntry(.asked(message.text)))
            case "assistant": if !message.text.isEmpty { appendText(message.text); closeReply() }
            case "tool", "error", "notice": entries.append(AgentChatEntry(.note(message.text)))
            case "receipt":
                if let set = message.changeSet {
                    let targets = message.targets ?? []
                    let items = targets.map { target in
                        AgentChatChange(title: target.title ?? target.page.rawValue.capitalized,
                                        detail: "Review")
                    }
                    let fallback = set.pages.sorted { $0.rawValue < $1.rawValue }.map {
                        AgentChatChange(title: $0.rawValue.capitalized, detail: "Review")
                    }
                    entries.append(AgentChatEntry(.changes(AgentChatChanges(
                        set: set, items: items.isEmpty ? fallback : items, steps: [], week: nil,
                        state: .recovered))))
                    entries.append(AgentChatEntry(.note("Review these saved changes. Undo from a previous app session is unavailable.")))
                }
            default: break
            }
        }
    }

    // MARK: Open and close

    func open() {
        closedAtOnce = false
        guard !isOpen else { return }
        chipPage = currentPage()
        bar.isChatOpen = true
        unread = false
        runner?.setWatching(true)
        refreshBar()
        // Off the opening's path, and not more than every few minutes.
        if let checkAgents, lastAgentCheck.map({ now().timeIntervalSince($0) > 300 }) ?? true {
            lastAgentCheck = now()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { checkAgents() }
        }
    }

    /// Closing never stops the run: it carries on, without touching the page.
    func close() {
        guard isOpen else { return }
        if writingLabel != nil { writingLabel = nil }
        if pickingItem { pickingItem = false }
        bar.isChatOpen = false
        runner?.setWatching(false)
        refreshBar()
    }

    func toggle() { isOpen ? close() : open() }

    /// Escape: a search for a task or note goes back first, then the chat closes.
    func escape() {
        if pickingItem { pickingItem = false } else { close() }
    }

    #if DEBUG
    /// UI-testing seam (`ATTIC_UI_TEST_CHAT`): an earlier exchange, already
    /// written, so an opening can be watched over a thread without a run.
    func seedExchangeForUITesting(asked: String, reply: String) {
        entries.append(AgentChatEntry(.asked(asked)))
        let words = AgentChatWords.paragraphs(reply).flatMap { $0 }
        entries.append(AgentChatEntry(.reply(AgentChatReply(raw: reply, wordTimes: words.map { _ in .distantPast },
                                                            marksStart: .distantPast))))
    }

    /// UI-testing seam: `ATTIC_UI_TEST_CHAT=seed;open@2;close@5;open@8`
    /// seeds an exchange and toggles the chat at those seconds after launch,
    /// so a recorder can watch openings with no click or key on screen.
    /// `send:<text>@3` sends a message then; `undo@9` undoes the last changes.
    func runUITestingScript(_ script: String) {
        for part in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part == "seed" {
                seedExchangeForUITesting(asked: "Tell me a short hello.", reply: "Hi there!")
                continue
            }
            let pieces = part.split(separator: "@")
            guard pieces.count == 2, let seconds = Double(pieces[1]) else { continue }
            // The composer's controls: `tap:<id>` clicks one from inside the
            // app, `menu-pick:<n>` and `menu-cancel` answer the menu it opened,
            // `search:<text>` types into Task or note….
            let command = String(pieces[0])
            if command.hasPrefix("tap:") || command.hasPrefix("menu-pick:") || command == "menu-cancel"
                || command.hasPrefix("search:") {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if command.hasPrefix("tap:") { AgentChatUITestSeams.tap(String(command.dropFirst(4))) }
                    else if command.hasPrefix("menu-pick:") { AgentChatUITestSeams.pick(Int(command.dropFirst(10)) ?? 0) }
                    else if command == "menu-cancel" { AgentChatUITestSeams.cancel() }
                    else { self?.uiTestQuery = String(command.dropFirst(7)) }
                }
                continue
            }
            if pieces[0] == "undo" {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self, let last = self.entries.last(where: {
                        if case .changes = $0.content { true } else { false }
                    }) else { return }
                    self.undo(last.id)
                }
                continue
            }
            if pieces[0].hasPrefix("send:") {
                let text = String(pieces[0].dropFirst(5))
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    self?.draft = text
                    self?.send()
                }
                continue
            }
            let opens = pieces[0] == "open"
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                opens ? self?.open() : self?.close()
            }
        }
    }
    #endif

    /// The panel has gone: the chat goes with no motion, and the run carries on.
    func panelDidHide() {
        guard isOpen else { return }
        // Stays set until the next open: the views read it a tick later.
        closedAtOnce = true
        close()
    }

    /// Whether an entry has been on screen: a reopened thread never replays.
    func wasShown(_ id: UUID) -> Bool { presented.contains(id) }
    func noteShown(_ id: UUID) { presented.insert(id) }

    /// The panel is on `page`: its dot goes, and a page the person went to
    /// (never one the agent opened) closes the chat.
    func pageChanged(to page: AgentPage?) {
        if let page { dots.remove(page) }
        if chipPage != page { chipPage = page }
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
        approval = nil
        queuedApprovals.removeAll()
        progress = nil
        pendingItems = []
        pendingSteps = []
        runWeek = nil
        nextWordTime = nil
        replyEnds = nil
        phase = .waiting
        refreshBar()
        if isOpen { effects.send(.sent(entry.id)) }
        let context = requestContext
        // What was added went with this message; the page chip stays.
        attachments = []
        attachmentRefusal = nil
        let sent = runner.send(text, context: context, watching: isOpen)
        let stream = runner.retainsThread ? runner.observe() : sent
        listen(to: stream)
    }

    private func listen(to stream: AsyncStream<AgentEvent>, skipping replayed: Int = 0) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            var skipped = 0
            for await event in stream {
                guard !Task.isCancelled else { return }
                if skipped < replayed { skipped += 1; continue }
                guard let self else { return }
                await self.waitForReply(before: event)
                if let write = self.noteWrite(before: event) { await write() }
                self.apply(event)
            }
            if !Task.isCancelled { self?.runEnded() }
        }
    }

    func stop() {
        guard isRunning else { return }
        runner?.cancel()
    }

    func resolveApproval(allow: Bool) {
        guard let approval else { return }
        self.approval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
        phase = self.approval == nil ? .acting : .needsYou
        if isOpen { effects.send(allow ? .approvalAllowed : .approvalDenied) }
        refreshBar()
        runner?.resolve(approval: approval.id, allow: allow)
    }

    /// Starts over. A run still going is stopped first.
    func newChat() {
        if isRunning { runner?.cancel() }
        runTask?.cancel()
        runTask = nil
        runner?.forgetThread()
        if writingLabel != nil { writingLabel = nil }
        isRunning = false
        entries = []
        approval = nil
        queuedApprovals.removeAll()
        phase = .idle
        progress = nil
        unread = false
        presented = []
        pendingItems = []
        pendingSteps = []
        runWeek = nil
        includesPage = true
        attachments = []
        attachmentRefusal = nil
        refreshBar()
        refreshHistory()
        // A run still ending is kept once its receipt is saved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refreshHistory() }
    }

    // MARK: History

    func refreshHistory() {
        let chats = runner?.chats() ?? []
        if chats != history { history = chats }
    }

    /// A saved chat comes back as it ended; the next message continues it.
    func reopen(_ id: UUID) {
        guard !isRunning, let runner, runner.reopen(chat: id) else { return }
        runTask?.cancel()
        runTask = nil
        if writingLabel != nil { writingLabel = nil }
        approval = nil
        queuedApprovals.removeAll()
        phase = .idle
        progress = nil
        unread = false
        pendingItems = []
        pendingSteps = []
        runWeek = nil
        restore(runner.threadSnapshot().entries)
        presented = Set(entries.map(\.id))
        refreshBar()
        refreshHistory()
    }

    /// The history list's day: Today, a weekday within the week, else the date.
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate((1..<7).contains(days) ? "EEE" : "d MMM")
        return formatter.string(from: date)
    }

    // MARK: Context

    /// What goes with the next message besides its text.
    var requestContext: AgentRequestContext {
        var context = AgentRequestContext()
        if includesPage {
            context.page = currentPage()
            context.pageItem = currentItem()
        }
        for attachment in attachments {
            switch attachment {
            case let .item(target): context.items.append(target)
            case let .file(file): context.files.append(file)
            }
        }
        return context
    }

    func removePage() { includesPage = false }
    func addPage() {
        chipPage = currentPage()
        includesPage = true
    }

    func attach(_ target: AgentTarget) {
        let attachment = AgentChatAttachment.item(target)
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
        attachments.append(attachment)
        attachmentRefusal = nil
    }

    /// File…: a text file is read now, whole, and only its name and text are kept.
    func attachFile(at url: URL) {
        switch AgentChatFiles.read(url) {
        case let .success(file):
            let attachment = AgentChatAttachment.file(file)
            attachments.removeAll { $0.id == attachment.id }
            attachments.append(attachment)
            attachmentRefusal = nil
        case let .failure(refusal):
            attachmentRefusal = refusal.message
        }
    }

    func removeAttachment(_ id: String) { attachments.removeAll { $0.id == id } }
    func clearAttachmentRefusal() { if attachmentRefusal != nil { attachmentRefusal = nil } }

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
        retreatDots(on: changes.week)
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

    private func retreatDots(on id: UUID?) {
        guard let entry = entries.first(where: { $0.id == id }),
              case let .week(week) = entry.content, week.landed > 0 else { return }
        let id = entry.id
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

    /// A watched note edit finishes once it has been seen being written:
    /// its row turns done as the chat comes back. Closed, it lands as it is.
    private func noteWrite(before event: AgentEvent) -> (() async -> Void)? {
        guard case let .stepFinished(step) = event, isOpen, let noteID = Self.writtenNote(step),
              let present = writeInNote?(noteID) else { return nil }
        return { [weak self] in
            guard let self else { return }
            if self.currentPage() != .notes { self.agentGoingTo = .notes }
            self.writingLabel = String(localized: "Writing in your note")
            await present()
            if self.writingLabel != nil { self.writingLabel = nil }
            if self.isOpen { self.effects.send(.wroteInNote) }
        }
    }

    /// The note a finished step changed, when it is one edit of one note.
    static func writtenNote(_ step: AgentStep) -> UUID? {
        guard step.kind == .update, case .done = step.state else { return nil }
        let notes = step.targets.filter { $0.page == .notes }
        guard notes.count == 1, step.targets.count == 1 else { return nil }
        return notes[0].itemID
    }

    /// The writing point moved; only an open chat draws it.
    func writingAt(_ point: CGPoint, star: Bool) {
        if isOpen { effects.send(.writing(point, star: star)) }
    }

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
        case let .stepReworded(step): update(step.id) { $0 = .step(step) }
        case let .stepFinished(step): stepFinished(step)
        case let .progress(done, total):
            progress = (done, total)
            refreshBar()
        case let .approvalNeeded(request):
            guard approval?.id != request.id,
                  !queuedApprovals.contains(where: { $0.id == request.id }) else { return }
            if approval == nil { approval = request }
            else { queuedApprovals.append(request) }
            phase = .needsYou
            refreshBar()
        case let .changes(set): changesArrived(set)
        case let .notice(message): entries.append(AgentChatEntry(.note(message)))
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
        let writes = isOpen && !reducesMotion() && !restoring
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
        reply.marksStart = isOpen && !reducesMotion() && !restoring
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
            // Adaptive UI: an empty week would be seven blank boxes.
            let days = runWeek == nil ? weekDays(now()) : nil
            if days?.contains(where: { !$0.bars.isEmpty }) ?? true {
                weekID = showWeek(holding: now(), target: nil, dots: 0, days: days)
            }
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
        if case let .partial(reason) = step.state {
            entries.append(AgentChatEntry(.note(reason)))
        }
        let committed: Bool
        switch step.state {
        case .done, .partial: committed = true
        case .running, .failed: committed = false
        }
        guard committed, Self.changesSomething(step.kind) else { return }
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
        let entry = AgentChatEntry(.changes(AgentChatChanges(set: set, items: pendingItems, steps: pendingSteps, week: runWeek)))
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
        queuedApprovals.removeAll()
        phase = .idle
        for entry in entries {
            guard case var .step(step) = entry.content, step.state == .running else { continue }
            step.title = String(localized: "Stopped")
            step.state = .failed("")
            update(entry.id) { $0 = .step(step) }
        }
        unread = !isOpen
        refreshBar()
        refreshHistory()
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

    /// The run's strip, made on first use. A move's day is always on show:
    /// the strip takes that day's week, so chips have a slot to land on and the
    /// strip says where the tasks went, whatever day the runner picks.
    private func showWeek(holding day: Date, target: Date?, dots: Int, days: [AgentChatWeekDay]? = nil) -> UUID {
        guard let runWeek else {
            let entry = AgentChatEntry(.week(AgentChatWeek(days: days ?? weekDays(day), target: target, dots: dots)))
            entries.append(entry)
            runWeek = entry.id
            return entry.id
        }
        guard let target else { return runWeek }
        let calendar = Calendar.autoupdatingCurrent
        update(runWeek) {
            guard case var .week(week) = $0 else { return }
            if !week.days.contains(where: { calendar.isDate($0.day, inSameDayAs: target) }) { week.days = weekDays(target) }
            if let shown = week.target, calendar.isDate(shown, inSameDayAs: target) {
                week.dots += dots
            } else {
                week.target = target
                week.dots = dots
                week.landed = 0
            }
            $0 = .week(week)
        }
        return runWeek
    }

    private func updateWeek(_ change: (inout AgentChatWeek) -> Void) {
        guard let runWeek else { return }
        update(runWeek) {
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

    /// Task due dates contribute short marks. Calendar occurrences occupy the
    /// actual fraction of each day, including overnight and all-day events.
    static func week(holding day: Date, dueDays: [DueDay], events: [CalendarEvent] = [],
                     calendar: Calendar = .autoupdatingCurrent) -> [AgentChatWeekDay] {
        emptyWeek(holding: day, calendar: calendar).map { entry in
            let parts = calendar.dateComponents([.year, .month, .day], from: entry.day)
            let due = dueDays.filter { $0.year == parts.year && $0.month == parts.month && $0.day == parts.day }.count
            let taskMarks = (0..<min(3, due)).map { index -> ClosedRange<Double> in
                let top = 0.06 + Double(index) * 0.3
                return top...(top + 0.24)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: entry.day) else {
                return AgentChatWeekDay(day: entry.day, bars: taskMarks)
            }
            let interval = DateInterval(start: entry.day, end: next)
            let seconds = next.timeIntervalSince(entry.day)
            let eventSpans = events.compactMap { event -> ClosedRange<Double>? in
                guard event.overlaps(interval) else { return nil }
                let start = max(0, min(1, event.start.timeIntervalSince(entry.day) / seconds))
                let end = max(start, min(1, event.end.timeIntervalSince(entry.day) / seconds))
                // Keep short appointments visible in the 38pt strip.
                return start...min(1, max(end, start + 0.025))
            }.sorted { $0.lowerBound < $1.lowerBound }
            // Merge overlapping meetings: busy time is the occupied duration,
            // rather than counting concurrent events twice.
            var busy: [ClosedRange<Double>] = []
            for span in eventSpans {
                if let last = busy.last, span.lowerBound <= last.upperBound {
                    busy[busy.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
                } else { busy.append(span) }
            }
            return AgentChatWeekDay(day: entry.day,
                                    bars: (busy + taskMarks).sorted { $0.lowerBound < $1.lowerBound })
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
