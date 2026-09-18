// Isolated AppKit experiment (scratch, not part of the repo).
// Question: does a fresh NSTextView that has no private undo manager inherit the
// window's undo stack, including typing actions registered by an earlier,
// already-removed text view? If so, is undo from the fresh view inert?
// Safety: activation policy .prohibited, borderless window never ordered front.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func spin(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

let usePrivateUndo = CommandLine.arguments.contains("--private")
final class Editor: NSTextView, NSTextViewDelegate {
    var label = ""
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { usePrivateUndo ? ownUndoManager : super.undoManager }
    var onDraft: ((String) -> Void)?
    deinit { print("  [deinit \(label)]") }
    func textDidChange(_ notification: Notification) {
        print("  textDidChange(\(label)) -> '\(string)'")
        onDraft?(string)
    }
}

var retained: [Editor] = []
let useTextKit1 = CommandLine.arguments.contains("--tk1")
let dropOldEditor = CommandLine.arguments.contains("--drop")
print("variant: textKit1=\(useTextKit1) dropOldEditor=\(dropOldEditor) private=\(usePrivateUndo)")

let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                      styleMask: [.borderless], backing: .buffered, defer: true)
window.isReleasedWhenClosed = false
let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
window.contentView = container

func makeEditor(_ label: String, text: String) -> Editor {
    let editor = Editor(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
    editor.label = label
    editor.delegate = editor
    editor.isRichText = false
    if useTextKit1 { _ = editor.layoutManager }
    editor.string = text
    editor.allowsUndo = true
    container.addSubview(editor)
    _ = window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    return editor
}

func describe(_ tag: String, _ manager: UndoManager?) {
    print("\(tag): canUndo=\(manager?.canUndo as Any) canRedo=\(manager?.canRedo as Any) undoTitle='\(manager?.undoMenuItemTitle ?? "-")'")
}

func plainMenuValidation(_ selectorName: String) -> String {
    let item = NSMenuItem(title: selectorName, action: Selector(selectorName), keyEquivalent: "")
    var responder: NSResponder? = window.firstResponder
    while let current = responder {
        if current.responds(to: Selector(selectorName)) {
            let valid: Bool
            if let validator = current as? NSMenuItemValidation {
                valid = validator.validateMenuItem(item)
            } else if let validator = current as? NSUserInterfaceValidations {
                valid = validator.validateUserInterfaceItem(item)
            } else {
                valid = true
            }
            return "\(selectorName) handled by \(type(of: current)) valid=\(valid)"
        }
        responder = current.nextResponder
    }
    if window.responds(to: Selector(selectorName)) {
        let valid = (window as NSMenuItemValidation).validateMenuItem(item)
        return "\(selectorName) handled by window valid=\(valid)"
    }
    return "\(selectorName) no handler"
}

print("window.undoManager is \(String(describing: window.undoManager))")

// 1. Insertion editor: type "gamma", then tear down (commit path).
weak var weakFirst: Editor?
do {
    let first = makeEditor("e1", text: "")
    weakFirst = first
    print("e1.undoManager === window.undoManager: \(first.undoManager === window.undoManager)")
    first.insertText("gam", replacementRange: NSRange(location: NSNotFound, length: 0))
    spin()
    first.breakUndoCoalescing()
    first.insertText("ma", replacementRange: NSRange(location: NSNotFound, length: 0))
    spin()
    describe("after typing in e1", first.undoManager)
    _ = window.makeFirstResponder(container)
    first.removeFromSuperview()
    spin()
    if !dropOldEditor { retained.append(first) }
}
spin(0.2)
print("e1 alive after teardown: \(weakFirst != nil)")
describe("window after e1 teardown", window.undoManager)
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))

// 2. Fresh editor on the committed object (edit entry, nothing typed yet).
let second = makeEditor("e2", text: "gamma")
var draftBumps = 0
second.onDraft = { _ in draftBumps += 1 }
if let first = weakFirst {
    first.onDraft = { _ in print("  (stale e1 onDraft fired)"); draftBumps += 1 }
}
spin()
print("e2.undoManager === window.undoManager: \(second.undoManager === window.undoManager)")
describe("fresh e2 at entry", second.undoManager)
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))

// 2b. Programmatic string assignment: does it post textDidChange?
second.string = "gamma"
spin()
print("draftBumps after programmatic string= : \(draftBumps)")
// 2c. Type in e2 and validate plain Undo against the focused editor.
second.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
spin()
describe("e2 after typing '!'", second.undoManager)
print("window UM === e2 UM: \(window.undoManager === second.undoManager)")
describe("window UM", window.undoManager)
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))
second.undoManager?.undo()
spin()
print("after undoing '!': e2='\(second.string)'")
describe("e2 after undo of '!'", second.undoManager)
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))
// 3. Route-style undo from the toolbar: guard canUndo, then undo.
if second.undoManager?.canUndo == true {
    second.undoManager?.undo()
    spin()
}
print("after 1st toolbar-style undo: e2='\(second.string)' e1='\(weakFirst?.string ?? "<deallocated>")' draftBumps=\(draftBumps)")
describe("e2 after 1st undo", second.undoManager)
if second.undoManager?.canUndo == true {
    second.undoManager?.undo()
    spin()
}
print("after 2nd toolbar-style undo: e2='\(second.string)' e1='\(weakFirst?.string ?? "<deallocated>")' draftBumps=\(draftBumps)")
describe("e2 after 2nd undo", second.undoManager)
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))

// 4. Tear e2 down without typing (cancel path); what does the canvas-level
// responder (container) see for plain Undo/Redo now?
_ = window.makeFirstResponder(container)
second.removeFromSuperview()
spin()
print("after e2 teardown, first responder = \(type(of: window.firstResponder!))")
print(plainMenuValidation("undo:"), "|", plainMenuValidation("redo:"))
describe("window after e2 teardown", window.undoManager)
print("done")
