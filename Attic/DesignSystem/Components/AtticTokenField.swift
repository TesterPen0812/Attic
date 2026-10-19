import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Token field

/// What the add bar's text field reports back, beyond its text. Every
/// callback is required, so a field that is drawn is always wired.
struct AtticTokenFieldActions {
    /// Return (`command` false) or ⌘Return (`command` true).
    let submit: (_ command: Bool) -> Void
    /// Backspace right after a chip: the chip turns back into plain text
    /// (nothing is deleted); the owner stops recognising that range.
    let dismissChip: (NSRange) -> Void
    /// A paste with more than one line. Return true when the owner takes it
    /// (the add bar offers "Add N tasks" or "Add as one task"); false pastes
    /// it as one line.
    let multilinePaste: (String) -> Bool
    /// Esc. Return true when the owner used it (clearing an offer, leaving
    /// the field); false lets it continue to the panel.
    let escape: () -> Bool
    /// An edit replaced `range` (UTF-16) with `replacement`, so the owner
    /// can move the ranges it remembers.
    let edited: (_ range: NSRange, _ replacement: String) -> Void
    /// Where the insertion point is (UTF-16), for "a chip forms once its
    /// word is finished".
    let caretMoved: (Int) -> Void
    /// A key while a suggestion list is showing (owner fix 5 B, review 15):
    /// ↑ ↓ move the highlight, Tab or Return take it (and keep editing),
    /// Esc hides the list. Return true when the list used the key. Marked
    /// text (an input method composing) always keeps its keys.
    var suggestionKey: ((AtticSuggestionKey) -> Bool)? = nil
    /// The draft's own undo (round 4): the owner steps its history back
    /// (text and pieces together) and returns the text and insertion point
    /// to show, or nil when the draft has nothing to undo (then ⌘Z reaches
    /// `undoFallback`: spec § Undo, "while typing … it undoes typing
    /// first", then the place being worked in). The field keeps no undo of
    /// its own: nothing it registers can outlive it in a window's undo
    /// manager.
    var undoDraft: (() -> (text: String, selection: NSRange)?)? = nil
    var redoDraft: (() -> (text: String, selection: NSRange)?)? = nil
    /// The whole selection (UTF-16) whenever it changes, so the owner's
    /// draft history can select replaced text again on undo.
    var selectionMoved: ((NSRange) -> Void)? = nil
    /// ⌘Z (⇧⌘Z) once the draft has nothing left to undo (redo): the page's
    /// history. Only undo reaches past a field; no other page or row
    /// command answers a key the field has (round 5).
    var undoFallback: () -> Void = {}
    var redoFallback: () -> Void = {}
    /// A paste of files or an image (O17-06, `AtticPastedFiles`): return
    /// true when the owner takes them (the add bar keeps them for the new
    /// task); nil or false pastes as usual.
    var pasteFiles: (([NSItemProvider]) -> Bool)? = nil
    /// Files dragged over the field (true) or away (false), when it takes
    /// them (`pasteFiles`): the owner shows where they will land.
    var fileDragTargeted: ((Bool) -> Void)? = nil
}

/// A recognised piece of typed text (`#tag`, a date, `!`, `!!`) and how it
/// is drawn (owner item 15, option H of v21): no pill; the piece in the
/// secondary ink, `!!` in High's orange, and a date with its calendar icon
/// drawn before it as decoration (never a character in the text).
struct AtticTokenChip: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A tag or `!`: the secondary ink.
        case piece
        /// A date: the secondary ink, with its calendar icon.
        case date
        /// `!!`: High's orange.
        case high
    }

    var range: NSRange
    var kind: Kind = .piece
}

/// The keys a suggestion list answers while the field has the keyboard.
enum AtticSuggestionKey: Equatable {
    case up, down, accept, dismiss
}

/// Edits the field's text the way typing does (review 14): through the
/// text view, so each change is one step of the field's own undo and the
/// insertion point lands after it, never by replacing the bound string
/// (which resets the selection and the typing undo).
@MainActor
final class AtticTokenFieldEditor {
    weak var textView: NSTextView?

    init() {}

    /// Replaces the edits, last first, as one undoable step; the insertion
    /// point ends after the last one. False when the field is not live.
    @discardableResult
    func replace(_ edits: [(range: NSRange, string: String)], caretAfter: Int? = nil) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let undo = textView.undoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= storage.length else { continue }
            textView.insertText(edit.string, replacementRange: edit.range)
        }
        if let caretAfter, caretAfter <= (textView.string as NSString).length {
            textView.setSelectedRange(NSRange(location: caretAfter, length: 0))
        }
        return true
    }

    /// The insertion point (UTF-16), or nil when the field is not live.
    var caret: Int? { textView?.selectedRange().location }
    var selection: NSRange? { textView?.selectedRange() }

    /// Gives the field the keyboard again (after a picker closes).
    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }
}

/// The add bar's text: a native text view (so typing, selection, spelling,
/// dictation and VoiceOver are the system's own) that draws recognised
/// pieces (`#tag`, a date, `!`) as `AtticTokenChip`s: no pill, the piece
/// in the secondary ink (`!!` in High's orange), a date with its calendar
/// icon fading in before it, the text itself unchanged. Backspace right
/// after a piece turns it back into plain words. One line: Return submits, pasted lines are offered to
/// the owner, and typed newlines never enter.
///
/// Keyboard focus follows `isFocused` both ways, so the shell's quick
/// capture can put the insertion point here.
struct AtticTokenField: NSViewRepresentable {
    @Binding var text: String
    /// The recognised pieces (UTF-16 ranges in `text`) and how each draws.
    var chips: [AtticTokenChip]
    @Binding var isFocused: Bool
    var accessibilityLabel: String
    var isEnabled = true
    let actions: AtticTokenFieldActions
    /// The text style (the add bar's body; a row title in the title editor).
    var style: AtticTextStyle = .listBody
    /// The text ink.
    var ink: AtticInk = .body
    /// The pieces' secondary ink: the add bar's placeholder grey (tuned on
    /// the bar's faces); a title being edited on its row takes the row's
    /// secondary grey.
    var pieceInk: AtticInk = .placeholder
    /// Edits made as typing (strip picks, suggestions).
    var editor: AtticTokenFieldEditor?
    /// For UI tests and automation.
    var accessibilityIdentifier = "AtticTokenField"
    /// A composer's field wraps onto more lines as the text grows (O17-05);
    /// nil keeps one line that scrolls sideways (a row's title editor).
    var growth: AtticTokenFieldGrowth? = nil

    @Environment(\.atticDesign) private var design

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AtticTokenFieldView {
        let view = AtticTokenFieldView()
        view.textView.delegate = context.coordinator
        view.textView.owner = context.coordinator
        context.coordinator.view = view
        editor?.textView = view.textView
        if let growth {
            view.wrap(minHeight: growth.minHeight, maxLines: growth.maxLines) { [weak coordinator = context.coordinator] height in
                coordinator?.heightChanged(height)
            }
        }
        return view
    }

    func updateNSView(_ view: AtticTokenFieldView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.isUpdating = true
        defer {
            // The text the owner set (a cleared draft) or a piece's room
            // can change the lines a wrapping field needs.
            view.measureWrappedHeight()
            coordinator.isUpdating = false
        }
        editor?.textView = view.textView
        let tokens = design.tokens
        view.apply(style: AtticTokenFieldView.Style(
            font: style.nsFont,
            text: NSColor(tokens.color(isEnabled ? ink : .disabledText)),
            piece: NSColor(tokens.color(isEnabled ? pieceInk : .disabledText)),
            high: NSColor(tokens.color(isEnabled ? .priorityMark : .disabledText)),
            caret: NSColor(tokens.color(.heading)),
            reduceMotion: design.reduceMotion
        ))
        view.textView.isEditable = isEnabled
        view.textView.setAccessibilityLabel(accessibilityLabel)
        view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
        if view.textView.string != text {
            coordinator.isApplyingModel = true
            // The owner replaced the text (a task was added, the bar was
            // cleared): the typing that led here is no longer undoable
            // typing, so ⌘Z reaches the page's own undo next.
            if let undoManager = view.textView.undoManager {
                undoManager.removeAllActions(withTarget: view.textView)
                if let storage = view.textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
            }
            view.textView.string = text
            view.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.isApplyingModel = false
        }
        view.setChips(chips)
        // Focus follows the binding: the shell's quick capture sets it. The
        // binding is read when the block runs, not when it was queued: a
        // click that focused the field in between wins (a stale "not
        // focused" must never take the keyboard back out of the field).
        let focusBinding = $isFocused
        let enabled = isEnabled
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            let wanted = focusBinding.wrappedValue
            let hasFocus = window.firstResponder === view.textView
            // A field of a page that is not drawn (kept built, hidden) never
            // takes the keyboard (round 12).
            if wanted, !hasFocus, enabled, !view.isHiddenOrHasHiddenAncestor {
                window.makeFirstResponder(view.textView)
            } else if !wanted, hasFocus {
                window.makeFirstResponder(nil)
            }
        }
    }

    /// The field's typing undo lives in the field (its own undo manager),
    /// so nothing it registered outlives it: a window-wide undo manager
    /// holding a torn-down field's text storage crashed on ⌘Z (the
    /// computer-use review's blocker).
    static func dismantleNSView(_ view: AtticTokenFieldView, coordinator: Coordinator) {
        view.textView.owner = nil
        view.textView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AtticTokenField
        weak var view: AtticTokenFieldView?
        var isApplyingModel = false
        /// Inside `updateNSView`: SwiftUI's update, where no state changes.
        var isUpdating = false

        init(_ parent: AtticTokenField) { self.parent = parent }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString else { return true }
            // One line: a typed or dropped newline never enters.
            if replacement.rangeOfCharacter(from: .newlines) != nil {
                let flattened = replacement.components(separatedBy: .newlines).joined(separator: " ")
                if flattened != replacement {
                    textView.insertText(flattened, replacementRange: range)
                    return false
                }
            }
            if !isApplyingModel {
                parent.actions.edited(range, replacement)
                // The selection moves before the text is reported: that
                // caret waits for `textDidChange`, which reports it with the
                // new text (round 7, R1: a caret one past the old text made
                // the word being typed look finished).
                isEditPending = true
            }
            return true
        }

        /// An edit is under way: its text is not reported yet.
        private var isEditPending = false

        func textDidChange(_ notification: Notification) {
            isEditPending = false
            // A wrapping field grows or shrinks with this keystroke, in the
            // same frame as its text (O17-05).
            view?.measureWrappedHeight()
            guard !isApplyingModel, let textView = view?.textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            reportSelection(of: textView)
        }

        /// The wrapped text needs a different height: the host's binding
        /// changes now when typing changed it, or after the layout pass
        /// that found it (a new width), never inside SwiftUI's update.
        func heightChanged(_ height: CGFloat) {
            guard let growth = parent.growth, growth.height.wrappedValue != height else { return }
            if isUpdating || view?.isInLayout == true {
                DispatchQueue.main.async { [weak self] in
                    guard let growth = self?.parent.growth, growth.height.wrappedValue != height else { return }
                    growth.height.wrappedValue = height
                }
            } else {
                growth.height.wrappedValue = height
            }
        }

        private var modelSelectionReportPending = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = view?.textView, !isEditPending else { return }
            if isApplyingModel {
                // AppKit reports the replacement's selection synchronously
                // inside updateNSView. Refresh the draft after that SwiftUI
                // update, using the final selection rather than publishing
                // back into the view that is still being updated.
                guard !modelSelectionReportPending else { return }
                modelSelectionReportPending = true
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self else { return }
                    self.modelSelectionReportPending = false
                    guard let textView, textView.delegate === self, !self.isEditPending else { return }
                    self.reportSelection(of: textView)
                }
                return
            }
            reportSelection(of: textView)
        }

        private func reportSelection(of textView: NSTextView) {
            let selection = textView.selectedRange()
            parent.actions.selectionMoved?(selection)
            parent.actions.caretMoved(selection.location)
        }

        /// Shows a state the owner's draft history returned: the text and
        /// its selection, as the model's own (no edit is reported).
        func show(_ state: (text: String, selection: NSRange), in textView: NSTextView) {
            isApplyingModel = true
            textView.string = state.text
            let length = (state.text as NSString).length
            let location = min(state.selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(state.selection.length, length - location)))
            isApplyingModel = false
            reportSelection(of: textView)
        }

        func undo(_ textView: NSTextView) {
            if let state = parent.actions.undoDraft?() { show(state, in: textView) } else { parent.actions.undoFallback() }
        }

        func redo(_ textView: NSTextView) {
            if let state = parent.actions.redoDraft?() { show(state, in: textView) } else { parent.actions.redoFallback() }
        }

        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        /// Backspace with an empty selection right after a chip.
        func chipBeforeCaret(_ textView: NSTextView) -> NSRange? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            return parent.chips.first { NSMaxRange($0.range) == selection.location }?.range
        }
    }
}

/// How a composer's token field grows (O17-05): the visible height it asks
/// its host for, from one line (`minHeight`) up to `maxLines` lines; past
/// that it scrolls inside.
struct AtticTokenFieldGrowth {
    var height: Binding<CGFloat>
    var minHeight: CGFloat
    var maxLines: Int = AtticComposerMetrics.maxLines

    /// The visible height for `lines` wrapped lines of `lineHeight` (pure,
    /// tested): one line is `minHeight`, each more adds a line.
    static func height(lines: Int, lineHeight: CGFloat, minHeight: CGFloat, maxLines: Int) -> CGFloat {
        minHeight + CGFloat(min(max(lines, 1), max(maxLines, 1)) - 1) * lineHeight
    }
}

/// The token field's AppKit view: a text view in a clip view that scrolls
/// sideways when the line is longer than the field, or (a composer's,
/// `wrap`) wraps onto more lines and scrolls down past its last one.
final class AtticTokenFieldView: NSView {
    struct Style: Equatable {
        var font: NSFont
        var text: NSColor
        /// A piece's secondary ink.
        var piece: NSColor
        /// `!!`: High's orange.
        var high: NSColor
        var caret: NSColor
        var reduceMotion = false
    }

    let textView: AtticTokenTextView
    private let scrollView = NSScrollView()
    private let clip = AtticLineClipView()
    private let layoutManager = AtticChipLayoutManager()
    private var style: Style?
    private var chips: [AtticTokenChip] = []
    /// Each date's icon, 0 (just recognised) to 1 (shown), by the date's
    /// order among the dates: the icon fades in and its room opens with it,
    /// so the words after it move gently (owner item 15).
    private var iconProgress: [CGFloat] = []
    private var fadeTimer: Timer?
    private var fadeStart: Date?
    private var fadeFrom: [CGFloat] = []
    /// Wrapping (a composer's field): its one-line height, its most lines,
    /// and who hears the height it needs.
    private var wrapping: (minHeight: CGFloat, maxLines: Int, changed: (CGFloat) -> Void)?
    private var measuredHeight: CGFloat?
    private(set) var isInLayout = false

    override init(frame: NSRect) {
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        textView = AtticTokenTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)
        textView.isRichText = false
        textView.importsGraphics = false
        // Undo is the owner's draft history (`AtticTokenFieldActions.undoDraft`):
        // the text view registers nothing with any undo manager.
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.focusRingType = .none
        textView.setAccessibilityRole(.textField)
        textView.setAccessibilityIdentifier("AtticTokenField")
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.contentView = clip
        // After the clip view is in place: `drawsBackground` is the clip
        // view's own, and a new NSClipView draws the control background (a
        // white bar behind the text, faint over glass at rest and bright
        // white under a hide animation's transform or snapshot).
        clip.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.focusRingType = .none
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.defaultLineHeight(for: style?.font ?? .systemFont(ofSize: 13))))
    }

    private var lineHeight: CGFloat {
        ceil(layoutManager.defaultLineHeight(for: style?.font ?? .systemFont(ofSize: 13)))
    }

    /// The clip the text scrolls in (tests).
    var textClip: NSClipView { clip }

    /// Makes the field wrap (O17-05): the text breaks at the field's width
    /// and the field asks for one more line each time it does.
    func wrap(minHeight: CGFloat, maxLines: Int, changed: @escaping (CGFloat) -> Void) {
        wrapping = (minHeight, maxLines, changed)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scrollView.verticalScrollElasticity = .none
        needsLayout = true
    }

    /// Lays the text out at the field's width and tells the host when the
    /// height it needs changed. One layout of what typing already lays out.
    func measureWrappedHeight() {
        guard let wrapping, bounds.width > 0, let container = textView.textContainer else { return }
        if abs(container.size.width - bounds.width) > 0.5 {
            container.size = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let lines = max(1, Int((used / lineHeight - 0.01).rounded(.up)))
        let height = AtticTokenFieldGrowth.height(lines: lines, lineHeight: lineHeight,
                                                  minHeight: wrapping.minHeight, maxLines: wrapping.maxLines)
        guard height != measuredHeight else { return }
        measuredHeight = height
        wrapping.changed(height)
    }

    /// The lines the text takes at the field's width (tests).
    var wrappedLineCount: Int {
        guard let container = textView.textContainer else { return 1 }
        layoutManager.ensureLayout(for: container)
        return max(1, Int((layoutManager.usedRect(for: container).height / lineHeight - 0.01).rounded(.up)))
    }

    override func layout() {
        isInLayout = true
        defer { isInLayout = false }
        super.layout()
        let lineHeight = lineHeight
        if let wrapping {
            // The text keeps the one-line field's top and bottom room, as
            // room around the clip, not inside the text (V-12): the clip
            // is whole lines tall at the most lines and scrolls by whole
            // lines, so no line is ever cut and no sliver of the line
            // above shows. It keeps the insertion point in view while the
            // field is shorter than its text (past the last line, or
            // growing).
            let pad = max(0, (wrapping.minHeight - lineHeight) / 2)
            scrollView.frame = bounds.insetBy(dx: 0, dy: pad)
            clip.lineHeight = lineHeight
            let visible = scrollView.frame.height
            textView.textContainerInset = .zero
            textView.minSize = NSSize(width: bounds.width, height: visible)
            textView.maxSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = bounds.width
            measureWrappedHeight()
            if let container = textView.textContainer {
                let content = layoutManager.usedRect(for: container).height
                textView.frame.size.height = max(visible, ceil(content))
            }
            if textView.frame.height <= visible + 0.5 {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scrollRangeToVisible(textView.selectedRange())
            }
            return
        }
        scrollView.frame = bounds
        clip.lineHeight = nil
        let top = max(0, (bounds.height - lineHeight) / 2)
        textView.textContainerInset = NSSize(width: 0, height: top)
        textView.minSize = NSSize(width: bounds.width, height: bounds.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height)
        textView.frame.size.height = bounds.height
        if textView.frame.width < bounds.width { textView.frame.size.width = bounds.width }
    }

    func apply(style newStyle: Style) {
        guard style != newStyle else { return }
        style = newStyle
        textView.font = newStyle.font
        textView.insertionPointColor = newStyle.caret
        textView.typingAttributes = [.font: newStyle.font, .foregroundColor: newStyle.text]
        layoutManager.iconColor = newStyle.piece
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func setChips(_ newChips: [AtticTokenChip]) {
        guard newChips != chips else { return }
        let oldDates = chips.filter { $0.kind == .date }.map(\.range)
        let newDates = newChips.filter { $0.kind == .date }.map(\.range)
        chips = newChips
        // A date already shown keeps its icon (moved along by typing
        // before it); a new one starts from nothing and fades in.
        let carried: [CGFloat] = newDates.enumerated().map { index, range in
            if oldDates.count == newDates.count, iconProgress.indices.contains(index) { return iconProgress[index] }
            if let old = oldDates.firstIndex(of: range), iconProgress.indices.contains(old) { return iconProgress[old] }
            return 0
        }
        iconProgress = carried
        if style?.reduceMotion == true || AtticMotionPreference.reducesMotion {
            iconProgress = iconProgress.map { _ in 1 }
        }
        restyle()
        if iconProgress.contains(where: { $0 < 1 }) { startFade() }
    }

    /// The icon's fade and its room opening, together (the popover's short
    /// motion), ticking at the display's pace until every icon is shown.
    private func startFade() {
        fadeFrom = iconProgress
        fadeStart = Date()
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeTick() {
        guard let fadeStart else { stopFade(); return }
        let t = min(1, Date().timeIntervalSince(fadeStart) / AtticTokenFieldMetrics.iconFade)
        // Ease out: the room opens quickly, then settles.
        let eased = CGFloat(1 - pow(1 - t, 3))
        iconProgress = zip(fadeFrom, iconProgress).map { from, _ in from + (1 - from) * eased }
        if fadeFrom.count != iconProgress.count { iconProgress = iconProgress.map { _ in CGFloat(eased) } }
        restyle()
        if t >= 1 { stopFade() }
    }

    private func stopFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fadeStart = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopFade() }
    }

    /// Pieces are attributes, never text: the characters stay exactly as
    /// typed. A date's icon room is kerning on the character before it (or
    /// the line's indent at the start), so no character is added.
    private func restyle() {
        guard let style, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let room = AtticChipLayoutManager.iconRoom
        storage.beginEditing()
        storage.setAttributes([.font: style.font, .foregroundColor: style.text], range: whole)
        var dateIndex = 0
        for chip in chips where NSMaxRange(chip.range) <= storage.length && chip.range.length > 0 {
            storage.addAttributes([.foregroundColor: chip.kind == .high ? style.high : style.piece, .atticChip: true], range: chip.range)
            guard chip.kind == .date else { continue }
            let progress = iconProgress.indices.contains(dateIndex) ? iconProgress[dateIndex] : 1
            dateIndex += 1
            storage.addAttribute(.atticDateIcon, value: progress, range: NSRange(location: chip.range.location, length: 1))
            if chip.range.location > 0 {
                storage.addAttribute(.kern, value: room * progress, range: NSRange(location: chip.range.location - 1, length: 1))
            } else {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = room * progress
                storage.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            }
        }
        storage.endEditing()
        textView.needsDisplay = true
    }
}

extension NSAttributedString.Key {
    /// Marks a recognised piece of add-bar text.
    static let atticChip = NSAttributedString.Key("AtticChip")
    /// On a date's first character: its calendar icon's progress (0...1).
    static let atticDateIcon = NSAttributedString.Key("AtticDateIcon")
}

/// A wrapping composer's clip (V-12): it scrolls by whole lines, so a
/// grown field never shows half a line at its bottom or a sliver of the
/// line above at its top. Sideways (one line) it scrolls freely.
final class AtticLineClipView: NSClipView {
    var lineHeight: CGFloat?

    /// Every scroll comes here (the insertion point kept in view, a wheel,
    /// `scroll(to:)`): it lands on a whole line.
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: snapped(newOrigin))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin = snapped(rect.origin, height: rect.height)
        return rect
    }

    /// A clip resized by the bar's spring keeps its origin wherever the
    /// spring left it: it settles back on a line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let origin = snapped(bounds.origin)
        if origin != bounds.origin { super.scroll(to: origin) }
    }

    private func snapped(_ origin: NSPoint, height: CGFloat? = nil) -> NSPoint {
        guard let lineHeight, lineHeight > 0 else { return origin }
        let limit = (documentView?.frame.height ?? 0) - (height ?? bounds.height)
        return NSPoint(x: origin.x, y: AtticLineSnap.offset(origin.y, line: lineHeight, limit: limit))
    }
}

/// Whole-line scrolling for the growing composers (V-12, pure): the
/// nearest whole line, never past the last one.
@MainActor
enum AtticLineSnap {
    /// A font's line pitch as the composers lay it out (rounded up), kept
    /// for the last font asked about: drawing asks on every frame.
    private static var cached: (font: NSFont, line: CGFloat)?

    static func lineHeight(of font: NSFont) -> CGFloat {
        if let cached, cached.font == font { return cached.line }
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        cached = (font, line)
        return line
    }

    nonisolated static func offset(_ y: CGFloat, line: CGFloat, limit: CGFloat) -> CGFloat {
        guard line > 0 else { return y }
        let snapped = (y / line).rounded() * line
        let last = (max(0, limit) / line).rounded(.down) * line
        return max(0, min(snapped, last))
    }
}

/// Draws a date's calendar icon in the room kept before it (owner item 15,
/// option H): decoration, not a character, in the piece's secondary ink,
/// faded by its progress.
final class AtticChipLayoutManager: NSLayoutManager {
    var iconColor: NSColor = .secondaryLabelColor

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.atticDateIcon, in: characters) { value, range, _ in
            guard let progress = value as? CGFloat, progress > 0.01 else { return }
            let glyph = glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let rect = boundingRect(forGlyphRange: glyph, in: container)
            guard let image = icon() else { return }
            let size = image.size
            let icon = NSRect(x: origin.x + rect.minX - AtticTokenFieldMetrics.dateIconGap - size.width,
                              y: origin.y + rect.midY - size.height / 2,
                              width: size.width, height: size.height)
            image.draw(in: icon, from: .zero, operation: .sourceOver, fraction: progress, respectFlipped: true, hints: nil)
        }
    }

    private var cachedIcon: (color: NSColor, image: NSImage)?

    private func icon() -> NSImage? {
        if let cachedIcon, cachedIcon.color == iconColor { return cachedIcon.image }
        guard let image = Self.calendar(color: iconColor) else { return nil }
        cachedIcon = (iconColor, image)
        return image
    }

    /// The room a date's icon takes before it: the symbol's drawn width
    /// and its gap.
    static let iconRoom: CGFloat = ceil(calendar(color: .black)?.size.width ?? AtticTokenFieldMetrics.dateIconSize)
        + AtticTokenFieldMetrics.dateIconGap

    private static func calendar(color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: AtticTokenFieldMetrics.dateIconSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

/// The text view: one line, Return submits, Backspace after a chip
/// dismisses it, a multi-line paste goes to the owner, and ⌘Z undoes
/// typing first, then the page.
final class AtticTokenTextView: NSTextView {
    weak var owner: AtticTokenField.Coordinator?
    /// No undo manager at all (round 4): the text view can register
    /// nothing anywhere (not the window's, which outlives it); ⌘Z and the
    /// Edit menu reach the owner's draft history through `undo(_:)`.
    override var undoManager: UndoManager? { nil }

    /// O14-01: one click on a panel that is not key both makes it key and
    /// acts here (`AtticPanel.acceptsEveryFirstMouse`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        AtticPanel.acceptsEveryFirstMouse(in: window) || super.acceptsFirstMouse(for: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { owner?.focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.focusChanged(false) }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A suggestion list takes its keys first; an input method's marked
        // text takes precedence over both the list and submitting.
        if !hasMarkedText(), flags.isEmpty || flags == .shift, let answer = owner?.parent.actions.suggestionKey {
            let key: AtticSuggestionKey? = switch event.keyCode {
            case 126: .up
            case 125: .down
            case 48 where flags.isEmpty, 36 where flags.isEmpty, 76 where flags.isEmpty: .accept
            case 53: .dismiss
            default: nil
            }
            if let key, answer(key) { return }
        }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if !hasMarkedText() {
                owner?.parent.actions.submit(flags.contains(.command))
                return
            }
        case 53: // Esc: an input method composing cancels its composition first.
            if !hasMarkedText(), owner?.parent.actions.escape() == true { return }
        default:
            break
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z", !hasMarkedText() {
            owner?.undo(self)
            return
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z", !hasMarkedText() {
            owner?.redo(self)
            return
        }
        super.keyDown(with: event)
    }

    /// The Edit menu's Undo and Redo (and ⌘Z matched by the menu first)
    /// reach the field before the window: the draft's history, then the
    /// page's (round 4: the crash came through this menu path).
    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        owner?.undo(self)
    }

    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        owner?.redo(self)
    }

    /// NSTextView validates menu items in `validateMenuItem:`, which AppKit
    /// asks before `validateUserInterfaceItem:`; both enable Undo and Redo
    /// while the field has an owner (its draft history, then the page's).
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) || menuItem.action == #selector(redo(_:)) { return owner != nil }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) { return owner != nil }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return submits and opens; it must not reach a menu first.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if window?.firstResponder === self, !hasMarkedText(), flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            owner?.parent.actions.submit(true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        // Composing text deletes within the composition, never a chip.
        if !hasMarkedText(), let owner, let chip = owner.chipBeforeCaret(self) {
            owner.parent.actions.dismissChip(chip)
            return
        }
        super.deleteBackward(sender)
    }

    /// One line: Tab moves the keyboard on, as in a text field (review 15:
    /// outside a suggestion list Tab is focus navigation).
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func cancelOperation(_ sender: Any?) {
        // An input method composing owns Esc: it ends the composition and
        // nothing else.
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            return
        }
        if owner?.parent.actions.escape() == true { return }
        // NSTextView declares but does not implement cancelOperation:, so
        // `super` would raise an unrecognized selector (found by the round 4
        // marked-text test); unhandled, Esc goes up the chain to the panel.
        passUp(#selector(cancelOperation(_:)), sender)
    }

    // Files dragged onto a composer's field wait for its new task, as a
    // paste does (O17-06); a plain text view would type their paths.

    private func draggedFiles(_ sender: NSDraggingInfo) -> [NSItemProvider]? {
        guard owner?.parent.actions.pasteFiles != nil else { return nil }
        let providers = AtticPastedFiles.providers(from: sender.draggingPasteboard, filesOnly: true)
        return providers.isEmpty ? nil : providers
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedFiles(sender) != nil else { return super.draggingEntered(sender) }
        owner?.parent.actions.fileDragTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedFiles(sender) != nil else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        owner?.parent.actions.fileDragTargeted?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedFiles(sender) != nil || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let providers = draggedFiles(sender) else { return super.performDragOperation(sender) }
        owner?.parent.actions.fileDragTargeted?(false)
        return owner?.parent.actions.pasteFiles?(providers) == true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        owner?.parent.actions.fileDragTargeted?(false)
        super.concludeDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if let take = owner?.parent.actions.pasteFiles {
            let providers = AtticPastedFiles.providers(from: .general)
            if !providers.isEmpty, take(providers) { return }
        }
        if let string = NSPasteboard.general.string(forType: .string),
           string.split(whereSeparator: \.isNewline).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1,
           owner?.parent.actions.multilinePaste(string) == true {
            return
        }
        super.paste(sender)
    }
}

/// The add bar's text with its pieces, drawn by SwiftUI (captures and the
/// gallery): the same inks and calendar icon the native field draws.
struct AtticChipText: View {
    let text: String
    let chips: [AtticTokenChip]
    var disabled = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let kind = segment.kind {
                    let ink: AtticInk = disabled ? .disabledText : (kind == .high ? .priorityMark : .placeholder)
                    HStack(spacing: AtticTokenFieldMetrics.dateIconGap) {
                        if kind == .date {
                            AtticIcon(systemName: "calendar", size: AtticTokenFieldMetrics.dateIconSize, weight: .regular, ink: ink)
                                .accessibilityHidden(true)
                        }
                        AtticText(verbatim: segment.text, style: .listBody, ink: ink, allowsOverlap: true)
                    }
                } else if segment.text.allSatisfy(\.isWhitespace) {
                    // Only space: nothing to read, so nothing to check.
                    Text(verbatim: segment.text).font(AtticTextStyle.listBody.font).accessibilityHidden(true)
                } else {
                    AtticText(verbatim: segment.text, style: .listBody, ink: disabled ? .disabledText : .body, allowsOverlap: true)
                }
            }
        }
        .lineLimit(1)
    }

    private var segments: [(text: String, kind: AtticTokenChip.Kind?)] {
        let string = text as NSString
        var result: [(String, AtticTokenChip.Kind?)] = []
        var location = 0
        for chip in chips.sorted(by: { $0.range.location < $1.range.location })
        where chip.range.location >= location && NSMaxRange(chip.range) <= string.length {
            if chip.range.location > location {
                result.append((string.substring(with: NSRange(location: location, length: chip.range.location - location)), nil))
            }
            result.append((string.substring(with: chip.range), chip.kind))
            location = NSMaxRange(chip.range)
        }
        if location < string.length { result.append((string.substring(from: location), nil)) }
        return result
    }
}

enum AtticTokenFieldMetrics {
    /// The field's height inside the add bar (one line).
    static let height: CGFloat = 20
    /// A date's calendar icon (option H): the size of a details-line icon
    /// a step up for the body text, 3 pt before the date's first letter.
    static let dateIconSize: CGFloat = 11
    static let dateIconGap: CGFloat = 3
    /// The icon's fade and its room opening (the popover motion's length).
    static let iconFade: TimeInterval = 0.18
}

/// What a paste into a composer holds as files (O17-06): copied files
/// (Finder), or an image with no text beside it (a screenshot, an image
/// copied in Preview). Text, and text with an image beside it, pastes as
/// text. Read from the pasteboard given, so tests never touch the general
/// one.
enum AtticPastedFiles {
    /// `filesOnly`: a drag, where a file or an image is the whole point
    /// even with text beside it (a browser's image drag carries its URL).
    static func providers(from pasteboard: NSPasteboard, filesOnly: Bool = false) -> [NSItemProvider] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        guard filesOnly || pasteboard.string(forType: .string) == nil else { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let uti = UTType(type.rawValue) else { continue }
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: uti.identifier)
            provider.suggestedName = String(localized: "Pasted Image")
            return [provider]
        }
        return []
    }
}
