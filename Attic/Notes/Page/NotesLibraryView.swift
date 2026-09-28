import SwiftUI

/// All notes, plain (slice 2): the fixed "All notes" label on the tabs'
/// line, Done's search row, then the notes in date groups. The filters and
/// More tags… arrive with slice 4. Typing searches; ↑ ↓ move through the
/// rows, Return opens, ⌘⌫ deletes; Esc clears the search, then goes back.
struct NotesLibraryView: View {
    @ObservedObject var model: NotesLibraryModel
    @ObservedObject var controller: NotesPageController
    @ObservedObject var store: NoteStore
    let layout: PanelPageLayout
    let bottomClearance: CGFloat
    @Binding var searchFocused: Bool
    let rowCommands: (UUID) -> [AtticMenuCommand]
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onBack: () -> Void

    @Environment(\.atticDesign) private var design

    static let space = NamedCoordinateSpace.named("AtticNotesLibrary")

    private var pageEdge: CGFloat { max(0, layout.chromeInsets.leading - AtticSpacing.panelMargin) }

    var body: some View {
        let groups = model.groups(store: store, drafts: controller.failedDrafts)
        let selected = controller.librarySelectionID
        VStack(alignment: .leading, spacing: 0) {
            AtticPageTabs(items: [AtticPageTabs.Item(page: 0, title: String(localized: "All notes"),
                                                     accessibilityIdentifier: "notes-library-label")],
                          selection: .constant(0))
                .focusable(false)
                .padding(.leading, AtticLayout.pageTabsX)
                .padding(.top, layout.headerBottom + AtticLayout.pageTabsTop)
                .padding(.bottom, AtticLayout.pageTabsToList)
            AtticListSearchField(
                placeholder: placeholder, text: $model.query, isFocused: $searchFocused,
                iconX: AtticNoteMetrics.searchIconX, textX: AtticNoteMetrics.searchTextX,
                onKeyPress: { press in key(press, groups: groups, selected: selected, inField: true) },
                onEscapeWhenEmpty: onBack
            )
            .accessibilityIdentifier("notes-library-search")
            list(groups, selected: selected)
        }
        .padding(.horizontal, pageEdge)
        .onExitCommand {
            if model.isSearching { model.clearSearch() } else { onBack() }
        }
        .onKeyPress(phases: .down) { press in key(press, groups: groups, selected: selected, inField: false) }
        .accessibilityIdentifier("notes-library")
    }

    private var placeholder: String {
        let count = store.notes.count
        return count == 1 ? String(localized: "Search 1 note") : String(localized: "Search \(count) notes")
    }

    private func list(_ groups: [NotesLibraryModel.Group], selected: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    status(groups)
                    ForEach(groups) { group in
                        AtticNoteGroupHeading(title: group.title)
                            .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                        ForEach(group.rows) { row in
                            AtticNoteRow(model: row, isSelected: row.id == selected && model.highlightedID == nil,
                                         isHighlighted: row.id == model.highlightedID) { onOpen(row.id) }
                                .id(row.id)
                                .contextMenu { AtticMenuItems(commands: rowCommands(row.id)) }
                                .accessibilityIdentifier("notes-library-row")
                                .modifier(AtticScrollEdgeFade(space: Self.space, top: TasksPage.listTopFade, bottom: AtticEdgeBlur.panelBottom))
                        }
                    }
                }
            }
            .contentMargins(.bottom, bottomClearance, for: .scrollContent)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectHidden(true, for: .all)
            .coordinateSpace(Self.space)
            .onAppear {
                if let selected { proxy.scrollTo(selected, anchor: .center) }
            }
            .onChange(of: model.highlightedID) { _, id in
                guard let id else { return }
                withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    /// Empty, no matches, searching and failure: one quiet line where the
    /// first row would be; a failure keeps the earlier results under it.
    @ViewBuilder
    private func status(_ groups: [NotesLibraryModel.Group]) -> some View {
        if case .failed = model.searchState {
            AtticErrorLine(message: String(localized: "Couldn’t search"), onRetry: model.retry)
                .padding(.leading, AtticNoteMetrics.rowTextX)
                .frame(height: AtticLayout.rowPitch)
                .accessibilityIdentifier("notes-library-search-failed")
        } else if groups.isEmpty {
            if model.isSearching {
                if model.matches == nil || model.showsLoading {
                    if model.showsLoading {
                        AtticLoadingRows(count: 2).accessibilityIdentifier("notes-library-searching")
                    }
                } else {
                    emptyLine(String(localized: "No notes match “\(model.matchedQuery)”"))
                }
            } else {
                emptyLine(String(localized: "No notes yet"))
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        AtticText(verbatim: text, style: .listBody, ink: .helper)
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticNoteMetrics.rowTextX)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("notes-library-empty")
    }

    private func key(_ press: KeyPress, groups: [NotesLibraryModel.Group], selected: UUID?, inField: Bool) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            model.moveHighlight(by: 1, in: groups, from: selected)
            return .handled
        case .upArrow:
            model.moveHighlight(by: -1, in: groups, from: selected)
            return .handled
        case .return:
            guard let id = model.highlightedID ?? (model.isSearching ? model.orderedIDs(groups).first : nil) else {
                return .ignored
            }
            onOpen(id)
            return .handled
        case .delete where press.modifiers.contains(.command):
            // In the search field ⌘⌫ edits the text until ↑ ↓ picked a row.
            guard let id = model.highlightedID ?? (inField ? nil : selected) else { return .ignored }
            onDelete(id)
            return .handled
        default:
            return .ignored
        }
    }
}
