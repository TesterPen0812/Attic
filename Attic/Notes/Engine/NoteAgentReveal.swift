import AppKit

/// What an agent's applied write added to the note on show, found against
/// the text from just before it. A watched run shows that span being written.
struct NoteAgentInsertion: Equatable {
    /// Where the added text sits in the editor's text now.
    var range: NSRange
    /// Something was replaced or removed as well: shown plainly, never typed.
    var replaces: Bool
}

extension NoteEditorEngine {
    /// The one changed span between `before` and the text on show: what the
    /// two share at the start and at the end is left out. Nil when they match.
    func agentInsertion(since before: NoteDocument) -> NoteAgentInsertion? {
        var shown = before
        if isBodyOnly {
            if !shown.blocks.isEmpty { shown.blocks.removeFirst() }
            if shown.blocks.isEmpty { shown.blocks = [.text("")] }
        }
        let old = NoteTextCodec.attributedString(from: shown, style: style, firstBlockIsTitle: !isBodyOnly).string
        return Self.agentInsertion(from: old as NSString, to: textStorage.string as NSString)
    }

    static func agentInsertion(from old: NSString, to new: NSString) -> NoteAgentInsertion? {
        let oldLength = old.length, newLength = new.length
        var prefix = 0
        while prefix < oldLength, prefix < newLength, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < oldLength - prefix, suffix < newLength - prefix,
              old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        guard newLength - prefix - suffix > 0 || oldLength - prefix - suffix > 0 else { return nil }
        var range = NSRange(location: prefix, length: newLength - prefix - suffix)
        // Never part of a character: the span grows to whole ones.
        if range.length > 0 { range = new.rangeOfComposedCharacterSequences(for: range) }
        return NoteAgentInsertion(range: range, replaces: oldLength - prefix - suffix > 0)
    }
}

/// The surface a watched note edit is written on. `NoteEditorTextView` is
/// the real one; tests use their own.
@MainActor
protocol AgentNoteSurface: AnyObject {
    func agentInsertion(since before: NoteDocument) -> NoteAgentInsertion?
    /// The added text as it reads in the note.
    func agentText(in range: NSRange) -> String
    /// Hides `range` past its first `shown` characters; the writing point's
    /// caret, in window coordinates. Display only: the text never changes.
    @discardableResult
    func veilAgentWriting(_ range: NSRange, shown: Int) -> CGRect?
    func liftAgentVeil()
    /// Shown, never handed the keyboard: it stays with the chat, even when
    /// the page's arrival gives the note its caret back.
    func keepKeyboardOff()
}

extension AgentNoteSurface {
    func keepKeyboardOff() {}
}

extension NoteEditorTextView: AgentNoteSurface {
    func agentInsertion(since before: NoteDocument) -> NoteAgentInsertion? {
        engine?.agentInsertion(since: before)
    }

    func agentText(in range: NSRange) -> String {
        let text = string as NSString
        guard NSMaxRange(range) <= text.length else { return "" }
        return text.substring(with: range)
    }

    /// The caret's rect at `offset`, in this view.
    private func agentCaret(at offset: Int) -> CGRect? {
        guard let window else { return nil }
        let offset = min(max(0, offset), (string as NSString).length)
        let screen = firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
        guard screen != .zero else { return nil }
        return convert(window.convertFromScreen(screen), from: nil)
    }

    /// The rest of the writing line and every line below it, down to the
    /// last added one, are masked out. Lines after the edit stay in place.
    @discardableResult
    func veilAgentWriting(_ range: NSRange, shown: Int) -> CGRect? {
        // The writer has the note from here.
        engine?.agentVeil = nil
        return applyAgentVeil(range, shown: shown)
    }

    /// Before the writer has the note: the added text is hidden from the
    /// first frame the page draws, as the note comes forward.
    func applyPendingAgentVeil() {
        guard let range = engine?.agentVeil, window != nil else { return }
        applyAgentVeil(range, shown: 0)
    }

    @discardableResult
    private func applyAgentVeil(_ range: NSRange, shown: Int) -> CGRect? {
        // The last added line, not the line after it: a span ending in a
        // new line ends before it.
        let text = string as NSString
        var last = NSMaxRange(range)
        if range.length > 0, last <= text.length, text.character(at: last - 1) == 10 { last -= 1 }
        guard let layer, let caret = agentCaret(at: range.location + shown),
              let end = agentCaret(at: last) else {
            removeAgentMask()
            return nil
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = layer.bounds
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        let path = CGMutablePath()
        path.addRect(layer.bounds)
        if shown < range.length {
            let line = CGRect(x: caret.minX, y: caret.minY, width: max(0, bounds.maxX - caret.minX), height: caret.height)
            path.addRect(convertToLayer(line))
            if end.maxY > line.maxY + 0.5 {
                // A little past the last line: a marker's or a box's edge.
                path.addRect(convertToLayer(CGRect(x: bounds.minX, y: line.maxY, width: bounds.width,
                                                   height: end.maxY + 2 - line.maxY)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = path
        if layer.mask !== mask { layer.mask = mask }
        CATransaction.commit()
        keepInSight(caret)
        return convert(caret, to: nil)
    }

    func keepKeyboardOff() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    func liftAgentVeil() {
        engine?.agentVeil = nil
        removeAgentMask()
    }

    private func removeAgentMask() {
        guard layer?.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask = nil
        CATransaction.commit()
    }

    /// The writing point stays in sight, clear of the composer at the bottom.
    private func keepInSight(_ caret: CGRect) {
        let composer: CGFloat = 120
        let usable = visibleRect.divided(atDistance: min(composer, visibleRect.height / 2), from: isFlipped ? .maxYEdge : .minYEdge).remainder
        guard !usable.contains(CGPoint(x: usable.midX, y: caret.midY)) else { return }
        scrollToVisible(caret.insetBy(dx: 0, dy: -composer))
    }
}
