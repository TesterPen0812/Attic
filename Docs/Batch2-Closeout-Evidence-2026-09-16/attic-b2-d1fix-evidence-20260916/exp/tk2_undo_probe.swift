// Scratch: does NSTextView post NSText.didChangeNotification (delegate
// textDidChange) for undo/redo, TextKit 2 vs TextKit 1? Non-activating process.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func spin(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
final class Editor: NSTextView, NSTextViewDelegate {
    let own = UndoManager()
    override var undoManager: UndoManager? { own }
    var changes: [String] = []
    func textDidChange(_ notification: Notification) { changes.append(string) }
}
for forceTK1 in [false, true] {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    window.contentView = container
    let editor = Editor(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
    editor.delegate = editor
    editor.isRichText = false
    if forceTK1 { _ = editor.layoutManager }
    editor.string = "Keep"
    editor.allowsUndo = true
    container.addSubview(editor)
    _ = window.makeFirstResponder(editor)
    let tk2 = editor.textLayoutManager != nil
    var undoNotes = 0, redoNotes = 0, closeNotes = 0
    let center = NotificationCenter.default
    let tokens = [
        center.addObserver(forName: .NSUndoManagerDidUndoChange, object: editor.own, queue: nil) { _ in undoNotes += 1 },
        center.addObserver(forName: .NSUndoManagerDidRedoChange, object: editor.own, queue: nil) { _ in redoNotes += 1 },
        center.addObserver(forName: .NSUndoManagerDidCloseUndoGroup, object: editor.own, queue: nil) { _ in closeNotes += 1 },
    ]
    editor.setSelectedRange(NSRange(location: 4, length: 0))
    editor.insertText(" draft", replacementRange: NSRange(location: 4, length: 0))
    spin()
    let afterTyping = editor.changes.count
    editor.own.undo(); spin()
    let afterUndo = editor.changes.count
    editor.own.redo(); spin()
    let afterRedo = editor.changes.count
    print("forceTK1=\(forceTK1) textLayoutManager(TK2)=\(tk2) typing->changes=\(afterTyping) undo->+\(afterUndo - afterTyping) redo->+\(afterRedo - afterUndo) string='\(editor.string)' undoNotes=\(undoNotes) redoNotes=\(redoNotes) closeGroupNotes=\(closeNotes)")
    tokens.forEach(center.removeObserver)
}
