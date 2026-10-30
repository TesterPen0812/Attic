import Foundation

@MainActor
final class CalendarOwnershipRecord {
    private struct Transition: Codable {
        var id: UUID
        var before: CalendarWriteSnapshot?
        var after: CalendarWriteSnapshot?
    }
    private struct State: Codable {
        var version = 1
        var entries: [UUID: CalendarWriteSnapshot] = [:]
        var pending: Transition?
    }

    private var state: State
    private let fileURL: URL?
    private let persist: (Data) throws -> Void
    var entries: [UUID: CalendarWriteSnapshot] { state.entries }

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
    func reload(using store: CalendarEventWriteStore) throws {
        if let disk = try Self.read(fileURL) { state = disk }
        guard state.pending != nil else { return }
        let resolved = resolvingPending(using: store).state
        try write(resolved)
        state = resolved
    }

    /// Write-ahead proof BEFORE the calendar commit. No calendar write can be
    /// committed if this atomic write fails (disk full, permissions, etc.).
    func prepare(id: UUID, before: CalendarWriteSnapshot?, after: CalendarWriteSnapshot?) throws {
        var prepared = state
        prepared.pending = Transition(id: id, before: before, after: after)
        try write(prepared)
        state = prepared
    }

    @discardableResult
    func resolve(using store: CalendarEventWriteStore) -> (changed: Bool, landed: Bool) {
        guard state.pending != nil, store.accessState == .granted else { return (false, false) }
        let previous = state.entries
        let resolution = resolvingPending(using: store)
        state = resolution.state
        // Compaction is optional: the already durable journal recovers either
        // outcome. A failure here must not report a committed write as failed.
        try? write(state)
        return (state.entries != previous, resolution.landed)
    }

    private func resolvingPending(using store: CalendarEventWriteStore) -> (state: State, landed: Bool) {
        guard let pending = state.pending else { return (state, false) }
        var resolved = state
        var landed = false
        if let after = pending.after,
           let live = store.event(identifier: after.itemIdentifier), live.matchesOwnership(of: after) {
            // Adopt committed IDs and provider observations, never stale staging.
            resolved.entries[pending.id] = live
            landed = true
        } else if let before = pending.before,
                  let live = store.event(identifier: before.eventIdentifier) ?? store.event(identifier: before.itemIdentifier),
                  live.matchesOwnership(of: before) {
            resolved.entries[pending.id] = live
        } else {
            resolved.entries[pending.id] = nil
            // Absence proves the requested delete only when both identifiers
            // are gone; a changed, still-present event remains ambiguous.
            if pending.after == nil, let before = pending.before {
                landed = store.event(identifier: before.eventIdentifier) == nil
                    && store.event(identifier: before.itemIdentifier) == nil
            }
        }
        resolved.pending = nil
        return (resolved, landed)
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
