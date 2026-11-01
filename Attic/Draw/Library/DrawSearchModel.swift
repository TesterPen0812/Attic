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
        didSet { if query != oldValue { highlightedID = nil } }
    }
    @Published private(set) var highlightedID: UUID?

    init(store: any DrawStoreProtocol, actions: DrawLibraryActions) {
        self.store = store
        self.actions = actions
    }

    var results: [Result] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DrawLibrarySetting.isEnabled, !query.isEmpty else { return [] }
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("#") }
        return ((try? store.search(query)) ?? []).map { match in
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
                detail = NotesLibraryModel.time(canvas.updatedAt, now: Date(), calendar: .autoupdatingCurrent)
            }
            return Result(canvas: canvas, title: DrawLibraryMenuModel.displayName(canvas.name), detail: detail,
                          textBoxIDs: line == nil ? [] : match.matchingTextBoxIDs)
        }
    }

    /// The drawing's 28 characters, then an ellipsis.
    static func shortened(_ text: String, limit: Int = 28) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A text match opens the canvas on its first matching box (in the
    /// board's order); any other match just opens the canvas.
    func open(_ result: Result) {
        highlightedID = nil
        let ids = Set(result.textBoxIDs)
        if !ids.isEmpty, let box = ((try? store.open(result.canvas.id).objects) ?? []).first(where: { ids.contains($0.id) }) {
            actions.reveal(result.canvas.id, box.id)
        } else {
            actions.open(result.canvas.id)
        }
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
    func openHighlighted() {
        let results = results
        guard let result = results.first(where: { $0.id == highlightedID }) ?? results.first else { return }
        open(result)
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
            let rows: [DrawLibraryMenuModel.Row] = results.isEmpty
                ? [DrawLibraryMenuModel.Row(kind: .noMatch, title: String(localized: "No canvases match “\(query)”"), isEnabled: false)]
                : results.map { DrawLibraryMenuModel.Row(kind: .canvas($0.canvas), title: $0.title, detail: $0.detail) }
            DrawLibraryCard(width: nil) {
                DrawLibraryRows(rows: rows, litID: lit.map { "canvas-\($0.uuidString)" },
                                scrollTarget: model.highlightedID.map { "canvas-\($0.uuidString)" },
                                hover: { row, inside in
                                    if let result = results.first(where: { $0.canvas.id == row.canvas?.id }) { model.hover(result, inside: inside) }
                                },
                                choose: { row in
                                    guard let result = results.first(where: { $0.canvas.id == row.canvas?.id }) else { return }
                                    model.open(result)
                                    topRow?.endSearch(on: .canvas)
                                })
            }
            .accessibilityLabel(String(localized: "Canvases found"))
            .accessibilityIdentifier("draw-search-results")
        }
    }
}
