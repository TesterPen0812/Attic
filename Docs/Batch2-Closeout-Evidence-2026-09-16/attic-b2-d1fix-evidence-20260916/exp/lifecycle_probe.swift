// Scratch: (1) does an editor that owns its undo manager deallocate after
// removal (no retain cycle through registered typing actions)? (2) does
// NSTextView's validateMenuItem consult validateUserInterfaceItem for undo:/redo:,
// including the negative case and the menu title?
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func spin(_ s: TimeInterval = 0.05) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
final class Editor: NSTextView {
    let own = UndoManager()
    let label: String
    init(label: String) { self.label = label; super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 50)) }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { label = "tc"; super.init(frame: frameRect, textContainer: container) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { print("  [deinit \(label)]") }
    override var undoManager: UndoManager? { own }
    @objc func undo(_ sender: Any?) { own.undo() }
    @objc func redo(_ sender: Any?) { own.redo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = own.undoMenuItemTitle
            return own.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = own.redoMenuItemTitle
            return own.canRedo
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
window.isReleasedWhenClosed = false
let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
window.contentView = container
let tk1 = CommandLine.arguments.contains("--tk1")
let clear = CommandLine.arguments.contains("--clear")
weak var weakEditor: Editor?
autoreleasepool {
    let editor = Editor(label: "e1")
    if tk1 { _ = editor.layoutManager }
    editor.isRichText = false
    editor.allowsUndo = true
    container.addSubview(editor)
    _ = window.makeFirstResponder(editor)
    weakEditor = editor
    let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    print("empty: validateMenuItem undo=\(editor.validateMenuItem(undoItem)) '\(undoItem.title)' redo=\(editor.validateMenuItem(redoItem)) '\(redoItem.title)'")
    editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
    spin()
    print("typed: validateMenuItem undo=\(editor.validateMenuItem(undoItem)) '\(undoItem.title)' redo=\(editor.validateMenuItem(redoItem)) '\(redoItem.title)'")
    NSApp.sendAction(Selector(("undo:")), to: editor, from: undoItem)
    spin()
    print("after undo: '\(editor.string)' validateMenuItem undo=\(editor.validateMenuItem(undoItem)) '\(undoItem.title)' redo=\(editor.validateMenuItem(redoItem)) '\(redoItem.title)'")
    NSApp.sendAction(Selector(("redo:")), to: editor, from: redoItem)
    spin()
    print("after redo: '\(editor.string)'")
    _ = window.makeFirstResponder(container)
    if clear { editor.own.removeAllActions() }
    editor.removeFromSuperview()
}
for _ in 0..<5 { autoreleasepool { spin(0.05) } }
print("tk1=\(tk1) clear=\(clear) editor alive after removal: \(weakEditor != nil)")
