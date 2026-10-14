#if DEBUG
import AppKit

/// Capture seam for the owner's screenshots of the format controls (debug
/// builds, UI-test launches over the in-memory store only):
/// `ATTIC_UI_TESTING=1 ATTIC_UI_TEST_NOTES_SCENE=<scene>` types a sample
/// note into the new draft through the real text view and router, then
/// shows one state: `structured`, `bar`, `aa`, `slash`, `date`, `link`,
/// `context`, `formatmenu`, `notemenu`, `hint`, `aasub`, `typography` (the owner's
/// CIA note, Notes v2), `caret` (O14-10's caret tour), `codex` (R14: the owner's
/// Codex Pages test page pasted as Markdown, every block at once); and, for the dropdown seam,
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
        guard let scene = requestedScene, !scene.hasPrefix("history"), !didRun else { return }
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
            if scene == "colour" {
                writeColourSample(controls: controls, textView: textView)
                return
            }
            if scene == "focus" {
                writeFocusSample(controls: controls, textView: textView)
                return
            }
            if scene == "objects" {
                writeObjectsSample(chrome: chrome, controls: controls, textView: textView)
                return
            }
            if scene == "tables" {
                writeTablesSample(controls: controls, chrome: chrome, textView: textView)
                return
            }
            if scene == "caret" {
                writeCaretSample(controls: controls, textView: textView)
                return
            }
            if scene == "codex" {
                writeCodexTestPage(textView: textView)
                return
            }
            writeSample(controls: controls, textView: textView, rich: scene == "structured" || scene == "aasub")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                show(scene, controls: controls, chrome: chrome, textView: textView)
            }
        }
    }

    /// R14: the owner's Codex Pages test page (`mockups/px-notes-r14-sheet`),
    /// pasted as one Markdown paste through the engine (E.2), then the two
    /// highlights (Markdown has none) and the folded section.
    /// `ATTIC_UI_TEST_NOTES_SCROLL=<pt>` scrolls the note that far from its
    /// top; `ATTIC_UI_TEST_HOVER_BLOCK=<text>` shows the block handle and
    /// Copy as if the pointer were over the block holding that text.
    private static func writeCodexTestPage(textView: NoteEditorTextView) {
        guard let engine = textView.engine else { return }
        type("Formatting test page\n", into: textView)
        _ = engine.pasteMarkdown(codexTestPage, at: textView.selectedRange())
        let text = textView.string as NSString
        _ = engine.setHighlight(.grey, selection: text.range(of: "grey highlight"))
        _ = engine.setHighlight(.yellow, selection: text.range(of: "colour highlight"))
        let folded = text.range(of: "Folded section")
        if folded.location != NSNotFound { _ = engine.toggleHeadingFold(at: folded.location) }
        engine.history.reset()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let environment = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let value = environment["ATTIC_UI_TEST_NOTES_SCROLL"].flatMap(Double.init), let scrollView = textView.enclosingScrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top + CGFloat(value)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if let hovered = environment["ATTIC_UI_TEST_HOVER_BLOCK"]?.replacingOccurrences(of: "_", with: " ") {
                // As a still pointer would: placed again as layout settles
                // (the page may host the editor in a new view; far
                // fragments are estimated until laid out).
                for step in 1...8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(step)) {
                        guard let view = engine.textView else { return }
                        let location = (view.string as NSString).range(of: hovered).location
                        guard location != NSNotFound else { return }
                        view.pinsBlockHandle = false
                        view.pinsMonoCopy = false
                        view.showHoverChrome(forBlockAt: location)
                    }
                }
            }
        }
    }

    /// The page's Markdown: a `⏎` ending a line is a CommonMark hard break
    /// (a backslash before the newline).
    static let codexTestPage = codexTestPageSource.replacingOccurrences(of: "⏎\n", with: "\\\n")
    private static let codexTestPageSource = #"""
    This page exercises every format Notes supports, from headings to diagrams.

    # Headings

    Levels one through six. The note's title sits above them all.

    ## Level two heading

    ### Level three heading

    #### Levels four to six

    Body text follows every heading 6 below it.

    ## Text formatting

    This is regular paragraph text. **Bold text** emphasizes a decision, *italic text* adds emphasis, and ***bold italic text*** combines both. ~~Strikethrough text~~ marks a superseded idea. Inline code such as `launch_status = "ready"` distinguishes code from prose.

    Mix formats in one sentence: **Maya** will review *the final draft* before `17:00`, replacing ~~version one~~ with **version two**.

    A normal link: [Visit the example project website](https://example.com/project).

    A grey highlight and a colour highlight stay as the owner chose.

    Unicode examples: Café · naïve · résumé · Ελληνικά · 日本語 · العربية. Symbols and emoji: → ✓ ± £ € 🚀 🎨 🌿.

    An intentional line break for an address:⏎
    Northstar Studio⏎
    24 Example Lane⏎
    London

    ## Bulleted and nested lists

    - Research
      - Interview five sample customers
      - Group findings by theme
    - Design
      - Explore two directions
        - Review typography and spacing
    - Delivery
      - Prepare the launch assets
      - Share the final handover

    ## Numbered lists

    1. Define the project goal.
    2. Create the first prototype.
       1. Sketch the main journey.
       2. Review the empty and error states.
    3. Test with the sample team.
    4. Record the decision.

    A continued sequence:

    5. Prepare the release notes.
    6. Archive the prototype.

    ## Checklists

    - [x] Agree on the sample brief
    - [x] Create the first design draft
    - [ ] Review accessibility
    - [ ] Confirm the launch date
    - [ ] Publish the demo
      - [x] Write the introduction
      - [ ] Review the final screenshots

    ## Quotes

    > Good design makes the next step clear.
    >
    > A fictional principle from the Northstar Studio team.

    Between the quotes.

    > This longer quote demonstrates how multiple lines wrap inside a quotation. It gives the reader a distinct visual pause while keeping the text editable.

    ## Callouts

    > [!TIP]
    > 💡 **Idea:** Test a shorter onboarding flow with the sample team.
    >
    > Start with a clear welcome screen and ask for only the essential information.

    > [!WARNING]
    > ⚠️ **Demo warning:** The launch budget is a fictional example and should not be used for planning.

    > [!NOTE]
    > ✅ **Decision:** Use the blue concept for the next design review.

    > [!NOTE]
    > A callout without an icon demonstrates the plain variant.

    ## Dividers

    The paragraph above this divider closes one topic.

    ---

    The paragraph below it opens the next.

    ## Tables

    | Item | Status | Cost |
    | --- | --- | ---: |
    | Brief | ✅ Done | £1,200 |
    | Prototype | 🟡 In review | £3,450 |
    | Launch | ⏳ Planned | £900 |

    ## Code blocks

    A JavaScript example with syntax highlighting:

    ```javascript
    const projects = [
      { name: "Welcome flow", complete: true },
      { name: "Search redesign", complete: false },
    ];

    const ready = projects.filter(project => project.complete);
    console.log(`${ready.length} project ready for review`);
    ```

    A JSON data example:

    ```json
    {
      "workspace": "Northstar Studio",
      "currency": "GBP",
      "activeProjects": 4,
      "demo": true
    }
    ```

    A plain text block and a diff:

    ```
    REVIEW SUMMARY
    Owner: Maya Chen
    Status: Ready for feedback
    Next step: Review the welcome flow
    ```

    ```diff
    - Ship the long onboarding
    + Ship the short onboarding
      Keep the welcome screen
    ```

    ## Diagram preview

    ```mermaid
    flowchart LR
        A[Project brief] --> B[Design draft]
        B --> C{Review approved?}
        C -->|Yes| D[Prepare launch]
        C -->|Changes needed| B
        D --> E[Launch and learn]
    ```

    ## Folded section

    This paragraph is folded away.

    ## The end

    A folded heading shows nothing else (N-1); the next heading follows it.
    """#

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

    /// The owner's CIA note as the Notes v2 drafts show it (wording and
    /// typos kept; "Colonial…" in the Title style, the four labels
    /// Subheadings, the citation in Mono), typed through the real editor and
    /// router into the isolated UI-test store (ported from Codex, b388c15).
    private static func writeTypographySample(controls: NoteFormatControls, textView: NoteEditorTextView) {
        let samples: [(String, NoteParagraphStyle)] = [
            ("CIA impact", .body),
            ("Colonial Pipeline ransomware attack", .heading(1)),
            ("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication", .body),
            ("Confidentiality", .heading(3)), ("", .body),
            ("Integrity", .heading(3)), ("Availability", .heading(3)),
            ("The clearest impact was the staff losing access to affected IT system, which led to a shutdown causing fuel transport to be interrupted", .body),
            ("Sources:", .heading(3)),
            ("@inproceedings{beerman2023review,", .mono),
            ("  title={A review of colonial pipeline ransomware attack},", .mono),
            ("  author={Beerman, Jack and Berent, David and Falter, Zach", .mono)
        ]
        for (index, sample) in samples.enumerated() {
            if index > 0 { textView.insertNewline(nil) }
            if index > 0 { controls.router.run(.paragraph(sample.1), from: .shortcut) }
            type(sample.0, into: textView)
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        // `ATTIC_UI_TEST_NOTES_SCROLL=<pt>` scrolls the note that far from
        // its top (the Mono block in view); `ATTIC_UI_TEST_MONO_COPY=1`
        // shows the block's Copy as if the pointer were over it.
        let environment = ProcessInfo.processInfo.environment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let value = environment["ATTIC_UI_TEST_NOTES_SCROLL"].flatMap(Double.init), let scrollView = textView.enclosingScrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top + CGFloat(value)))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if environment["ATTIC_UI_TEST_MONO_COPY"] == "1", let engine = textView.engine {
                let code = (textView.string as NSString).range(of: "@inproceedings")
                if code.location != NSNotFound, let block = engine.monoBlockRange(at: code.location),
                   let rect = engine.monoBlockRect(for: block) {
                    let origin = textView.textContainerOrigin
                    textView.updateMonoCopy(at: NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y))
                    textView.pinsMonoCopy = true
                }
            }
        }
    }

    /// O14-10's measurement: "Type pay" in every line kind (title, body,
    /// the three headings, lists, checklist, quote, code, a table cell) and
    /// an empty last line (the "Type / for" hint). The caret then visits the
    /// start of each line in turn, `ATTIC_UI_TEST_CARET_DWELL` seconds
    /// (default 1.6) on each, for on-screen pixel measurement.
    private static func writeCaretSample(controls: NoteFormatControls, textView: NoteEditorTextView) {
        let engine = controls.engine
        let kinds: [NoteParagraphStyle] = [.body, .body, .heading(1), .heading(2), .heading(3), .bullet, .number,
                                           .checklist, .quote, .mono]
        for (index, kind) in kinds.enumerated() {
            if index > 0 { textView.insertNewline(nil) }
            if index > 0 { controls.router.run(.paragraph(kind), from: .shortcut) }
            type("Type pay", into: textView)
        }
        textView.insertNewline(nil)
        controls.router.run(.paragraph(.body), from: .shortcut)
        engine.insertTable(NoteTable(texts: [["Type pay", "Type pay"]]), replacing: textView.selectedRange(), name: "Insert Table", entering: false)
        controls.router.run(.paragraph(.body), from: .shortcut)
        let text = textView.string as NSString
        var starts: [Int] = []
        var search = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: "Type pay", options: [], range: search)
            guard found.location != NSNotFound else { break }
            starts.append(found.location)
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        let dwell = Double(ProcessInfo.processInfo.environment["ATTIC_UI_TEST_CARET_DWELL"] ?? "1.6") ?? 1.6
        var steps: [() -> Void] = starts.map { start in { textView.window?.makeFirstResponder(textView); textView.setSelectedRange(NSRange(location: start, length: 0)) } }
        steps.append { engine.tableViews().first?.activate(NoteTable.Position(row: 0, column: 0), caret: .start) }
        steps.append { textView.window?.makeFirstResponder(textView); textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * dwell, execute: step)
        }
    }

    /// Sheet 3's sample (Notes v2 tables): the CIA note's start, the pillars
    /// table, then "Sources:" and the citation. `ATTIC_UI_TEST_TABLE_STATE`
    /// picks the state: `rest` (default), `editing` (the caret in a cell,
    /// Aa's row in table mode) or `wide` (four columns, scrolled sideways,
    /// its indicator showing).
    private static func writeTablesSample(controls: NoteFormatControls, chrome: NotesPageChrome, textView: NoteEditorTextView) {
        let engine = controls.engine
        let state = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_TABLE_STATE"] ?? "rest"
        type("CIA impact", into: textView)
        textView.insertNewline(nil)
        controls.router.run(.paragraph(.heading(1)), from: .shortcut)
        type("Colonial Pipeline ransomware attack", into: textView)
        textView.insertNewline(nil)
        controls.router.run(.paragraph(.body), from: .shortcut)
        type("The attackers breached by compromising password fro a VPN account that did not reqiuire multi factor authentication", into: textView)
        textView.insertNewline(nil)
        // `ATTIC_UI_TEST_TABLE_RULE=1`: a `---` rule typed above the table
        // (A39: a rule spans the text column only).
        if ProcessInfo.processInfo.environment["ATTIC_UI_TEST_TABLE_RULE"] == "1" {
            type("---", into: textView)
            textView.insertNewline(nil)
            type("Below the rule", into: textView)
            textView.insertNewline(nil)
        }
        let wide = state == "wide"
        let rows: [[String]] = wide
            ? [["Pillar", "What happened", "Control that failed", "Source"],
               ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"],
               ["Integrity", "Systems encrypted by ransomware", "No MFA on the VPN account", "beerman2023review"],
               ["Availability", "Pipeline shut down", "No IT/OT separation", "beerman2023review"]]
            : [["Pillar", "What happened"], ["Confidentiality", "Data taken from the IT network"],
               ["Integrity", "Systems encrypted by ransomware"], ["Availability", "Pipeline shut down"]]
        engine.insertTable(NoteTable(texts: rows), replacing: textView.selectedRange(), name: "Insert Table", entering: false)
        controls.router.run(.paragraph(.heading(3)), from: .shortcut)
        type("Sources:", into: textView)
        textView.insertNewline(nil)
        controls.router.run(.paragraph(.mono), from: .shortcut)
        for (index, line) in ["@inproceedings{beerman2023review,", "  title={A review of colonial pipeline ransomware attack},",
                              "  author={Beerman, Jack and Berent, David and Falter, Zach"].enumerated() {
            if index > 0 { textView.insertNewline(nil) }
            type(line, into: textView)
        }
        engine.history.reset()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let table = engine.tableViews().first else { return }
            switch state {
            case "editing":
                table.activate(NoteTable.Position(row: 2, column: 1), caret: .end)
                chrome.openFormatBar(keyboard: false)
            case "wide":
                let offset = max(0, table.grid.columnX(1) + 60)
                table.setScrollOffset(offset)
            default:
                break
            }
        }
    }

    /// The colour pass sheet's note: tags in their colours, a highlight,
    /// a link, a checklist with its first box ticked, and a caution notice
    /// (a read failure) for the notice icon.
    private static func writeColourSample(controls: NoteFormatControls, textView: NoteEditorTextView) {
        let router = controls.router
        type("Launch plan #launch #pricing \n", into: textView)
        type("Pricing goes live Friday. The annual plan gets two months free; see the competitor page for reference.", into: textView)
        textView.insertNewline(nil)
        line("Before launch", .paragraph(.heading(2)), controls: controls, textView: textView)
        line("Final copy from Sam", .paragraph(.checklist), controls: controls, textView: textView)
        line("One screenshot per plan", nil, controls: controls, textView: textView)
        type("Student pricing", into: textView)
        router.run(.mark(.highlight), from: .shortcut, selection: range(of: "two months free", in: textView))
        router.run(.link("https://example.com/competitors"), from: .linkPopover, selection: range(of: "competitor page", in: textView))
        let box = range(of: "Final copy", in: textView)
        if box.location != NSNotFound { controls.engine.toggleCheckbox(atLineOf: box.location) }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        controls.engine.onNotice?(NoteNotice(kind: .notReadable, detail: String(localized: "An attachment couldn’t be read. Nothing was pasted.")))
    }

    /// The owner's first-round fixes (F-01 to F-04): every block style with a
    /// caret to look at, quote bars (one line, wrapped, two paragraphs), and
    /// a highlight beside inline code. `ATTIC_UI_TEST_CARET_AT=<text>` puts
    /// the caret at the end of the line containing that text (the last line
    /// when it is absent).
    /// A file card and an image, one of them selected (F-06b's ring):
    /// `ATTIC_UI_TEST_OBJECT=file|image` picks which.
    private static func writeObjectsSample(chrome: NotesPageChrome, controls: NoteFormatControls, textView: NoteEditorTextView) {
        type("Objects\nA file and an image below.\n", into: textView)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-capture-objects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Quarterly notes.txt")
        try? Data("Capture fixture\n".utf8).write(to: file)
        let image = folder.appendingPathComponent("Swatch.png")
        let picture = NSImage(size: NSSize(width: 480, height: 240), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 180, dy: 60)).fill()
            return true
        }
        if let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: image)
        }
        chrome.captureImport?([file, image])
        let which = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_OBJECT"] ?? "file"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let engine = controls.engine
            let length = engine.textStorage.length
            for location in 0..<length {
                guard let object = engine.object(at: location) else { continue }
                if (which == "image") == (object is NoteImageAttachment) {
                    textView.setSelectedRange(NSRange(location: location, length: 1))
                    break
                }
            }
        }
    }

    private static func writeFocusSample(controls: NoteFormatControls, textView: NoteEditorTextView) {
        let router = controls.router
        type("Focus note\n", into: textView)
        line("A highlight beside some inline code, in body text.", .paragraph(.body), controls: controls, textView: textView)
        line("A heading", .paragraph(.heading(2)), controls: controls, textView: textView)
        line("A subheading", .paragraph(.heading(3)), controls: controls, textView: textView)
        line("A short quote", .paragraph(.quote), controls: controls, textView: textView)
        line("Body text between the quotes", .paragraph(.body), controls: controls, textView: textView)
        // A quote line continues the quote; the command would toggle it off.
        line("A longer quote that wraps onto a second line so the bar follows all of its text.", .paragraph(.quote),
             controls: controls, textView: textView)
        line("The second paragraph of that quote", nil, controls: controls, textView: textView)
        line("A bullet item", .paragraph(.bullet), controls: controls, textView: textView)
        line("A checklist item", .paragraph(.checklist), controls: controls, textView: textView)
        line("let total = 1 + 2", .paragraph(.mono), controls: controls, textView: textView)
        type("A last body line", into: textView)
        router.run(.paragraph(.body), from: .shortcut)
        router.run(.mark(.highlight), from: .shortcut, selection: range(of: "highlight", in: textView))
        router.run(.mark(.code), from: .shortcut, selection: range(of: "inline code", in: textView))
        let environment = ProcessInfo.processInfo.environment
        var caret = (textView.string as NSString).length
        if let needle = environment["ATTIC_UI_TEST_CARET_AT"] {
            let found = range(of: needle, in: textView)
            if found.location != NSNotFound {
                caret = NSMaxRange((textView.string as NSString).lineRange(for: found)) - 1
            }
        }
        textView.setSelectedRange(NSRange(location: caret, length: 0))
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
        case "aastyle":
            // O14-02: Aa's row, then its style list (the menu's unfold).
            textView.setSelectedRange(NSRange(location: range(of: "Keep pricing", in: textView).location, length: 0))
            chrome.openFormatBar(keyboard: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { controls.pressRowItem(.style) }
        case "aasub":
            // A39 F11: Aa's row with the longest style name ("Subheading").
            textView.setSelectedRange(NSRange(location: range(of: "Open questions", in: textView).location, length: 0))
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
        case "notetags":
            // The note's tag editor (Attic's tag picker; ⋯ itself is native).
            chrome.presentTagEditor()
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
