import Foundation

/// The seam between the agent's run and the chat view. The view reads events and
/// calls these methods; it never reaches into tools or the model connection.
enum AgentPage: String, Sendable, Equatable, CaseIterable, Codable {
    case tasks, notes, calendar, draw
}

/// One thing a step touches, so the chat can animate the real row, note or event.
struct AgentTarget: Sendable, Equatable, Codable {
    var page: AgentPage
    var itemID: UUID? = nil
    var title: String? = nil
    /// EventKit occurrence identifiers are strings, not app UUIDs.
    var externalID: String? = nil
    /// The canvas containing a Draw object (itemID is the actual object).
    var containerID: UUID? = nil
}

enum AgentStepState: Sendable, Equatable {
    case running, done, partial(String), failed(String)
}

/// How a step changes what's on screen, so the view can pick its motion.
enum AgentStepKind: Sendable, Equatable {
    case read, create, update, move(toDay: Date?), delete, openPage
}

struct AgentStep: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var kind: AgentStepKind
    var targets: [AgentTarget]
    var state: AgentStepState
}

struct AgentApproval: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var targets: [AgentTarget]
}

/// Everything one request changed, undone as a whole.
struct AgentChangeSet: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    var title: String
    var pages: Set<AgentPage>
    var count: Int
}

enum AgentEvent: Sendable, Equatable {
    case textDelta(String)
    case stepStarted(AgentStep)
    case stepFinished(AgentStep)
    case progress(done: Int, total: Int)
    case approvalNeeded(AgentApproval)
    case changes(AgentChangeSet)
    case finished
    case failed(String)
}

/// Read-only conversation history, including messages sent before the panel reopened.
struct AgentThreadEntry: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let role: String
    var text: String
    /// Serialized commit receipt for review after process-local Undo expires.
    var changeSet: AgentChangeSet? = nil
    var targets: [AgentTarget]? = nil
}

struct AgentThreadSnapshot: Sendable, Equatable {
    let entries: [AgentThreadEntry]
    let events: [AgentEvent]
    let isRunning: Bool
}

/// `watching` is true while the chat is open. When false, the run must not move
/// the owner's page or take focus; it works in the background.
@MainActor
protocol AgentRunning: AnyObject {
    func send(_ text: String, watching: Bool) -> AsyncStream<AgentEvent>
    func setWatching(_ watching: Bool)
    func setMode(_ mode: AgentChatMode)
    func resolve(approval id: UUID, allow: Bool)
    func undo(changeSet id: UUID) async throws
    func cancel()
    /// Reattach to a running agent without starting a new request.
    func observe() -> AsyncStream<AgentEvent>
    func threadSnapshot() -> AgentThreadSnapshot
    /// The live backend owns its history and events across view lifetimes.
    var retainsThread: Bool { get }
    func forgetThread()
}

extension AgentRunning {
    func setMode(_ mode: AgentChatMode) {}
    // Existing scripted runners and test doubles continue to deliver their
    // events from send(). Only the live backend has a persistent thread.
    var retainsThread: Bool { false }
    func observe() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }
    func threadSnapshot() -> AgentThreadSnapshot {
        AgentThreadSnapshot(entries: [], events: [], isRunning: false)
    }
    func forgetThread() {}
}
