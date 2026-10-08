#if DEBUG
import AppKit

/// Capture seam for the owner's screenshots of the format controls (debug
/// builds, UI-test launches over the in-memory store only):
/// `ATTIC_UI_TESTING=1 ATTIC_UI_TEST_NOTES_SCENE=<scene>` types a sample
/// note into the new draft through the real text view and router, then
/// shows one state: `structured`, `bar`, `aa`, `slash`, `date`, `link`,
/// `context`, `formatmenu`, `notemenu`, `hint`; and, for the dropdown seam,
/// `slash-lead`, `slash-da` and `date-lead` (under the first paragraph);
/// `aacycle` opens and closes Aa's format row on a timer for recordings
/// (two slow cycles, then five quick ones, repeating).
/// Nothing here runs in a normal launch.
@MainActor
enum NoteFormatCaptureScene {
    private static var didRun = false

    static var requestedScene: String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1" else { return nil }
        return environment["ATTIC_UI_TEST_NOTES_SCENE"] ?? AtticDropdownCaptureSeam.current?.notesScene
    }

    static func runIfRequested(controls: NoteFormatControls, chrome: NotesPageChrome, textView: NoteEditorTextView) {
        guard let scene = requestedScene, !didRun else { return }
        didRun = true
        let delay = Double(ProcessInfo.processInfo.environment["ATTIC_UI_TEST_NOTES_SCENE_DELAY"] ?? "2.5") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            textView.window?.makeFirstResponder(textView)
            if scene == "hint" {
                type("Launch sync\n", into: textView)
                textView.needsDisplay = true
                return
            }
            if scene == "typography" {
                writeTypographySample(controls: controls, textView: textView)
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

    /// The owner's visible excerpt only, entered through the real editor in an isolated UI-test store.
    private static func writeTypographySample(controls: NoteFormatControls, textView: NoteEditorTextView) {
        let samples: [(String, NoteParagraphStyle)] = [
            ("CIA impact", .body),
            ("Colonial Pipeline ransomware attack", .heading(2)),
            ("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication", .body),
            ("Confidentiality", .heading(3)), ("", .body),
            ("Integrity", .heading(3)), ("Availability", .heading(3)),
            ("The clearest impact was the staff losing access to affected IT system, which led to a shutdown causing fuel transport to be interrupted", .body),
            ("Sources:", .heading(3)),
            ("@inproceedings{beerman2023review,", .mono),
            ("  title={A review of colonial pipeline ransomware attack},", .mono),
            ("  author={Beerman, Jack and Brent, David and Falter, Zach", .mono)
        ]
        for (index, sample) in samples.enumerated() {
            if index > 0 { textView.insertNewline(nil) }
            if index > 0 { controls.router.run(.paragraph(sample.1), from: .shortcut) }
            type(sample.0, into: textView)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
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
        textView.needsDisplay = true
    }

    /// Slow: open 1.6 s, closed 1.6 s, twice; then five quick open/close
    /// pairs 0.25 s apart; then again. The process opts out of App Nap
    /// while it runs: a panel app that is not frontmost has its timers
    /// coalesced, which merged a quick close with the next open.
    private static var latencyActivity: NSObjectProtocol?

    private static func cycleFormatRow(chrome: NotesPageChrome, after delay: Double) {
        if latencyActivity == nil {
            latencyActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                                    reason: "Format row recording seam")
        }
        var steps: [(Double, Bool)] = [(delay, true), (1.6, false), (1.6, true), (1.6, false)]
        steps.append((1.6, true))
        for index in 0..<9 { steps.append((0.25, index % 2 == 0 ? false : true)) }
        run(steps[...], chrome: chrome)
    }

    private static func run(_ steps: ArraySlice<(Double, Bool)>, chrome: NotesPageChrome) {
        guard let (wait, open) = steps.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { cycleFormatRow(chrome: chrome, after: 0) }
            return
        }
        let timer = Timer(timeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated {
                if open { chrome.openFormatBar(keyboard: false) } else { chrome.closeFormatBar() }
                run(steps.dropFirst(), chrome: chrome)
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func show(_ scene: String, controls: NoteFormatControls, chrome: NotesPageChrome,
                             textView: NoteEditorTextView) {
        switch scene {
        case "bar":
            textView.setSelectedRange(range(of: "most people only need the panel", in: textView))
        case "barclick":
            // A click through the event queue on the bar's Bold (the panel's
            // hit test, the bar keeping the selection and the keyboard).
            textView.setSelectedRange(range(of: "Student pricing", in: textView))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let window = textView.window else { return }
                let bar = controls.barFrame
                let m = AtticNoteFormatMetrics.self
                let style = bar.width - AtticControlSize.capsuleInset * 2 - m.barGroupGap * 3 - 8 * m.barToggleWidth
                let point = NSPoint(x: bar.minX + AtticControlSize.capsuleInset + style + m.barGroupGap + m.barToggleWidth / 2,
                                    y: bar.midY)
                let location = textView.convert(point, to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                }
            }
        case "aa":
            textView.setSelectedRange(NSRange(location: range(of: "Keep pricing", in: textView).location, length: 0))
            chrome.openFormatBar(keyboard: false)
        case "slash":
            textView.insertNewline(nil)
            textView.insertNewline(nil)
            type("/", into: textView)
        case "slash-lead", "slash-da", "date-lead":
            // The dropdown seam (`ATTIC_UI_TEST_POPOVER`): a new line under
            // the first paragraph, as in mockups p2-24 and p2-25, so the
            // list or card opens below the caret.
            let lead = range(of: "Keep pricing on one screen.", in: textView)
            guard lead.location != NSNotFound else { return }
            textView.setSelectedRange(NSRange(location: NSMaxRange(lead), length: 0))
            textView.insertNewline(nil)
            switch scene {
            case "slash-lead":
                type("/", into: textView)
            case "slash-da":
                type("/da", into: textView)
            default:
                type("Call Sam /da", into: textView)
                controls.slashModel.onPick?(.date)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { controls.cardModel.dateText = "fri" }
            }
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
        case "fadecheck":
            // A long note scrolled so text sits under the header and the
            // bottom row (round 3's no-fade-behind-glass check).
            for index in 1...30 {
                type("Line \(index): text that runs under the glass controls as the note scrolls.\n", into: textView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AtticCaptureScroll.scrollToMiddle(in: textView.enclosingScrollView)
            }
        case "library":
            chrome.captureToggleLibrary?()
        case "aacycle":
            textView.setSelectedRange(NSRange(location: range(of: "Keep pricing", in: textView).location, length: 0))
            cycleFormatRow(chrome: chrome, after: 1)
        default:
            break
        }
    }
}
#endif
