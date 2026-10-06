import AppKit
import SwiftUI

/// The composed task-note host (UX plan § 9.1): **one** native scroll view
/// whose flipped document view stacks the task head, the Subtasks block and
/// the note's text view.
///
/// - The text view never scrolls on its own: it is not in a scroll view of
///   its own, its height is TextKit 2's incremental estimate, and caret
///   visibility scrolls the shared clip through the one coordinate mapper.
/// - The engine and its text view are made once and kept across fold, head
///   changes and deleted states (`attach` is the only place a text view is
///   made).
/// - Layout stays viewport-only: nothing here asks TextKit 2 for the whole
///   document's layout on open, fold, resize or keystroke. `layoutCounter`
///   measures that.
@MainActor
final class TaskNoteComposedHost: NSObject {
    /// The flipped document: head, block and text view, top to bottom.
    final class DocumentView: NSView {
        override var isFlipped: Bool { true }
        /// Clicks in the gaps between the regions do nothing (the regions and
        /// the text view take their own).
        override var acceptsFirstResponder: Bool { false }
    }

    let scrollView: NSScrollView
    let documentView = DocumentView()
    private(set) var engine: NoteEditorEngine
    private(set) var textView: NoteEditorTextView
    let mapper: NoteCoordinateMapper
    private let headController: NSHostingController<AnyView>
    private let blockController: NSHostingController<AnyView>
    /// Instrumentation for the § 9.1 gate (nil unless asked for).
    let layoutCounter: TaskNoteLayoutCounter?

    /// The text column's inset from each side (28 in a 320 pt panel).
    var columnInset: CGFloat {
        didSet { if columnInset != oldValue { textView.textContainerInset = NSSize(width: columnInset, height: 0); restack() } }
    }

    /// The Subtasks block's height from its model (fixed row pitch); nil
    /// measures the SwiftUI content.
    var blockHeight: (() -> CGFloat)?
    var onInvalidate: (() -> Void)?

    /// How many times the regions were re-measured and restacked (a fold or
    /// a head change does it once; a keystroke never does).
    private(set) var restackCount = 0
    private var restackScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var textHeightObserver: NSObjectProtocol?
    private var lastWidth: CGFloat = 0
    private var regionHeights: (head: CGFloat, block: CGFloat) = (0, 0)
    private var measuredHeadWidth: CGFloat = 0
    private var headNeedsMeasurement = true

    init(engine: NoteEditorEngine, head: AnyView, block: AnyView, columnInset: CGFloat,
         blockHeight: (() -> CGFloat)? = nil,
         countsLayout: Bool? = nil) {
        self.engine = engine
        self.columnInset = columnInset
        self.blockHeight = blockHeight
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 520))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        self.scrollView = scrollView
        headController = NSHostingController(rootView: head)
        blockController = NSHostingController(rootView: block)
        headController.sizingOptions = []
        blockController.sizingOptions = []
        // The engine's one text view, a stacked view in the shared document.
        let textView = engine.makeComposedView(in: scrollView)
        engine.keepsComposedViewportWarm = true
        self.textView = textView
        mapper = NoteCoordinateMapper(textView: textView, scrollView: scrollView)
        layoutCounter = (countsLayout ?? TaskNoteLayoutCounter.isRequested) ? TaskNoteLayoutCounter() : nil
        super.init()
        documentView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 400)
        documentView.autoresizingMask = [.width]
        scrollView.documentView = documentView
        for view in [headController.view, blockController.view] {
            view.translatesAutoresizingMaskIntoConstraints = true
            documentView.addSubview(view)
        }
        install(textView)
        observeClip()
        restack()
    }

    private func observeClip() {
        let clip = scrollView.contentView
        clip.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipDidResize() }
            })
    }

    func resume(reusingViewport: Bool = false) {
        guard observers.isEmpty else { return }
        observeClip()
        if reusingViewport, engine.resumeComposedView(textView, in: scrollView) {
            install(textView)
            restack()
        } else {
            replaceEngine(engine)
        }
    }

    private func install(_ textView: NoteEditorTextView) {
        textView.coordinateMapper = mapper
        textView.textContainerInset = NSSize(width: columnInset, height: 0)
        textView.autoresizingMask = []
        textView.postsFrameChangedNotifications = true
        if let layoutCounter, let manager = textView.textLayoutManager { layoutCounter.attach(to: manager) }
        if textView.superview !== documentView { documentView.addSubview(textView) }
        textHeightObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.textHeightDidChange() }
            }
    }

    /// A clean external import deliberately replaces the session engine.
    /// Retire the old native editor at the same boundary; it must never
    /// remain editable after the session stopped owning its storage.
    func replaceEngine(_ replacement: NoteEditorEngine) {
        guard replacement !== engine || engine.textView !== textView else { return }
        let old = textView
        let frame = old.frame
        let selected = old.selectedRange()
        let focused = old.window?.firstResponder === old
        if let textHeightObserver { NotificationCenter.default.removeObserver(textHeightObserver) }
        textHeightObserver = nil
        old.coordinateMapper = nil
        old.isEditable = false
        layoutCounter?.detach()
        if engine.textView === old { engine.detachView() }
        if replacement !== engine { engine.discardClosedComposedViewport() }
        old.removeFromSuperview()
        engine = replacement
        textView = replacement.makeComposedView(in: scrollView)
        replacement.keepsComposedViewportWarm = true
        mapper.rebind(textView: textView)
        textView.frame = frame
        install(textView)
        let length = replacement.textStorage.length
        let location = min(selected.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
        restack()
        if focused { textView.window?.makeFirstResponder(textView) }
    }

    func invalidate() {
        onInvalidate?()
        onInvalidate = nil
        if let textHeightObserver { NotificationCenter.default.removeObserver(textHeightObserver) }
        textHeightObserver = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        textView.coordinateMapper = nil
        textView.isEditable = false
        textView.writingToolsBehavior = .none
        textView.suggestionCommand = nil
        textView.onLayout = nil
        layoutCounter?.detach()
        if engine.textView === textView { engine.detachView() }
    }

    // MARK: Stacking

    /// The head's or the block's content changed: restack once, on the next
    /// turn (several changes in one turn restack once).
    func setNeedsRestack() {
        headNeedsMeasurement = true
        guard !restackScheduled else { return }
        restackScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restackScheduled = false
            self.restack()
        }
    }

    /// Measures the head and the block for the column's width and stacks the
    /// three. The final heights are committed once; when the reader is in
    /// the writing, the viewport keeps its anchor (the text stays put while
    /// the block folds above it).
    func restack() {
        restackScheduled = false
        restackCount += 1
        let width = max(1, scrollView.contentView.bounds.width)
        let column = max(1, width - columnInset * 2)
        // The regions' SwiftUI content answers for the model's current state
        // (a fold or a rename this turn), not the last drawn one.
        let head: CGFloat
        if headNeedsMeasurement || measuredHeadWidth != column {
            headController.view.needsLayout = true
            headController.view.layoutSubtreeIfNeeded()
            head = ceil(headController.sizeThatFits(in: NSSize(width: column, height: .greatestFiniteMagnitude)).height)
            measuredHeadWidth = column
            headNeedsMeasurement = false
        } else {
            head = regionHeights.head
        }
        // The block's rows have a fixed pitch: its height is arithmetic, so a
        // fold of 50 rows never measures them.
        let block: CGFloat
        if let blockHeight {
            block = blockHeight()
        } else {
            blockController.view.needsLayout = true
            blockController.view.layoutSubtreeIfNeeded()
            block = ceil(blockController.sizeThatFits(in: NSSize(width: column, height: .greatestFiniteMagnitude)).height)
        }
        let oldTextTop = textView.frame.minY
        let anchored = isReadingWriting
        headController.view.frame = NSRect(x: columnInset, y: 0, width: column, height: head)
        let blockTop = head + TaskNoteMetrics.headToBlock
        blockController.view.frame = NSRect(x: columnInset, y: blockTop, width: column, height: block)
        let textTop = blockTop + block + TaskNoteMetrics.blockToWriting
        regionHeights = (head, block)
        if textView.frame.width != width || textView.frame.minY != textTop {
            textView.frame = NSRect(x: 0, y: textTop, width: width, height: textView.frame.height)
        }
        updateMinimumTextHeight()
        textHeightDidChange()
        lastWidth = width
        let shift = textTop - oldTextTop
        if anchored, abs(shift) >= 0.5 {
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.y += shift
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// The top of what the reader sees is in the writing, past the regions.
    private var isReadingWriting: Bool {
        let clip = scrollView.contentView
        let top = clip.bounds.minY + scrollView.contentInsets.top
        return textView.frame.minY > 0 && top > textView.frame.minY
    }

    /// The text view fills the rest of the page, so a click under the last
    /// line puts the caret at the end.
    private func updateMinimumTextHeight() {
        let insets = scrollView.contentInsets
        let visible = scrollView.contentView.bounds.height - insets.top - insets.bottom
        let minimum = max(0, visible - textView.frame.minY)
        if textView.minSize.height != minimum {
            textView.minSize = NSSize(width: 0, height: minimum)
            if textView.frame.height < minimum { textView.setFrameSize(NSSize(width: textView.frame.width, height: minimum)) }
        }
    }

    private func textHeightDidChange() {
        let height = ceil(textView.frame.maxY)
        let width = scrollView.contentView.bounds.width
        if documentView.frame.height != height || documentView.frame.width != width {
            documentView.setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func clipDidResize() {
        let width = scrollView.contentView.bounds.width
        if width != lastWidth { restack() } else { updateMinimumTextHeight(); textHeightDidChange() }
    }

    /// The scroll view's insets under the header and above the bottom row.
    func setContentInsets(top: CGFloat, bottom: CGFloat) {
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard scrollView.contentInsets.top != top || scrollView.contentInsets.bottom != bottom else { return }
        scrollView.contentInsets = insets
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        updateMinimumTextHeight()
    }

    var headRootView: AnyView {
        get { headController.rootView }
        set { headController.rootView = newValue; headNeedsMeasurement = true }
    }
    var blockRootView: AnyView {
        get { blockController.rootView }
        set { blockController.rootView = newValue }
    }

    var headFrame: NSRect { headController.view.frame }
    var blockFrame: NSRect { blockController.view.frame }

    // MARK: Focus

    /// The writing takes the keyboard: at the top of the writing (a caret,
    /// no ring), or where its caret was.
    func focusWriting(atTop: Bool) {
        guard let window = textView.window else { return }
        if atTop {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        window.makeFirstResponder(textView)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Scrolls back to the page's top (the head).
    func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }
}

// MARK: - Instrumentation (§ 9.1 item 2)

/// Counts TextKit 2 layout work on one layout manager: fragments created
/// (TextKit makes a fragment when layout first reaches a paragraph or an
/// edit replaces one) and a census of fragments whose layout is available.
/// Exposed to tests; installed in the app only with
/// `ATTIC_TASK_NOTE_LAYOUT_COUNTS=1` in a UI-testing launch.
@MainActor
final class TaskNoteLayoutCounter: NSObject, NSTextLayoutManagerDelegate {
    /// Unit tests turn the counter on for every host they open.
    static var enabledForTesting = false

    static var isRequested: Bool {
        if enabledForTesting { return true }
        let environment = ProcessInfo.processInfo.environment
        return environment["ATTIC_UI_TESTING"] == "1" && environment["ATTIC_TASK_NOTE_LAYOUT_COUNTS"] == "1"
    }

    private(set) var fragmentsCreated = 0
    private weak var manager: NSTextLayoutManager?

    func attach(to manager: NSTextLayoutManager) {
        self.manager = manager
        manager.delegate = self
    }

    func detach() {
        if manager?.delegate === self { manager?.delegate = nil }
        manager = nil
    }

    nonisolated func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                       textLayoutFragmentFor location: any NSTextLocation,
                                       in textElement: NSTextElement) -> NSTextLayoutFragment {
        MainActor.assumeIsolated { fragmentsCreated += 1 }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    /// Fragments with layout available, and paragraphs in the document. Walks
    /// the existing fragments without asking for layout (test use only).
    func census() -> (laidOut: Int, paragraphs: Int) {
        guard let manager, let content = manager.textContentManager as? NSTextContentStorage,
              let storage = content.textStorage else { return (0, 0) }
        var laidOut = 0
        let before = fragmentsCreated
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            if fragment.state == .layoutAvailable { laidOut += 1 }
            return true
        }
        // The walk itself may create fragment objects; they are not layout.
        fragmentsCreated = before
        let string = storage.string as NSString
        var paragraphs = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, _, _, _ in
            paragraphs += 1
        }
        return (laidOut, max(1, paragraphs))
    }
}
