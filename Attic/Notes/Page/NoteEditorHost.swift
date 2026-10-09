import AppKit
import SwiftUI

/// What the writing view's chrome shows beside the text: the header title
/// once the title has scrolled away, the note menu's open state and the tag
/// editor. Owned by the page; the text view's accessories report into it.
@MainActor
final class NotesPageChrome: ObservableObject {
    enum TagEditorAnchor: Equatable { case tags, menu }

    /// 0 while the title shows; 1 once it has passed under the header. The
    /// header title's opacity follows it 1:1 (UX plan § 7).
    @Published var headerTitleProgress: CGFloat = 0
    @Published var headerTitle = ""
    @Published var isMenuOpen = false
    /// The tag editor is open, from the tag line or from the menu button.
    @Published var tagEditor: TagEditorAnchor?

    /// Aa's format row (OD-14). Its own object, not a published value
    /// here: opening or closing it redraws the bottom row alone, never the
    /// page or the note (`NoteFormatRowSwitch`).
    let formatRow = NoteFormatRowState()
    /// ⌃Tab / ⌃⇧Tab out of the text (OD-7): the page takes the keyboard
    /// to its next (true) or previous control.
    var leaveEditor: ((_ forward: Bool) -> Void)?
    #if DEBUG
    /// The capture seam's All notes (UI-test launches only).
    var captureToggleLibrary: (() -> Void)?
    #endif
    /// The open panel for Insert › Image or File…, the `/` row (one file),
    /// or a failed object's Retry and Locate… (one file, for that object).
    enum FileRequest: Equatable {
        case insert
        /// The `/` row's request, with the session it was made in: its
        /// completion goes to that request only (review P2, `8008974`).
        case slash(NoteSlashFileTicket)
        case retry(UUID), locate(UUID)
    }
    @Published var fileRequest: FileRequest? {
        didSet { if let fileRequest { presentedFileRequest = fileRequest } }
    }
    /// What the open panel on screen was opened for. SwiftUI sets the
    /// presentation binding to false (clearing `fileRequest`) before it
    /// calls the importer's completion, so the completion reads this (CU
    /// P3-01: a `/` Image or File… pick was taken for a plain Insert and
    /// left `/image` or `/file` in the text).
    private(set) var presentedFileRequest: FileRequest?

    /// The open panel finished: what it was opened for, once.
    func takeFileRequest() -> FileRequest? {
        defer {
            presentedFileRequest = nil
            if fileRequest != nil { fileRequest = nil }
        }
        return presentedFileRequest ?? fileRequest
    }

    /// The note menu's commands for the note on screen (built by the page).
    var menuCommands: () -> [AtticMenuCommand] = { [] }
    fileprivate weak var accessories: NoteTitleAccessories?
    /// The format controls over the note on screen (bar, `/`, cards).
    fileprivate(set) weak var controls: NoteFormatControls?
    /// The images and files of the note on screen (ring, drop, menus).
    fileprivate(set) weak var objectControls: NoteObjectControls?

    init() {
        formatRow.onChange = { [weak self] open, keyboard in self?.formatRowChanged(open: open, keyboard: keyboard) }
    }

    /// Aa, ⌘T, or Return on Aa's keyboard stop: the bottom row becomes the
    /// format row. From the keyboard, its ring shows on the style at once.
    func openFormatBar(keyboard: Bool) {
        guard controls != nil else { return }
        formatRow.open(keyboard: keyboard)
    }

    func closeFormatBar() { formatRow.close() }

    private func formatRowChanged(open: Bool, keyboard: Bool) {
        controls?.isFormatBarOpen = open
        if open {
            guard keyboard else { return }
            if controls?.hasKeyboard == false { returnKeyboardToText() }
            controls?.enterRowKeyboard()
        } else {
            // ✕ or Esc: the keyboard is the text's, where the caret was.
            DispatchQueue.main.async { [weak self] in self?.focusText() }
        }
    }

    /// ⇧⌘I, the ⋯ and the header title: the note's native menu, under the
    /// ⋯ while the title shows, under the header title once it has scrolled.
    func presentMenu() {
        accessories?.presentMenu(fromHeader: headerTitleProgress >= 0.5)
    }

    /// ⋯ → Tags…: the tag editor, from the tags when there are some.
    func presentTagEditor() {
        tagEditor = (accessories?.hasTags ?? false) ? .tags : .menu
    }

    func focusText() { accessories?.focusText() }

    /// The keyboard back into the text from a bottom-row control (⌃Tab round
    /// the footer, OD-7), with the caret and selection it had. The control's
    /// `FocusState` is cleared in the same turn, and SwiftUI answers that
    /// clear on its own schedule by resigning whatever it believes has the
    /// keyboard, which left the panel as first responder when the text was
    /// focused in the same turn (P2-A12-1). So the text is focused again on
    /// display frames until it has stayed first responder through SwiftUI's
    /// update (`NotesKeyboardReturn`). The run is one ticket: a click, a
    /// caret move or typing, a note switch, the editor going away, the panel
    /// hiding, composition starting, or a later move out of the text
    /// (`cancelKeyboardReturn`) invalidates it, and it is checked before
    /// every attempt.
    func returnKeyboardToText(pacing: NotesKeyboardReturn.Pacing = .init(), clock: NotesFrameClock? = nil) {
        cancelKeyboardReturn()
        guard let accessories else { return }
        let run = NotesKeyboardReturn(target: accessories, clock: clock ?? accessories.frameClock, pacing: pacing)
        keyboardReturn = run
        // A click anywhere (another control, the text, the panel's background)
        // is the user taking the keyboard somewhere on purpose.
        returnPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak run] event in
            MainActor.assumeIsolated { run?.cancel() }
            return event
        }
        run.onEnd = { [weak self, weak run] _ in
            guard let self, let run, self.keyboardReturn === run else { return }
            self.keyboardReturn = nil
            if let monitor = self.returnPointerMonitor { NSEvent.removeMonitor(monitor) }
            self.returnPointerMonitor = nil
        }
        run.start()
    }

    /// The keyboard went somewhere else on purpose: stop restoring the text.
    func cancelKeyboardReturn() { keyboardReturn?.cancel() }

    /// The return on its way, if any (tests read how it ended).
    private(set) var keyboardReturn: NotesKeyboardReturn?
    private var returnPointerMonitor: Any?
}

/// What the keyboard return needs to know of, and do to, the text on screen.
@MainActor
protocol NotesKeyboardReturnTarget: AnyObject {
    /// The text is still the page's note and its panel is visible and key.
    var canTakeKeyboard: Bool { get }
    var textHasKeyboard: Bool { get }
    /// An input method is composing in the text.
    var textHasMarkedText: Bool { get }
    var textSelection: NSRange? { get set }
    func focusText()
}

/// Display frames for the keyboard return (a fake in tests).
@MainActor
protocol NotesFrameClock: AnyObject {
    /// Runs `block` once, on the next display frame.
    func nextFrame(_ block: @escaping @MainActor () -> Void)
    /// Disarms any outstanding frame and its fallback immediately.
    func cancel()
}

/// ⌃Tab's way back into the text (P2-A12-1, A17): focus the text and put the
/// caret back, then look at the next display frames, focusing again whenever
/// SwiftUI's late focus update takes the keyboard away, and stop once the text
/// has held it for `heldFrames` frames in a row after at least `minimumFrames`
/// (SwiftUI's update has landed by then). Bounded by frames and by time. The
/// run is cancelled, never merely out-waited, by anything that moves the
/// keyboard on purpose: it stops before any attempt if the note, the window
/// or the user's input changed since the last one.
@MainActor
final class NotesKeyboardReturn {
    struct Pacing: Equatable {
        var minimumFrames = 6
        var heldFrames = 3
        var maximumFrames = 30
        var maximumSeconds: TimeInterval = 1
    }

    enum End: Equatable {
        /// The text held the keyboard through SwiftUI's update.
        case settled
        /// Frames or time ran out (the text may still have the keyboard).
        case gaveUp
        /// The user, the note or the panel moved on.
        case cancelled
    }

    private let target: NotesKeyboardReturnTarget
    private let clock: NotesFrameClock
    private let pacing: Pacing
    private let uptime: () -> TimeInterval
    private var expected: NSRange?
    private var frames = 0
    private var held = 0
    private var startedAt: TimeInterval = 0
    private(set) var end: End?
    /// Called once, when the run ends in any way.
    var onEnd: ((End) -> Void)?
    /// How many times the run focused the text (tests).
    private(set) var focusCount = 0

    var isRunning: Bool { end == nil && started }
    private var started = false

    init(target: NotesKeyboardReturnTarget, clock: NotesFrameClock, pacing: Pacing = .init(),
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.target = target
        self.clock = clock
        self.pacing = pacing
        self.uptime = uptime
    }

    func start() {
        guard !started, end == nil else { return }
        started = true
        startedAt = uptime()
        guard allowed else { return finish(.cancelled) }
        expected = target.textSelection
        focus()
        schedule()
    }

    func cancel() { finish(.cancelled) }

    /// Still the same note, window and composition: nothing has moved the
    /// keyboard on purpose since the last check.
    private var allowed: Bool { target.canTakeKeyboard && !target.textHasMarkedText }

    private func focus() {
        focusCount += 1
        target.focusText()
        if let expected, target.textSelection != expected { target.textSelection = expected }
    }

    private func schedule() {
        clock.nextFrame { [weak self] in self?.step() }
    }

    private func step() {
        guard end == nil else { return }
        guard allowed else { return finish(.cancelled) }
        frames += 1
        if target.textHasKeyboard {
            // The text has the keyboard with the caret somewhere we did not
            // put it: the user typed or moved it, and it is theirs again.
            if let expected, let current = target.textSelection, current != expected { return finish(.cancelled) }
            held += 1
        } else {
            held = 0
            focus()
        }
        if frames >= pacing.minimumFrames, held >= pacing.heldFrames { return finish(.settled) }
        if frames >= pacing.maximumFrames || uptime() - startedAt >= pacing.maximumSeconds { return finish(.gaveUp) }
        schedule()
    }

    private func finish(_ result: End) {
        guard end == nil else { return }
        end = result
        clock.cancel()
        onEnd?(result)
        onEnd = nil
    }
}

/// One display frame at a time, from a display link while the view is on
/// screen; a short timer stands in when the panel gets no frames (hidden), so
/// a run always reaches its next check and ends by its own bound.
@MainActor
final class NotesDisplayFrameClock: NSObject, NotesFrameClock {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var fallback: Timer?
    private var pending: (@MainActor () -> Void)?
    private var generation = 0

    init(view: NSView?) { self.view = view }

    /// A frame source exists only while the return has a check pending.
    var isRunning: Bool { pending != nil || link != nil || fallback != nil }

    func nextFrame(_ block: @escaping @MainActor () -> Void) {
        cancel()
        let ticket = generation
        pending = block
        if let view, let window = view.window, window.isVisible, window.screen != nil {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        let fallback = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(ticket) }
        }
        self.fallback = fallback
        RunLoop.main.add(fallback, forMode: .common)
    }

    func cancel() {
        generation &+= 1
        pending = nil
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
    }

    @objc private func frame(_ link: CADisplayLink) { fire(generation) }

    private func fire(_ ticket: Int) {
        guard ticket == generation, let block = pending else { return }
        cancel()
        block()
    }
}

/// The two views that sit on the title's lines inside the text view: the ⋯
/// at the end of its first line and the tag line under its last. They are
/// subviews of the text view, so they scroll with the text natively; the
/// engine keeps the title's lines clear of them.
@MainActor
final class NoteTitleAccessories: NotesKeyboardReturnTarget {
    private let engine: NoteEditorEngine
    private weak var textView: NoteEditorTextView?
    private weak var scrollView: NSScrollView?
    private let chrome: NotesPageChrome
    private let menuHost: NSHostingView<AnyView>
    private let tagHost: NSHostingView<AnyView>
    /// The suggestions under a `#word` being typed in the title.
    private let suggestionHost: AtticOverlayHostingView
    /// The shown list's natural size (its widest row, its rows' height),
    /// the `#` it hangs from, and where it is (nil while hidden): it keeps
    /// its side while it shows.
    private var suggestionSize = CGSize.zero
    private var suggestionHash: Int?
    private var suggestionPlacement: AtticDropdownLayout.Placement?
    private var suggestions: [AtticTagSuggestion] = []
    /// The row ↑ ↓ are on; nil until they move (Return then takes the
    /// typed word, as Space does), or the typed word's own existing tag.
    private var highlightedSuggestion: Int?
    /// Every tag in Notes with how many notes carry it.
    var tagCounts: () -> [String: Int] = { [:] }
    /// Measures the tag line's wrapped height at the column's width.
    private let tagMeasure = NSHostingController(rootView: AnyView(EmptyView()))
    /// The measured tag line, kept until the tags or the width change (the
    /// layout pass runs on every keystroke).
    private var measuredTagLine: (tags: [String], width: CGFloat, height: CGFloat)?
    private var spokenTitle = ""
    private var boundsObserver: NSObjectProtocol?
    private var shownTags: [String] = []
    var design: AtticDesignContext { didSet { if design != oldValue { rebuild() } } }
    var headerBottom: CGFloat
    /// A never-saved, empty draft shows no ⋯.
    var isUntouched: () -> Bool
    private let tagEditor: () -> AnyView

    var hasTags: Bool { !engine.tags.isEmpty }

    /// The text has the keyboard: it is the window's first responder.
    var textHasKeyboard: Bool {
        guard let textView else { return false }
        return textView.window?.firstResponder === textView
    }

    /// The caret and selection, kept by the text while a control has the keyboard.
    var textSelection: NSRange? {
        get { textView?.selectedRange() }
        set { if let newValue { textView?.setSelectedRange(newValue) } }
    }

    /// An input method is composing in the text.
    var textHasMarkedText: Bool { textView?.hasMarkedText() ?? false }

    /// This is still the note on screen (not dismantled, not replaced) and
    /// its panel is visible and key.
    var canTakeKeyboard: Bool {
        guard chrome.accessories === self, let window = textView?.window else { return false }
        return window.isVisible && window.isKeyWindow
    }

    /// Display frames of the text's screen.
    var frameClock: NotesFrameClock { NotesDisplayFrameClock(view: textView) }

    init(engine: NoteEditorEngine, textView: NoteEditorTextView, scrollView: NSScrollView, chrome: NotesPageChrome,
         design: AtticDesignContext, headerBottom: CGFloat, isUntouched: @escaping () -> Bool,
         tagEditor: @escaping () -> AnyView) {
        self.engine = engine
        self.textView = textView
        self.scrollView = scrollView
        self.chrome = chrome
        self.design = design
        self.headerBottom = headerBottom
        self.isUntouched = isUntouched
        self.tagEditor = tagEditor
        menuHost = NSHostingView(rootView: AnyView(EmptyView()))
        tagHost = NSHostingView(rootView: AnyView(EmptyView()))
        suggestionHost = AtticOverlayHostingView(rootView: AnyView(EmptyView()))
        suggestionHost.isHidden = true
        suggestionHost.contentInset = AtticDropdownMetrics.shadowRoom
        suggestionHost.isInteractive = true
        suggestionHost.menuLabel = String(localized: "Tag suggestions")
        for host in [tagHost, menuHost, suggestionHost] {
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            AtticOverlayHierarchy.attach(host, to: textView)
        }
        textView.accessoryViews = [tagHost, menuHost, suggestionHost]
        textView.suggestionCommand = { [weak self] selector in self?.handleSuggestionKey(selector) ?? false }
        engine.onCaretChange = { [weak self] in self?.updateSuggestions() }
        chrome.accessories = self
        rebuild()
        textView.onLayout = { [weak self] in self?.layout() }
        engine.onTagsDisplayChange = { [weak self] in
            self?.rebuild()
            self?.textView?.needsLayout = true
        }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHeaderTitle()
                // Can run inside a layout pass (the clip settling).
                AtticOverlayHierarchy.layoutPass { self?.followSuggestions() }
            }
        }
    }

    func invalidate() {
        // Dismantled or replaced (a note switch): a keyboard return on its
        // way belongs to the old text.
        if chrome.accessories === self { chrome.cancelKeyboardReturn() }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        engine.onTagsDisplayChange = nil
        engine.onCaretChange = nil
        textView?.onLayout = nil
        textView?.suggestionCommand = nil
        textView?.accessoryViews = []
        for host in [menuHost, tagHost, suggestionHost] { AtticOverlayHierarchy.remove(host) }
        if chrome.accessories === self {
            chrome.accessories = nil
            // Dismantling runs inside a SwiftUI update: publish afterwards.
            let chrome = chrome
            DispatchQueue.main.async {
                if chrome.accessories == nil { chrome.headerTitleProgress = 0 }
            }
        }
    }

    private func rebuild() {
        shownTags = engine.tags
        let chrome = chrome
        let design = design
        let tagEditor = tagEditor
        menuHost.rootView = AnyView(NoteMenuButtonRoot(chrome: chrome, tagEditor: tagEditor) { [weak self] in
            self?.presentMenu(fromHeader: false)
        }
        .atticDesign(design))
        tagHost.rootView = AnyView(NoteTagLineRoot(chrome: chrome, tags: shownTags, tagEditor: tagEditor)
            .atticDesign(design))
        tagMeasure.rootView = AnyView(AtticNoteTagLine(tags: shownTags) { _ in }.atticDesign(design))
    }

    /// Keeps the ⋯ on the title's first line and the tags under its last,
    /// and the title's lines clear of both. Runs after each layout pass
    /// (cheap: only the title is measured).
    func layout() {
        guard let textView, let rects = engine.titleLineRects() else { return }
        if shownTags != engine.tags { rebuild() }
        let m = AtticNoteMetrics.self
        let inset = textView.textContainerInset.width
        let columnLeft = inset
        let columnRight = textView.bounds.width - inset
        // The ⋯: its glyph ends on the column's edge, centred on the first
        // line's capitals.
        let font = engine.style.titleFont
        let capMiddle = rects.first.minY + font.ascender - font.capHeight / 2
        let size = m.menuButtonSize
        let menuFrame = NSRect(x: columnRight - m.menuGlyphSize / 2 - size / 2, y: (capMiddle - size / 2).rounded(),
                               width: size, height: size)
        if menuHost.frame != menuFrame { menuHost.frame = menuFrame }
        menuHost.isHidden = isUntouched()
        // The tag line: 4 under the title's last line, the column's width.
        var tagHeight: CGFloat = 0
        let width = max(0, columnRight - columnLeft)
        if !engine.tags.isEmpty, width > 0 {
            if let measured = measuredTagLine, measured.tags == engine.tags, measured.width == width {
                tagHeight = measured.height
            } else {
                tagHeight = ceil(tagMeasure.sizeThatFits(in: NSSize(width: width, height: 10_000)).height)
                measuredTagLine = (engine.tags, width, tagHeight)
            }
            let frame = NSRect(x: columnLeft, y: rects.last.minY + NoteTextStyle.titleLineHeight + NoteTextStyle.titleToTags,
                               width: width, height: tagHeight)
            if tagHost.frame != frame { tagHost.frame = frame }
            tagHost.isHidden = false
        } else {
            tagHost.isHidden = true
        }
        engine.setTitleReserves(tagLine: tagHeight, trailing: m.titleTrailingReserve)
        // Layout can run inside a SwiftUI update: publish on the next turn.
        DispatchQueue.main.async { [weak self] in
            self?.updateHeaderTitle()
            self?.updateSuggestions()
        }
        // VoiceOver: "Note, Pricing page".
        let title = engine.lineText(at: 0).trimmingCharacters(in: .whitespaces)
        if title != spokenTitle {
            spokenTitle = title
            textView.setAccessibilityLabel(title.isEmpty ? String(localized: "Note")
                                                         : String(localized: "Note, \(title)"))
        }
    }

    // MARK: Tag suggestions

    /// Shows, moves or hides the suggestions for the `#word` at the caret
    /// in the title (never during a composition, never for a hashtag kept
    /// as text).
    func updateSuggestions() {
        guard let textView, textView.window?.firstResponder === textView,
              let active = engine.activeTitleHashtag,
              let hashRect = engine.rect(for: NSRange(location: active.range.location, length: 1)) else {
            hideSuggestions()
            return
        }
        let list = AtticTagSuggestion.make(typed: active.tag, counts: tagCounts(), excluding: Set(engine.tags))
        guard !list.isEmpty else { hideSuggestions(); return }
        if list.map(\.id) != suggestions.map(\.id) {
            highlightedSuggestion = list.firstIndex { !$0.isNew && $0.name == active.tag }
        }
        suggestions = list
        let m = AtticDropdownMetrics.self
        let titles = list.map { $0.isNew ? String(localized: "New tag “#\($0.name)”") : "#" + $0.name }
        let ideal = zip(titles, list).map { title, suggestion in
            m.inset * 2 + m.rowPadding * 2 + AtticTextStyle.dropdownRow.measuredWidth(title)
                + (suggestion.isNew ? 0 : m.detailGap + AtticTextStyle.shortcut.measuredWidth("\(suggestion.count)"))
        }.max() ?? m.minWidth
        suggestionSize = CGSize(width: ideal, height: CGFloat(list.count) * m.rowHeight + m.inset * 2)
        suggestionHash = active.range.location
        placeSuggestions(hashRect: hashRect, render: true)
    }

    /// The note scrolled: the suggestions follow their `#` (P3-B4). Only
    /// the host's frame moves; the list is rebuilt only if its room
    /// changes. Nothing runs while no suggestions show.
    private func followSuggestions() {
        guard suggestionPlacement != nil, let hash = suggestionHash,
              let hashRect = engine.rect(for: NSRange(location: hash, length: 1)) else { return }
        placeSuggestions(hashRect: hashRect, render: false)
    }

    /// Places the list under (or over) the `#` with the shared placement,
    /// keeping its side while it shows. While the `#` is scrolled out of the
    /// note's visible part the list waits out of sight.
    private func placeSuggestions(hashRect: NSRect, render: Bool) {
        guard let textView, let scrollView, let space = AtticDropdownSpace(around: textView, bounding: textView) else { return }
        // The clip less the header and bottom insets, in the text's terms.
        let insets = scrollView.contentInsets
        let clip = textView.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let readable = NSRect(x: clip.minX, y: clip.minY + insets.top, width: clip.width,
                              height: max(0, clip.height - insets.top - insets.bottom))
        guard readable.contains(NSPoint(x: hashRect.midX, y: hashRect.midY)) else {
            suggestionHost.isHidden = true
            return
        }
        let placed = space.place(idealWidth: suggestionSize.width, height: suggestionSize.height,
                                 anchor: space.anchor(hashRect, in: textView), prefer: .below, current: suggestionPlacement?.side)
        let resized = placed.heightLimit != suggestionPlacement?.heightLimit || placed.width != suggestionPlacement?.width
        suggestionPlacement = placed
        space.show(suggestionHost, at: placed)
        if render || resized { renderSuggestions() }
        suggestionHost.isHidden = false
    }

    private func renderSuggestions() {
        let room = AtticDropdownMetrics.shadowRoom
        suggestionHost.rootView = AnyView(
            AtticTagSuggestionList(suggestions: suggestions, highlighted: highlightedSuggestion ?? -1) { [weak self] index in
                self?.pickSuggestion(index)
            }
            .environment(\.atticDropdownHeight, suggestionPlacement?.heightLimit)
            .environment(\.atticDropdownWidth, suggestionPlacement?.width)
            .padding(room)
            .atticDesign(design)
        )
    }

    private func hideSuggestions() {
        guard !suggestionHost.isHidden || !suggestions.isEmpty else { return }
        suggestionHost.isHidden = true
        suggestions = []
        highlightedSuggestion = nil
        suggestionHash = nil
        suggestionPlacement = nil
    }

    private func pickSuggestion(_ index: Int) {
        guard suggestions.indices.contains(index) else { return }
        let suggestion = suggestions[index]
        hideSuggestions()
        engine.takeTitleHashtag(as: suggestion.isNew ? nil : suggestion.name)
        focusText()
    }

    /// ↑ ↓ move through the suggestions, Return or Tab takes the highlighted
    /// one, Esc keeps the hashtag as text. Other keys type as usual.
    private func handleSuggestionKey(_ selector: Selector) -> Bool {
        guard !suggestionHost.isHidden, !suggestions.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlightedSuggestion = highlightedSuggestion.map { min($0 + 1, suggestions.count - 1) } ?? 0
            renderSuggestions()
            return true
        case #selector(NSResponder.moveUp(_:)):
            highlightedSuggestion = highlightedSuggestion.map { max($0 - 1, 0) } ?? suggestions.count - 1
            renderSuggestions()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab completes: the highlighted suggestion, else the typed word.
            if let highlightedSuggestion {
                pickSuggestion(highlightedSuggestion)
            } else {
                hideSuggestions()
                engine.takeTitleHashtag()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let highlightedSuggestion {
                pickSuggestion(highlightedSuggestion)
                return true
            }
            // Nothing picked: the list closes and Return goes on as usual,
            // taking the typed word and moving into the body.
            hideSuggestions()
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            _ = engine.keepTitleHashtagLiteral()
            hideSuggestions()
            return true
        default:
            return false
        }
    }

    /// The header title fades in as the title passes under the header.
    func updateHeaderTitle() {
        guard let scrollView, let rects = engine.titleLineRects() else { return }
        let clip = scrollView.contentView.bounds
        let titleBottom = rects.last.minY + NoteTextStyle.titleLineHeight - clip.minY
        let progress = min(max((headerBottom + 4 - titleBottom) / NoteTextStyle.titleLineHeight, 0), 1)
        if progress > 0 {
            let title = engine.lineText(at: 0).trimmingCharacters(in: .whitespaces)
            let shown = title.isEmpty ? String(localized: "Untitled note") : title
            if chrome.headerTitle != shown { chrome.headerTitle = shown }
        }
        let current = chrome.headerTitleProgress
        if abs(progress - current) >= 0.02 || ((progress == 0 || progress == 1) && progress != current) {
            chrome.headerTitleProgress = progress
        }
    }

    /// The note's native menu under the ⋯, or under the header title.
    func presentMenu(fromHeader: Bool) {
        guard let scrollView else { return }
        let commands = chrome.menuCommands()
        guard !commands.isEmpty else { return }
        chrome.isMenuOpen = true
        defer { chrome.isMenuOpen = false }
        if !fromHeader, !menuHost.isHidden, let textView,
           textView.visibleRect.insetBy(dx: 0, dy: 0).contains(NSPoint(x: menuHost.frame.midX, y: menuHost.frame.midY)) {
            AtticNativeMenu.popUpContextMenu(commands, below: menuHost.bounds.insetBy(dx: 4, dy: 2), in: menuHost)
            return
        }
        // Under the header's middle, where the header title sits.
        let bounds = scrollView.bounds
        let y = scrollView.isFlipped ? headerBottom : bounds.height - headerBottom
        let anchor = NSRect(x: bounds.midX - 90, y: scrollView.isFlipped ? y - 36 : y, width: 180, height: 36)
        AtticNativeMenu.popUpContextMenu(commands, below: anchor, in: scrollView)
    }

    func focusText() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}


private struct NoteMenuButtonRoot: View {
    @ObservedObject var chrome: NotesPageChrome
    let tagEditor: () -> AnyView
    let action: () -> Void

    var body: some View {
        AtticNoteMenuButton(isOpen: chrome.isMenuOpen, action: action)
            .accessibilityIdentifier("notes-menu-button")
            // The E1 tag picker, as in Tasks (CU P2-03), in the panel's
            // overlay layer.
            .atticDropdown(isPresented: Binding(get: { chrome.tagEditor == .menu },
                                                set: { if !$0, chrome.tagEditor == .menu { chrome.tagEditor = nil } }),
                           label: String(localized: "Tags")) { tagEditor() }
    }
}

private struct NoteTagLineRoot: View {
    @ObservedObject var chrome: NotesPageChrome
    let tags: [String]
    let tagEditor: () -> AnyView

    var body: some View {
        AtticNoteTagLine(tags: tags) { _ in chrome.tagEditor = .tags }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("notes-tag-line")
            .atticDropdown(isPresented: Binding(get: { chrome.tagEditor == .tags },
                                                set: { if !$0, chrome.tagEditor == .tags { chrome.tagEditor = nil } }),
                           label: String(localized: "Tags")) { tagEditor() }
    }
}

/// Hosts the session's text view. The view is made per appearance and
/// released on dismantle; the text, caret and undo history stay in the
/// session.
struct NoteEditorRepresentable: NSViewRepresentable {
    let session: NoteSession
    let chrome: NotesPageChrome
    /// The text column's inset from each side of the panel.
    let columnInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let headerBottom: CGFloat
    let design: AtticDesignContext
    let tagEditor: () -> AnyView
    /// Every tag in Notes with its count (for the title's suggestions).
    let tagCounts: () -> [String: Int]

    final class Coordinator {
        var engine: NoteEditorEngine?
        var accessories: NoteTitleAccessories?
        var controls: NoteFormatControls?
        var objects: NoteObjectControls?
        var tables: NoteTableChrome?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let engine = session.engine
        context.coordinator.engine = engine
        let (scrollView, textView) = engine.makeView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        engine.find.setGeometry(top: topInset, column: columnInset)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        textView.textContainerInset = NSSize(width: columnInset, height: 0)
        let session = session
        context.coordinator.accessories = NoteTitleAccessories(
            engine: engine, textView: textView, scrollView: scrollView, chrome: chrome, design: design,
            headerBottom: headerBottom,
            isUntouched: { [weak session] in
                guard let session else { return true }
                return !session.isPersisted && session.engine.textStorage.length == 0 && session.engine.tags.isEmpty
                    && !session.isImporting
            },
            tagEditor: tagEditor)
        context.coordinator.accessories?.tagCounts = tagCounts
        let controls = NoteFormatControls(engine: engine, textView: textView, scrollView: scrollView, design: design,
                                          noteID: session.noteID,
                                          isNewDraft: !session.isPersisted && session.isUntouchedDraft)
        let chrome = chrome
        controls.requestFormatBar = { [weak chrome] keyboard in chrome?.openFormatBar(keyboard: keyboard) }
        controls.leaveEditor = { [weak chrome] forward in chrome?.leaveEditor?(forward) }
        controls.closeFormatBar = { [weak chrome] in chrome?.closeFormatBar() }
        controls.requestFile = { [weak chrome, sessionID = session.id] slash in
            chrome?.fileRequest = slash.map { .slash(NoteSlashFileTicket(sessionID: sessionID, request: $0)) } ?? .insert
        }
        context.coordinator.controls = controls
        chrome.controls = controls
        controls.isFormatBarOpen = chrome.formatRow.isOpen
        let objects = NoteObjectControls(engine: engine, textView: textView)
        objects.requestSource = { [weak chrome] request in
            switch request {
            case let .retry(id): chrome?.fileRequest = .retry(id)
            case let .locate(id): chrome?.fileRequest = .locate(id)
            }
        }
        context.coordinator.objects = objects
        chrome.objectControls = objects
        let tables = NoteTableChrome(engine: engine, textView: textView, design: design)
        engine.onTableScroll = { [weak tables] view in tables?.tableDidScroll(view) }
        context.coordinator.tables = tables
        #if DEBUG
        NoteFormatCaptureScene.runIfRequested(controls: controls, chrome: chrome, textView: textView)
        #endif
        let selection = session.selection
        DispatchQueue.main.async {
            let length = engine.textStorage.length
            textView.setSelectedRange(NSRange(location: min(selection.location, length),
                                              length: min(selection.length, max(0, length - selection.location))))
            if session.scrollOffset > 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: session.scrollOffset))
            } else {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -topInset))
                textView.scrollRangeToVisible(textView.selectedRange())
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.window?.makeFirstResponder(textView)
            context.coordinator.accessories?.layout()
        }
        return scrollView
    }

    /// The editor takes exactly the room it is given. Without this SwiftUI
    /// asks the scroll view for its fitting size, which is its current
    /// frame: after Settings narrowed the panel (420 → 320) the page kept its
    /// old width, with the right-hand controls cut off (A39 F08).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 400))
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let insets = NSEdgeInsets(top: topInset + session.engine.find.clearance, left: 0, bottom: bottomInset, right: 0)
        session.engine.find.setGeometry(top: topInset, column: columnInset)
        if scrollView.contentInsets.top != insets.top || scrollView.contentInsets.bottom != insets.bottom {
            scrollView.contentInsets = insets
        }
        if let textView = scrollView.documentView as? NSTextView, textView.textContainerInset.width != columnInset {
            textView.textContainerInset = NSSize(width: columnInset, height: 0)
        }
        context.coordinator.accessories?.design = design
        context.coordinator.accessories?.headerBottom = headerBottom
        context.coordinator.controls?.update(design: design)
        context.coordinator.objects?.applyLook()
        context.coordinator.tables?.design = design
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.accessories?.invalidate()
        coordinator.accessories = nil
        coordinator.controls?.invalidate()
        coordinator.controls = nil
        coordinator.objects?.invalidate()
        coordinator.objects = nil
        coordinator.tables?.invalidate()
        coordinator.tables = nil
        if coordinator.engine?.scrollView === scrollView { coordinator.engine?.detachView() }
    }
}
