import Foundation
import SwiftUI

/// Search on the Draw page (Accepted 2026-10-31, Search): the shared top
/// Search finds canvases by name, `#tag` or the text written on them,
/// through the store's `search`. A text match opens the canvas on its
/// matching text box (`reveal`). The page binds its top-row field's text to
/// `query`, forwards ↑ ↓ and Return, and shows `DrawSearchResults` under it.
@MainActor
final class DrawSearchModel: ObservableObject {
    struct Result: Identifiable, Equatable {
        let canvas: DrawCanvas
        let title: String
        /// The date for a name match, the matching text (quoted) for a text
        /// match, else the canvas's tags.
        let detail: String
        /// The matching text boxes, empty unless the name doesn't match.
        let textBoxIDs: [UUID]
        var id: UUID { canvas.id }
    }

    let store: any DrawStoreProtocol
    let actions: DrawLibraryActions

    @Published var query = "" {
        didSet {
            if query != oldValue {
                highlightedID = nil
                openError = nil
            }
        }
    }
    @Published private(set) var highlightedID: UUID?
    @Published private(set) var openError: String?

    private struct SearchKey: Equatable {
        let query: String
        let revision: UInt64
        let enabled: Bool
    }

    private struct SearchSnapshot {
        let results: [Result]
        let error: String?
    }

    private var cache: (key: SearchKey, snapshot: SearchSnapshot)?

    init(store: any DrawStoreProtocol, actions: DrawLibraryActions) {
        self.store = store
        self.actions = actions
    }

    var results: [Result] { snapshot.results }
    var searchError: String? { snapshot.error }

    /// Highlights only read this snapshot; a query or store revision is the
    /// only reason to run another repository search (including after failure).
    private var snapshot: SearchSnapshot {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = SearchKey(query: query, revision: store.revision, enabled: AtticDraw.isEnabled)
        if let cache, cache.key == key { return cache.snapshot }
        let refreshed: SearchSnapshot
        if !key.enabled || query.isEmpty {
            refreshed = SearchSnapshot(results: [], error: nil)
        } else {
            do {
                refreshed = SearchSnapshot(results: Self.present(try store.search(query), query: query), error: nil)
            } catch {
                refreshed = SearchSnapshot(results: [], error: String(localized: "Could not search canvases: \(error.localizedDescription)"))
            }
        }
        cache = (key, refreshed)
        return refreshed
    }

    private static func present(_ matches: [DrawSearchMatch], query: String) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("#") }
        return matches.map { match in
            let canvas = match.canvas
            let nameMatches = !words.isEmpty && words.allSatisfy { canvas.name.localizedStandardContains($0) }
            let line = nameMatches ? nil : canvas.textIndex.split(separator: "\n").first { line in
                words.contains { line.localizedStandardContains($0) }
            }
            let detail: String
            if let line {
                detail = "“\(Self.shortened(String(line)))”"
            } else if !nameMatches, !canvas.tags.isEmpty {
                detail = canvas.tags.map { "#\($0)" }.joined(separator: " ")
            } else {
                detail = AtticRelativeDateFormatting.editTime(canvas.updatedAt, now: Date(), calendar: .autoupdatingCurrent)
            }
            return Result(canvas: canvas, title: DrawLibraryMenuModel.displayName(canvas.name), detail: detail,
                          textBoxIDs: line == nil ? [] : match.matchingTextBoxIDs)
        }
    }

    /// The results are showing: their thumbnails take the menu's path.
    func showThumbnails() {
        actions.thumbnailsShown(results.map(\.canvas))
    }

    /// The drawing's 28 characters, then an ellipsis.
    static func shortened(_ text: String, limit: Int = 28) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A text match opens the canvas on its first matching box (in the
    /// board's order); any other match just opens the canvas.
    @discardableResult
    func open(_ result: Result) -> Bool {
        let ids = Set(result.textBoxIDs)
        if !ids.isEmpty {
            do {
                if let box = try store.open(result.canvas.id).objects.first(where: { ids.contains($0.id) }) {
                    actions.reveal(result.canvas.id, box.id)
                } else {
                    actions.open(result.canvas.id)
                }
            } catch {
                openError = String(localized: "Could not open canvas: \(error.localizedDescription)")
                return false
            }
        } else {
            actions.open(result.canvas.id)
        }
        highlightedID = nil
        openError = nil
        return true
    }

    /// ↑ ↓ in the search field, stopping at the ends.
    func moveHighlight(by step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty, step != 0 else { return }
        if let highlightedID, let at = ids.firstIndex(of: highlightedID) {
            self.highlightedID = ids[max(0, min(ids.count - 1, at + step))]
        } else {
            highlightedID = step > 0 ? ids[0] : ids[ids.count - 1]
        }
    }

    /// Return in the search field: the highlighted result, else the first.
    @discardableResult
    func openHighlighted() -> Bool {
        let results = results
        guard let result = results.first(where: { $0.id == highlightedID }) ?? results.first else { return false }
        return open(result)
    }

    /// The row drawn highlighted: the keyboard's or the pointer's, else the
    /// one Return opens.
    func litID(in results: [Result]) -> UUID? {
        if let highlightedID, results.contains(where: { $0.id == highlightedID }) { return highlightedID }
        return results.first?.id
    }

    /// The pointer over a result moves the one highlight; leaving it clears it.
    func hover(_ result: Result, inside: Bool) {
        if inside {
            if highlightedID != result.id { highlightedID = result.id }
        } else if highlightedID == result.id {
            highlightedID = nil
        }
    }
}

/// The results under the Draw page's search field, as the working file
/// draws them: the menu's card across the panel, a row per canvas
/// (thumbnail, name, then its date, matching text or tags), or "No
/// canvases match “…”". Opening one ends the search, as on the other pages.
struct DrawSearchResults: View {
    @ObservedObject var model: DrawSearchModel
    @Environment(\.panelTopRowState) private var topRow

    var body: some View {
        let results = model.results
        let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let lit = model.litID(in: results)
            let message: String? = model.searchError ?? model.openError ??
                (results.isEmpty ? String(localized: "No canvases match “\(query)”") : nil)
            let rows = results.map { DrawLibraryMenuModel.Row(kind: .canvas($0.canvas), title: $0.title, detail: $0.detail) }
                + (message.map { [DrawLibraryMenuModel.Row(kind: .noMatch, title: $0, isEnabled: false)] } ?? [])
            DrawLibraryCard(width: nil) {
                DrawLibraryRows(rows: rows, litID: lit.map { "canvas-\($0.uuidString)" },
                                scrollTarget: model.highlightedID.map { "canvas-\($0.uuidString)" },
                                hover: { row, inside in
                                    if let result = results.first(where: { $0.canvas.id == row.canvas?.id }) { model.hover(result, inside: inside) }
                                },
                                choose: { row in
                                    guard let result = results.first(where: { $0.canvas.id == row.canvas?.id }) else { return }
                                    if model.open(result) { topRow?.endSearch(on: .canvas) }
                                },
                                thumbnailsShown: { [actions = model.actions] in actions.thumbnailsShown($0) },
                                thumbnailsHidden: { [actions = model.actions] in actions.thumbnailsHidden($0) },
                                searchThumbnail: { [actions = model.actions] in actions.searchThumbnail($0) },
                                thumbnailRevision: model.store.revision)
            }
            .accessibilityLabel(String(localized: "Canvases found"))
            .accessibilityIdentifier("draw-search-results")
        }
    }
}
