import Combine
import Foundation
#if DEBUG && ATTIC_LOCAL_ONLY
import Darwin

/// Opt-in probe for the isolated agent-pass preview. Only numeric timings and
/// process footprint are written; message text, credentials and IDs never are.
@MainActor
enum AgentPassProbe {
    private static let enabled = Bundle.main.bundleIdentifier == "com.taha.Attic.preview.agentpass"
        && ProcessInfo.processInfo.environment["ATTIC_AGENT_PASS_METRICS"] == "1"
    private static let cliDiagnostics = ProcessInfo.processInfo.environment["ATTIC_AGENT_PASS_CLI_DIAGNOSTICS"] == "1"
    private static var opening: UInt64?
    private static var sending: UInt64?
    private static var awaitingFirstDelta = false
    private static let destination: URL? = {
        guard enabled, let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("AgentPassTimings.ndjson")
    }()

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func record(_ name: String, value: Double) {
        guard let destination, value.isFinite else { return }
        let payload: [String: Any] = ["name": name, "value": value]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(10)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: destination) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    static func beginOpen() { if enabled { opening = now() } }
    static func stageUpdated() {
        if let start = opening {
            opening = nil
            record("ChatOpenToStageUpdate.ms", value: Double(now() - start) / 1_000_000)
        }
    }
    static func beginSend() {
        guard enabled else { return }
        sending = now()
        awaitingFirstDelta = true
    }
    static func firstDelta() {
        guard awaitingFirstDelta, let start = sending else { return }
        awaitingFirstDelta = false
        sending = nil
        record("SendToFirstDelta.ms", value: Double(now() - start) / 1_000_000)
        mark("FirstDelta")
    }
    /// Preview-only, numeric control outcomes. No prompts, item IDs, models,
    /// tool arguments, token values or vendor stderr enter this file.
    static func mark(_ name: String, value: Double = 1) {
        guard enabled, cliDiagnostics else { return }
        record("CLI.\(name)", value: value)
    }
    static func footprint(_ name: String) {
        guard enabled else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            record("\(name).footprintMiB", value: Double(info.phys_footprint) / 1_048_576)
        }
    }
}
#endif

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

#if DEBUG
extension AgentChatBar {
    /// Tests and off-screen renders: a closed bar showing `state`.
    convenience init(showing state: AgentChatBarState) {
        self.init()
        self.state = state
    }
}
#endif

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
    /// A visible reply reuses completed paragraph text. Hidden runs defer
    /// presentation work until reveal.
    var parsed: AgentReplyPresentation? = nil
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
    /// The spark as the agent's pointer: where it goes, or nil to let go.
    case pointer(AgentWatchPoint?)
    /// The pointer taps: the design's ring (40, 0.42 s) and seven stars.
    case tap(AgentWatchPoint)
    /// Stars and a ring from a point: the design's burst where a change lands.
    case burst(AgentWatchPoint, count: Int, speed: Double, ring: CGFloat)
    /// A row lights up: the design's ping, for `duration` seconds.
    case ping(AgentWatchRect, duration: Double)
    /// A sketch drawn in over Draw.
    case sketch(AgentSketchReplay)
    /// Task rows matching a reply's underlined phrase light up.
    case pingRows([UUID])
    /// The chat is back from watching the agent work on a page.
    case watchEnded
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
    /// Step beats (the design's step transitions, not its demo timings): a
    /// step shows running at least this long (its 200 ms arrival, then a
    /// readable shimmer) before it turns done…
    var stepRun: TimeInterval = 0.5
    /// …and its check (400 ms ring, tick to 460 ms) finishes before the next
    /// step arrives. Beats only hold what is shown; the run never waits.
    var stepHandover: TimeInterval = 0.46
    /// Events that waited longer than this skip their beats until the chat
    /// has caught up with the run.
    var catchUp: TimeInterval = 1.0
    /// After a watched action, how long the chat stays aside for the next
    /// one before it comes back.
    var watchReturn: TimeInterval = 0.4

    static let instant = AgentChatPacing(word: 0, comma: 0, sentence: 0, settle: 0, dotRetreat: 0,
                                         stepRun: 0, stepHandover: 0, catchUp: 0, watchReturn: 0)
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

    /// Parses appended text once while preserving the reference parser's
    /// cross-chunk `**` marks, whitespace and paragraph boundaries.
    @MainActor
    final class Stream {
        private(set) var words: [Word] = []
        private var breaks: [Int] = []
        private var currentWord: Int?
        private var partHasCharacters = false
        private var partFirstWhitespace = false
        private var partLastWhitespace = false
        private var partWords = 0
        private var touching = false
        private var inKey = false
        private var key = 0
        private var pendingStar = false
        private var previousNewline = false
        private(set) var charactersExamined = 0
        private(set) var wordsMaterialized = 0
        private let presentation = AgentReplyPresentation()
        private var presentedBreaks = 0
        private var presentedParagraphStart = 0

        var wordCount: Int { words.count + (pendingStar && currentWord == nil ? 1 : 0) }

        func word(at index: Int) -> Word {
            if index < words.count {
                var result = words[index]
                if pendingStar && currentWord == index { result.text += "*" }
                return result
            }
            return Word(text: "*", key: inKey ? key : nil,
                        joinsPrevious: partWords == 0 && touching && (!partHasCharacters || !partFirstWhitespace))
        }

        func append(_ text: String) {
            charactersExamined += text.utf16.count
            for character in text {
                if character == "*" {
                    previousNewline = false
                    if pendingStar {
                        pendingStar = false
                        if partHasCharacters { touching = !partLastWhitespace }
                        partHasCharacters = false
                        partWords = 0
                        currentWord = nil
                        inKey.toggle()
                        if inKey { key += 1 }
                    } else {
                        pendingStar = true
                    }
                    continue
                }
                if pendingStar {
                    consume("*")
                    pendingStar = false
                }
                if character == "\n", previousNewline {
                    if words.count > (breaks.last ?? 0) { breaks.append(words.count) }
                    partHasCharacters = false
                    partWords = 0
                    currentWord = nil
                    touching = false
                    previousNewline = false
                } else {
                    consume(character)
                    previousNewline = character == "\n"
                }
            }
        }

        private func consume(_ character: Character) {
            let whitespace = character.isWhitespace
            if !partHasCharacters {
                partHasCharacters = true
                partFirstWhitespace = whitespace
            }
            partLastWhitespace = whitespace
            if whitespace {
                currentWord = nil
            } else if let currentWord {
                words[currentWord].text.append(character)
            } else {
                words.append(Word(text: String(character), key: inKey ? key : nil,
                                  joinsPrevious: partWords == 0 && touching && !partFirstWhitespace))
                partWords += 1
                currentWord = words.count - 1
            }
        }

        /// Only newly settled words and the unfinished tail reach the view.
        /// The parser keeps one word buffer and reuses completed paragraph Text.
        func present() -> AgentReplyPresentation {
            let settled = currentWord ?? words.count
            while presentation.committedWords < settled {
                let index = presentation.committedWords
                wordsMaterialized += 1
                presentation.commit(words[index], at: index, paragraphStart: paragraphStart(at: index))
            }
            if currentWord != nil || pendingStar {
                let index = currentWord ?? words.count
                wordsMaterialized += 1
                presentation.showTail(word(at: index), at: index, paragraphStart: paragraphStart(at: index))
            } else {
                presentation.showTail(nil, at: words.count, paragraphStart: 0)
            }
            return presentation
        }

        private func paragraphStart(at index: Int) -> Int {
            while presentedBreaks < breaks.count, breaks[presentedBreaks] <= index {
                presentedParagraphStart = breaks[presentedBreaks]
                presentedBreaks += 1
            }
            return presentedParagraphStart
        }

        func paragraphs() -> [[Word]] {
            var snapshot = words
            if pendingStar {
                if let currentWord {
                    snapshot[currentWord].text += "*"
                } else {
                    snapshot.append(word(at: snapshot.count))
                }
            }
            var paragraphs: [[Word]] = []
            var start = 0
            for end in breaks where end > start {
                wordsMaterialized += end - start
                paragraphs.append(Array(snapshot[start..<end]))
                start = end
            }
            if start < snapshot.count {
                wordsMaterialized += snapshot.count - start
                paragraphs.append(Array(snapshot[start...]))
            }
            return paragraphs
        }
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
    /// How far the glass has cleared for the agent's work on the page. At
    /// `watching` the chat steps aside: the thread goes, the composer stays.
    @Published private(set) var watch: AgentWatchLevel = .none
    /// While watching: what the agent is doing, over the composer, in the
    /// step's own words ("Opening Tasks", "Writing in your note").
    @Published private(set) var liveLabel: String?

    // MARK: The composer's controls

    /// Who answers the next message: the same setting as Settings → In-app
    /// agent → Agent. A change never touches a run already going.
    @Published var agent: AgentBackend = .claude {
        didSet {
            if agent != oldValue {
                agentChanged?(agent)
                #if DEBUG && ATTIC_LOCAL_ONLY
                AgentPassProbe.mark(agent == .claude ? "SelectedClaude" : "SelectedCodex")
                #endif
            }
        }
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
    private var uiTestSeededPairs = 0
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
    /// A change the agent has just made, shown being made on its page: the
    /// page forward, the change played in, then back. Nil when there is
    /// nothing to show. Set by the shell; asked only while watching, and only
    /// once the change is saved.
    var presentWatched: ((AgentWatchedAction) -> (() async -> Void)?)?
    /// The Tasks rows on show, with their titles, for a reply's hover ping.
    var rowTitles: () -> [(id: UUID, title: String)] = { [] }
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
    /// A stopped run still drains committed action receipts before its thread
    /// can be archived. Keep an immediate next message until that completes.
    private var newChatDrainTask: Task<Void, Never>?
    private typealias QueuedSend = (text: String, context: AgentRequestContext,
                                    attachments: [AgentChatAttachment])
    private var newChatQueuedSend: QueuedSend?
    private var pendingQueuedSaveFailure: String?
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
    /// The page the agent switched to while it is watched: the chip names it
    /// once the change has been seen and the chat comes back, not at the
    /// switch (the drawing's chip turns over as the thread returns).
    private var chipAfterWatching: AgentPage?
    /// The run's events, stamped as they arrive, for the step beats.
    private var feedTask: Task<Void, Never>?
    /// When each shown step started, and when the last one turned done.
    private var stepShownAt: [UUID: Date] = [:]
    private var lastStepDone: Date?
    /// A watched action ended: the chat comes back unless the next event
    /// is another one to watch.
    private var returnPending: UUID?
    /// The glance step the glass thinned for.
    private var glanceStep: UUID?
    /// Entries already drawn once: a reopened thread does not replay them.
    private var presented: Set<UUID> = []
    private var nextWordTime: Date?
    private var replyEnds: Date?
    private var replyParser: AgentChatWords.Stream?
    #if DEBUG
    private(set) var replyParsingCharactersExamined = 0
    private(set) var replyParsingWordsMaterialized = 0
    #endif
    /// While a saved thread is put back: its words are already written.
    private var restoring = false

    /// True only while `panelDidHide` closes the chat.
    private(set) var closedAtOnce = false

    var isOpen: Bool { bar.isChatOpen }
    private(set) var watchingGeneration: UInt64 = 0
    func isWatching(_ generation: UInt64) -> Bool { isOpen && watchingGeneration == generation }
    var isConnected: Bool { runner != nil }
    var isBusy: Bool { isRunning }

    /// The one place a runner comes in. `AppCoordinator` calls it.
    func connect(_ runner: AgentRunning) {
        runTask?.cancel()
        newChatDrainTask?.cancel()
        newChatDrainTask = nil
        newChatQueuedSend = nil
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
        presented = Set(entries.map(\.id))
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
        replyParser = nil
        for message in archived {
            switch message.role {
            case "user": entries.append(AgentChatEntry(.asked(message.text)))
            case "assistant": if !message.text.isEmpty { appendText(message.text); closeReply() }
            case "tool", "error", "notice": entries.append(AgentChatEntry(.note(message.text)))
            case "receipt":
                if let set = message.changeSet {
                    let canUndo = runner?.canUndoRecovered(set.id) == true
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
                        state: canUndo ? .ready : .recovered))))
                    if !canUndo {
                        entries.append(AgentChatEntry(.note("Review these saved changes. Undo from a previous app session is unavailable.")))
                    }
                }
            default: break
            }
        }
    }

    // MARK: Open and close

    func open() {
        closedAtOnce = false
        guard !isOpen else { return }
        watchingGeneration &+= 1
        IdleLatencyTrace.controlDispatched(.chat)
        #if DEBUG && ATTIC_LOCAL_ONLY
        AgentPassProbe.beginOpen()
        #endif
        chipPage = currentPage()
        chipAfterWatching = nil
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
        watchingGeneration &+= 1
        stopWatching()
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
                // A timer in the common modes: it still fires while a menu
                // this seam opened is tracking (a main-queue block would not).
                let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if command.hasPrefix("tap:") { AgentChatUITestSeams.tap(String(command.dropFirst(4))) }
                        else if command.hasPrefix("menu-pick:") { AgentChatUITestSeams.pick(Int(command.dropFirst(10)) ?? 0) }
                        else if command == "menu-cancel" { AgentChatUITestSeams.cancel() }
                        else { self?.uiTestQuery = String(command.dropFirst(7)) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
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
            if pieces[0].hasPrefix("mem:") {
                let target = min(240, max(0, Int(pieces[0].dropFirst(4)) ?? 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let self else { return }
                    while self.uiTestSeededPairs < target {
                        self.seedExchangeForUITesting(
                            asked: "How can I plan this task?",
                            reply: String(repeating: "Plan a short task, record progress, review priorities. ", count: 10))
                        self.uiTestSeededPairs += 1
                    }
                    #if ATTIC_LOCAL_ONLY
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        AgentPassProbe.footprint("Thread\(target)")
                    }
                    #endif
                }
                continue
            }
            if pieces[0] == "stop" || pieces[0] == "new-chat" {
                let command = String(pieces[0])
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if command == "stop" { self?.stop() } else { self?.newChat() }
                }
                continue
            }
            if pieces[0].hasPrefix("agent:") {
                let backend = String(pieces[0].dropFirst(6))
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    if let selection = AgentBackend(rawValue: backend) { self?.agent = selection }
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
            if pieces[0] == "allow" {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.resolveApproval(allow: true) }
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
        if let page, page == agentGoingTo, watch == .watching {
            chipAfterWatching = page
        } else {
            chipAfterWatching = nil
            if chipPage != page { chipPage = page }
        }
        defer { agentGoingTo = nil }
        if isOpen, page != agentGoingTo { close() }
    }

    // MARK: Sending

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG && ATTIC_LOCAL_ONLY
        if isRunning { AgentPassProbe.mark("SendRejectedWhileRunning") }
        #endif
        guard !text.isEmpty, !isRunning, let runner else { return }
        #if DEBUG && ATTIC_LOCAL_ONLY
        AgentPassProbe.beginSend()
        AgentPassProbe.mark("SendStarted")
        #endif
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
        if newChatDrainTask != nil {
            // The queued request already owns this context while the old run drains.
            newChatQueuedSend = (text, context, attachments)
            attachments = []
            attachmentRefusal = nil
            return
        }
        sendToRunner(text, context: context)
    }

    private func sendToRunner(_ text: String, context: AgentRequestContext, queued: QueuedSend? = nil) {
        guard let runner else { runEnded(); return }
        let sent = runner.send(text, context: context, watching: isOpen)
        if runner.retainsThread && !runner.threadSnapshot().isRunning {
            // The live runner refused to persist the question. Keep the draft
            // and its attachments so the owner can retry without losing input.
            if let queued {
                if draft.isEmpty && attachments.isEmpty {
                    draft = text
                    attachments = queued.attachments
                } else {
                    pendingQueuedSaveFailure = Self.unsentQueuedNotice(queued)
                }
            } else {
                draft = text
            }
            restore(runner.threadSnapshot().entries)
            listen(to: sent)
            return
        }
        // Only an accepted request consumes its attached context.
        if queued == nil {
            attachments = []
            attachmentRefusal = nil
        }
        let stream = runner.retainsThread ? runner.observe() : sent
        listen(to: stream)
    }

    private static func unsentQueuedNotice(_ queued: QueuedSend) -> String {
        let names = queued.attachments.map(\.name)
        let attached = names.isEmpty ? "" : " Attached: \(names.joined(separator: ", "))."
        return "The previous message was not sent: \(queued.text).\(attached) Copy it to retry."
    }

    /// The run's events reach the thread in order. They are stamped as they
    /// arrive, so the thread can hold a step for its beat or a watched change
    /// while the run goes on: the run never waits for what is shown, and
    /// events that queued up behind skip their beats until it catches up.
    private func listen(to stream: AsyncStream<AgentEvent>, skipping replayed: Int = 0) {
        runTask?.cancel()
        feedTask?.cancel()
        let (stamped, feed) = AsyncStream.makeStream(of: (event: AgentEvent, arrived: Date).self)
        if pacing.stepRun > 0 || pacing.stepHandover > 0 {
            feedTask = Task { [now] in
                for await event in stream { feed.yield((event, now())) }
                feed.finish()
            }
        } else {
            // No beats to hold (tests' `.instant`): the events as they come.
            feedTask = nil
            feed.finish()
            runTask = Task { [weak self] in
                var skipped = 0
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    if skipped < replayed { skipped += 1; continue }
                    guard let self else { return }
                    await self.handle(event, arrived: self.now())
                }
                if !Task.isCancelled { self?.runEnded() }
            }
            return
        }
        runTask = Task { [weak self] in
            var skipped = 0
            for await (event, arrived) in stamped {
                guard !Task.isCancelled else { return }
                if skipped < replayed { skipped += 1; continue }
                guard let self else { return }
                await self.handle(event, arrived: arrived)
            }
            if !Task.isCancelled { self?.runEnded() }
        }
    }

    /// One event: its reply's words and its beat first, then the chat steps
    /// aside for it if it is watched, then it lands.
    private func handle(_ event: AgentEvent, arrived: Date) async {
        await waitForReply(before: event)
        await beat(before: event, arrived: arrived)
        guard !Task.isCancelled else { return }
        watchBefore(event)
        if let present = watched(before: event) { await present() }
        guard !Task.isCancelled else { return }
        apply(event)
        watchAfter(event)
    }

    // MARK: Step beats

    /// Holds a step's turn: running for `stepRun`, and the last one's check
    /// drawn before the next arrives. Only while open, with motion, and only
    /// for an event that has not already waited `catchUp`.
    private func beat(before event: AgentEvent, arrived: Date) async {
        guard isOpen, !reducesMotion() else { return }
        let due: Date?
        switch event {
        case let .stepStarted(step) where step.kind != .openPage:
            due = lastStepDone?.addingTimeInterval(pacing.stepHandover)
        case let .stepFinished(step):
            due = stepShownAt[step.id]?.addingTimeInterval(pacing.stepRun)
        default:
            due = nil
        }
        guard let due, now().timeIntervalSince(arrived) < pacing.catchUp else { return }
        // Never longer than the catch-up allows from the event's arrival.
        let until = min(due, arrived.addingTimeInterval(pacing.catchUp))
        let wait = until.timeIntervalSince(now())
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    // MARK: Watching

    /// The chat steps aside for a step that works on a page you can watch,
    /// and thins its glass for rows being read or moved on Tasks. A watched
    /// action that just ended stays aside only for the next one.
    private func watchBefore(_ event: AgentEvent) {
        if case .approvalNeeded = event {
            // The approval card comes first, over the chat as it is.
            stopWatching()
            return
        }
        guard isOpen else { return }
        if case let .stepStarted(step) = event, AgentWatchedAction.watchable(step),
           !(step.kind == .openPage && step.targets.first?.page == currentPage()) {
            returnPending = nil
            setWatch(.watching, label: step.title)
            return
        }
        if returnPending != nil {
            returnPending = nil
            let glance = Self.glances(event)
            setWatch(glance ? .glance : .none, label: nil)
            effects.send(.watchEnded)
            if glance, case let .stepStarted(step) = event { glanceStep = step.id }
            return
        }
        if watch == .none, case let .stepStarted(step) = event, Self.glances(event) {
            glanceStep = step.id
            setWatch(.glance, label: nil)
        }
    }

    private func watchAfter(_ event: AgentEvent) {
        switch event {
        case let .stepStarted(step):
            if isOpen { stepShownAt[step.id] = now() }
        case let .stepFinished(step):
            stepShownAt[step.id] = nil
            if isOpen { lastStepDone = now() }
            if step.id == glanceStep {
                glanceStep = nil
                if watch == .glance { setWatch(.none, label: nil) }
            }
            if watch == .watching, isOpen { endWatching() }
        case .failed:
            stopWatching()
        case .finished:
            if watch == .watching { endWatching() } else if watch == .glance { setWatch(.none, label: nil) }
        default:
            break
        }
    }

    /// Steps whose rows show through a thinned glass: Tasks rows read, moved
    /// or deleted.
    private static func glances(_ event: AgentEvent) -> Bool {
        guard case let .stepStarted(step) = event else { return false }
        switch step.kind {
        case .read: return step.targets.contains { $0.page == .tasks }
        case .move, .delete: return true
        default: return false
        }
    }

    /// A watched action is done: back after `watchReturn`, unless another
    /// one starts first.
    private func endWatching() {
        let token = UUID()
        returnPending = token
        let wait = pacing.watchReturn
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, self.returnPending == token else { return }
            self.returnPending = nil
            self.setWatch(.none, label: nil)
            if self.isOpen { self.effects.send(.watchEnded) }
        }
    }

    /// Back at once: closed, a new chat, an approval.
    private func stopWatching() {
        returnPending = nil
        glanceStep = nil
        setWatch(.none, label: nil)
    }

    private func setWatch(_ level: AgentWatchLevel, label: String?) {
        if watch != level { watch = level }
        if liveLabel != label { liveLabel = label }
        if level == .none, let page = chipAfterWatching {
            chipAfterWatching = nil
            if chipPage != page { chipPage = page }
        }
    }

    /// The pointer and the page's motion, sent only while the chat is open.
    func watchEffect(_ effect: AgentChatEffect) {
        if isOpen { effects.send(effect) }
    }

    /// Hovering a reply's underlined phrase: the Tasks rows it names light
    /// up (the design matches the phrase's first word).
    func pingPhrase(_ phrase: String) {
        guard isOpen, let word = phrase.split(whereSeparator: \.isWhitespace).first?.lowercased(), !word.isEmpty else { return }
        let ids = rowTitles().filter { $0.title.lowercased().contains(word) }.map(\.id)
        if let first = ids.first { effects.send(.pingRows([first])) }
    }

    func stop() {
        guard isRunning else { return }
        #if DEBUG && ATTIC_LOCAL_ONLY
        AgentPassProbe.mark("StopRequested")
        #endif
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
        newChatDrainTask?.cancel()
        newChatDrainTask = nil
        newChatQueuedSend = nil
        pendingQueuedSaveFailure = nil
        let draining = runner?.retainsThread == true && runner?.threadSnapshot().isRunning == true
        if isRunning || draining { runner?.cancel() }
        runTask?.cancel()
        runTask = nil
        feedTask?.cancel()
        feedTask = nil
        let beforeForget = runner?.threadSnapshot().entries
        runner?.forgetThread()
        if !draining, runner?.retainsThread == true,
           let beforeForget, !beforeForget.isEmpty,
           runner?.threadSnapshot().entries == beforeForget {
            // Failed journal write: the runner still owns the old thread.
            // The view must keep it visible and available for another try.
            restore(beforeForget)
            presented = Set(entries.map(\.id))
            runEnded()
            return
        }
        if draining, let runner {
            newChatDrainTask = Task { [weak self] in
                // The runner finishes this stream only after action receipts
                // are committed and the previous conversation is archived.
                for await _ in runner.observe() {}
                guard !Task.isCancelled, let self else { return }
                self.newChatDrainTask = nil
                if runner.threadSnapshot().entries.contains(where: { $0.role == "user" }) {
                    // Deferred forgetting failed during the old run's final save.
                    // A queued send must not accidentally enter that old thread.
                    self.restore(runner.threadSnapshot().entries)
                    self.presented = Set(self.entries.map(\.id))
                    if let queued = self.newChatQueuedSend {
                        if self.draft.isEmpty && self.attachments.isEmpty {
                            self.draft = queued.text
                            self.attachments = queued.attachments
                        } else {
                            self.entries.append(AgentChatEntry(.note(Self.unsentQueuedNotice(queued))))
                        }
                    }
                    self.newChatQueuedSend = nil
                    self.runEnded()
                    self.refreshBar()
                    self.refreshHistory()
                    return
                }
                self.refreshHistory()
                if let queued = self.newChatQueuedSend {
                    self.newChatQueuedSend = nil
                    self.sendToRunner(queued.text, context: queued.context, queued: queued)
                }
            }
        }
        stopWatching()
        isRunning = false
        entries = []
        replyParser = nil
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
        feedTask?.cancel()
        feedTask = nil
        stopWatching()
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
        chipAfterWatching = nil
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
        #if DEBUG && ATTIC_LOCAL_ONLY
        AgentPassProbe.mark(failure == nil ? "UndoSucceeded" : "UndoRefused")
        #endif
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

    /// A watched change finishes once it has been seen being made: its row
    /// turns done as the chat comes back. The change is saved already (a
    /// step finishes only once its action has committed). Closed, it lands
    /// as it is.
    private func watched(before event: AgentEvent) -> (() async -> Void)? {
        guard isOpen, let presentWatched else { return nil }
        let action: AgentWatchedAction
        let label: String
        switch event {
        case let .stepStarted(step) where step.kind == .openPage,
             let .stepFinished(step) where step.kind == .openPage:
            // A run's open_page knows its page once it has answered.
            guard let page = step.targets.first?.page, page != currentPage() else { return nil }
            action = .openPage(page)
            label = liveLabel ?? step.title
        case let .stepFinished(step):
            guard let finished = AgentWatchedAction.finished(step) else { return nil }
            action = finished
            // The step's running words, as the thread shows them.
            label = entries.first { $0.id == step.id }.flatMap { entry -> String? in
                if case let .step(shown) = entry.content { shown.title } else { nil }
            } ?? step.title
        default:
            return nil
        }
        guard let present = presentWatched(action) else { return nil }
        return { [weak self] in
            guard let self, self.isOpen else { return }
            if self.currentPage() != action.page { self.agentGoingTo = action.page }
            self.returnPending = nil
            self.setWatch(.watching, label: label)
            await present()
            // An open-page step ends here; a change ends with its step.
            if case .openPage = action, self.watch == .watching, self.isOpen { self.endWatching() }
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
        case let .stepFinished(step):
            #if DEBUG && ATTIC_LOCAL_ONLY
            if case .done = step.state { AgentPassProbe.mark("StepDone") }
            #endif
            stepFinished(step)
        case let .progress(done, total):
            progress = (done, total)
            refreshBar()
        case let .approvalNeeded(request):
            #if DEBUG && ATTIC_LOCAL_ONLY
            AgentPassProbe.mark("ApprovalRequested")
            #endif
            guard approval?.id != request.id,
                  !queuedApprovals.contains(where: { $0.id == request.id }) else { return }
            if approval == nil { approval = request }
            else { queuedApprovals.append(request) }
            phase = .needsYou
            refreshBar()
        case let .changes(set):
            #if DEBUG && ATTIC_LOCAL_ONLY
            AgentPassProbe.mark("ReceiptChanges", value: Double(set.count))
            #endif
            changesArrived(set)
        case let .notice(message): entries.append(AgentChatEntry(.note(message)))
        case .finished:
            #if DEBUG && ATTIC_LOCAL_ONLY
            AgentPassProbe.mark("RunFinished")
            #endif
            runEnded()
        case let .failed(message):
            #if DEBUG && ATTIC_LOCAL_ONLY
            AgentPassProbe.mark("RunFailed")
            #endif
            if message == AgentRunEngine.journalSaveFailure {
                // The runner reverted an uncommitted streamed answer. Restore
                // the actual checkpoint, including any durable action receipts.
                restore(runner?.threadSnapshot().entries ?? [])
                presented = Set(entries.map(\.id))
                pendingItems = []
                pendingSteps = []
                runWeek = nil
                runChangeCount = 0
                nextWordTime = nil
                replyEnds = nil
            }
            if let pendingQueuedSaveFailure {
                entries.append(AgentChatEntry(.note(pendingQueuedSaveFailure)))
                self.pendingQueuedSaveFailure = nil
            }
            entries.append(AgentChatEntry(.note(message)))
            runEnded()
        }
    }

    private func appendText(_ text: String) {
        #if DEBUG && ATTIC_LOCAL_ONLY
        if !restoring && !text.isEmpty { AgentPassProbe.firstDelta() }
        #endif
        phase = .acting
        let time = now()
        var reply = AgentChatReply()
        var id: UUID?
        if let last = entries.last, case let .reply(current) = last.content, current.marksStart == nil {
            reply = current
            id = last.id
        }
        if id == nil { replyParser = AgentChatWords.Stream() }
        let parser = replyParser ?? AgentChatWords.Stream()
        replyParser = parser
        reply.raw += text
        #if DEBUG
        let previousCharacters = parser.charactersExamined
        #endif
        parser.append(text)
        #if DEBUG
        replyParsingCharactersExamined += parser.charactersExamined - previousCharacters
        #endif
        // Closed, or with Reduce Motion: already written when it is next seen.
        let writes = isOpen && !reducesMotion() && !restoring
        var next = writes ? max(nextWordTime ?? time, time) : time
        while reply.wordTimes.count < parser.wordCount {
            let word = parser.word(at: reply.wordTimes.count)
            reply.wordTimes.append(writes ? next : .distantPast)
            next += AgentChatWords.gap(after: word.text, pacing: pacing)
        }
        #if DEBUG
        let previousMaterialized = parser.wordsMaterialized
        #endif
        reply.parsed = isOpen && !restoring ? parser.present() : nil
        #if DEBUG
        replyParsingWordsMaterialized += parser.wordsMaterialized - previousMaterialized
        #endif
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
        replyParser = nil
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
        if step.kind == .openPage {
            // Watching with no watcher to show it: the page comes forward as it is.
            if isOpen, let page = step.targets.first?.page, page != currentPage() {
                agentGoingTo = page
                openPage?(page)
            }
            return
        }
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
