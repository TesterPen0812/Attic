import AppKit
import SwiftUI

/// One Find session for the shared note engine, including table-cell text.
/// Highlights are rendering attributes only: searching never changes the
/// document, its save state or its Undo history.
@MainActor
final class NoteFindController: ObservableObject {
    struct Match: Equatable {
        let noteRange: NSRange
        var tableID: UUID? = nil
        var cell: NoteTable.Position? = nil
        var cellRange: NSRange? = nil
    }
    weak var engine: NoteEditorEngine?
    @Published private(set) var isShown = false
    @Published var query = "" { didSet { refresh(selectFirst: true) } }
    @Published private(set) var matches: [Match] = []
    @Published private(set) var index: Int? = nil
    @Published var fieldFocused = false
    private var monitor: Any?
    private var host: NSHostingView<AnyView>?
    private var topInset: CGFloat = 0
    private var columnInset: CGFloat = 16
    static var height: CGFloat { AtticControlSize.smallHeight * 2 + AtticSpacing.s4 + AtticSpacing.s8 * 2 }
    var clearance: CGFloat { isShown ? Self.height : 0 }
    let highlight = NSColor.systemYellow.withAlphaComponent(0.4)

    init(engine: NoteEditorEngine) { self.engine = engine }

    func attach() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let view = self.engine?.textView, let window = view.window,
                      event.window === window, window.isKeyWindow else { return event }
                let responder = window.firstResponder
                let inNote = responder === view || self.engine?.activeTableView?.isFocused == true
                let inFind = (responder as? NSTextView)?.isFieldEditor == true
                    && ((responder as? NSTextView)?.delegate as? NSView).map { field in
                        self.host.map { field.isDescendant(of: $0) } == true
                    } == true
                return (inNote || inFind) && self.handleKey(event) ? nil : event
            }
        }
        layoutBar()
    }

    func detach() {
        close(returnFocus: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        host?.removeFromSuperview()
        host = nil
    }

    func setGeometry(top: CGFloat, column: CGFloat) {
        topInset = top
        columnInset = column
        layoutBar()
    }

    func layoutBar() {
        guard let scroll = engine?.scrollView, let host else { return }
        let y = scroll.isFlipped ? topInset : scroll.bounds.height - topInset - Self.height
        host.frame = NSRect(x: columnInset, y: y, width: max(0, scroll.bounds.width - 2 * columnInset), height: Self.height)
        host.isHidden = !isShown
    }

    func show() {
        guard let engine, let scroll = engine.scrollView else { return }
        if host == nil {
            let host = NSHostingView(rootView: AnyView(NoteFindBar(find: self).atticDesign(engine.style.design)))
            self.host = host
            scroll.addSubview(host)
        }
        if !isShown {
            topInset = scroll.contentInsets.top
            isShown = true
            scroll.contentInsets.top = topInset + Self.height
            layoutBar()
            refresh(selectFirst: false)
        }
        fieldFocused = true
    }

    func close(returnFocus: Bool = true) {
        guard isShown else { return }
        let selected = index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        isShown = false
        fieldFocused = false
        matches = []
        index = nil
        engine?.scrollView?.contentInsets.top = topInset
        layoutBar()
        updateHighlights(clear: true)
        if returnFocus, let engine {
            if let id = selected?.tableID, let cell = selected?.cell, let range = selected?.cellRange,
               let (table, _) = engine.tableAttachment(id: id) {
                engine.enterTable(table, at: cell, caret: .range(range))
            } else { engine.textView?.window?.makeFirstResponder(engine.textView) }
        }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 3, flags == .command { show(); return true }
        if event.keyCode == 5, flags == .command || flags == [.command, .shift] {
            if !isShown { show() }
            next(backward: flags.contains(.shift))
            return true
        }
        if isShown, event.keyCode == 53, flags.isEmpty { close(); return true }
        if isShown, fieldFocused, event.keyCode == 36, flags.isEmpty || flags == .shift {
            next(backward: flags.contains(.shift)); return true
        }
        return false
    }

    private func ranges(in string: String) -> [NSRange] {
        let text = string as NSString
        var result: [NSRange] = [], start = 0
        guard !query.isEmpty else { return [] }
        while start < text.length {
            let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: NSRange(location: start, length: text.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            start = NSMaxRange(range)
        }
        return result
    }

    func refresh(selectFirst: Bool = false) {
        guard isShown, let engine else { return }
        let old = index.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
        var found = ranges(in: engine.textStorage.string).map { Match(noteRange: $0) }
        for (object, range) in engine.objects() {
            guard let table = object as? NoteTableAttachment else { continue }
            for row in table.table.rows.indices {
                for column in table.table.columns.indices {
                    let cell = NoteTable.Position(row: row, column: column)
                    found += ranges(in: table.table[cell].text).map {
                        Match(noteRange: range, tableID: table.objectID, cell: cell, cellRange: $0)
                    }
                }
            }
        }
        found.sort {
            if $0.noteRange.location != $1.noteRange.location { return $0.noteRange.location < $1.noteRange.location }
            if $0.cell?.row != $1.cell?.row { return ($0.cell?.row ?? -1) < ($1.cell?.row ?? -1) }
            if $0.cell?.column != $1.cell?.column { return ($0.cell?.column ?? -1) < ($1.cell?.column ?? -1) }
            return ($0.cellRange?.location ?? 0) < ($1.cellRange?.location ?? 0)
        }
        matches = found
        index = selectFirst ? found.indices.first : old.flatMap { found.firstIndex(of: $0) }
        updateHighlights()
        if selectFirst { reveal(activateCell: false) }
    }

    func next(backward: Bool = false) {
        guard !matches.isEmpty else { return }
        index = index.map { ($0 + (backward ? matches.count - 1 : 1)) % matches.count }
            ?? (backward ? matches.count - 1 : 0)
        reveal(activateCell: true)
    }

    private func reveal(activateCell: Bool) {
        guard let engine, let index, matches.indices.contains(index) else { return }
        let match = matches[index]
        if let id = match.tableID, let cell = match.cell, let range = match.cellRange,
           let (table, _) = engine.tableAttachment(id: id) {
            engine.textView?.scrollRangeToVisible(match.noteRange)
            if activateCell { engine.enterTable(table, at: cell, caret: .range(range)); fieldFocused = false }
        } else {
            engine.activeTableView?.deactivate()
            if activateCell && !fieldFocused {
                engine.textView?.window?.makeFirstResponder(engine.textView)
            }
            engine.textView?.setSelectedRange(match.noteRange)
            engine.textView?.scrollRangeToVisible(match.noteRange)
        }
        updateHighlights()
    }

    func decorate(_ string: NSMutableAttributedString, tableID: UUID, cell: NoteTable.Position) {
        for match in matches where match.tableID == tableID && match.cell == cell {
            if let range = match.cellRange, NSMaxRange(range) <= string.length {
                string.addAttribute(.backgroundColor, value: highlight, range: range)
            }
        }
    }

    func updateHighlights(clear: Bool = false) {
        guard isShown || clear else { return }
        guard let engine else { return }
        if let layout = engine.layoutManager {
            layout.removeRenderingAttribute(.backgroundColor, for: engine.contentStorage.documentRange)
            for match in matches where match.tableID == nil {
                if let range = engine.textRange(for: match.noteRange) {
                    layout.addRenderingAttribute(.backgroundColor, value: highlight, for: range)
                }
            }
        }
        for view in engine.tableViews() {
            view.canvas.needsDisplay = true
            if view.hasEditor, let cell = view.activeCell, let id = view.attachment?.objectID,
               let layout = view.editor.textLayoutManager, let content = layout.textContentManager {
                layout.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
                for match in matches where match.tableID == id && match.cell == cell {
                    if let range = match.cellRange,
                       let start = content.location(content.documentRange.location, offsetBy: range.location),
                       let end = content.location(start, offsetBy: range.length),
                       let textRange = NSTextRange(location: start, end: end) {
                        layout.addRenderingAttribute(.backgroundColor, value: highlight, for: textRange)
                    }
                }
            }
        }
    }
}

private struct NoteFindBar: View {
    @ObservedObject var find: NoteFindController
    var body: some View {
        VStack(spacing: 4) {
            AtticTabsSearchField(placeholder: String(localized: "Find in note"), text: $find.query,
                                 isFocused: $find.fieldFocused, nativeInputIdentifier: "note-find", onEscape: { find.close() })
            HStack(spacing: 4) {
                AtticText(verbatim: find.matches.isEmpty ? String(localized: "No matches") : "\((find.index ?? -1) + 1) / \(find.matches.count)",
                          style: .rowMeta, ink: .helper)
                    .accessibilityIdentifier("note-find-count")
                Spacer()
                AtticSmallButton(systemName: "chevron.up", label: "Previous match") { find.next(backward: true) }
                    .accessibilityIdentifier("note-find-previous")
                    .disabled(find.matches.isEmpty)
                AtticSmallButton(systemName: "chevron.down", label: "Next match") { find.next() }
                    .accessibilityIdentifier("note-find-next")
                    .disabled(find.matches.isEmpty)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-find-bar")
        .padding(AtticSpacing.s8)
        .background(AtticPopoverBackground(cornerRadius: AtticRadius.contentCard))
    }
}
