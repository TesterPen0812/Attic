import SwiftUI

/// The Done log (spec § Now, Backlog and Done): everything finished, kept
/// indefinitely, grouped by the day it was finished (Today, Yesterday,
/// Mon 21 Sep…), searchable from the field at the top of its list
/// (Direction A: the add bar below always adds), each task restorable to
/// Now (its circle, or right-click). Loaded a page at a time as it scrolls,
/// so 5,000 finished tasks never load at once.
struct TasksDonePage<Cell: View>: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    let footerZone: CGFloat
    /// The search field's keyboard focus (Search from the menu bar sets it).
    @Binding var searchFocused: Bool
    let cell: (TasksListRow) -> Cell

    static var space: NamedCoordinateSpace { .named("AtticTasksDone") }

    var body: some View {
        let days = model.doneDays()
        VStack(alignment: .leading, spacing: 0) {
            AtticListSearchField(placeholder: model.searchPlaceholder, text: $model.doneSearch, isFocused: $searchFocused)
                .accessibilityIdentifier("tasks-done-search")
            list(days)
        }
        .onAppear { model.loadDoneLogIfNeeded() }
        .onChange(of: model.doneSearch) { _, _ in model.loadDoneLogIfNeeded() }
        .onChange(of: store.revision) { _, _ in model.loadDoneLogIfNeeded() }
    }

    private func list(_ days: [TasksDoneDay]) -> some View {
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
                        .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
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
        .contentMargins(.bottom, footerZone, for: .scrollContent)
        .scrollEdgeEffectHidden(true, for: .all)
        .coordinateSpace(Self.space)
    }
}
