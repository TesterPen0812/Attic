import SwiftUI

/// The Done log (spec § Now, Backlog and Done): everything finished, kept
/// indefinitely, grouped by the day it was finished (Today, Yesterday,
/// Mon 21 Sep…), searchable from the field at the top of its list
/// (Direction A: the add bar below always adds), each task restorable to
/// Now (its circle, or right-click). Loaded a page at a time as it scrolls,
/// so 5,000 finished tasks never load at once.
struct TasksDonePage<Cell: View, Mask: View>: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    /// Where the first line rests (under the tabs) and what the bottom
    /// stack needs clear (owner fix 8): the search row and the day
    /// headings scroll under the tabs like Now's rows.
    let listTop: CGFloat
    let bottomClearance: CGFloat
    let mask: Mask
    /// The search field's keyboard focus (Search from the menu bar sets it).
    @Binding var searchFocused: Bool
    /// A row the keyboard moved to: brought into the visible area (review 8).
    @Binding var reveal: TasksPageModel.ScrollRequest?
    let cell: (TasksListRow) -> Cell

    static var space: NamedCoordinateSpace { .named("AtticTasksDone") }

    var body: some View {
        let days = model.doneDays()
        list(days)
        .onAppear { model.loadDoneLogIfNeeded() }
        .onChange(of: model.doneSearch) { _, _ in model.loadDoneLogIfNeeded() }
        .onChange(of: store.revision) { _, _ in model.loadDoneLogIfNeeded() }
    }

    private func list(_ days: [TasksDoneDay]) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                AtticListSearchField(placeholder: model.searchPlaceholder, text: $model.doneSearch, isFocused: $searchFocused)
                    .accessibilityIdentifier("tasks-done-search")
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
                        .onAppear { model.loadMoreDoneLog() }
                }
                if days.isEmpty, model.doneLogFailure == nil {
                    let query = model.doneSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                    AtticEmptyLine(text: query.isEmpty
                        ? String(localized: "Finished tasks collect here.")
                        : String(localized: "No finished tasks match “\(query)”."))
                }
            }
        }
        .contentMargins(.top, listTop, for: .scrollContent)
        .contentMargins(.bottom, bottomClearance, for: .scrollContent)
        .contentMargins(.top, listTop, for: .scrollIndicators)
        .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
        .scrollEdgeEffectHidden(true, for: .all)
        .mask { mask }
        .coordinateSpace(Self.space)
        .onChange(of: reveal) { _, request in
            guard let request else { return }
            proxy.scrollTo(request.id)
        }
        // An agent's `show` of a finished task (the model loaded its page).
        .onChange(of: model.scrollRequest) { _, request in
            guard let request, model.tab == .done else { return }
            DispatchQueue.main.async { proxy.scrollTo(request.id, anchor: .center) }
        }
        }
    }
}
