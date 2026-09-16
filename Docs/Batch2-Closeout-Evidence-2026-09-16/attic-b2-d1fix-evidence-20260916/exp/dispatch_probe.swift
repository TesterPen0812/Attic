// Scratch: which undo manager does AppKit's standard undo:/redo: action use when
// the focused NSTextView supplies a private undo manager?
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func spin(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
let respondsToUndo = CommandLine.arguments.contains("--responds")
final class Editor: NSTextView, NSTextViewDelegate {
    let own = UndoManager()
    override var undoManager: UndoManager? { own }
}
final class RespondingEditor: NSTextView, NSTextViewDelegate {
    let own = UndoManager()
    override var undoManager: UndoManager? { own }
    @objc func undo(_ sender: Any?) { own.undo() }
    @objc func redo(_ sender: Any?) { own.redo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case Selector(("undo:")): return own.canUndo
        case Selector(("redo:")): return own.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
window.isReleasedWhenClosed = false
let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
window.contentView = container
let editor: NSTextView = respondsToUndo ? RespondingEditor(frame: NSRect(x: 0, y: 0, width: 200, height: 50)) : Editor(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
editor.isRichText = false
editor.allowsUndo = true
container.addSubview(editor)
print("makeFirstResponder:", window.makeFirstResponder(editor), "firstResponder is editor:", window.firstResponder === editor)
print("editor responds to undo:", editor.responds(to: Selector(("undo:"))), "window responds:", window.responds(to: Selector(("undo:"))))
print("NSResponder responds to undo: (container)", container.responds(to: Selector(("undo:"))))
editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
spin()
print("private canUndo:", editor.undoManager!.canUndo, "window UM canUndo:", window.undoManager!.canUndo)
// Seed the window UM with an unrelated action so we can tell which one runs.
var windowActionRan = false
final class Box: NSObject {}
let box = Box()
window.undoManager!.registerUndo(withTarget: box) { _ in windowActionRan = true }
window.undoManager!.setActionName("Window Thing")
spin()
let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
// Validate the way NSMenu does: find the target along the responder chain.
var r: NSResponder? = window.firstResponder
var target: NSResponder?
while let cur = r { if cur.responds(to: Selector(("undo:"))) { target = cur; break }; r = cur.nextResponder }
print("validation target:", target.map { String(describing: type(of: $0)) } ?? "nil")
if let t = target as? NSMenuItemValidation { print("validateMenuItem:", t.validateMenuItem(item), "title now:", item.title) }
else if let t = target as? NSUserInterfaceValidations { print("validateUserInterfaceItem:", t.validateUserInterfaceItem(item)) }
// Dispatch undo: along the chain from the first responder.
let handled = window.firstResponder!.tryToPerform(Selector(("undo:")), with: item)
spin()
print("tryToPerform undo: handled=\(handled) editor='\(editor.string)' windowActionRan=\(windowActionRan) privateCanUndo=\(editor.undoManager!.canUndo)")
