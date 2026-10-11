import Combine
import Foundation
import SwiftData
import SwiftUI

/// Tag colours (colour pass, owner 2026-10-10): what each tag shows, and the
/// writes that give, carry and change them.
///
/// - **Given once, then stored.** A tag in use with no stored colour takes
///   `AtticTagHue.assigned(to:avoiding:)` (its hash, or the next hue no tag
///   in use has), oldest tag first, and that colour is stored, so it never
///   changes by itself. Until the store has it, the palette already shows
///   the colour it is about to store.
/// - **Duplicate-safe.** Presentation groups rows by name, picking newest time,
///   lowest UUID, then lowest colour key. Writes reach both every same-name
///   row and all physical replicas of their UUIDs, retaining divergent names.
/// - **Atomic.** Each write is one save of its own context; a failed save
///   rolls back and leaves the palette as it was.
@MainActor
final class TagColourStore: ObservableObject {
    /// Every tag's hue as the app draws it.
    @Published private(set) var palette: AtticTagPalette = .empty
    private(set) var lastErrorMessage: String?

    private let container: ModelContainer
    private let persist: (ModelContext) throws -> Void
    private let now: () -> Date

    init(
        container: ModelContainer,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping () -> Date = Date.init
    ) {
        self.container = container
        self.persist = persist
        self.now = now
    }

    // MARK: Reading

    /// One hue per name among replicas: the newest change wins, then the
    /// lowest id, so every device and every launch agree. Rows with no
    /// colour, or one this version doesn't know, are skipped.
    static func storedHues(_ rows: [TagColour]) -> [String: AtticTagHue] {
        var winners: [String: TagColour] = [:]
        for row in rows where row.hue != nil {
            guard let current = winners[row.name] else { winners[row.name] = row; continue }
            if row.modifiedAt > current.modifiedAt
                || (row.modifiedAt == current.modifiedAt && (row.id.uuidString < current.id.uuidString
                    || (row.id == current.id && row.colourKey! < current.colourKey!))) {
                winners[row.name] = row
            }
        }
        return winners.compactMapValues(\.hue)
    }

    /// Rebuilds the palette for the tags in use (oldest first) and stores a
    /// colour for each one that has none, in one save. Returns false if
    /// that save failed (rolled back; the palette still shows the colours,
    /// and the next refresh tries again).
    @discardableResult
    func refresh(inUse names: [String]) -> Bool {
        let context = ModelContext(container)
        let rows: [TagColour]
        do {
            rows = try context.fetch(FetchDescriptor<TagColour>())
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let stored = Self.storedHues(rows)
        let resolved = AtticTagPalette.resolve(inUse: names, stored: stored)
        if resolved != palette { palette = resolved }

        // Store what was resolved: fill a name's colourless rows, or add a
        // row for a name that has none. A row holding an unknown colour is
        // a newer Attic's choice and stays as it is.
        let rowsByName = Dictionary(grouping: rows, by: \.name)
        let date = now()
        var changed = false
        for name in names where stored[name] == nil {
            guard let hue = resolved.hues[name] else { continue }
            let existing = rowsByName[name] ?? []
            if existing.isEmpty {
                context.insert(TagColour(name: name, hue: hue, at: date))
                changed = true
            } else if existing.allSatisfy({ $0.colourKey == nil }) {
                for row in existing {
                    row.colourKey = hue.rawValue
                    row.modifiedAt = date
                }
                changed = true
            }
        }
        guard changed else { return true }
        return save(context)
    }

    // MARK: Writing

    /// Changes a tag's colour (the tag menu): every row of its name, or a
    /// new row when it has none. False, changing nothing, if the save fails.
    @discardableResult
    func setHue(_ hue: AtticTagHue, for tag: String) -> Bool {
        guard let name = AtticTag.normalize(tag) else { return false }
        let context = ModelContext(container)
        do {
            try write(hue, for: name, in: context)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        guard save(context) else { return false }
        // A UUID replica can carry a divergent name. Publish every affected
        // alias as well, without renaming or deleting any physical row.
        do {
            let stored = Self.storedHues(try context.fetch(FetchDescriptor<TagColour>()))
            var updated = palette
            for (name, hue) in stored { updated.hues[name] = hue }
            palette = updated
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        return true
    }

    /// A rename or merge, inside its own context and before its save: the
    /// target keeps its colour when it is already in use (merging into it);
    /// otherwise it takes the first source's colour (a rename keeps the
    /// colour). The sources' rows stay, so undoing the rename brings the
    /// old name back in its colour.
    func carry(from sources: [String], to target: String, targetInUse: Bool, in context: ModelContext) throws {
        let stored = Self.storedHues(try context.fetch(FetchDescriptor<TagColour>()))
        guard let source = sources.first else { return }
        let name = targetInUse ? target : source
        let hue = stored[name] ?? AtticTagHue.assigned(to: name, avoiding: Set(stored.values))
        try write(hue, for: target, in: context)
    }

    // MARK: Private

    private func rows(named name: String, in context: ModelContext) throws -> [TagColour] {
        try context.fetch(FetchDescriptor<TagColour>(predicate: #Predicate { $0.name == name }))
    }

    private func write(_ hue: AtticTagHue, for name: String, in context: ModelContext) throws {
        let date = now()
        let all = try context.fetch(FetchDescriptor<TagColour>())
        let ids = Set(all.filter { $0.name == name }.map(\.id))
        let existing = all.filter { $0.name == name || ids.contains($0.id) }
        if existing.isEmpty {
            context.insert(TagColour(name: name, hue: hue, at: date))
        }
        for row in existing {
            row.colourKey = hue.rawValue
            row.modifiedAt = date
        }
    }

    private func save(_ context: ModelContext) -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
            return true
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Environment

/// Puts the library's tag colours in the environment, observed, with the
/// tag menu's Colour action (an undoable library change). One structure
/// whether or not a library is there yet, so nothing below remounts when
/// it arrives.
private struct AtticTagColourEnvironment: ViewModifier {
    weak var library: AtticLibrary?
    @State private var palette: AtticTagPalette = .empty

    func body(content: Content) -> some View {
        let changes: AnyPublisher<AtticTagPalette, Never> = library?.tagColours.$palette.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
        content
            .environment(\.atticTagColouring, AtticTagColouring(palette: palette, setHue: library.map { library in
                { [weak library] tag, hue in library?.setTagHue(hue, for: tag) }
            }))
            .onReceive(changes) { if $0 != palette { palette = $0 } }
    }
}

extension View {
    /// Every tag below draws in its stored colour and offers the Colour row.
    func atticTagColours(_ library: AtticLibrary?) -> some View {
        modifier(AtticTagColourEnvironment(library: library))
    }
}
