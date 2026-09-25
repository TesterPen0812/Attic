import AppKit
import SwiftUI

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
    /// ⌘Z when the field has no typing left to undo: the page's own undo.
    let undoFallback: () -> Void
    /// ⇧⌘Z when the field has no typing left to redo.
    let redoFallback: () -> Void
    /// An edit replaced `range` (UTF-16) with `replacement`, so the owner
    /// can move the ranges it remembers.
    let edited: (_ range: NSRange, _ replacement: String) -> Void
    /// Where the insertion point is (UTF-16), for "a chip forms once its
    /// word is finished".
    let caretMoved: (Int) -> Void
}

/// The add bar's text: a native text view (so typing, selection, spelling,
/// dictation and VoiceOver are the system's own) that draws recognised
/// pieces (`#tag`, a date, `!`) as chips: the tag colours on a recessed
/// pill, the text itself unchanged. Backspace right after a chip turns it
/// back into text. One line: Return submits, pasted lines are offered to
/// the owner, and typed newlines never enter.
///
/// Keyboard focus follows `isFocused` both ways, so the shell's quick
/// capture can put the insertion point here.
struct AtticTokenField: NSViewRepresentable {
    @Binding var text: String
    /// Ranges (UTF-16, in `text`) drawn as chips.
    var chips: [NSRange]
    @Binding var isFocused: Bool
    var accessibilityLabel: String
    var isEnabled = true
    let actions: AtticTokenFieldActions

    @Environment(\.atticDesign) private var design

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AtticTokenFieldView {
        let view = AtticTokenFieldView()
        view.textView.delegate = context.coordinator
        view.textView.owner = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: AtticTokenFieldView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let tokens = design.tokens
        view.apply(style: AtticTokenFieldView.Style(
            font: AtticTextStyle.body.nsFont,
            text: NSColor(tokens.color(isEnabled ? .body : .disabledText)),
            chipText: NSColor(tokens.color(.accentText)),
            chipFill: NSColor(tokens.tagFill.color),
            caret: NSColor(tokens.color(.heading))
        ))
        view.textView.isEditable = isEnabled
        view.textView.setAccessibilityLabel(accessibilityLabel)
        if view.textView.string != text {
            coordinator.isApplyingModel = true
            view.textView.string = text
            view.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.isApplyingModel = false
        }
        view.setChips(chips)
        // Focus follows the binding: the shell's quick capture sets it.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            let hasFocus = window.firstResponder === view.textView
            if isFocused, !hasFocus, isEnabled {
                window.makeFirstResponder(view.textView)
            } else if !isFocused, hasFocus {
                window.makeFirstResponder(nil)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AtticTokenField
        weak var view: AtticTokenFieldView?
        var isApplyingModel = false

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
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModel, let textView = view?.textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            parent.actions.caretMoved(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = view?.textView else { return }
            parent.actions.caretMoved(textView.selectedRange().location)
        }

        func focusChanged(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        /// Backspace with an empty selection right after a chip.
        func chipBeforeCaret(_ textView: NSTextView) -> NSRange? {
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return nil }
            return parent.chips.first { NSMaxRange($0) == selection.location }
        }
    }
}

/// The token field's AppKit view: a text view in a clip view that scrolls
/// sideways when the line is longer than the field.
final class AtticTokenFieldView: NSView {
    struct Style: Equatable {
        var font: NSFont
        var text: NSColor
        var chipText: NSColor
        var chipFill: NSColor
        var caret: NSColor
    }

    let textView: AtticTokenTextView
    private let scrollView = NSScrollView()
    private let layoutManager = AtticChipLayoutManager()
    private var style: Style?
    private var chips: [NSRange] = []

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
        textView.allowsUndo = true
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
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.focusRingType = .none
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(layoutManager.defaultLineHeight(for: style?.font ?? .systemFont(ofSize: 13))))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: style?.font ?? .systemFont(ofSize: 13)))
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
        layoutManager.chipFill = newStyle.chipFill
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func setChips(_ newChips: [NSRange]) {
        guard newChips != chips else { return }
        chips = newChips
        restyle()
    }

    /// Chips are attributes, never text: the characters stay exactly as typed.
    private func restyle() {
        guard let style, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: style.font, .foregroundColor: style.text], range: whole)
        for chip in chips where NSMaxRange(chip) <= storage.length {
            storage.addAttributes([.foregroundColor: style.chipText, .atticChip: true], range: chip)
        }
        storage.endEditing()
        textView.needsDisplay = true
    }
}

extension NSAttributedString.Key {
    /// Marks a recognised piece of add-bar text, drawn as a chip.
    static let atticChip = NSAttributedString.Key("AtticChip")
}

/// Draws a recessed pill behind every run marked `.atticChip`: the tag
/// chip's shape (18 tall, the control corner) around the text as typed.
final class AtticChipLayoutManager: NSLayoutManager {
    var chipFill: NSColor = .clear

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.atticChip, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = boundingRect(forGlyphRange: glyphs, in: container)
            let height = AtticControlSize.tagHeight
            rect.origin.x += origin.x - AtticTokenFieldMetrics.chipOutset
            rect.size.width += AtticTokenFieldMetrics.chipOutset * 2
            rect.origin.y = origin.y + rect.midY - height / 2
            rect.size.height = height
            let radius = AtticRadius.control(height: height)
            chipFill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// The text view: one line, Return submits, Backspace after a chip
/// dismisses it, a multi-line paste goes to the owner, and ⌘Z undoes
/// typing first, then the page.
final class AtticTokenTextView: NSTextView {
    weak var owner: AtticTokenField.Coordinator?

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
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if !hasMarkedText() {
                owner?.parent.actions.submit(flags.contains(.command))
                return
            }
        case 53: // Esc
            if owner?.parent.actions.escape() == true { return }
        default:
            break
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if undoManager?.canUndo == true { undoManager?.undo() } else { owner?.parent.actions.undoFallback() }
            return
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" {
            if undoManager?.canRedo == true { undoManager?.redo() } else { owner?.parent.actions.redoFallback() }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return submits and opens; it must not reach a menu first.
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if window?.firstResponder === self, flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            owner?.parent.actions.submit(true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        if let owner, let chip = owner.chipBeforeCaret(self) {
            owner.parent.actions.dismissChip(chip)
            return
        }
        super.deleteBackward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if owner?.parent.actions.escape() == true { return }
        super.cancelOperation(sender)
    }

    override func paste(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string),
           string.split(whereSeparator: \.isNewline).filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1,
           owner?.parent.actions.multilinePaste(string) == true {
            return
        }
        super.paste(sender)
    }
}

enum AtticTokenFieldMetrics {
    /// A chip reaches this far past its text on each side (into the spaces
    /// around the word, which are wider).
    static let chipOutset: CGFloat = 3
    /// The field's height inside the add bar.
    static let height: CGFloat = 20
}
