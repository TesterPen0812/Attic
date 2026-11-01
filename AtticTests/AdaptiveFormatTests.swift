import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Adaptive picks 2, Notes format (Accepted 2026-11-01): N1 the Style pill
/// widens into its five styles, N2 Highlight's chevron widens into its
/// colours, N3 the Link cell widens into the address field, and N7 "+"
/// stays on an open note with Aa before it. Reduce Motion is stated on (so
/// the widenings land at once) and Reduce Transparency off.
@MainActor
final class AdaptiveFormatTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var controlsList: [NoteFormatControls] = []
    private var previousEnhanced: Any?

    private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    override func setUp() async throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        previousEnhanced = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
    }

    override func tearDown() async throws {
        controlsList.forEach { $0.invalidate() }
        controlsList.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        NSApp.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        AtticMotionPreference.systemReduceMotionOverride = nil
        AtticTransparencySeam.systemOverride = nil
    }

    // MARK: Rig

    private static let sample = NoteDocument(blocks: [
        .text("Pricing page"),
        .text("Lead with the free tier: most people only need the panel."),
        .text("Before launch")
    ])

    private var design: AtticDesignContext {
        var design = AtticDesignContext.default
        design.reduceMotion = true
        return design
    }

    private func make() -> (NoteFormatControls, NoteEditorEngine, NoteEditorTextView) {
        let engine = NoteEditorEngine(noteID: UUID(), document: Self.sample, readOnly: false)
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        scrollView.automaticallyAdjustsContentInsets = false
        textView.textContainerInset = NSSize(width: 28, height: 0)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        windows.append(window)
        window.makeFirstResponder(textView)
        let controls = NoteFormatControls(engine: engine, textView: textView, scrollView: scrollView, design: design)
        controlsList.append(controls)
        scrollView.layoutSubtreeIfNeeded()
        return (controls, engine, textView)
    }

    private func spin(_ seconds: TimeInterval = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func settle(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1.5)
        while !condition(), Date() < deadline { spin() }
    }

    private func range(_ text: String, _ textView: NSTextView) -> NSRange {
        (textView.string as NSString).range(of: text)
    }

    private func elements(_ root: AnyObject) -> [AnyObject] {
        let children = (root.accessibilityChildren?() ?? nil) ?? []
        return [root] + children.flatMap { elements($0 as AnyObject) }
    }

    private func element(_ id: String, in root: AnyObject) -> AnyObject? {
        elements(root).first { ($0.accessibilityIdentifier?() ?? "") == id }
    }

    /// An element's frame in screen points (comparable between elements).
    private func frame(_ id: String, in root: AnyObject) -> CGRect? {
        guard let found = element(id, in: root), let frame = found.accessibilityFrame?(), frame.width > 0 else { return nil }
        return frame
    }

    private func press(_ id: String, in root: AnyObject, file: StaticString = #filePath, line: UInt = #line) {
        let found = element(id, in: root)
        XCTAssertNotNil(found, "\(id) is there", file: file, line: line)
        XCTAssertTrue(found?.accessibilityPerformPress?() ?? false, "\(id) presses", file: file, line: line)
    }

    private func escape(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false,
                         keyCode: 53)!
    }

    /// The selection bar's host (in the plain window, the scroll view).
    private func barHost(_ textView: NSTextView) throws -> AtticOverlayHostingView {
        let parent = try XCTUnwrap(textView.window?.contentView)
        return try XCTUnwrap(parent.subviews.compactMap { $0 as? AtticOverlayHostingView }
            .first { element("notes-format-bar", in: $0) != nil })
    }

    private func showBar(over text: String) throws -> (NoteFormatControls, NoteEditorEngine, NoteEditorTextView, AtticOverlayHostingView) {
        let (controls, engine, textView) = make()
        textView.setSelectedRange(range(text, textView))
        controls.refresh()
        settle { controls.formatModel.barShown }
        XCTAssertTrue(controls.formatModel.barShown, "the selection bar shows")
        let host = try barHost(textView)
        host.layoutSubtreeIfNeeded()
        spin(0.1)
        return (controls, engine, textView, host)
    }

    private func id(_ command: NoteFormatCommand) -> String { NoteCommandRouter.identifier(command) }

    // MARK: N1

    /// The format row at 320 pt: the pill widens from its own leading edge
    /// into Title · Heading · Subheading · Body · Mono, the lists and the
    /// indents fold away, ✕ stays; a pick, Esc or the marked style folds it
    /// back exactly.
    func testN1StylePillWidensIntoFiveStylesAndFitsA320PointRow() throws {
        let (controls, engine, textView) = make()
        let body = range("Lead with", textView)
        textView.setSelectedRange(NSRange(location: body.location + 4, length: 0))
        controls.isFormatBarOpen = true
        controls.refreshSnapshot()
        let model = controls.formatModel
        // The bottom row of a 320 pt panel: 320 less the 16 pt chrome insets.
        let rowWidth: CGFloat = 320 - 2 * 16
        // Open and settled, as the bottom row lays it out (its width given).
        let side = AtticControlSize.headerControl
        let growth = AtticFormatRowGrowth(source: CGRect(x: rowWidth - 2 * side - 12, y: 0, width: side, height: side),
                                          rowWidth: rowWidth, leading: 1, trailing: 1,
                                          sourceSymbol: NoteFormatRowSource.symbol)
        let host = NSHostingView(rootView: NoteFormatRowView(model: model, growth: growth, onClose: {}).atticDesign(design)
            .frame(width: rowWidth, height: side))
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: AtticControlSize.headerControl)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        spin(0.2)

        let pill = try XCTUnwrap(frame("notes-format-row-style", in: host), "the Style pill")
        let close = try XCTUnwrap(frame("notes-format-row-close", in: host), "✕")
        XCTAssertNotNil(element(id(.paragraph(.bullet)), in: host), "the lists show at rest")
        XCTAssertNil(element("notes-format-style-strip", in: host))

        press("notes-format-row-style", in: host)
        XCTAssertTrue(model.rowStyleListOpen)
        spin(0.2)
        host.layoutSubtreeIfNeeded()
        let names = NoteFormatModel.stripStyles.map { "notes-format-strip-" + id($0) }
        let cells = try names.map { try XCTUnwrap(frame($0, in: host), $0) }
        XCTAssertEqual(NoteFormatModel.stripStyles.map(NoteFormatStyleStrip.name), ["Title", "Heading", "Subheading", "Body", "Mono"])
        for command in [NoteFormatCommand.paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .table, .outdent, .indent] {
            XCTAssertNil(element(id(command), in: host), "\(command) folds away")
        }
        let closeOpen = try XCTUnwrap(frame("notes-format-row-close", in: host), "✕ stays")
        XCTAssertEqual(closeOpen.minX, close.minX, accuracy: 0.5, "✕ doesn't move")
        XCTAssertEqual(cells[0].minX, pill.minX, accuracy: 0.5, "the styles start where the pill did")
        let stripWidth = (cells.last?.maxX ?? 0) - cells[0].minX
        let room = close.minX - pill.minX
        print("N1 widths at 320 pt: strip \(stripWidth) pt (computed \(NoteFormatStyleStrip.width)), room beside ✕ \(room) pt, row \(rowWidth) pt; cells \(cells.map(\.width))")
        XCTAssertEqual(stripWidth, NoteFormatStyleStrip.width, accuracy: 1)
        XCTAssertLessThanOrEqual(stripWidth, room, "the five names fit beside ✕ at 320 pt")
        XCTAssertTrue(model.snapshot.value(.paragraph(.body)) == .on, "Body is the marked one")

        // A pick applies and folds back.
        press(names[0], in: host)
        XCTAssertFalse(model.rowStyleListOpen)
        XCTAssertEqual(engine.paragraphStyle(at: textView.selectedRange().location), .heading(1))
        spin(0.2)
        XCTAssertNotNil(element(id(.paragraph(.bullet)), in: host), "the lists come back")
        XCTAssertEqual(try XCTUnwrap(frame("notes-format-row-style", in: host)).minX, pill.minX, accuracy: 0.5)

        // Esc folds it back and is used up.
        press("notes-format-row-style", in: host)
        XCTAssertTrue(model.rowStyleListOpen)
        XCTAssertEqual(controls.closeInnermostOnEscape(escape(textView.window!)), true)
        XCTAssertFalse(model.rowStyleListOpen)
        XCTAssertTrue(controls.isFormatBarOpen, "Esc folds the styles, not the row")
        spin(0.2)

        // The marked style again: folds back, nothing changes.
        press("notes-format-row-style", in: host)
        spin(0.1)
        controls.refreshSnapshot()
        spin(0.1)
        press(names[0], in: host)
        XCTAssertFalse(model.rowStyleListOpen)
        XCTAssertEqual(engine.paragraphStyle(at: textView.selectedRange().location), .heading(1))
    }

    /// The keys: Space on the pill widens it with the ring on the current
    /// style, ← → move, Return picks.
    func testN1TheWidenedStylesAreOperableFromTheKeyboard() {
        let (controls, engine, textView) = make()
        let body = range("Lead with", textView)
        textView.setSelectedRange(NSRange(location: body.location, length: 0))
        controls.isFormatBarOpen = true
        controls.refreshSnapshot()
        controls.enterRowKeyboard(at: 0)
        controls.pressRowItem(.style)
        XCTAssertTrue(controls.formatModel.rowStyleListOpen)
        XCTAssertEqual(controls.formatModel.styleStripKeyboardIndex, 3, "the ring on Body, the current style")
        let window = textView.window!
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: code == 36 ? "\r" : " ", charactersIgnoringModifiers: code == 36 ? "\r" : " ",
                             isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(controls.handleKey(key(124)))
        XCTAssertEqual(controls.formatModel.styleStripKeyboardIndex, 4, "→ to Mono")
        XCTAssertTrue(controls.handleKey(key(36)))
        XCTAssertFalse(controls.formatModel.rowStyleListOpen)
        XCTAssertEqual(engine.paragraphStyle(at: textView.selectedRange().location), .mono)
        XCTAssertEqual(controls.formatModel.rowKeyboardIndex, 0, "the ring is back on the pill")
    }

    // MARK: N2

    /// The bar: the chevron widens Highlight into the six colours (20 pt
    /// cells, the app's order), B I U S fold away, the style stays put and
    /// the bar keeps its width; a colour applies and folds back;
    /// Esc and the chevron fold back too.
    func testN2HighlightWidensIntoItsColoursAndBIUSFold() throws {
        let (controls, engine, textView, host) = try showBar(over: "free tier")
        let target = textView.selectedRange()
        let model = controls.formatModel
        let style = try XCTUnwrap(frame("notes-format-bar-style", in: host))
        let link = try XCTUnwrap(frame(id(.mark(.link)), in: host))
        XCTAssertNotNil(element(id(.mark(.bold)), in: host))

        press("notes-format-highlight-colour", in: host)
        XCTAssertEqual(model.highlightPalette, .selectionBar)
        spin(0.2)
        host.layoutSubtreeIfNeeded()
        for mark in NoteCommandCatalog.barMarks { XCTAssertNil(element(id(mark), in: host), "\(mark) folds away") }
        let swatches = try NoteHighlightColour.menuOrder.map { try XCTUnwrap(frame("notes-format-highlight-\($0.rawValue)", in: host)) }
        XCTAssertEqual(NoteHighlightColour.menuOrder, [.yellow, .green, .blue, .pink, .purple, .grey])
        // Accessibility frames carry the 28 pt hit target, so cells are
        // measured centre to centre.
        for (left, right) in zip(swatches, swatches.dropFirst()) {
            XCTAssertEqual(right.midX - left.midX, NoteHighlightPalette.cellWidth, accuracy: 0.5, "20 pt cells")
        }
        XCTAssertEqual(NoteHighlightPalette.cellWidth, 20)
        XCTAssertEqual(try XCTUnwrap(frame("notes-format-bar-style", in: host)).minX, style.minX, accuracy: 0.5, "the style stays")
        let openLink = try XCTUnwrap(frame(id(.mark(.link)), in: host))
        let marksAndGap = CGFloat(NoteCommandCatalog.barMarks.count) * AtticNoteFormatMetrics.barToggleWidth
            + AtticNoteFormatMetrics.barGroupGap
        XCTAssertEqual(openLink.midX, link.midX - marksAndGap, accuracy: 0.5, "Link closes up to the style")
        XCTAssertEqual(swatches[0].midX - openLink.midX, AtticNoteFormatMetrics.barToggleWidth / 2 + NoteHighlightPalette.cellWidth / 2,
                       accuracy: 0.5, "the colours start right after Link")
        let open = try XCTUnwrap(frame("notes-format-bar", in: host))
        print("N2 widths: bar \(model.barRestWidth) pt laid out at rest, \(open.width) pt open; swatch pitch \(swatches[1].midX - swatches[0].midX)")
        XCTAssertEqual(NoteFormatBarView.paletteSlack, 4, "the colours take 4 pt less than what folds")
        XCTAssertEqual(open.width, model.barRestWidth, accuracy: 1, "the bar keeps its width")

        // A colour applies and folds back.
        press("notes-format-highlight-green", in: host)
        XCTAssertNil(model.highlightPalette)
        XCTAssertEqual(engine.highlightColour(selection: target), .green)
        spin(0.2)
        XCTAssertNotNil(element(id(.mark(.bold)), in: host), "B I U S come back")
        XCTAssertEqual(try XCTUnwrap(frame(id(.mark(.link)), in: host)).midX, link.midX, accuracy: 0.5, "Link back in its place")

        // Esc folds the colours, and the bar stays.
        textView.setSelectedRange(target)
        press("notes-format-highlight-colour", in: host)
        XCTAssertEqual(controls.closeInnermostOnEscape(escape(textView.window!)), true)
        XCTAssertNil(model.highlightPalette)
        XCTAssertTrue(model.barShown, "Esc folds the colours, not the bar")
        spin(0.2)

        // The chevron again folds them; the marked colour only folds.
        press("notes-format-highlight-colour", in: host)
        spin(0.1)
        press("notes-format-highlight-colour-fold", in: host)
        XCTAssertNil(model.highlightPalette)
        spin(0.2)
        press("notes-format-highlight-colour", in: host)
        spin(0.1)
        press("notes-format-highlight-green", in: host)
        XCTAssertEqual(engine.highlightColour(selection: target), .green, "the marked colour stays")
        XCTAssertNil(model.highlightPalette)
    }

    /// The bar's keys: ↓ on the highlighter widens it, the ring on the
    /// current colour; → and Return pick the next.
    func testN2TheColoursAreOperableFromTheKeyboard() throws {
        let (controls, engine, textView, _) = try showBar(over: "free tier")
        let target = textView.selectedRange()
        controls.enterBarKeyboard()
        let index = try XCTUnwrap(NoteFormatBarItem.all.firstIndex(of: .command(.mark(.highlight))))
        controls.formatModel.barKeyboardIndex = index
        let window = textView.window!
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(controls.handleKey(key(125)))
        XCTAssertEqual(controls.formatModel.highlightPalette, .selectionBar)
        XCTAssertEqual(controls.formatModel.paletteKeyboardIndex, 0)
        XCTAssertTrue(controls.handleKey(key(124)))
        XCTAssertTrue(controls.handleKey(key(36)))
        XCTAssertNil(controls.formatModel.highlightPalette)
        XCTAssertEqual(engine.highlightColour(selection: target), .green)
        XCTAssertEqual(controls.formatModel.barKeyboardIndex, index, "the ring is back on the highlighter")
    }

    // MARK: N3

    /// Link widens into the field in the bar (no column-wide card): the
    /// style and B I U S fold away, Highlight and Code stay where they were
    /// and the bar keeps its width. A bad address rings it and keeps it;
    /// Return applies; editing shows the address and Remove Link removes.
    func testN3LinkWidensIntoTheFieldInTheBar() throws {
        let (controls, engine, textView, host) = try showBar(over: "free tier")
        let target = textView.selectedRange()
        let model = controls.formatModel
        let highlight = try XCTUnwrap(frame(id(.mark(.highlight)), in: host))
        let code = try XCTUnwrap(frame(id(.mark(.code)), in: host))

        controls.router.run(.mark(.link), from: .selectionBar)
        XCTAssertTrue(controls.linkInBar, "the field opens in the bar")
        XCTAssertTrue(model.linkFieldOpen)
        XCTAssertEqual(controls.cardModel.card, .link(hasLink: false))
        settle { controls.cardHasKeyboard }
        XCTAssertTrue(controls.cardHasKeyboard, "the field takes the keyboard from the note")
        host.layoutSubtreeIfNeeded()
        spin(0.1)
        XCTAssertNotNil(element("notes-link-field", in: host))
        XCTAssertNil(element("notes-link-card", in: textView.window!.contentView!), "no card")
        XCTAssertNil(element("notes-format-bar-style", in: host), "the style folds away")
        for mark in NoteCommandCatalog.barMarks { XCTAssertNil(element(id(mark), in: host), "\(mark) folds away") }
        let open = try XCTUnwrap(frame("notes-format-bar", in: host))
        let field = try XCTUnwrap(frame("notes-link-bar-field", in: host))
        print("N3 widths: bar \(model.barRestWidth) pt laid out at rest, \(open.width) pt open, field \(field.width) pt")
        // The field takes exactly what folds (Highlight and Code stay put
        // below); the bar's own accessibility frame also spans its hidden
        // colours, so its width isn't read here.
        XCTAssertEqual(field.width, NoteLinkCell.fieldWidth(barWidth: model.barRestWidth), accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frame(id(.mark(.highlight)), in: host)).minX, highlight.minX, accuracy: 0.5, "Highlight stays")
        XCTAssertEqual(try XCTUnwrap(frame(id(.mark(.code)), in: host)).minX, code.minX, accuracy: 0.5, "Code stays")
        XCTAssertNil(element("notes-link-remove", in: host), "no Remove Link before there is a link, and no ×")

        controls.cardModel.linkText = "not a link"
        controls.cardModel.submitLink()
        XCTAssertNotNil(controls.cardModel.linkError, "a bad address keeps the field")
        XCTAssertTrue(controls.linkInBar)
        controls.cardModel.linkText = "example.com/pricing"
        XCTAssertNil(controls.cardModel.linkError, "typing clears the error")
        controls.cardModel.submitLink()
        XCTAssertFalse(controls.linkInBar)
        XCTAssertFalse(controls.isCardOpen)
        XCTAssertEqual(engine.document().blocks[1].marks.first { $0.kind == .link }?.url, "https://example.com/pricing")
        XCTAssertEqual(textView.selectedRange(), target, "the selection comes back")
        settle { controls.formatModel.barShown && !controls.formatModel.linkFieldOpen }
        XCTAssertTrue(controls.formatModel.barShown, "with its bar")

        // Editing shows the address; Remove Link at the field's end removes it.
        controls.router.run(.mark(.link), from: .selectionBar)
        XCTAssertEqual(controls.cardModel.card, .link(hasLink: true))
        XCTAssertEqual(controls.cardModel.linkText, "https://example.com/pricing")
        host.layoutSubtreeIfNeeded()
        spin(0.1)
        press("notes-link-remove", in: host)
        XCTAssertTrue(engine.document().blocks[1].marks.filter { $0.kind == .link }.isEmpty)
        XCTAssertFalse(controls.linkInBar)
    }

    /// Esc closes the field and gives back the bar with the same selection;
    /// a caret inside a link edits the whole link from the bar.
    func testN3EscapeRestoresTheBarAndACaretEditsTheWholeLink() throws {
        let (controls, engine, textView, _) = try showBar(over: "free tier")
        let target = textView.selectedRange()
        controls.router.run(.mark(.link), from: .selectionBar)
        XCTAssertTrue(controls.linkInBar)
        XCTAssertEqual(controls.closeInnermostOnEscape(escape(textView.window!)), true)
        XCTAssertFalse(controls.linkInBar)
        XCTAssertFalse(controls.isCardOpen)
        XCTAssertEqual(textView.selectedRange(), target)
        settle { controls.formatModel.barShown && !controls.formatModel.linkFieldOpen }
        XCTAssertTrue(controls.formatModel.barShown, "the bar is back")

        controls.router.run(.link("https://example.com"), from: .linkPopover, selection: target)
        let caret = NSRange(location: target.location + 3, length: 0)
        textView.setSelectedRange(caret)
        controls.router.run(.mark(.link), from: .shortcut)
        XCTAssertTrue(controls.linkInBar, "⇧⌘K at a caret in a link opens the field over the link")
        XCTAssertEqual(controls.cardModel.linkText, "https://example.com")
        controls.cardModel.linkText = "example.org"
        controls.cardModel.submitLink()
        let link = try XCTUnwrap(engine.document().blocks[1].marks.first { $0.kind == .link })
        XCTAssertEqual(link.url, "https://example.org")
        XCTAssertEqual(link.length, target.length, "the whole link")
        XCTAssertEqual(textView.selectedRange(), caret, "the caret comes back")
    }

    // MARK: N7

    private final class Box<T> { var value: T?; init() {} }

    /// An open note's bottom row: Back on the left, "+" on the right where
    /// All notes has it, Aa 12 pt before it. The open format row takes the
    /// whole row, "+" included, and ✕ brings both back.
    func testN7PlusStaysOnAnOpenNoteWithAaBeforeIt() throws {
        let suite = "AdaptiveFormat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        _ = try notes.createDocumentNote(id: UUID(), document: NoteDocument(blocks: [.text("Launch plan"), .text("Book the venue")]),
                                         tags: ["launch"]).get()
        let state = PanelUIState()
        let size = CGSize(width: 320, height: 560)
        state.updatePanelSize(size)
        state.loadPageContent()
        let chrome = PanelChromeInteractionState()
        let settings = AppSettings(defaults: defaults)
        let draft = NoteDraftController(noteStore: notes)
        let host = AtticPanelHostingView(
            rootView: AtticPanelView(store: store, noteStore: notes,
                                     canvasSession: CanvasSession(store: CanvasStore(container: container)),
                                     noteDraft: draft, chromeInteractionState: chrome, uiState: state,
                                     settings: settings, tasksPageState: TasksPageState()),
            panelCornerRadius: 52, dockedCorner: .topRight, chromeInteractionState: chrome)
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let panel = KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.orderFront(nil)
        defer {
            host.cancelActiveInteraction(reason: .lostWindow)
            state.releasePageContent()
            spin(0.3)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        spin(1.0)
        func local(_ id: String) -> CGRect? {
            host.layoutSubtreeIfNeeded()
            guard let screen = frame(id, in: host) else { return nil }
            return host.convert(panel.convertFromScreen(screen), from: nil)
        }
        state.selectSection(.notes)
        spin(1.0)
        XCTAssertTrue(draft.pages.showLibrary())
        spin(0.8)
        let libraryPlus = try XCTUnwrap(local("notes-new-note"), "All notes' \"+\"")
        draft.pages.dismissLibrary()
        spin(1.2)
        // Aa waits for text under the title: give the open note a line.
        func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }
        let textView = try XCTUnwrap(views(NoteEditorTextView.self, in: host).first, "the note's editor")
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        textView.insertText("Book the venue", replacementRange: NSRange(location: NSNotFound, length: 0))
        spin(1.0)
        let layout = PanelPageLayout(cornerSize: 52, panelSize: host.bounds.size)
        let back = try XCTUnwrap(local("notes-all-notes"), "Back")
        let aa = try XCTUnwrap(local("notes-format-button"), "Aa")
        let plus = try XCTUnwrap(local("notes-new-note"), "\"+\" on an open note")
        print("N7 frames at 320 pt: back \(back), Aa \(aa), plus \(plus), All notes' plus \(libraryPlus)")
        XCTAssertEqual(back.minX, layout.chromeInsets.leading, accuracy: 0.5, "Back on the left")
        XCTAssertEqual(plus.maxX, host.bounds.width - layout.chromeInsets.trailing, accuracy: 0.5, "\"+\" on the right")
        XCTAssertEqual(plus.width, AtticControlSize.headerControl, accuracy: 0.5)
        XCTAssertEqual(plus.minX, libraryPlus.minX, accuracy: 0.5, "\"+\" stays where All notes has it")
        XCTAssertEqual(plus.midY, libraryPlus.midY, accuracy: 0.5)
        XCTAssertEqual(plus.minX - aa.maxX, AtticNoteMetrics.formatButtonGap, accuracy: 0.5, "Aa just before \"+\"")
        XCTAssertEqual(aa.midY, plus.midY, accuracy: 0.5)

        press("notes-format-button", in: host)
        spin(1.0)
        let row = try XCTUnwrap(local("notes-format-row"), "the format row")
        XCTAssertEqual(row.minX, layout.chromeInsets.leading, accuracy: 0.5, "the row takes the whole row")
        XCTAssertEqual(row.maxX, host.bounds.width - layout.chromeInsets.trailing, accuracy: 0.5, "\"+\" included")
        XCTAssertNil(local("notes-new-note"), "\"+\" makes way for the row")
        XCTAssertNil(local("notes-all-notes"))

        press("notes-format-row-close", in: host)
        spin(1.0)
        let back2 = try XCTUnwrap(local("notes-new-note"), "\"+\" comes back")
        XCTAssertEqual(back2.minX, plus.minX, accuracy: 0.5)
        XCTAssertNotNil(local("notes-format-button"), "and Aa")
    }
}
