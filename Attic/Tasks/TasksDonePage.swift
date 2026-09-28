import SwiftUI

/// The Done log (spec § Now, Backlog and Done): everything finished, kept
/// indefinitely, grouped by the day it was finished (Today, Yesterday,
/// Mon 21 Sep…), searchable from the tabs line (owner item 17: the field
/// takes the tabs' place while searching; the add bar below always adds),
/// matches highlighted, with a quiet "N of M done tasks"; each task restorable to
/// Now (its circle, or right-click). Loaded a page at a time as it scrolls,
/// so 5,000 finished tasks never load at once.
struct TasksDonePage<Cell: View, Mask: View>: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    /// Where the first line rests (under the tabs) and what the bottom
    /// stack needs clear (owner fix 8): the day headings scroll under the
    /// tabs like Now's rows.
    let listTop: CGFloat
    let bottomClearance: CGFloat
    /// The add bar's zone: the only bottom margin (round 6; the rest of the
    /// clearance is room at the end of the list, so rows there take clicks).
    let bottomMargin: CGFloat
    let mask: Mask
    /// A row the keyboard moved to: brought into the visible area (review 8).
    @Binding var reveal: TasksPageModel.ScrollRequest?
    /// Brings a row into the uncovered part of the list (the page's rule).
    let revealRow: (UUID, ScrollViewProxy) -> Void
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
                } else if let count = model.doneSearchCount() {
                    // A quiet line under the results (v22 card B).
                    AtticText(verbatim: String(localized: "\(count.matches) of \(count.total) done tasks"), style: .rowMeta, ink: .helper)
                        .frame(height: AtticLayout.rowPitch)
                        .padding(.leading, AtticLayout.textX)
                        .accessibilityIdentifier("tasks-done-search-count")
                }
            }
            .padding(.bottom, bottomClearance - bottomMargin)
            // Read only while Done is the page shown (see `TasksPage.listPage`).
            .accessibilityHidden(model.tab != .done)
        }
        .contentMargins(.top, listTop, for: .scrollContent)
        .contentMargins(.bottom, bottomMargin, for: .scrollContent)
        .contentMargins(.top, listTop, for: .scrollIndicators)
        .contentMargins(.bottom, bottomClearance, for: .scrollIndicators)
        .scrollEdgeEffectHidden(true, for: .all)
        .mask { mask }
        .coordinateSpace(Self.space)
        .onChange(of: reveal) { _, request in
            guard let request else { return }
            revealRow(request.id, proxy)
        }
        // An agent's `show` of a finished task (the model loaded its page).
        .onChange(of: model.scrollRequest) { _, request in
            guard let request, model.tab == .done else { return }
            DispatchQueue.main.async { proxy.scrollTo(request.id, anchor: .center) }
        }
        }
    }
}
