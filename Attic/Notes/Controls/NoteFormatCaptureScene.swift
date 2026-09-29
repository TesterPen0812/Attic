#if DEBUG
import AppKit

/// Capture seam for the owner's screenshots of the format controls (debug
/// builds, UI-test launches over the in-memory store only):
/// `ATTIC_UI_TESTING=1 ATTIC_UI_TEST_NOTES_SCENE=<scene>` types a sample
/// note into the new draft through the real text view and router, then
/// shows one state: `structured`, `bar`, `aa`, `slash`, `date`, `link`,
/// `context`, `formatmenu`, `notemenu`, `hint`. Nothing here runs in a
/// normal launch.
@MainActor
enum NoteFormatCaptureScene {
    private static var didRun = false

    static var requestedScene: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1" else { return nil }
        return environment["ATTIC_UI_TEST_NOTES_SCENE"]
    }

    static func runIfRequested(controls: NoteFormatControls, chrome: NotesPageChrome, textView: NoteEditorTextView) {
        guard let scene = requestedScene, !didRun else { return }
        didRun = true
        let delay = Double(ProcessInfo.processInfo.environment["ATTIC_UI_TEST_NOTES_SCENE_DELAY"] ?? "2.5") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            textView.window?.makeFirstResponder(textView)
            if scene == "hint" {
                type("Launch sync\n", into: textView)
                return
            }
            writeSample(controls: controls, textView: textView, rich: scene == "structured")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                show(scene, controls: controls, chrome: chrome, textView: textView)
            }
        }
    }

    private static func type(_ text: String, into textView: NoteEditorTextView) {
        for character in text {
            if character == "\n" { textView.insertNewline(nil) } else {
                textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    private static func line(_ text: String, _ command: NoteFormatCommand?, controls: NoteFormatControls,
                             textView: NoteEditorTextView) {
        type(text, into: textView)
        if let command { controls.router.run(command, from: .shortcut) }
        textView.insertNewline(nil)
    }

    private static func range(of text: String, in textView: NoteEditorTextView) -> NSRange {
        (textView.string as NSString).range(of: text)
    }

    private static func writeSample(controls: NoteFormatControls, textView: NoteEditorTextView, rich: Bool) {
        let router = controls.router
        type("Pricing page\n", into: textView)
        line("Lead with the free tier: most people only need the panel. Keep pricing on one screen.", nil,
             controls: controls, textView: textView)
        line("Before launch", .paragraph(.heading(2)), controls: controls, textView: textView)
        line("Final copy from Sam", .paragraph(.checklist), controls: controls, textView: textView)
        type("One screenshot per plan", into: textView)
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        line("Annual plan: two months free?", .paragraph(.bullet), controls: controls, textView: textView)
        type("Student pricing", into: textView)
        if rich {
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            line("Open questions", .paragraph(.heading(3)), controls: controls, textView: textView)
            line("Talk to three customers", .paragraph(.number), controls: controls, textView: textView)
            type("Draft the FAQ", into: textView)
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            line("Simple beats clever.", .paragraph(.quote), controls: controls, textView: textView)
            line("price = base * seats", .paragraph(.mono), controls: controls, textView: textView)
            type("See the competitor page for reference.", into: textView)
            let seeRange = range(of: "competitor page", in: textView)
            router.run(.link("https://example.com/pricing"), from: .linkPopover, selection: seeRange)
            router.run(.mark(.bold), from: .shortcut, selection: range(of: "free tier", in: textView))
            router.run(.mark(.highlight), from: .shortcut, selection: range(of: "one screen", in: textView))
            router.run(.mark(.italic), from: .shortcut, selection: range(of: "two months", in: textView))
            router.run(.mark(.code), from: .shortcut, selection: range(of: "FAQ", in: textView))
        }
        let box = range(of: "Final copy", in: textView)
        if box.location != NSNotFound { controls.engine.toggleCheckbox(atLineOf: box.location) }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    private static func show(_ scene: String, controls: NoteFormatControls, chrome: NotesPageChrome,
                             textView: NoteEditorTextView) {
        switch scene {
        case "bar":
            textView.setSelectedRange(range(of: "most people only need the panel", in: textView))
        case "aa":
            textView.setSelectedRange(NSRange(location: range(of: "Keep pricing", in: textView).location, length: 0))
            chrome.openFormatPopover(keyboard: false)
        case "slash":
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            type("/", into: textView)
        case "date":
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            type("Call Sam /da", into: textView)
            controls.slashModel.onPick?(.date)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.cardModel.dateText = "fri" }
        case "link":
            let target = range(of: "free tier", in: textView)
            textView.setSelectedRange(target)
            controls.router.run(.mark(.link), from: .shortcut, selection: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.cardModel.linkText = "example.com/pricing" }
        case "context":
            let target = range(of: "most people", in: textView)
            textView.setSelectedRange(target)
            guard let rect = controls.engine.rect(for: target), let window = textView.window,
                  let event = NSEvent.mouseEvent(with: .rightMouseDown, location: textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil),
                                                 modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1),
                  let menu = textView.menu(for: event) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: rect.midX, y: rect.maxY), in: textView)
        case "formatmenu":
            let target = range(of: "most people", in: textView)
            textView.setSelectedRange(target)
            let rect = controls.engine.rect(for: target) ?? .zero
            AtticNativeMenu.popUp(controls.router.formatMenuCommands(from: .noteMenu),
                                  below: NSRect(x: 24, y: rect.maxY, width: 10, height: 1), in: textView)
        case "notemenu":
            chrome.presentMenu()
        default:
            break
        }
    }
}
#endif
