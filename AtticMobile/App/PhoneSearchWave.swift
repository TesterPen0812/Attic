import Foundation
import SwiftUI

/// A read-only search over the snapshots already loaded by PhoneAppState.
/// Neither matching nor rendering reads note attachment bytes, Draw objects or EventKit.
@MainActor
enum PhoneSearchWaveIndex {
    struct Hit<Value: Identifiable>: Identifiable where Value.ID == UUID {
        let value: Value
        let detail: String?
        let score: Int
        let updatedAt: Date

        var id: UUID { value.id }
    }

    struct Results {
        let now: [Hit<PhoneLibrary.TaskRow>]
        let later: [Hit<PhoneLibrary.TaskRow>]
        let done: [Hit<PhoneLibrary.TaskRow>]
        let notes: [Hit<PhoneLibrary.NoteRow>]
        let canvases: [Hit<DrawCanvas>]

        var taskCount: Int { now.count + later.count + done.count }
        var totalCount: Int { taskCount + notes.count + canvases.count }

        func count(for tab: PhoneTasksTab) -> Int { tasks(for: tab).count }

        func tasks(for tab: PhoneTasksTab) -> [Hit<PhoneLibrary.TaskRow>] {
            switch tab {
            case .now: now
            case .later: later
            case .done: done
            }
        }

        var firstPopulatedTaskGroup: PhoneTasksTab {
            if !now.isEmpty { return .now }
            if !later.isEmpty { return .later }
            return .done
        }
    }

    private struct Query {
        let raw: String
        let words: [String]
        let tagTerms: [String]

        init(_ raw: String) {
            self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = self.raw.split(whereSeparator: \.isWhitespace).map(String.init)
            words = parts.filter { !$0.hasPrefix("#") }
            tagTerms = parts.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) }
        }

        var isSearchable: Bool {
            (!words.isEmpty || !tagTerms.isEmpty) && tagTerms.allSatisfy { !$0.isEmpty }
        }

        var highlights: [String] { words + tagTerms.map { "#" + $0 } }
    }

    static func search(_ query: String, tasks: [PhoneLibrary.TaskRow],
                       notes: [PhoneLibrary.NoteRow], canvases: [DrawCanvas]) -> Results {
        let terms = Query(query)
        guard terms.isSearchable else { return Results(now: [], later: [], done: [], notes: [], canvases: []) }

        let taskMatches: [Hit<PhoneLibrary.TaskRow>] = sort(tasks.compactMap { task in
            guard task.parentID == nil,
                  let score = relevance(title: task.title, tags: task.tags, content: "", query: terms) else { return nil }
            return Hit(value: task, detail: matchingTags(task.tags, query: terms),
                       score: score, updatedAt: task.updatedAt)
        })
        let noteMatches: [Hit<PhoneLibrary.NoteRow>] = sort(notes.compactMap { note in
            guard let score = relevance(title: note.title, tags: note.tags, content: note.body, query: terms) else { return nil }
            return Hit(value: note, detail: preview(content: note.body, tags: note.tags, query: terms),
                       score: score, updatedAt: note.updatedAt)
        })
        let canvasMatches: [Hit<DrawCanvas>] = sort(canvases.compactMap { canvas in
            guard canvas.deletedAt == nil,
                  let score = relevance(title: canvas.name, tags: canvas.tags, content: canvas.textIndex, query: terms)
            else { return nil }
            return Hit(value: canvas, detail: preview(content: canvas.textIndex, tags: canvas.tags, query: terms),
                       score: score, updatedAt: canvas.updatedAt)
        })

        return Results(now: taskMatches.filter { $0.value.listedStatus != .backlog && $0.value.listedStatus != .done },
                       later: taskMatches.filter { $0.value.listedStatus == .backlog },
                       done: taskMatches.filter { $0.value.listedStatus == .done },
                       notes: noteMatches, canvases: canvasMatches)
    }

    /// Every free-text word must occur somewhere in this item. #words search tags only.
    /// Strong title hits rank before metadata, which ranks before body/board previews.
    private static func relevance(title: String, tags: [String], content: String, query: Query) -> Int? {
        guard query.tagTerms.allSatisfy({ term in
            tags.contains { $0.localizedStandardContains(term) }
        }) else { return nil }

        var score = query.tagTerms.count * 140
        for word in query.words {
            if title.localizedStandardCompare(word) == .orderedSame {
                score += 400
            } else if title.range(of: word, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil {
                score += 320
            } else if title.localizedStandardContains(word) {
                score += 260
            } else if tags.contains(where: { $0.localizedStandardContains(word) }) {
                score += 160
            } else if content.localizedStandardContains(word) {
                score += 80
            } else {
                return nil
            }
        }
        if query.tagTerms.isEmpty && !query.words.isEmpty {
            if title.localizedStandardCompare(query.raw) == .orderedSame { score += 600 }
            else if title.range(of: query.raw, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil { score += 180 }
        }
        return score
    }

    private static func sort<Value>(_ hits: [Hit<Value>]) -> [Hit<Value>] {
        hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func matchingTags(_ tags: [String], query: Query) -> String? {
        let matching = tags.filter { tag in
            query.tagTerms.contains { tag.localizedStandardContains($0) }
                || query.words.contains { tag.localizedStandardContains($0) }
        }
        return matching.isEmpty ? nil : matching.map { "#" + $0 }.joined(separator: "  ")
    }

    private static func preview(content: String, tags: [String], query: Query) -> String? {
        // A #tag query should display the tag that matched, not an unrelated line.
        if !query.tagTerms.isEmpty, let matched = matchingTags(tags, query: query) { return matched }
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let line = lines.first(where: { line in query.words.contains { line.localizedStandardContains($0) } }) {
            return excerpt(line, around: query.words)
        }
        if let matched = matchingTags(tags, query: query) { return matched }
        return lines.first.map { excerpt($0, around: []) }
    }

    /// Centre a long preview around the first match, without changing stored text.
    private static func excerpt(_ line: String, around words: [String], limit: Int = 100) -> String {
        let flat = line.replacingOccurrences(of: "\t", with: " ")
        guard flat.count > limit else { return flat }
        let firstMatch = words.compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            .min { $0.lowerBound < $1.lowerBound }
        let offset = firstMatch.map { flat.distance(from: flat.startIndex, to: $0.lowerBound) } ?? 0
        let start = max(0, min(offset - 20, flat.count - limit))
        let low = flat.index(flat.startIndex, offsetBy: start)
        let high = flat.index(low, offsetBy: limit, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > 0 ? "…" : "") + String(flat[low..<high]) + (high < flat.endIndex ? "…" : "")
    }
}

/// Split at real String indices so matching is case/diacritic insensitive while
/// retaining exact Unicode spelling, emoji and punctuation in the displayed text.
enum PhoneSearchWaveHighlight {
    struct Fragment: Equatable {
        let text: String
        let matched: Bool
    }

    static func fragments(_ text: String, terms: [String]) -> [Fragment] {
        let needles = terms.filter { !$0.isEmpty }
        var remainder = text[...]
        var fragments: [Fragment] = []
        while !remainder.isEmpty {
            let ranges = needles.compactMap { remainder.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
            guard let match = ranges.min(by: { a, b in
                a.lowerBound == b.lowerBound ? a.upperBound > b.upperBound : a.lowerBound < b.lowerBound
            }) else {
                fragments.append(Fragment(text: String(remainder), matched: false))
                break
            }
            if match.lowerBound > remainder.startIndex {
                fragments.append(Fragment(text: String(remainder[..<match.lowerBound]), matched: false))
            }
            fragments.append(Fragment(text: String(remainder[match]), matched: true))
            remainder = remainder[match.upperBound...]
        }
        return fragments.isEmpty ? [Fragment(text: text, matched: false)] : fragments
    }

    static func styled(_ text: String, terms: [String]) -> AttributedString {
        var result = AttributedString()
        for fragment in fragments(text, terms: terms) {
            var piece = AttributedString(fragment.text)
            if fragment.matched {
                piece.backgroundColor = Color.accentColor.opacity(0.16)
                piece.foregroundColor = Color.primary
            }
            result.append(piece)
        }
        return result
    }
}

/// Standalone Stage 4 sheet; the shell owns presentation and navigation.
/// Tasks show one status group at a time, with accessible counts to switch groups.
struct PhoneSearchWaveSheet: View {
    @ObservedObject var state: PhoneAppState
    var onOpen: (PhoneRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var taskGroup: PhoneTasksTab = .now

    private var highlights: [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "#" }
    }

    var body: some View {
        let results = PhoneSearchWaveIndex.search(query, tasks: state.tasks, notes: state.notes,
                                                  canvases: state.canvases)
        let visibleGroup = results.count(for: taskGroup) > 0 ? taskGroup : results.firstPopulatedTaskGroup
        return NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !state.loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 48)
                    } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("Search Attic", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity).padding(.top, 45)
                    } else if results.totalCount == 0 {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity).padding(.top, 34)
                    } else {
                        if results.taskCount > 0 {
                            sectionHeading("Tasks", symbol: "checkmark.circle", count: results.taskCount)
                            taskGroupPicker(results, selected: visibleGroup)
                            rows(results.tasks(for: visibleGroup), symbol: "circle",
                                 kind: "Task") { .task($0) }
                        }
                        if !results.notes.isEmpty {
                            sectionHeading("Notes", symbol: "note.text", count: results.notes.count)
                            rows(results.notes, symbol: "note.text",
                                 kind: "Note") { .note($0) }
                        }
                        if !results.canvases.isEmpty {
                            sectionHeading("Canvases", symbol: "scribble.variable", count: results.canvases.count)
                            rows(results.canvases, symbol: "scribble.variable",
                                 kind: "Canvas") { .canvas($0) }
                        }
                    }
                }
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("phone-search-wave-close")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, newQuery in
            let updated = PhoneSearchWaveIndex.search(newQuery, tasks: state.tasks,
                                                       notes: state.notes, canvases: state.canvases)
            taskGroup = updated.firstPopulatedTaskGroup
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Tasks, notes and canvases", text: $query)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { focused = false }
                .accessibilityLabel("Search tasks, notes and canvases")
                .accessibilityIdentifier("phone-search-field")
            if !query.isEmpty {
                Button {
                    query = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("phone-search-wave-clear")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 0)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private func sectionHeading(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20))
                .frame(width: 24).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(count, format: .number).font(.subheadline).monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 51)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) results")
        .accessibilityAddTraits(.isHeader)
    }

    private func taskGroupPicker(_ results: PhoneSearchWaveIndex.Results,
                                 selected: PhoneTasksTab) -> some View {
        HStack(spacing: 6) {
            ForEach(PhoneTasksTab.allCases) { group in
                let count = results.count(for: group)
                Button {
                    taskGroup = group
                    focused = false
                } label: {
                    HStack(spacing: 5) {
                        Text(group.title)
                        Text(count, format: .number).monospacedDigit()
                    }
                    .font(.subheadline.weight(selected == group ? .semibold : .regular))
                    .foregroundStyle(selected == group ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(selected == group ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .accessibilityLabel("\(group.title), \(count) matching tasks")
                .accessibilityAddTraits(selected == group ? .isSelected : [])
                .accessibilityIdentifier("phone-search-wave-\(group.rawValue)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private func rows<Value>(_ matches: [PhoneSearchWaveIndex.Hit<Value>], symbol: String,
                             kind: String, route: @escaping (UUID) -> PhoneRoute) -> some View {
        ForEach(matches) { match in
            let title: String = switch match.value {
            case let task as PhoneLibrary.TaskRow: task.title
            case let note as PhoneLibrary.NoteRow: note.title.isEmpty ? "Untitled note" : note.title
            case let canvas as DrawCanvas: canvas.name.isEmpty ? "Untitled canvas" : canvas.name
            default: ""
            }
            Button {
                focused = false
                onOpen(route(match.id))
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(PhoneSearchWaveHighlight.styled(title, terms: highlights))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let detail = match.detail, !detail.isEmpty {
                            Text(PhoneSearchWaveHighlight.styled(detail, terms: highlights))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 5)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(minHeight: 49)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([kind, title, match.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Open \(kind.lowercased())")
            .accessibilityIdentifier("phone-search-wave-\(kind.lowercased())-\(match.id.uuidString)")
            Divider().padding(.leading, 56)
        }
    }
}
