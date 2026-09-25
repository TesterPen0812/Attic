import SwiftUI

/// The Done log (spec § Now, Backlog and Done): everything finished, kept
/// indefinitely, grouped by the day it was finished (Today, Yesterday,
/// Mon 21 Sep…), searchable from the bottom bar, each task restorable to
/// Now (its circle, or right-click). Loaded a page at a time as it scrolls,
/// so 5,000 finished tasks never load at once.
struct TasksDonePage<Cell: View>: View {
    @ObservedObject var model: TasksPageModel
    @ObservedObject var store: TaskStore
    let footerZone: CGFloat
    let cell: (TasksListRow) -> Cell

    static var space: NamedCoordinateSpace { .named("AtticTasksDone") }

    var body: some View {
        let days = model.doneDays()
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    AtticText(verbatim: day.title, style: .rowMeta, ink: .helper)
                        .frame(height: AtticLayout.rowPitch, alignment: .bottom)
                        .padding(.bottom, AtticSpacing.s4)
                        .padding(.leading, AtticLayout.circleX)
                        .accessibilityAddTraits(.isHeader)
                        .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                    ForEach(day.rows) { row in
                        cell(row).id(row.id)
                    }
                }
                if model.doneLogHasMore {
                    AtticLoadingRows(count: 2)
                        .onAppear { model.loadMoreDoneLog() }
                }
                if days.isEmpty {
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
        .onAppear { model.loadDoneLogIfNeeded() }
        .onChange(of: model.doneSearch) { _, _ in model.loadDoneLogIfNeeded() }
        .onChange(of: store.revision) { _, _ in model.loadDoneLogIfNeeded() }
    }
}
