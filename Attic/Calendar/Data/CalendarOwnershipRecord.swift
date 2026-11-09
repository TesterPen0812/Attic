import Foundation

/// Confined to its transaction owner (the serial writer queue in the app).
final class CalendarOwnershipRecord {
    private struct Transition: Codable, Equatable {
        var id: UUID
        var before: CalendarWriteSnapshot?
        var after: CalendarWriteSnapshot?
        /// A single missing/stale read cannot prove a provider write failed.
        var observation: Observation?
    }
    private struct Observation: Codable, Equatable {
        var kind: String
        var count: Int
    }
    private struct State: Codable, Equatable {
        var version = 1
        var entries: [UUID: CalendarWriteSnapshot] = [:]
        var pending: Transition?
    }

    struct Recovery: Sendable {
        let id: UUID
        let before: CalendarWriteSnapshot?
        let after: CalendarWriteSnapshot?
    }

    private struct Resolution {
        let state: State
        let landed: Bool
        let recovery: Recovery?
    }

    private var state: State
    private let fileURL: URL?
    private let persist: (Data) throws -> Void
    var entries: [UUID: CalendarWriteSnapshot] { state.entries }
    var hasPendingTransition: Bool { state.pending != nil }

    /// No URL means memory-only (tests). The live factory supplies an app-local
    /// Application Support file. Corruption fails closed, never resets ownership.
    init(fileURL: URL? = nil, persist: ((Data) throws -> Void)? = nil) throws {
        self.fileURL = fileURL
        self.persist = persist ?? { data in
            if let fileURL { try data.write(to: fileURL, options: .atomic) }
        }
        state = try Self.read(fileURL) ?? State()
    }

    /// Refresh before each operation, including across two engine instances.
    /// Pending transactions are resolved from committed store state. This is
    /// also recovery after a crash between EventKit commit and file compaction.
    @discardableResult
    func reload(using store: CalendarEventWriteStore) throws -> Recovery? {
        if let disk = try Self.read(fileURL) { state = disk }
        guard state.pending != nil, store.accessState == .granted else { return nil }
        let resolution = resolvingPending(using: store)
        if resolution.state != state {
            try write(resolution.state)
            state = resolution.state
        }
        return resolution.recovery
    }

    /// Write-ahead proof BEFORE the calendar commit. No calendar write can be
    /// committed if this atomic write fails (disk full, permissions, etc.).
    func prepare(id: UUID, before: CalendarWriteSnapshot?, after: CalendarWriteSnapshot?) throws {
        guard state.pending == nil else {
            throw CalendarEventWriteError.saveFailed("A previous Calendar write is awaiting verification.")
        }
        var prepared = state
        prepared.pending = Transition(id: id, before: before, after: after, observation: nil)
        try write(prepared)
        state = prepared
    }

    /// Before commit, EventKit has only staged changes; it is safe to remove
    /// the prepared proof after rollback. Once commit is attempted, never do so.
    func abortUncommitted() throws {
        guard state.pending != nil else { return }
        var aborted = state
        aborted.pending = nil
        try write(aborted)
        state = aborted
    }

    @discardableResult
    func resolve(using store: CalendarEventWriteStore, commitConfirmed: Bool = false) -> (changed: Bool, landed: Bool) {
        guard state.pending != nil, store.accessState == .granted else { return (false, false) }
        let original = state
        let previous = state.entries
        let resolution = resolvingPending(using: store, commitConfirmed: commitConfirmed)
        state = resolution.state
        // Compaction is optional; a failure leaves the durable pending proof
        // for relaunch. Never claim an ambiguous outcome was finalized.
        if resolution.state != original { try? write(state) }
        return (state.entries != previous, resolution.landed)
    }

    private func resolvingPending(using store: CalendarEventWriteStore, commitConfirmed: Bool = false) -> Resolution {
        guard var pending = state.pending else { return Resolution(state: state, landed: false, recovery: nil) }
        var resolved = state
        if let after = pending.after,
           let live = store.event(identifier: after.itemIdentifier), live.matchesOwnership(of: after) {
            // Adopt committed IDs and provider observations, never stale staging.
            resolved.entries[pending.id] = live
            resolved.pending = nil
            return Resolution(state: resolved, landed: true,
                              recovery: Recovery(id: pending.id, before: pending.before, after: live))
        } else if let before = pending.before,
                  let live = store.event(identifier: before.eventIdentifier) ?? store.event(identifier: before.itemIdentifier),
                  live.matchesOwnership(of: before) {
            // A before-match immediately after commit may be a stale reader.
            // Require a second independent observation before rejecting it.
            if pending.observation?.kind == "before", pending.observation?.count == 1 {
                resolved.entries[pending.id] = live
                resolved.pending = nil
            } else {
                pending.observation = Observation(kind: "before", count: 1)
                resolved.pending = pending
            }
            return Resolution(state: resolved, landed: false, recovery: nil)
        } else if pending.after == nil, let before = pending.before,
                  store.event(identifier: before.eventIdentifier) == nil,
                  store.event(identifier: before.itemIdentifier) == nil {
            // A delete has no after-snapshot: absent under both provider IDs
            // is the delete's definitive observation.
            resolved.entries[pending.id] = nil
            resolved.pending = nil
            return Resolution(state: resolved, landed: true,
                              recovery: Recovery(id: pending.id, before: before, after: nil))
        } else {
            // A missing created event, or a changed existing event, proves
            // neither success nor failure. Hold the original journal intact.
            pending.observation = nil
        }
        resolved.pending = pending
        return Resolution(state: resolved, landed: false, recovery: nil)
    }

    private static func read(_ url: URL?) throws -> State? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard decoded.version == 1 else { throw CalendarEventWriteError.recordFailed("Unsupported ownership record version.") }
            return decoded
        } catch { throw recordError(error) }
    }

    private func write(_ value: State) throws {
        do { try persist(JSONEncoder().encode(value)) }
        catch { throw Self.recordError(error) }
    }

    private static func recordError(_ error: Error) -> CalendarEventWriteError {
        if let typed = error as? CalendarEventWriteError { return typed }
        return .recordFailed(error.localizedDescription)
    }
}
