import AppKit

/// Whole-block selection is separate from TextKit's character selection.
/// The engine still performs every mutation and owns its one-step Undo.
@MainActor
final class NoteMarqueeSelection {
    private weak var textView: NoteEditorTextView?
    private(set) var ranges: [NSRange] = []
    private var geometry: [MarqueeItem] = []
    private var blockRanges: [Int: NSRange] = [:]
    private var geometryWidth: CGFloat = 0
    private var geometryViewport = CGRect.null
    private var geometryNeedsRefresh = true
    private(set) var controller: AtticMarqueeController?
    private(set) var isSettingNativeSelection = false
    var isEmpty: Bool { ranges.isEmpty }

    init(textView: NoteEditorTextView, scrollView: NSScrollView) {
        self.textView = textView
        let controller = AtticMarqueeController(scrollView: scrollView)
        self.controller = controller
        controller.items = { [weak self] in self?.items() ?? [] }
        controller.selection = { [weak self] in Set(self?.ranges.map { AnyHashable($0.location) } ?? []) }
        controller.apply = { [weak self] in self?.select(offsets: Set($0.compactMap { $0.base as? Int })) }
        controller.enabled = { [weak textView] in textView?.engine?.activity == .idle && textView?.hasMarkedText() == false }
        controller.press = { [weak self] point, event in self?.press(at: point, event: event) ?? .ignore }
        controller.click = { [weak self] point in
            guard let self, let textView = self.textView else { return }
            self.clear()
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: textView.characterIndexForInsertion(at: point), length: 0))
        }
        controller.clear = { [weak self] in self?.clear() }
        controller.embeddedClick = { [weak self] in self?.clear() }
        controller.move = { [weak self] point in
            guard let self, let textView = self.textView, let engine = textView.engine else { return }
            let at = textView.characterIndexForInsertion(at: point)
            let line = engine.paragraphRange(at: at)
            let rect = engine.rect(for: line)
            let target = point.y > (rect?.midY ?? point.y) ? NSMaxRange(line) : line.location
            _ = self.move(to: target)
        }
        controller.movePreview = { [weak self] point in
            guard let self, let textView = self.textView, let engine = textView.engine else { return nil }
            let line = engine.paragraphRange(at: textView.characterIndexForInsertion(at: point))
            guard let rect = engine.rect(for: line) else { return nil }
            return CGRect(x: textView.textContainerOrigin.x, y: point.y > rect.midY ? rect.maxY : rect.minY,
                          width: textView.textContainer?.size.width ?? rect.width, height: 1)
        }
    }

    private func press(at point: CGPoint, event: NSEvent) -> AtticMarqueeController.Press {
        guard let textView, let engine = textView.engine else { return .ignore }
        geometry = []
        if !event.modifierFlags.contains(.shift), !isEmpty,
           items().contains(where: { item in ranges.contains { AnyHashable($0.location) == item.id } && item.rect.contains(point) }),
           textView.isEditable { return .move }
        // Real text, hosted tables, checkboxes and accessory controls keep
        // their existing mouse routes. Only the column margins and blank
        // space after the document start a marquee.
        // The block handle in the margin (R14 D.2) is its own control.
        if !textView.blockHandle.isHidden, textView.blockHandle.frame.contains(point) { return .ignore }
        let x = textView.textContainerOrigin.x
        let width = textView.textContainer?.size.width ?? textView.bounds.width
        let outsideColumn = point.x < x || point.x > x + width
        // Ordinary text clicks and scrolling must keep TextKit's lazy
        // layout. Only ask for the final caret if this hit resolves there.
        let atEnd = !outsideColumn && textView.characterIndexForInsertion(at: point) >= engine.textStorage.length
        let below = atEnd && point.y > (engine.caretRect(at: engine.textStorage.length)?.maxY ?? 0)
        if outsideColumn || below {
            _ = items()
            textView.window?.makeFirstResponder(textView)
            return .select
        }
        clear()
        return .ignore
    }

    /// Measure only the viewport and the auto-scroll band. During a drag,
    /// retain visited blocks so scrolling does not drop earlier selections.
    /// Layout changes refresh the visible positions; folding and edits reset
    /// the whole gesture before old geometry can select hidden text.
    func items() -> [MarqueeItem] {
        guard let textView, let engine = textView.engine, let layout = engine.layoutManager else { return [] }
        let viewport = textView.visibleRect.insetBy(dx: 0, dy: -24)
        if !geometry.isEmpty, !geometryNeedsRefresh,
           geometryWidth == textView.bounds.width, geometryViewport == viewport { return geometry }
        let retainVisited = controller?.isDragging == true && geometryWidth == textView.bounds.width
        geometryWidth = textView.bounds.width
        geometryViewport = viewport
        geometryNeedsRefresh = false
        if !retainVisited { geometry = []; blockRanges = [:] }
        var measured = Dictionary(uniqueKeysWithValues: geometry.map { ($0.id, $0) })
        let string = engine.textStorage.string as NSString
        let origin = textView.textContainerOrigin
        let top = CGPoint(x: 0, y: max(0, viewport.minY - origin.y))
        let start = layout.textLayoutFragment(for: top)?.rangeInElement.location
            ?? layout.textViewportLayoutController.viewportRange?.location
            ?? engine.contentStorage.documentRange.location
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > viewport.maxY { return false }
            guard frame.maxY >= viewport.minY else { return true }
            let offset = engine.contentStorage.offset(from: engine.contentStorage.documentRange.location,
                                                      to: fragment.rangeInElement.location)
            guard offset >= 0, offset < string.length else { return true }
            let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
            guard !engine.isRangeFolded(range) else { return true }
            let ink = fragment.textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
            let rect = CGRect(x: origin.x - 4, y: frame.minY + (ink.isNull ? 0 : ink.minY),
                              width: (textView.textContainer?.size.width ?? frame.width) + 8,
                              height: max(ink.isNull ? frame.height : ink.height, 18))
            measured[AnyHashable(range.location)] = MarqueeItem(id: range.location, rect: rect)
            blockRanges[range.location] = self.blockRange(at: range.location)
            return true
        }
        geometry = measured.values.sorted { ($0.id.base as? Int ?? 0) < ($1.id.base as? Int ?? 0) }
        // Give the inter-paragraph space to the preceding block: adjacent
        // selected blocks meet, with no stripes across the column.
        for index in geometry.indices.dropLast() {
            let item = geometry[index]
            var rect = item.rect
            rect.size.height = max(rect.height, geometry[index + 1].rect.minY - rect.minY)
            geometry[index] = MarqueeItem(id: item.id, rect: rect)
        }
        return geometry
    }

    private func blockRange(at offset: Int) -> NSRange? {
        guard let engine = textView?.engine, offset >= 0, offset < engine.textStorage.length else { return nil }
        let range = engine.paragraphRange(at: offset)
        guard !engine.isRangeFolded(range) else { return nil }
        if let section = engine.headingSection(at: offset), section.id.map(engine.foldedHeadingIDs.contains) == true {
            return NSRange(location: range.location, length: NSMaxRange(section.content) - range.location)
        }
        return range
    }

    func select(offsets: Set<Int>) {
        _ = items()
        ranges = offsets.sorted().compactMap { blockRanges[$0] ?? blockRange(at: $0) }
        // Save the real caret mode before TextKit's collapsed-selection
        // transition temporarily changes the indicator's display mode.
        textView?.caretFitter.refresh()
        // A collapsed native range avoids native blue character highlights;
        // the caret fitter hides its modern indicator until selection clears.
        isSettingNativeSelection = true
        if let first = ranges.first { textView?.setSelectedRange(NSRange(location: first.location, length: 0)) }
        isSettingNativeSelection = false
        textView?.updateInsertionPointStateAndRestartTimer(true)
        if let textView { NSAccessibility.post(element: textView, notification: .selectedTextChanged) }
        controller?.refresh()
    }

    func clear() {
        guard !ranges.isEmpty else { return }
        ranges = []
        textView?.updateInsertionPointStateAndRestartTimer(true)
        controller?.refresh()
    }

    func layoutChanged() {
        geometryNeedsRefresh = true
        if !ranges.isEmpty { controller?.refresh() }
    }

    func textChanged() {
        ranges = []
        geometry = []
        blockRanges = [:]
        controller?.invalidate()
        textView?.updateInsertionPointStateAndRestartTimer(true)
    }

    @discardableResult
    func delete() -> Bool {
        guard let engine = textView?.engine, !ranges.isEmpty else { return false }
        let copy = ranges
        let result = NSMutableAttributedString(attributedString: engine.textStorage)
        for range in copy.reversed() { result.deleteCharacters(in: range) }
        preserveEndOfDocument(in: result, original: engine.textStorage.string)
        return engine.performEdit(NSRange(location: 0, length: engine.textStorage.length), with: result,
                                  name: "Delete Blocks", selection: NSRange(location: min(copy[0].location, result.length), length: 0))
    }

    /// One atomic edit preserves attachment identities and avoids a partial
    /// move if an admission gate refuses the resulting document.
    @discardableResult
    func move(to destination: Int) -> Bool {
        guard let engine = textView?.engine, !ranges.isEmpty,
              destination >= 0, destination <= engine.textStorage.length else { return false }
        let copy = ranges
        if copy.contains(where: { destination > $0.location && destination < NSMaxRange($0) }) { return false }
        let payload = selectedText()
        let remaining = NSMutableAttributedString(attributedString: engine.textStorage)
        for range in copy.reversed() { remaining.deleteCharacters(in: range) }
        var target = destination - copy.filter { NSMaxRange($0) <= destination }.reduce(0) { $0 + $1.length }
        target = min(target, remaining.length)
        let insertion = NSMutableAttributedString(attributedString: payload)
        // Moving the final, unterminated block earlier still leaves whole
        // paragraphs. Moving to an unterminated end needs a leading break.
        if target > 0, (remaining.string as NSString).character(at: target - 1) != 10 {
            insertion.insert(NSAttributedString(string: "\n", attributes: engine.style.bodyAttributes), at: 0)
        }
        if target < remaining.length, !insertion.string.hasSuffix("\n") {
            insertion.append(NSAttributedString(string: "\n", attributes: engine.style.bodyAttributes))
        }
        remaining.insert(insertion, at: target)
        preserveEndOfDocument(in: remaining, original: engine.textStorage.string)
        guard !remaining.isEqual(to: engine.textStorage) else { return false }
        return engine.performEdit(NSRange(location: 0, length: engine.textStorage.length), with: remaining,
                                  name: "Move Blocks", selection: NSRange(location: target, length: 0))
    }

    /// A newline separates blocks; it is not an extra blank block when the
    /// final block is removed or an internal block is moved to the end.
    /// Preserve an empty last block only if the document already had one.
    private func preserveEndOfDocument(in text: NSMutableAttributedString, original: String) {
        if !original.hasSuffix("\n"), text.string.hasSuffix("\n") {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
    }

    private func selectedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard let engine = textView?.engine else { return result }
        for range in ranges { result.append(engine.textStorage.attributedSubstring(from: range)) }
        return result
    }

    @discardableResult
    func copy(to board: NSPasteboard) -> Bool {
        guard let engine = textView?.engine, !ranges.isEmpty else { return false }
        // Reuse the established export path, including table fallback and
        // private attachment payload, without changing the live selection.
        return engine.writeSelection(selectedText(), to: board,
            types: [NoteEditorEngine.fragmentType, .rtf, .string, TasksTextExport.markdownType])
    }
}
