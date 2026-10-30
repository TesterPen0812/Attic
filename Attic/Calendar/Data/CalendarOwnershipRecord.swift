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
        guard let pending = state.pending else { return }
        var resolved = state
        if let after = pending.after,
           let live = store.event(identifier: after.itemIdentifier),
           Self.matchesStaged(live, after) {
            resolved.entries[pending.id] = live
        } else if let before = pending.before,
                  store.event(identifier: before.eventIdentifier) == before {
            resolved.entries[pending.id] = before
        } else {
            // Missing, changed, or a committed delete: no ownership to claim.
            resolved.entries[pending.id] = nil
        }
        resolved.pending = nil
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

    func finish(committed: Bool, using store: CalendarEventWriteStore) {
        guard let pending = state.pending else { return }
        if committed, let after = pending.after {
            // EventKit may assign its event ID only at commit. The item ID was
            // allocated at creation; require it and every other proof field.
            let live = store.event(identifier: after.itemIdentifier)
            state.entries[pending.id] = live.flatMap { Self.matchesStaged($0, after) ? $0 : nil } ?? after
        } else {
            state.entries[pending.id] = committed ? nil : pending.before
        }
        state.pending = nil
        // Compaction is optional: the already durable journal recovers either
        // outcome. A failure here must not report a committed write as failed.
        try? write(state)
    }

    private static func matchesStaged(_ live: CalendarWriteSnapshot, _ staged: CalendarWriteSnapshot) -> Bool {
        var comparable = live
        comparable.eventIdentifier = staged.eventIdentifier
        return comparable == staged
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
