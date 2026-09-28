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

    /// The note menu's commands for the note on screen (built by the page).
    var menuCommands: () -> [AtticMenuCommand] = { [] }
    fileprivate weak var accessories: NoteTitleAccessories?

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
}

/// The two views that sit on the title's lines inside the text view: the ⋯
/// at the end of its first line and the tag line under its last. They are
/// subviews of the text view, so they scroll with the text natively; the
/// engine keeps the title's lines clear of them.
@MainActor
final class NoteTitleAccessories {
    private let engine: NoteEditorEngine
    private weak var textView: NoteEditorTextView?
    private weak var scrollView: NSScrollView?
    private let chrome: NotesPageChrome
    private let menuHost: NSHostingView<AnyView>
    private let tagHost: NSHostingView<AnyView>
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
        for host in [tagHost, menuHost] {
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = []
            textView.addSubview(host)
        }
        textView.accessoryViews = [tagHost, menuHost]
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
            MainActor.assumeIsolated { self?.updateHeaderTitle() }
        }
    }

    func invalidate() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        engine.onTagsDisplayChange = nil
        textView?.onLayout = nil
        textView?.accessoryViews = []
        menuHost.removeFromSuperview()
        tagHost.removeFromSuperview()
        if chrome.accessories === self {
            chrome.accessories = nil
            chrome.headerTitleProgress = 0
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
        DispatchQueue.main.async { [weak self] in self?.updateHeaderTitle() }
        // VoiceOver: "Note, Pricing page".
        let title = engine.lineText(at: 0).trimmingCharacters(in: .whitespaces)
        if title != spokenTitle {
            spokenTitle = title
            textView.setAccessibilityLabel(title.isEmpty ? String(localized: "Note")
                                                         : String(localized: "Note, \(title)"))
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
            AtticNativeMenu.popUp(commands, below: menuHost.bounds.insetBy(dx: 4, dy: 2), in: menuHost)
            return
        }
        // Under the header's middle, where the header title sits.
        let bounds = scrollView.bounds
        let y = scrollView.isFlipped ? headerBottom : bounds.height - headerBottom
        let anchor = NSRect(x: bounds.midX - 90, y: scrollView.isFlipped ? y - 36 : y, width: 180, height: 36)
        AtticNativeMenu.popUp(commands, below: anchor, in: scrollView)
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
            .popover(isPresented: Binding(get: { chrome.tagEditor == .menu },
                                          set: { if !$0, chrome.tagEditor == .menu { chrome.tagEditor = nil } }),
                     arrowEdge: .bottom) { tagEditor() }
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
            .popover(isPresented: Binding(get: { chrome.tagEditor == .tags },
                                          set: { if !$0, chrome.tagEditor == .tags { chrome.tagEditor = nil } }),
                     arrowEdge: .bottom) { tagEditor() }
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

    final class Coordinator {
        var engine: NoteEditorEngine?
        var accessories: NoteTitleAccessories?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let engine = session.engine
        context.coordinator.engine = engine
        let (scrollView, textView) = engine.makeView()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let insets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        if scrollView.contentInsets.top != insets.top || scrollView.contentInsets.bottom != insets.bottom {
            scrollView.contentInsets = insets
        }
        if let textView = scrollView.documentView as? NSTextView, textView.textContainerInset.width != columnInset {
            textView.textContainerInset = NSSize(width: columnInset, height: 0)
        }
        context.coordinator.accessories?.design = design
        context.coordinator.accessories?.headerBottom = headerBottom
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.accessories?.invalidate()
        coordinator.accessories = nil
        if coordinator.engine?.scrollView === scrollView { coordinator.engine?.detachView() }
    }
}
