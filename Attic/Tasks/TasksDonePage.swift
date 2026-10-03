import Combine
import SwiftUI

/// The Done log (spec § Now, Backlog and Done): everything finished, kept
/// indefinitely, grouped by the day it was finished (Today, Yesterday,
/// Mon 21 Sep…), searchable from the tabs line (owner item 17: the field
/// takes the tabs' place while searching; the add bar below always adds),
/// matches highlighted, with a quiet "N of M done tasks"; each task restorable to
/// Now (its circle, or right-click). Loaded a page at a time as it scrolls,
/// so 5,000 finished tasks never load at once.
struct TasksDonePage<Cell: View, Mask: View>: View {
    let model: TasksPageModel
    /// Every change to the model while the page is drawn; nothing while it
    /// is kept built but not drawn (round 11, `TasksCellUpdates`).
    @ObservedObject var updates: TasksCellUpdates
    /// Observed only while the page is drawn (`TasksDoneRevisionWatcher`).
    let store: TaskStore
    /// Where the first line rests (under the tabs) and what the bottom
    /// stack needs clear (owner fix 8): the day headings scroll under the
    /// tabs like Now's rows.
    let listTop: CGFloat
    let bottomClearance: CGFloat
    /// The add bar's zone: the only bottom margin (round 6; the rest of the
    /// clearance is room at the end of the list, so rows there take clicks).
    let bottomMargin: CGFloat
    /// The visible viewport ends before the tabs/Find and bottom controls.
    let viewportTop: CGFloat
    let bottomInset: CGFloat
    /// The bottom stack, whose height the bottom bar follows.
    let bottomStack: TasksBottomStackHeight
    /// False while the page is kept built but not shown (round 11).
    var drawn = true
    /// How the log meets the floating controls (`TasksPage.edgeStyle`).
    var edges: AtticScrollEdgeStyle = .systemSoft
    /// Round 13's clean cut (the system soft edge needs none).
    let mask: Mask
    /// A row the keyboard moved to: brought into the visible area (review 8).
    @Binding var reveal: TasksPageModel.ScrollRequest?
    /// Brings a row into the uncovered part of the list (the page's rule).
    let revealRow: (UUID, ScrollViewProxy) -> Void
    let cell: (TasksListRow) -> Cell
    /// Where the page keeps the log's scroll view and proxy (round 10).
    var proxies: TasksListProxies?
    var registerList: (ScrollViewProxy) -> Void = { _ in }

    static var space: NamedCoordinateSpace { .named("AtticTasksDone") }

    var body: some View {
        let days = model.doneDays()
        list(days)
        // Round 12: a page kept built but not drawn reads nothing and
        // watches nothing (its copy of the log is not on screen); drawn
        // again, it catches up with whatever changed meanwhile.
        .onAppear { if drawn { model.loadDoneLogIfNeeded() } }
        .onChange(of: model.doneSearch) { _, _ in if drawn { model.loadDoneLogIfNeeded() } }
        .onChange(of: drawn) { _, drawn in if drawn { model.loadDoneLogIfNeeded() } }
        .background {
            if drawn {
                TasksDoneRevisionWatcher(store: store) { model.loadDoneLogIfNeeded() }
            }
        }
    }

    private func list(_ days: [TasksDoneDay]) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    // A day heading takes one row's pitch, its text on
                    // the rows' title line, so the log keeps the 34 / 48
                    // rhythm of the rows under it.
                    AtticText(verbatim: day.title, style: .rowMeta, ink: .helper)
                        .frame(height: AtticTaskRowMetrics.titleLineHeight)
                        .frame(height: AtticLayout.rowPitch)
                        .padding(.leading, AtticLayout.circleX)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.rows) { row in
                        cell(row).id(row.id)
                    }
                }
                if model.doneLogFailure != nil {
                    // A read failed (Astra 18): what loaded stays, and the
                    // page says it could not load more, never "no more".
                    AtticErrorLine(message: String(localized: "Couldn’t load more"), onRetry: model.retryDoneLog)
                        .frame(height: AtticLayout.rowPitch)
                        .padding(.leading, AtticLayout.circleX)
                        .accessibilityIdentifier("tasks-done-load-failed")
                } else if model.doneLogHasMore {
                    AtticLoadingRows(count: 2)
                        // Only a drawn page pages on; one drawn again with
                        // the sentinel already in view reads the next page.
                        .task(id: drawn) { if drawn { model.loadMoreDoneLog() } }
                }
                if days.isEmpty, model.doneLogFailure == nil {
                    let query = model.doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                    AtticEmptyLine(text: query.isEmpty
                        ? String(localized: "Finished tasks collect here.")
                        : String(localized: "No finished tasks match “\(query)”."))
                } else if let count = model.doneSearchCount() {
                    // A quiet line under the results (v22 card B).
                    AtticText(verbatim: String(localized: "\(count.matches) of \(count.total) done tasks"), style: .rowMeta, ink: .helper)
                        .frame(height: AtticLayout.rowPitch)
                        .padding(.leading, AtticLayout.textX)
                        .accessibilityIdentifier("tasks-done-search-count")
                }
                if edges == .systemSoft {
                    TasksListTailClearance(stack: bottomStack, bottomInset: bottomInset, bottomClearance: bottomClearance)
                }
            }
            .padding(.bottom, edges == .cleanCut ? bottomClearance - bottomMargin : 0)
            // The log's place is kept while its page is not built (round 10).
            .background(TasksScrollKeeper(model: model, tab: .done, proxies: proxies, drawn: drawn).accessibilityHidden(true))
        }
        .tasksListEdges(edges, top: viewportTop, listTop: listTop, bottomInset: bottomInset,
                        bottomMargin: bottomMargin, bottomClearance: bottomClearance, stack: bottomStack, mask: mask)
        .coordinateSpace(Self.space)
        .onChange(of: reveal) { _, request in
            guard let request else { return }
            revealRow(request.id, proxy)
        }
        // An agent's `show` of a finished task (the model loaded its page).
        // The page scrolls the log to a `show`'s row, also one made before
        // the log was built (round 10).
        .onAppear { registerList(proxy) }
        }
    }
}

/// The store's revision, watched by its own small view so that a Done page
/// kept built but not drawn does not observe the store at all (round 12).
private struct TasksDoneRevisionWatcher: View {
    @ObservedObject var store: TaskStore
    let reload: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.revision) { _, _ in reload() }
            .accessibilityHidden(true)
    }
}

/// Only the Find field observes its draft; result publication is coalesced.
@MainActor
final class TasksDoneSearchInput: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var text = ""
    func edit(_ text: String) { self.text = text }
    func replace(_ text: String) {
        guard self.text != text else { return }
        objectWillChange.send()
        self.text = text
    }
}

struct TasksDoneSearchField: View {
    let model: TasksPageModel
    @ObservedObject var input: TasksDoneSearchInput
    let isFocused: Binding<Bool>
    let onEscape: () -> Void

    var body: some View {
        AtticTabsSearchField(placeholder: model.searchPlaceholder(for: .done),
                             text: Binding(get: { input.text }, set: { model.typeDoneSearch($0) }),
                             isFocused: isFocused, nativeInputIdentifier: "tasks-done-search", onEscape: onEscape)
    }
}
