import AppKit
import SwiftUI

/// Emoji & Symbols has no per-request completion or dismissal callback. Its
/// visible input client therefore lives until a pick or explicit editing intent.
@MainActor
final class NoteCalloutIconSession {
    enum State: Equatable { case active, committing, ended }
    enum Outcome: Equatable { case applied, unchanged, invalid, expired }

    let id = UUID()
    private(set) var state: State = .active
    private(set) var outcome: Outcome?
    weak var engine: NoteEditorEngine?
    weak var editor: NoteEditorTextView?
    weak var window: NSWindow?
    let noteID: UUID
    let target: NSRange
    let blockID: UUID?
    let generation: Int
    let historyGeneration: Int
    let originalSelection: NSRange
    let receiver: NoteCalloutIconInputView
    private let control = NSView()
    private let cancelButton: NSButton
    var accessibilityControls: [NSView] { [receiver, cancelButton] }
    private var ring: NSHostingView<AnyView>?
    private let storageDocument: NoteDocument
    private var observers: [NSObjectProtocol] = []

    init(engine: NoteEditorEngine, editor: NoteEditorTextView, window: NSWindow, location: Int) {
        self.engine = engine
        self.editor = editor
        self.window = window
        noteID = engine.noteID
        target = engine.blockRange(at: location)
        blockID = target.location < engine.textStorage.length
            ? engine.textStorage.attribute(.noteBlockID, at: target.location, effectiveRange: nil) as? UUID
            : engine.pendingParagraphStyle?.state.block?.id
        generation = engine.documentEditGeneration
        historyGeneration = engine.history.recordingGeneration
        originalSelection = editor.selectedRange()
        storageDocument = NoteTextCodec.document(from: engine.textStorage, template: NoteDocument(blocks: []))
        receiver = NoteCalloutIconInputView(usingTextLayoutManager: true)
        receiver.frame = NSRect(x: 28, y: 4, width: 24, height: 24)
        cancelButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!, target: nil, action: nil)
        receiver.session = self
        receiver.string = engine.paragraphStyle(at: location)?.calloutIcon ?? ""
        receiver.font = .systemFont(ofSize: 18)
        receiver.alignment = .center
        // The note already draws the current icon. Keep the receiver's own
        // value accessible without drawing a second glyph over that icon.
        receiver.textColor = .clear
        receiver.insertionPointColor = .clear
        receiver.selectedTextAttributes = [.foregroundColor: NSColor.clear, .backgroundColor: NSColor.clear]
        receiver.textContainerInset = .zero
        receiver.textContainer?.lineFragmentPadding = 0
        receiver.isRichText = false
        receiver.allowsUndo = false
        receiver.isAutomaticTextCompletionEnabled = false
        receiver.isAutomaticSpellingCorrectionEnabled = false
        receiver.drawsBackground = false
        receiver.focusRingType = .none
        receiver.setAccessibilityLabel("Callout icon")
        receiver.setAccessibilityHelp("Choose one emoji in Emoji & Symbols. Press Escape or Cancel to return to the note.")
        receiver.toolTip = "Choose one emoji. Escape or Cancel returns to the note."
        receiver.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Cancel", target: receiver, selector: #selector(NoteCalloutIconInputView.accessibilityCancelIcon))])
        let ring = NSHostingView(rootView: Self.focusRing(design: engine.style.design))
        self.ring = ring
        ring.sizingOptions = []
        ring.frame = NSRect(x: 24, y: 0, width: 32, height: 32)
        control.addSubview(ring)
        control.addSubview(receiver)
        cancelButton.frame = NSRect(x: 0, y: 6, width: 20, height: 20)
        cancelButton.isBordered = false
        cancelButton.target = receiver
        cancelButton.action = #selector(NoteCalloutIconInputView.cancelIcon)
        cancelButton.setAccessibilityLabel("Cancel")
        cancelButton.toolTip = "Cancel callout icon"
        control.addSubview(cancelButton)
        let origin = editor.calloutInputOrigin(at: target.location)
        control.frame = NSRect(x: origin.x - 24, y: origin.y, width: 56, height: 32)
    }

    private static func focusRing(design: AtticDesignContext) -> AnyView {
        AnyView(AtticFocusRing(cornerRadius: AtticRadius.control(height: 24))
            .frame(width: 24, height: 24).padding(4).environment(\.atticDesign, design))
    }

    func updateAppearance() {
        if let engine { ring?.rootView = Self.focusRing(design: engine.style.design) }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(showPalette: () -> Void) {
        guard let editor, let window else { return end(.expired, reason: "missing window") }
        editor.addSubview(control)
        observe(NSWindow.willCloseNotification, object: window) { $0.cancel(reason: "window close") }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window) { session in
            if session.window?.isVisible != true { session.cancel(reason: "window hidden") }
        }
        observe(NSTextStorage.didProcessEditingNotification, object: engine?.textStorage) { $0.validateAfterStorageEdit() }
        guard window.makeFirstResponder(receiver), window.firstResponder === receiver else {
            return end(.expired, reason: "receiver focus refused")
        }
        receiver.setSelectedRange(NSRange(location: 0, length: receiver.string.utf16.count))
        NSAccessibility.post(element: editor, notification: .layoutChanged)
        showPalette()
    }

    private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor @Sendable (NoteCalloutIconSession) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.state == .active { action(self) } }
        })
    }

    private func validateAfterStorageEdit() {
        guard let engine, isValid,
              NoteTextCodec.document(from: engine.textStorage, template: NoteDocument(blocks: [])) == storageDocument else {
            return cancel(reason: "document edit")
        }
    }

    private var isValid: Bool {
        guard state == .active, let engine, let editor, let window,
              editor.calloutIconSession === self, editor.engine === engine,
              editor.window === window, !editor.isHiddenOrHasHiddenAncestor,
              !engine.isReadOnly, engine.activity == .idle, editor.isEditable, !editor.hasMarkedText(),
              engine.noteID == noteID,
              engine.documentEditGeneration == generation,
              engine.history.recordingGeneration == historyGeneration,
              target.location <= engine.textStorage.length,
              engine.paragraphStyle(at: target.location)?.isCallout == true,
              engine.blockRange(at: target.location) == target else { return false }
        let currentID = target.location < engine.textStorage.length
            ? engine.textStorage.attribute(.noteBlockID, at: target.location, effectiveRange: nil) as? UUID
            : engine.pendingParagraphStyle?.state.block?.id
        return currentID == blockID
    }

    func receive(_ input: Any) {
        guard state == .active else { return }
        guard isValid, let engine, let editor else { return end(.expired, reason: "validation expired") }
        let text = (input as? NSAttributedString)?.string ?? (input as? String) ?? ""
        guard Self.isSingleEmoji(text), !receiver.receivedComposition, !receiver.hasMarkedText() else { return end(.invalid, reason: "invalid input", returnFocus: true) }
        guard engine.paragraphStyle(at: target.location)?.calloutIcon != text else {
            return end(.unchanged, reason: "current icon", returnFocus: true)
        }
        state = .committing
        engine.history.breakCoalescing()
        editor.setSelectedRange(originalSelection)
        let applied = engine.setCalloutIcon(text, at: target.location)
        editor.setSelectedRange(originalSelection)
        engine.history.completeSelection()
        engine.history.breakCoalescing()
        end(applied ? .applied : .expired, reason: applied ? "applied" : "commit refused", returnFocus: true)
    }

    func cancel(reason: String, returnFocus: Bool = false) {
        guard state == .active else { return }
        end(.expired, reason: reason, returnFocus: returnFocus)
    }

    private func end(_ outcome: Outcome, reason: String, returnFocus: Bool = false) {
        guard state != .ended else { return }
        state = .ended
        self.outcome = outcome
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        receiver.inputContext?.discardMarkedText()
        let ownedFocus = window?.firstResponder === receiver || window?.firstResponder === cancelButton
        if editor?.calloutIconSession === self { editor?.calloutIconSession = nil }
        if ownedFocus { window?.makeFirstResponder(nil) }
        control.removeFromSuperview()
        if returnFocus, ownedFocus, let editor, editor.window === window, !editor.isHiddenOrHasHiddenAncestor {
            editor.setSelectedRange(originalSelection)
            window?.makeFirstResponder(editor)
        }
        if let editor { NSAccessibility.post(element: editor, notification: .layoutChanged) }
    }

    /// Accepts the existing single-emoji palette input.
    static func isSingleEmoji(_ text: String) -> Bool {
        text.count == 1 && text.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C
        }
    }
}

/// Its private text system is deliberately unrelated to the note's storage.
/// No rejected, duplicate or stale delivery can fall through to note insertion.
final class NoteCalloutIconInputView: NSTextView {
    weak var session: NoteCalloutIconSession?
    private(set) var receivedComposition = false
    override func mouseDown(with event: NSEvent) { session?.editor?.mouseDown(with: event) }
    override func insertText(_ string: Any, replacementRange: NSRange) { session?.receive(string) }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // Composition stays in this private text system until its final
        // callback, which is rejected. Never hand an in-flight IME to the note.
        receivedComposition = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func paste(_ sender: Any?) { session?.receive(NSPasteboard.general.string(forType: .string) ?? "") }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    @objc func accessibilityCancelIcon() -> Bool {
        guard session?.state == .active else { return false }
        cancelIcon()
        return true
    }
    override func cancelOperation(_ sender: Any?) { cancelIcon() }
    @objc func cancelIcon() { session?.cancel(reason: "Cancel or Escape", returnFocus: true) }
    override func insertTab(_ sender: Any?) { session?.cancel(reason: "Tab", returnFocus: true) }
    override func insertBacktab(_ sender: Any?) { session?.cancel(reason: "Shift Tab", returnFocus: true) }
}
