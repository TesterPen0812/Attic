import Foundation
import SwiftUI

/// The canvas menu under the title capsule (Accepted 2026-10-31, "Draw:
/// the canvas page", Title; D4): the canvases, newest first, filtered live
/// by the capsule's text through the store's `search`, with a check on the
/// open one; New canvas (New canvas “…” once there is filter text); then,
/// with no filter, the open canvas's Rename, Tags…, Linked from… (greyed
/// until linking exists), Duplicate, Export…, Copy as Image (greyed until
/// job 3 supplies them) and Delete (to Recently Deleted).
///
/// The page binds the capsule's text to `filter`, forwards Return to
/// `openFirstMatch()` and ↑ ↓ to `moveHighlight(by:)`, and tells the model
/// which canvas is open (`currentCanvasID`).
@MainActor
final class DrawLibraryMenuModel: ObservableObject {
    enum Command: String, CaseIterable, Sendable {
        case rename, tags, linkedFrom, duplicate, export, copyAsImage, delete

        var title: String {
            switch self {
            case .rename: String(localized: "Rename")
            case .tags: String(localized: "Tags…")
            case .linkedFrom: String(localized: "Linked from…")
            case .duplicate: String(localized: "Duplicate")
            case .export: String(localized: "Export…")
            case .copyAsImage: String(localized: "Copy as Image")
            case .delete: String(localized: "Delete")
            }
        }

        /// The menus' one icon family (AtticMenuSymbols' names where it has them).
        var systemImage: String {
            switch self {
            case .rename: "pencil"
            case .tags: "tag"
            case .linkedFrom: "link"
            case .duplicate: "plus.square.on.square"
            case .export: "square.and.arrow.up"
            case .copyAsImage: "photo.on.rectangle"
            case .delete: "trash"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case canvas(DrawCanvas)
            /// "No canvases match “…”": shown, never chosen.
            case noMatch
            case newCanvas(name: String?)
            case command(Command)
        }

        let kind: Kind
        let title: String
        /// The canvas's date.
        var detail: String?
        var isEnabled = true
        var isOpen = false
        var isDestructive = false
        /// A rule above it (before Rename).
        var startsSection = false

        var id: String {
            switch kind {
            case let .canvas(canvas): "canvas-\(canvas.id.uuidString)"
            case .noMatch: "no-match"
            case .newCanvas: "new-canvas"
            case let .command(command): "command-\(command.rawValue)"
            }
        }

        var canvas: DrawCanvas? { if case let .canvas(canvas) = kind { canvas } else { nil } }
    }

    enum Mode: Equatable {
        case list
        /// Tags…: the app's tag picker in the menu's place.
        case tags
    }

    let store: any DrawStoreProtocol
    let actions: DrawLibraryActions

    /// The capsule's text (D4: the capsule is the menu's filter).
    @Published var filter = "" {
        didSet { if filter != oldValue { highlightedID = nil } }
    }
    /// The canvas on the board: checked in the list, and the one the
    /// commands act on.
    @Published var currentCanvasID: UUID?
    /// The keyboard's (and the pointer's) row; nil until ↑ ↓ or a hover.
    @Published private(set) var highlightedID: String?
    @Published private(set) var mode: Mode = .list
    /// Rename edits the name in the capsule itself, as the working file
    /// draws it: the page shows a field bound to `nameDraft` while this is
    /// set, commits on Return or when the field loses focus, and cancels on
    /// Escape.
    @Published private(set) var isRenaming = false
    @Published var nameDraft = ""

    /// Where Delete posts its Undo toast (the panel's, from the view).
    weak var toasts: PanelToastCenter?
    private var deletionToastID: UUID?

    /// Only the still-offered canvas deletion owns the board's Undo key.
    func undoDeletionIfOffered() -> Bool {
        guard let toasts, let deletionToastID, toasts.current?.id == deletionToastID,
              toasts.current?.answersUndoKey == true else { return false }
        _ = toasts.performAction()
        return true
    }
    private let now: () -> Date
    private let calendar: Calendar

    private struct RowsKey: Equatable {
        let revision: UInt64
        let currentHasPendingEdit: Bool
        let query: String
        let canvasID: UUID?
        let today: DueDay
        let environment: DatePresentationEnvironment
    }
    private var rowsCache: (key: RowsKey, rows: [Row])?

    init(store: any DrawStoreProtocol, actions: DrawLibraryActions,
         now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.actions = actions
        self.now = now
        self.calendar = calendar
    }

    // MARK: Rows

    private var query: String { filter.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The canvases the filter keeps, newest first. With no filter, an open
    /// canvas that is still a draft (nothing drawn yet) leads the list so it
    /// keeps its check.
    var canvases: [DrawCanvas] {
        guard AtticDraw.isEnabled else { return [] }
        let query = query
        if !query.isEmpty { return ((try? store.search(query)) ?? []).map(\.canvas) }
        var list = (try? store.library()) ?? []
        if let current = currentCanvas(in: list), !list.contains(where: { $0.id == current.id }) {
            list.insert(current, at: 0)
        }
        return list
    }

    /// The open canvas, if it is live.
    var currentCanvas: DrawCanvas? { currentCanvas(in: (try? store.library()) ?? []) }

    /// The open canvas from the library's metadata; only a draft (not in
    /// the library yet) is read from the store's session.
    private func currentCanvas(in library: [DrawCanvas]) -> DrawCanvas? {
        guard let currentCanvasID else { return nil }
        if let listed = library.first(where: { $0.id == currentCanvasID }) { return listed }
        guard let canvas = try? store.open(currentCanvasID).canvas, canvas.deletedAt == nil else { return nil }
        return canvas
    }

    var rows: [Row] {
        guard AtticDraw.isEnabled else { return [] }
        let instant = now()
        let key = RowsKey(revision: store.revision,
            currentHasPendingEdit: currentCanvasID.map { store.pendingEdits[$0] != nil } ?? false,
            query: query, canvasID: currentCanvasID,
            today: DueDay(date: instant, calendar: calendar),
            environment: DatePresentationEnvironment(calendar: calendar, locale: .current))
        if let rowsCache, rowsCache.key == key { return rowsCache.rows }
        let rows = makeRows(at: instant)
        rowsCache = (key, rows)
        return rows
    }

    private func makeRows(at instant: Date) -> [Row] {
        let query = query
        let found = canvases
        var rows = found.map { canvas in
            Row(kind: .canvas(canvas), title: Self.displayName(canvas.name),
                detail: AtticRelativeDateFormatting.editTime(canvas.updatedAt, now: instant, calendar: calendar),
                isOpen: canvas.id == currentCanvasID)
        }
        if !query.isEmpty, found.isEmpty {
            rows.append(Row(kind: .noMatch, title: String(localized: "No canvases match “\(query)”"), isEnabled: false))
        }
        rows.append(Row(kind: .newCanvas(name: query.isEmpty ? nil : query),
                        title: query.isEmpty ? String(localized: "New canvas") : String(localized: "New canvas “\(query)”")))
        guard query.isEmpty else { return rows }
        let current = currentCanvas(in: found)
        let hasCanvas = current != nil
        let drawn = current.map { actions.hasContent($0.id) } ?? false
        for command in Command.allCases {
            let enabled: Bool = switch command {
            case .linkedFrom: false
            case .export: drawn && actions.export != nil
            case .copyAsImage: drawn && actions.copyAsImage != nil
            case .duplicate: hasCanvas && (current.map { store.pendingEdits[$0.id] == nil } ?? false)
            default: hasCanvas
            }
            rows.append(Row(kind: .command(command), title: command.title, isEnabled: enabled,
                            isDestructive: command == .delete, startsSection: command == .rename))
        }
        return rows
    }

    /// The row Return chooses: the highlighted one, else the first match,
    /// else (with filter text and no match) New canvas “…”.
    func returnTarget(in rows: [Row]) -> Row? {
        if let highlightedID, let row = rows.first(where: { $0.id == highlightedID && $0.isEnabled }) { return row }
        if let first = rows.first(where: { $0.canvas != nil }) { return first }
        return query.isEmpty ? nil : rows.first { if case .newCanvas = $0.kind { true } else { false } }
    }

    /// The row drawn highlighted: the keyboard's or the pointer's, and while
    /// filtering the one Return would choose.
    func litRowID(in rows: [Row]) -> String? {
        if let highlightedID, rows.contains(where: { $0.id == highlightedID && $0.isEnabled }) { return highlightedID }
        return query.isEmpty ? nil : returnTarget(in: rows)?.id
    }

    /// The menu is showing these rows: their thumbnails go to the page,
    /// which re-renders any drawn for the other appearance. Called after
    /// the list appears or changes, never from a layout pass.
    func showThumbnails() {
        actions.thumbnailsShown(rows.compactMap(\.canvas))
    }

    // MARK: Keys

    /// Return in the capsule.
    func openFirstMatch() {
        guard let row = returnTarget(in: rows) else { return }
        choose(row)
    }

    /// ↑ ↓ in the capsule: the next row that can be chosen, stopping at the
    /// ends (the app's menus don't wrap).
    func moveHighlight(by step: Int) {
        let selectable = rows.filter(\.isEnabled).map(\.id)
        guard !selectable.isEmpty, step != 0 else { return }
        let start = litRowID(in: rows)
        if let start, let at = selectable.firstIndex(of: start) {
            highlightedID = selectable[max(0, min(selectable.count - 1, at + step))]
        } else {
            highlightedID = step > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
    }

    /// The pointer over a row moves the one highlight; leaving the lit row
    /// clears it.
    func hover(_ row: Row, inside: Bool) {
        if inside, row.isEnabled {
            if highlightedID != row.id { highlightedID = row.id }
        } else if highlightedID == row.id {
            highlightedID = nil
        }
    }

    // MARK: Choosing

    func choose(_ row: Row) {
        guard row.isEnabled else { return }
        switch row.kind {
        case let .canvas(canvas):
            finish()
            actions.open(canvas.id)
        case .noMatch:
            return
        case let .newCanvas(name):
            finish()
            actions.newCanvas(name: name)
        case let .command(command):
            perform(command)
        }
    }

    func perform(_ command: Command) {
        guard let canvas = currentCanvas else { return }
        switch command {
        case .rename:
            nameDraft = canvas.name
            isRenaming = true
            finish()
        case .tags:
            highlightedID = nil
            mode = .tags
        case .linkedFrom:
            return
        case .duplicate:
            guard store.pendingEdits[canvas.id] == nil else { return }
            do {
                guard let copy = try store.duplicate(canvas.id) else {
                    showCommandError(String(localized: "The canvas couldn’t be duplicated."))
                    return
                }
                finish()
                actions.open(copy.id)
            } catch {
                showCommandError(String(localized: "The canvas couldn’t be duplicated: \(error.localizedDescription)"))
            }
        case .export:
            guard let export = actions.export else { return }
            finish()
            export(canvas.id)
        case .copyAsImage:
            guard let copy = actions.copyAsImage else { return }
            finish()
            copy(canvas.id)
        case .delete:
            delete(canvas)
        }
    }

    private func showCommandError(_ message: String) {
        toasts?.show(message, actionTitle: String(localized: "OK"), answersUndoKey: false, action: {})
    }

    /// Delete: the canvas goes to Recently Deleted, the board moves to the
    /// newest other canvas (or a new one), and a toast offers Undo.
    private func delete(_ canvas: DrawCanvas) {
        let result = store.perform(.deleteCanvas, on: canvas.id)
        switch result {
        case .saved, .unchanged: break
        case let .retry(message), let .held(message):
            toasts?.show(message.isEmpty ? String(localized: "The canvas couldn’t be deleted.") : message,
                         actionTitle: String(localized: "OK"), answersUndoKey: false, action: {})
            return
        }
        finish()
        if let next = ((try? store.library()) ?? []).first(where: { $0.id != canvas.id }) {
            actions.open(next.id)
        } else {
            actions.newCanvas(name: nil)
        }
        let store = store
        let actions = actions
        toasts?.show(String(localized: "Deleted “\(Self.displayName(canvas.name))”")) {
            let restored = store.perform(.restoreCanvas, on: canvas.id)
            switch restored {
            case .saved, .unchanged:
                actions.open(canvas.id)
                return .applied
            case let .retry(message), let .held(message):
                return .failed(CommandFailure(message))
            }
        }
        deletionToastID = toasts?.current?.id
    }

    // MARK: Rename

    func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let canvas = currentCanvas, !name.isEmpty, name != canvas.name else { return }
        _ = store.perform(.rename(name), on: canvas.id)
    }

    func cancelRename() {
        isRenaming = false
    }

    // MARK: Tags

    /// Every tag in the library with how many canvases carry it, plus the
    /// open canvas's own.
    var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for canvas in (try? store.library()) ?? [] {
            for tag in canvas.tags { counts[tag, default: 0] += 1 }
        }
        for tag in currentCanvas?.tags ?? [] where counts[tag] == nil { counts[tag] = 1 }
        return counts
    }

    func setTag(_ name: String, on: Bool) {
        guard let canvas = currentCanvas, let tag = AtticTag.normalize(name) else { return }
        var tags = canvas.tags
        if on { if !tags.contains(tag) { tags.append(tag) } } else { tags.removeAll { $0 == tag } }
        _ = store.perform(.tags(tags), on: canvas.id)
        objectWillChange.send()
    }

    /// The tag picker closed (Escape, or a click away): the menu is done.
    func closeTags() {
        guard mode == .tags else { return }
        finish()
    }

    /// The menu is done: it forgets its filter, highlight and mode, and the
    /// page closes it.
    private func finish() {
        highlightedID = nil
        mode = .list
        if !filter.isEmpty { filter = "" }
        actions.close()
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Untitled canvas") : trimmed
    }
}
