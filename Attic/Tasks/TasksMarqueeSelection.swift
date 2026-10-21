import AppKit

/// Adapts the list's measured row frames to the shared marquee. It writes
/// only the existing model selection; delete/move/tag/complete and the
/// selection bar therefore retain their established command routes.
@MainActor
final class TasksMarqueeSelection {
    private(set) var controller: AtticMarqueeController
    private weak var model: TasksPageModel?
    private weak var pointer: TasksPointer?
    private weak var scroll: NSScrollView?
    private let tab: TasksTab
    private var measured: [AnyHashable: CGRect] = [:]

    init(scroll: NSScrollView, model: TasksPageModel, pointer: TasksPointer, tab: TasksTab,
         focusSelection: @escaping (UUID?) -> Void = { _ in }) {
        self.scroll = scroll
        self.model = model
        self.pointer = pointer
        self.tab = tab
        controller = AtticMarqueeController(scrollView: scroll)
        controller.drawsHighlights = false // the rows already draw merged selection runs
        controller.consumesSelectionEscape = false // Tasks closes expanded content before clearing selection
        controller.enabled = { [weak model] in model?.isPageShown == true && model?.isHidden == false && model?.tab == tab && model?.editingTitleID == nil }
        controller.items = { [weak self] in self?.items() ?? [] }
        controller.selection = { [weak model] in Set(model?.selection.map(AnyHashable.init) ?? []) }
        controller.apply = { [weak model] ids in
            guard let model else { return }
            let ordered = Self.rowIDs(in: model, tab: tab).filter { ids.contains(AnyHashable($0)) }
            if Set(ordered) != model.selection { model.selectCopies(ordered) }
        }
        controller.clear = { [weak model] in model?.clearSelection() }
        controller.click = { [weak model] _ in model?.clearSelection() }
        controller.press = { [weak self] point, _ in self?.press(at: point) ?? .ignore }
        controller.selectionEnded = { [weak self, weak model] point in
            guard let self, let model else { return }
            // A marquee starts outside any row, so no row received the
            // native click that normally gives it keyboard commands. Hand
            // off once, on release, to the selected row nearest the pointer.
            // Keep the whole selection and avoid jumping to an offscreen start.
            let nearest = self.items().filter { ($0.id.base as? UUID).map(model.selection.contains) == true }
                .min { abs($0.rect.midY - point.y) < abs($1.rect.midY - point.y) }
            focusSelection(nearest?.id.base as? UUID)
        }
    }

    private func press(at point: CGPoint) -> AtticMarqueeController.Press {
        guard let scroll, let document = scroll.documentView else { return .ignore }
        if let page = pointer?.view, let control = pointer?.completedTodayFrames[tab],
           document.convert(control, from: page).contains(point) { return .ignore }
        measured = [:]
        let rows = items()
        let margin = AtticLayout.rowHighlightInset
        // Row text/grabs, circles, disclosure buttons and metadata keep all
        // of their original mouse/reorder behaviour.
        let inMargin = point.x < margin || point.x > document.bounds.width - margin
        let below = point.y > (rows.map(\.rect.maxY).max() ?? 0)
        guard inMargin || below else { return .ignore }
        // End text editing so the list's existing keyboard commands receive
        // delete/copy after a marquee started from an empty region.
        if scroll.window?.firstResponder is NSTextView { scroll.window?.makeFirstResponder(scroll) }
        return .select
    }

    func items() -> [MarqueeItem] {
        guard let model, let pointer, let page = pointer.view, let document = scroll?.documentView else { return [] }
        let live = Set(Self.rowIDs(in: model, tab: tab))
        measured = measured.filter { ($0.key.base as? UUID).map(live.contains) == true }
        for (row, rect) in pointer.frames where row.tab == tab && live.contains(row.id) {
            measured[AnyHashable(row.id)] = document.convert(rect, from: page)
        }
        // Keep offscreen measurements while auto-scrolling: lazy rows leave
        // the hierarchy but must remain selectable back to the drag origin.
        return measured.map { MarqueeItem(id: $0.key, rect: $0.value) }
    }

    private static func rowIDs(in model: TasksPageModel, tab: TasksTab) -> [UUID] {
        // Done includes its paged archive and today's finished rows. The
        // Now/Later row source is empty there: treating that as no rows
        // would take normal row clicks and drag-out as empty-space drags.
        tab == .done ? model.doneDays().flatMap { $0.rows.map(\.id) } : model.rows(for: tab).map(\.id)
    }
}
