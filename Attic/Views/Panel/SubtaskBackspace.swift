import AppKit
import SwiftUI

/// Keeps the existing SwiftUI fields and their native typing history. A
/// window-scoped monitor handles only the empty field's structural commands
/// before NSTextView consumes Backspace. Other fields and IME input pass on.
struct SubtaskBackspace: NSViewRepresentable {
    let text: () -> String
    let remove: () -> Bool
    let undo: (Bool) -> Bool
    let redo: (Bool) -> Bool
    let didEdit: () -> Void

    func makeNSView(context: Context) -> Bridge { Bridge() }
    func updateNSView(_ view: Bridge, context: Context) {
        view.text = text; view.remove = remove; view.undo = undo; view.redo = redo; view.didEdit = didEdit
    }
    static func dismantleNSView(_ view: Bridge, coordinator: Void) { view.stop() }

    final class Bridge: NSView {
        var text: () -> String = { "" }
        var remove: () -> Bool = { false }
        var undo: (Bool) -> Bool = { _ in false }
        var redo: (Bool) -> Bool = { _ in false }
        var didEdit: () -> Void = {}
        private var monitor: Any?
        private var typingObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            typingObserver = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let editor = notification.object as? NSTextView, self.owns(editor) else { return }
                    self.didEdit()
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let typingObserver { NotificationCenter.default.removeObserver(typingObserver) }
            typingObserver = nil
        }
        private func owns(_ editor: NSTextView) -> Bool {
            guard editor.window === window, window?.firstResponder === editor, editor.isEditable else { return false }
            let field = editor.convert(editor.bounds, to: nil)
            let marker = convert(bounds, to: nil)
            let overlap = field.intersection(marker)
            return !overlap.isNull && marker.width > 0 && marker.height > 0
                && overlap.width >= min(field.width, marker.width) * 0.5
                && overlap.height >= min(field.height, marker.height) * 0.5
        }
        func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, let window,
                  let editor = window.firstResponder as? NSTextView,
                  owns(editor), !editor.hasMarkedText(), editor.string == text() else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 51, modifiers.isEmpty, editor.string.isEmpty { return remove() }
            if event.keyCode == 6, modifiers == .command { return undo(editor.undoManager?.canUndo == true) }
            if event.keyCode == 6, modifiers == [.command, .shift] { return redo(editor.undoManager?.canRedo == true) }
            return false
        }
    }
}
