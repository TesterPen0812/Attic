import AppKit
import SwiftUI

#if DEBUG
/// Capture seam for the task's-note fixes (Phase 3 0b round 2a): with
/// `ATTIC_UI_TESTING=1`, in a preview identity only, `ATTIC_UI_TEST_TASK_NOTE_SCRIPT`
/// drives the open page from inside the app with posted key events (never
/// AppleScript, never another app) and writes what happened to
/// `tmp/tasknote-script.log` in the app's container. Steps are spaced so a
/// `screencapture` from outside can photograph each state.
@MainActor
enum TaskNoteCaptureScript {
    static func runIfRequested(_ presenter: TaskNotePresenter) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1",
              AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier),
              let script = environment["ATTIC_UI_TEST_TASK_NOTE_SCRIPT"] else { return }
        let steps: [(Double, () -> Void)]
        let model = presenter.model, host = presenter.host
        switch script {
        case "tab":
            // Add subtask has the keyboard; Tab; type.
            steps = [(2.0, { model.requestFocus(.add) }),
                     (1.0, { post("\t", keyCode: 48) }),
                     (0.8, { type("Typed after Tab ") }),
                     (0.8, { log("tab", host) })]
        case "find":
            steps = [(2.0, { model.focusWriting(atTop: true) }),
                     (0.6, { post("f", keyCode: 3, flags: .command) }),
                     (0.8, { type("Line 40") }),
                     (0.6, { post("\r", keyCode: 36) }),
                     (0.6, { post("g", keyCode: 5, flags: .command) }),
                     (0.8, { log("find bar visible=\(host.scrollView.isFindBarVisible)", host) })]
        case "reorder":
            steps = [(2.0, { model.newSubtaskText = "CU order row"; _ = model.commitNewSubtask() }),
                     (0.6, {
                         if let write = model.rows.first(where: { $0.title == "Write release notes" }) { model.toggle(write.id) }
                     }),
                     (0.6, {
                         model.releaseHold()
                         model.focusedRowID = model.rows.first(where: \.isDone)?.id
                         model.requestFocus(.list)
                     }),
                     (0.6, { post(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, flags: .command) }),
                     (0.8, { log("reorder failure=\(model.failure?.message ?? "none") rows=\(model.rows.map(\.title))", host) })]
        case "ax":
            steps = [(2.0, {
                         model.focusedRowID = model.rows.last?.id
                         model.requestFocus(.list)
                     }),
                     (0.6, { post(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126) }),
                     (0.8, { log("ax focused=\(focusedElements(in: host.blockView))", host) })]
        case "fold":
            steps = [(2.5, { withAnimationIfAllowed { model.setFolded(true) } }),
                     (1.5, { withAnimationIfAllowed { model.setFolded(false) } }),
                     (1.5, { withAnimationIfAllowed { model.setFolded(true) } }),
                     (1.0, { log("fold done", host) })]
        default:
            steps = []
        }
        var delay = 0.0
        for (gap, step) in steps {
            delay += gap
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { step() }
        }
    }

    private static func withAnimationIfAllowed(_ body: () -> Void) {
        withAnimation(AtticMotionPreset.expand.animation(reduceMotion: false)) { body() }
    }

    private static func post(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func type(_ text: String) {
        for character in text { post(String(character), keyCode: 0) }
    }

    private static func focusedElements(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 14, let object = element as? NSAccessibilityProtocol else { return }
            if (element as AnyObject).responds(to: #selector(NSAccessibilityProtocol.isAccessibilityFocused)),
               object.isAccessibilityFocused() {
                let label = (element as AnyObject).responds(to: #selector(NSAccessibilityProtocol.accessibilityLabel))
                    ? object.accessibilityLabel() : nil
                found.append(label ?? String(describing: Swift.type(of: element)))
            }
            let children = (element as AnyObject).responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren))
                ? object.accessibilityChildren() ?? [] : []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return found
    }

    private static func log(_ line: String, _ host: TaskNoteComposedHost) {
        let responder = host.textView.window?.firstResponder
        let text = String(host.engine.textStorage.string.prefix(40))
        let entry = "\(Date()) \(line) firstResponder=\(responder.map { "\(Swift.type(of: $0))" } ?? "nil") writingFirst=\(responder === host.textView) text=\(text.debugDescription)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tasknote-script.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
        NSLog("TASKNOTE-SCRIPT %@", entry)
    }
}
#endif
