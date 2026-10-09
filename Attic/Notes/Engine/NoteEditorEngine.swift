import AppKit

/// Where the editor gets image bytes that are already stored.
@MainActor
protocol NoteImageProviding: AnyObject {
    /// The stored row's file (materialised off the main thread), or nil when
    /// the row or its bytes are gone.
    func fileURL(forAttachment id: UUID) async -> URL?
    func filename(forAttachment id: UUID) -> String?
    /// Bytes of another note's image, for a paste that copies it here.
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment?
    func attachmentBytes(forAttachment id: UUID) -> StagedNoteAttachment?
    func hasAttachmentBytes(_ id: UUID) -> Bool
    func verifiedBytes(forAttachment id: UUID) async -> StagedNoteAttachment?
    func locateAttachment(_ id: UUID, at url: URL) async -> Bool
    func locatePlacement(_ block: NoteBlock, noteID: UUID, at url: URL) async -> Bool
}

/// One accepted source in an import batch. A failed source has no stored
/// bytes; it remains an inline card with Retry and Remove actions.
struct NoteImportedObject: Sendable {
    let filename: String
    let contentTypeIdentifier: String
    let byteCount: Int64
    let staged: StagedNoteAttachment?
    let pixelSize: CGSize?
    let failure: String?

    init(staged: StagedNoteAttachment, pixelSize: CGSize?) {
        filename = staged.filename
        contentTypeIdentifier = staged.contentTypeIdentifier
        byteCount = staged.byteCount
        self.staged = staged
        self.pixelSize = pixelSize
        failure = nil
    }

    init(filename: String, contentTypeIdentifier: String, byteCount: Int64, failure: String) {
        self.filename = filename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        staged = nil
        pixelSize = nil
        self.failure = failure
    }
}

extension NoteImageProviding {
    func attachmentBytes(forAttachment id: UUID) -> StagedNoteAttachment? {
        imageBytes(forAttachment: id)
    }
    func verifiedBytes(forAttachment id: UUID) async -> StagedNoteAttachment? { attachmentBytes(forAttachment: id) }
    func hasAttachmentBytes(_ id: UUID) -> Bool {
        attachmentBytes(forAttachment: id) != nil
    }
    func locateAttachment(_ id: UUID, at url: URL) async -> Bool { false }
    func locatePlacement(_ block: NoteBlock, noteID: UUID, at url: URL) async -> Bool {
        guard let id = block.attachmentID else { return false }
        return await locateAttachment(id, at: url)
    }
}

/// One note's text engine: a stock TextKit 2 text system whose storage,
/// undo history and staged images live here, outside any view. Views come
/// and go (`makeView`, `detachView`); the note, its caret and its history
/// stay.
///
/// Owns the contracts the text system itself does not give:
/// - editor-owned undo (`NoteUndoHistory`, requirement 4);
/// - the object guard: images, checklist boxes and dates are removed only by
///   a person's own editing (typing, deleting, cutting, pasting, dragging,
///   the editor's commands); Find and Replace (single and All), Services,
///   text checking and Writing Tools are refused when they would remove one
///   (requirements 3 and 9);
/// - Writing Tools recovery that can't be undone back into object loss;
/// - stable object identity through copy, cut, paste, undo and redo;
/// - incremental per-edit upkeep (only the edited paragraphs and their
///   neighbours are restyled).
@MainActor
final class NoteEditorEngine: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    enum Activity: Equatable {
        case idle, composing, writingToolsSafe, writingToolsRefused
    }
    /// The note's id; a new note's reserved id may be replaced on its first save.
    var noteID: UUID
    let contentStorage: NSTextContentStorage
    let textStorage: NSTextStorage
    let history: NoteUndoHistory
    let isReadOnly: Bool
    private(set) var style: NoteTextStyle
    private let renderer: NoteObjectRenderer
    private(set) var today: NoteDay
    /// Document-level fields the text doesn't hold (format, requires, extras).
    private var template: NoteDocument
    private(set) weak var textView: NoteEditorTextView?
    private(set) var scrollView: NSScrollView?
    private(set) var layoutManager: NSTextLayoutManager?
    private(set) lazy var find = NoteFindController(engine: self)

    weak var imageProvider: NoteImageProviding?
    /// The text changed through editing, undo or an editor command.
    var onTextChange: (() -> Void)?
    var onActivityChanged: ((Activity, Activity) -> Void)?
    var onWritingToolsDidEnd: (() -> Void)?
    /// A short explanation for the status slot (a refused change).
    var onNotice: ((String) -> Void)?
    /// Called before a Writing Tools session starts (the session saves and
    /// keeps a version first).
    var onWritingToolsWillBegin: (() -> Bool)?
    /// The controller keeps the caret position with its session.
    var onSelectionChange: ((NSRange) -> Void)?
    /// The note's tags changed (the title shorthand, its Undo or Redo, or
    /// the tag editor). Tags are saved with the document.
    var onTagsChange: (() -> Void)?
    /// The tag line redraws (the page's; separate from the session's save hook).
    var onTagsDisplayChange: (() -> Void)?
    /// The caret moved or the text changed (the title's tag suggestions follow it).
    var onCaretChange: (() -> Void)?
    var onSlashSessionChange: ((NoteSlashSession?) -> Void)?
    var onSlashDateRequest: (() -> Void)?
    var onSlashFileRequest: ((NoteSlashFileRequest) -> Void)?
    var onLinkRequest: ((NoteLinkTarget) -> Void)?
    var onRetryImportObject: ((UUID) -> Void)?
    var onLocateObject: ((UUID) -> Void)?
    var onFileBatchRequest: (([URL], String, NSRange) -> Void)?
    var onRawImageBatchRequest: ((Data, String, NSRange) -> Void)?
    /// Same admission gate used by paste, drop, slash and Retry.
    var onImportAdmission: ((StagedNoteAttachment) -> String?)?
    /// The controller checks the complete proposed document before a private
    /// fragment can stage bytes or make an Undo entry.
    var onFragmentAdmission: ((NoteDocument, [StagedNoteAttachment]) -> String?)?
    var canPasteFragment: (() -> Bool)?
    /// A table's grips, "+" chips or indicator must move (the caret entered
    /// or left a table, a table changed, scrolled or was laid out again).
    var onTableChromeChange: (() -> Void)?
    /// The caret entered or left a table, or its cell or cell selection
    /// changed (Aa's row turns into the table's tools and back).
    var onTableFocusChange: (() -> Void)?
    /// A wide table scrolled sideways (its indicator shows for a moment).
    var onTableScroll: ((NoteTableView) -> Void)?
    /// The table the keyboard is in, or was in before a control (Aa's row,
    /// a grip's menu) took it for a moment.
    weak var activeTableView: NoteTableView?
    /// Link… on a cell's text: the page opens its link card for it.
    var onCellLinkRequest: ((NoteCellLinkTarget) -> Void)?
    /// The last paste that became a table, which "Paste as Text" can take back.
    var tablePasteOffer: NoteTablePasteOffer?
    /// ⌥⇧⌘V and "Paste as Text": tabular text stays text.
    var isPastingAsPlainText = false
    private var pendingLinkTarget: NoteLinkTarget?
    private var activeSlashSession: NoteSlashSession?
    private var slashDateRequest: NoteSlashSession?
    /// The `/` Image or File… request the open panel or the loading answers.
    /// Only that request's completion may commit or cancel it.
    private(set) var pendingSlashFile: NoteSlashFileRequest?
    private var slashFileGeneration: UInt64 = 0
    private(set) var pendingParagraphStyle: (location: Int, state: NoteUndoHistory.ParagraphState)?

    fileprivate func notifyTagsChanged() {
        onTagsChange?()
        onTagsDisplayChange?()
    }

    /// The note's tags: normalised, unique, sorted (`AtticTag`). Metadata
    /// kept beside the text, saved with the document in one transaction.
    private(set) var tags: [String]
    /// The `#` of a hashtag in the title that stays text (Esc, or an Undo of
    /// its conversion) until it is typed again. Follows edits like the
    /// import anchor.
    var literalHashLocation: Int?

    /// Images imported in this session but not yet saved.
    private(set) var staged: [UUID: StagedNoteAttachment] = [:]
    func stageImported(_ item: StagedNoteAttachment) { staged[item.id] = item }
    func unstageImported(_ id: UUID) { staged[id] = nil }

    // Guard state.
    var userEditDepth = 0 { didSet { clearNewlineEditIfIdle() } }
    private var engineEditDepth = 0 { didSet { clearNewlineEditIfIdle() } }
    /// True while the edit in flight inserted exactly one line break (Return),
    /// so only Return carries inline marks onto the next line.
    private var newlineEditInFlight = false
    private func clearNewlineEditIfIdle() {
        if userEditDepth == 0 && engineEditDepth == 0 { newlineEditInFlight = false }
    }
    private(set) var isWritingToolsSessionActive = false
    private(set) var writingToolsBeganInView = false
    private(set) var activity: Activity = .idle
    private func setActivity(_ next: Activity) {
        guard next != activity else { return }
        if next != .idle {
            slashSession = nil
            pendingSlashDate = nil
            pendingSlashFile = nil
            pendingLinkTarget = nil
        }
        let previous = activity
        activity = next
        onActivityChanged?(previous, next)
    }
    private var writingToolsBlocked = false
    var isWritingToolsBlocked: Bool { writingToolsBlocked }
    var writingToolsRefusalReason: String?
    private var writingToolsSnapshot: NSAttributedString?
    private var writingToolsEmptyParagraph: NoteBlock?
    private var writingToolsHistory: NoteUndoHistory.Checkpoint?
    private var writingToolsImportTarget: (anchor: Int, replacementLength: Int, isBoundary: Bool)?
    private var pendingImportEdit: (range: NSRange, replacementLength: Int)?
    private var writingToolsObjectsBefore = Set<UUID>()
    private var restoringWritingToolsSnapshot = false
    private var writingToolsAvailable = true
    private var beginningWritingTools = false
    var isPerformingSelfMove = false
    private(set) var refusals: [String] = []
    private(set) var writingToolsRecoveries = 0

    /// Diagnostic: time spent in the last per-edit upkeep (ms).
    private(set) var lastUpkeepMilliseconds: Double = 0
    private(set) var documentExtractionCount = 0
    private var documentCache: (document: NoteDocument, finalParagraphStart: Int, finalParagraphDirty: Bool)?
    private var pendingImageLoads = Set<ObjectIdentifier>()
    private var importAnchor: Int?
    var currentImportAnchor: Int? { importAnchor }
    private var importReplacementLength = 0
    private var importIsBoundary = false
    var currentImportTarget: (anchor: Int, replacementLength: Int, isBoundary: Bool)? {
        importAnchor.map { ($0, importReplacementLength, importIsBoundary) }
    }

    func documentAfterRemovingImportTarget() -> NoteDocument {
        guard let anchor = importAnchor, importReplacementLength > 0 else { return document() }
        let at = min(anchor, textStorage.length)
        let replacement = NSRange(location: at, length: min(importReplacementLength, textStorage.length - at))
        let remaining = NSMutableAttributedString(attributedString: textStorage)
        remaining.deleteCharacters(in: replacement)
        return NoteTextCodec.document(from: remaining, template: template)
    }
    private var importNoteID: UUID?

    init(noteID: UUID, document: NoteDocument, readOnly: Bool = false,
         design: AtticDesignContext = .default, today: NoteDay = NoteDay(date: Date()),
         imageProvider: NoteImageProviding? = nil,
         stagedAttachments: [StagedNoteAttachment] = [], tags: [String] = []) {
        self.noteID = noteID
        self.tags = AtticTag.normalizedSet(tags)
        self.isReadOnly = readOnly
        self.style = NoteTextStyle(design: design)
        self.renderer = NoteObjectRenderer(design: design)
        self.today = today
        self.template = document
        self.imageProvider = imageProvider
        self.staged = Dictionary(uniqueKeysWithValues: stagedAttachments.map { ($0.id, $0) })
        contentStorage = NSTextContentStorage()
        textStorage = contentStorage.textStorage ?? NSTextStorage()
        history = NoteUndoHistory(storage: textStorage)
        super.init()
        // Lists are shown at their own indent, their markers drawn by the
        // editor (`textContentStorage(_:textParagraphWith:)`).
        contentStorage.delegate = self
        renderer.faceProvider = { [weak self] object in self?.objectFace(for: object) }
        renderer.columnWidth = { [weak self] in self?.objectColumnWidth ?? 300 }
        textStorage.setAttributedString(NoteTextCodec.attributedString(from: document, style: style))
        if document.blocks.count > 1, let last = document.blocks.last,
           last.kind == .text, last.text.isEmpty { restoreEmptyParagraph(last) }
        textStorage.delegate = self
        renderObjects(in: NSRange(location: 0, length: textStorage.length))
        history.onReplay = { [weak self] range in self?.didReplay(range) }
        history.onTagFlip = { [weak self] tag, add, changesTags, range in
            self?.didFlipTag(tag, add: add, changesTags: changesTags, range: range)
        }
        history.onTagPickerDelta = { [weak self] adds, removes in
            guard let self else { return }
            var current = Set(self.tags)
            current.subtract(removes)
            current.formUnion(adds)
            self.setTags(Array(current))
        }
        history.onParagraphStyleSnapshot = { [weak self] location, state in
            self?.setPendingParagraphStyle(state.style, indent: state.indent, at: location, metadata: state.block)
        }
        history.emptyParagraphState = { [weak self] in self?.emptyParagraphBlock() }
        history.onEmptyParagraphSnapshot = { [weak self] block in self?.restoreEmptyParagraph(block) }
        history.onTypingMarkSnapshot = { [weak self] kind, enabled in self?.setTypingMark(kind, enabled: enabled) }
        history.onBoundaryTypingMarksSnapshot = { [weak self] marks in
            guard let self, let textView = self.textView else { return }
            var attributes = self.attributes(forParagraphAt: textView.selectedRange().location)
            for (kind, value) in marks { attributes[.noteMark(kind)] = value }
            attributes.merge(self.style.markedAttributes(marks: marks, baseFont: attributes[.font] as? NSFont ?? self.style.bodyFont)) { _, new in new }
            textView.typingAttributes = attributes
            self.updateTextChecking()
        }
        history.canReplay = { [weak self] in self?.activity == .idle }
        history.onTableSnapshot = { [weak self] id, table, focus in
            self?.restoreTable(id: id, table: table, focus: focus) ?? false
        }
    }

    // MARK: Document

    func document() -> NoteDocument {
        if var cached = documentCache {
            if !cached.finalParagraphDirty { return cached.document }
            let range = NSRange(location: cached.finalParagraphStart,
                                length: textStorage.length - cached.finalParagraphStart)
            let paragraph = textStorage.attributedSubstring(from: range)
            let tail = NoteTextCodec.document(from: paragraph, template: template, firstBlockIsTitle: false)
            if tail.blocks.count == 1, Self.isSimpleTextBlock(tail.blocks[0]),
               let last = cached.document.blocks.last, Self.isSimpleTextBlock(last) {
                cached.document.blocks[cached.document.blocks.count - 1] = tail.blocks[0]
                cached.finalParagraphDirty = false
                documentCache = cached
                documentExtractionCount += 1
                return cached.document
            }
        }
        var result = NoteTextCodec.document(from: textStorage, template: template)
        if let pending = pendingParagraphStyle, pending.location == textStorage.length,
           let last = result.blocks.indices.last, result.blocks[last].kind == .text,
           result.blocks[last].text.isEmpty {
            result.blocks[last] = block(for: pending.state)
            result.refreshRequiredCapabilities()
        }
        let string = textStorage.string as NSString
        let newline = string.range(of: "\n", options: .backwards)
        let finalStart = newline.location == NSNotFound ? 0 : newline.location + 1
        documentCache = (result, finalStart, false)
        documentExtractionCount += 1
        return result
    }

    /// Recovery checkpoints during a refused Writing Tools session contain
    /// the starting document, never an in-place rewrite that bypassed the guard.
    func checkpointDocument() -> NoteDocument {
        if activity == .writingToolsRefused, let writingToolsSnapshot {
            var result = NoteTextCodec.document(from: writingToolsSnapshot, template: template)
            if let empty = writingToolsEmptyParagraph, let last = result.blocks.indices.last,
               result.blocks[last].kind == .text, result.blocks[last].text.isEmpty {
                result.blocks[last] = empty
                result.refreshRequiredCapabilities()
            }
            return result
        }
        return document()
    }

    func setWritingToolsAvailable(_ available: Bool) {
        writingToolsAvailable = available
        if activity == .idle && !beginningWritingTools {
            textView?.writingToolsBehavior = available ? .complete : .none
        }
    }

    /// AppKit can discard marked text without sending a text-change callback.
    func refreshCompositionActivity() {
        if textView?.hasMarkedText() == true {
            slashSession = nil
            pendingSlashDate = nil
            pendingSlashFile = nil
        }
        if activity == .composing && textView?.hasMarkedText() != true { setActivity(.idle) }
    }

    private static func isSimpleTextBlock(_ block: NoteBlock) -> Bool {
        block.kind == .text && block.id == nil && block.style == nil && block.level == nil
            && block.indent == nil && block.marks.isEmpty && block.extras.isEmpty
            && block.inlines.isEmpty && !block.text.contains(NoteDocument.objectCharacter)
    }

    var plainText: String { NoteTextExport.plainText(document()) }

    /// The staged images the given document shows (to commit with it).
    func stagedAttachments(for document: NoteDocument) -> [StagedNoteAttachment] {
        let shown = Set(document.attachmentIDs)
        return staged.values.filter { shown.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Staged images that are now stored rows are dropped from the session.
    func forgetStaged(_ ids: Set<UUID>) {
        for id in ids { staged[id] = nil }
    }

    func restoreStaged(_ items: [StagedNoteAttachment]) {
        for item in items { staged[item.id] = item }
    }

    // MARK: Views

    /// A text view bound to this note's storage (TextKit 2). Only one view
    /// at a time: making a new one detaches the old.
    func makeView() -> (NSScrollView, NoteEditorTextView) {
        detachView()
        let layoutManager = NSTextLayoutManager()
        // The Mono block, list markers and quote bars (`NoteBlockLayoutFragment`).
        layoutManager.delegate = self
        let container = NSTextContainer(size: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.primaryTextLayoutManager = layoutManager
        let textView = NoteEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 400), textContainer: container)
        textView.engine = self
        configure(textView)
        textView.installHeadingsRotor()
        let scrollView = NoteDocumentScrollView(frame: textView.frame)
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        textView.autoresizingMask = [.width]
        self.layoutManager = layoutManager
        self.textView = textView
        self.scrollView = scrollView
        history.textView = textView
        find.attach()
        return (scrollView, textView)
    }

    func detachView() {
        find.detach()
        let wasComposing = activity == .composing
        if let layoutManager { contentStorage.removeTextLayoutManager(layoutManager) }
        textView?.engine = nil
        textView?.delegate = nil
        layoutManager = nil
        textView = nil
        scrollView = nil
        history.textView = nil
        if wasComposing { setActivity(.idle) }
    }

    private func configure(_ textView: NoteEditorTextView) {
        textView.delegate = self
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        // Native font/color commands would create attributes format 1 cannot
        // store. The engine still owns its styled attributed storage and
        // object attachments; only native rich-text editing is disabled.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.proseTextCompletionEnabled = textView.isAutomaticTextCompletionEnabled
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = style.titleAttributes
        textView.insertionPointColor = style.bodyColor
        // Writing Tools: inline, plain-text results only, objects protected.
        textView.writingToolsBehavior = writingToolsAvailable ? .complete : .none
        textView.allowedWritingToolsResultOptions = [.plainText]
        textView.setAccessibilityLabel(String(localized: "Note"))
        textView.setAccessibilityIdentifier("note-text")
    }

    // MARK: Look

    /// Room under the title for the tag line and at the end of its lines for
    /// the note menu. Attributes only (never an Undo step).
    private var pendingTitleReserves: (tagLine: CGFloat, trailing: CGFloat)?
    private var titleReservesScheduled = false

    func setTitleReserves(tagLine: CGFloat, trailing: CGFloat) {
        guard style.tagLineHeight != tagLine || style.titleTrailingReserve != trailing else {
            pendingTitleReserves = nil
            return
        }
        // The title accessories measure from NSTextView.layout. Restyling
        // here would invalidate the viewport fragments that AppKit has
        // just laid out, leaving their layers blank after a tag change.
        // Coalesce the latest geometry and apply it outside every layout
        // pass, including a nested run-loop callback.
        if AtticOverlayHierarchy.isInLayoutPass {
            pendingTitleReserves = (tagLine, trailing)
            scheduleTitleReserves()
            return
        }
        pendingTitleReserves = nil
        style.tagLineHeight = tagLine
        style.titleTrailingReserve = trailing
        let title = titleParagraphRange
        guard title.length > 0 else {
            textView?.typingAttributes = attributes(forParagraphAt: textView?.selectedRange().location ?? 0)
            return
        }
        restyle(title)
        invalidateLayout(title)
        if let textView, paragraphRange(at: textView.selectedRange().location).location == 0 {
            textView.typingAttributes = style.titleAttributes
        }
    }

    private func scheduleTitleReserves() {
        guard !titleReservesScheduled else { return }
        titleReservesScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titleReservesScheduled = false
            guard let pending = self.pendingTitleReserves else { return }
            self.setTitleReserves(tagLine: pending.tagLine, trailing: pending.trailing)
        }
    }

    /// How many times a change of look redrew the whole note (diagnostic:
    /// only a change of colours may do it).
    private(set) var appearanceRefreshCount = 0

    func update(design: AtticDesignContext) {
        guard renderer.update(design: design) else { return }
        appearanceRefreshCount += 1
        style = NoteTextStyle(design: design, tagLineHeight: style.tagLineHeight,
                              titleTrailingReserve: style.titleTrailingReserve)
        restyle(NSRange(location: 0, length: textStorage.length))
        renderObjects(in: NSRange(location: 0, length: textStorage.length), force: true)
        textView?.insertionPointColor = style.bodyColor
        invalidateLayout(NSRange(location: 0, length: textStorage.length))
        // Restyling invalidates TextKit's attachment providers too. Finish
        // their viewport layout before a focused table can be parked at a
        // stale frame while the appearance or panel width changes.
        textView?.needsLayout = true
        DispatchQueue.main.async { [weak self] in
            self?.textView?.layoutSubtreeIfNeeded()
            self?.textView?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// Dates read as Today, Tomorrow or Yesterday: recomputed when the panel
    /// shows (no timers while hidden).
    func refreshRelativeDates(today: NoteDay) {
        guard today != self.today else { return }
        self.today = today
        var dates: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let date = value as? NoteDateAttachment else { return }
            renderer.apply(to: date, today: today)
            dates.append(range)
        }
        dates.forEach(invalidateLayout)
    }

    /// Fonts, inks and paragraph styles for the given paragraphs: the first
    /// paragraph is the title. Attributes only; never a history step.
    func restyle(_ range: NSRange) {
        let string = textStorage.string as NSString
        guard string.length > 0 else { return }
        let firstBreak = string.range(of: "\n", options: .literal)
        let titleEnd = firstBreak.location == NSNotFound ? string.length : firstBreak.location + 1
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: string.length))
        let titleRange = NSIntersectionRange(clamped, NSRange(location: 0, length: titleEnd))
        if titleRange.length > 0 || (clamped.location <= titleEnd && clamped.length == 0) {
            let apply = NSRange(location: 0, length: titleEnd)
            if apply.length > 0 {
                textStorage.addAttributes(style.titleAttributes, range: apply)
                restyleMarks(in: apply, base: style.titleAttributes)
            }
        }
        let bodyStart = max(titleEnd, clamped.location)
        let bodyEnd = NSMaxRange(clamped)
        if bodyEnd > bodyStart {
            var position = bodyStart
            while position < bodyEnd {
                let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
                let actual = NSIntersectionRange(paragraph, NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                let metadata = textStorage.attributes(at: position, effectiveRange: nil)
                let name = metadata[.noteBlockStyle] as? String
                let depth = metadata[.noteBlockIndent] as? Int ?? 0
                let blockObject = isBlockObject(at: paragraph.location)
                var base = style.paragraphAttributes(
                    style: name, level: metadata[.noteBlockLevel] as? Int, indent: metadata[.noteBlockIndent] as? Int,
                    previous: paragraph.location <= titleEnd ? .title : paragraphKind(at: paragraph.location - 1),
                    isChecklist: checklistBox(inParagraphAt: paragraph.location) != nil, isBlockObject: blockObject,
                    monoHang: name == "mono" ? style.monoHang(for: string.substring(with: paragraph)) : 0,
                    monoExitsAtEnd: name == "mono" && monoExitsAtEnd(paragraph))
                if let name, ["bullet", "number"].contains(name) {
                    let marker: NSTextList.MarkerFormat = name == "number" ? .decimal : .disc
                    var lists: [NSTextList] = []
                    if paragraph.location > titleEnd {
                        let before = string.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
                        let prior = textStorage.attributes(at: before.location, effectiveRange: nil)
                        if ["bullet", "number"].contains(prior[.noteBlockStyle] as? String ?? "") {
                            lists = (prior[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
                        }
                    }
                    if lists.count > depth + 1 { lists = Array(lists.prefix(depth + 1)) }
                    while lists.count <= depth { lists.append(NSTextList(markerFormat: marker, options: 0)) }
                    if lists[depth].markerFormat != marker { lists[depth] = NSTextList(markerFormat: marker, options: 0) }
                    let paragraphStyle = (base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                    paragraphStyle.textLists = lists
                    base[.paragraphStyle] = paragraphStyle
                }
                textStorage.addAttributes(base, range: actual)
                restyleMarks(in: actual, base: base)
                // No spelling or grammar marks inside code (Mono, Codex's change).
                if name == "mono" { textView?.setSpellingState(0, range: actual) }
                position = NSMaxRange(paragraph)
                if position <= actual.location { break }
            }
        }
    }

    private func restyleMarks(in range: NSRange, base: [NSAttributedString.Key: Any]) {
        var runs: [([NoteMark.Kind: Any], NSRange)] = []
        textStorage.enumerateAttributes(in: range) { values, markRange, _ in
            let marks = Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.compactMap { kind in
                values[.noteMark(kind)].map { (kind, $0) }
            })
            runs.append((marks, markRange))
        }
        for key in [NSAttributedString.Key.link, .underlineStyle, .strikethroughStyle, .backgroundColor] {
            textStorage.removeAttribute(key, range: range)
        }
        let font = base[.font] as? NSFont ?? style.bodyFont
        for (marks, markRange) in runs {
            textStorage.addAttributes(style.markedAttributes(marks: marks, baseFont: font), range: markRange)
            if marks[.code] != nil { textView?.setSpellingState(0, range: markRange) }
        }
    }

    /// The paragraphs covering `range`, plus one on each side.
    func paragraphs(around range: NSRange) -> NSRange {
        let string = textStorage.string as NSString
        guard string.length > 0 else { return NSRange(location: 0, length: 0) }
        let start = min(range.location, string.length)
        let end = min(NSMaxRange(range), string.length)
        var result = string.paragraphRange(for: NSRange(location: start, length: end - start))
        if result.location > 0 {
            result = NSUnionRange(result, string.paragraphRange(for: NSRange(location: result.location - 1, length: 0)))
        }
        if NSMaxRange(result) < string.length {
            result = NSUnionRange(result, string.paragraphRange(for: NSRange(location: NSMaxRange(result), length: 0)))
        }
        return result
    }

    /// The cached document no longer matches the text (a table's grid
    /// changed in place).
    func invalidateDocumentCache() { documentCache = nil }

    /// Draws an object with the note's renderer (a date inside a cell).
    func rendererApply(_ object: NoteObjectAttachment) { renderer.apply(to: object, today: today) }

    private func renderObjects(in range: NSRange, force: Bool = false) {
        guard range.length > 0 else { return }
        textStorage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let object = value as? NoteObjectAttachment else { return }
            if let table = object as? NoteTableAttachment {
                adoptTable(table, force: force)
            } else if let image = object as? NoteImageAttachment {
                // A decoded image looks the same in every appearance: only a
                // missing one's placeholder is drawn again.
                if image.renderedImage == nil || (force && image.isMissing) { loadImage(image) }
            } else if let file = object as? NoteFileAttachment {
                if let id = file.attachmentID {
                    file.originalMissing = staged[id] == nil && imageProvider?.hasAttachmentBytes(id) != true
                }
                if force || file.renderedImage == nil { renderer.apply(to: file, today: today) }
            } else if force || object.renderedImage == nil {
                renderer.apply(to: object, today: today)
            }
        }
    }

    func invalidateLayout(_ range: NSRange) {
        guard let layoutManager, let textRange = textRange(for: range) else { return }
        layoutManager.invalidateLayout(for: textRange)
        textView?.needsDisplay = true
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        let documentStart = contentStorage.documentRange.location
        guard let start = contentStorage.location(documentStart, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: Images

    private func loadImage(_ image: NoteImageAttachment) {
        let key = ObjectIdentifier(image)
        guard !pendingImageLoads.contains(key) else { return }
        if let reserved = staged[image.attachmentID], reserved.byteCount == 0, reserved.digest.isEmpty {
            image.isMissing = false
            image.renderedImage = renderer.placeholder(
                size: image.displaySize(columnWidth: textView?.textContainer?.size.width ?? 320),
                text: String(localized: "Loading image…")
            )
            return
        }
        pendingImageLoads.insert(key)
        image.filename = staged[image.attachmentID]?.filename
            ?? imageProvider?.filename(forAttachment: image.attachmentID) ?? image.filename
        let stagedData = staged[image.attachmentID]?.data
        let provider = imageProvider
        let attachmentID = image.attachmentID
        let maxPixel = 1400
        Task { [weak self, weak image] in
            var url: URL?
            if stagedData == nil { url = await provider?.fileURL(forAttachment: attachmentID) }
            let header = await Task.detached(priority: .userInitiated) {
                if let stagedData { return NoteImageDecoder.pixelSize(of: stagedData) }
                guard let url else { return nil }
                return NoteImageDecoder.pixelSize(at: url)
            }.value
            guard let self, let image else { return }
            if image.pixelSize == nil, let header {
                image.pixelSize = header
                image.renderedImage = self.renderer.placeholder(
                    size: image.displaySize(columnWidth: self.textView?.textContainer?.size.width ?? 320),
                    text: String(localized: "Loading image…"))
                if let range = self.range(of: image) { self.invalidateLayout(range) }
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                if let stagedData { return NoteImageDecoder.thumbnail(of: stagedData, maxPixel: maxPixel) }
                guard let url else { return nil }
                return NoteImageDecoder.thumbnail(at: url, maxPixel: maxPixel)
            }.value
            self.pendingImageLoads.remove(ObjectIdentifier(image))
            if self.staged[attachmentID]?.data != stagedData {
                self.loadImage(image)
                return
            }
            self.finishImageLoad(image, cgImage: decoded, pixelSize: header)
        }
    }

    func retryImagePreview(_ image: NoteImageAttachment) {
        image.renderedImage = nil
        image.isMissing = false
        loadImage(image)
    }

    private func finishImageLoad(_ image: NoteImageAttachment, cgImage: CGImage?, pixelSize: CGSize?) {
        var sizeChanged = false
        if image.pixelSize == nil, let pixelSize {
            image.pixelSize = pixelSize
            sizeChanged = true
        }
        if let cgImage {
            image.isMissing = false
            image.failureMessage = nil
            image.renderedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            image.isMissing = true
            image.failureMessage = staged[image.attachmentID] != nil
                || imageProvider?.hasAttachmentBytes(image.attachmentID) == true
                    ? String(localized: "Preview unavailable") : String(localized: "Original missing")
            let size = image.displaySize(columnWidth: textView?.textContainer?.size.width ?? 320)
            image.renderedImage = objectFace(for: image).map { renderer.imageFailure(size: size, face: $0) }
                ?? renderer.placeholder(size: size, text: String(localized: "Image unavailable"))
        }
        guard let range = range(of: image) else { return }
        // A size learnt from the file is stored with the next real save;
        // opening a note never writes it.
        if sizeChanged { documentCache = nil }
        invalidateLayout(range)
    }

    func range(of attachment: NSTextAttachment) -> NSRange? {
        var found: NSRange?
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if (value as AnyObject?) === attachment {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Objects

    func objectIDs(in range: NSRange? = nil) -> [UUID] {
        var ids: [UUID] = []
        let scope = range ?? NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.attachment, in: scope) { value, _, _ in
            if let object = value as? NoteObjectAttachment { ids.append(object.objectID) }
        }
        return ids
    }

    func objects() -> [(NoteObjectAttachment, NSRange)] {
        var result: [(NoteObjectAttachment, NSRange)] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let object = value as? NoteObjectAttachment { result.append((object, range)) }
        }
        return result
    }

    func rangeContainsObject(_ range: NSRange) -> Bool {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        guard clamped.length > 0 else { return false }
        var found = false
        textStorage.enumerateAttribute(.attachment, in: clamped) { value, _, stop in
            if value is NoteObjectAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func object(at location: Int) -> NoteObjectAttachment? {
        guard location >= 0, location < textStorage.length else { return nil }
        return textStorage.attribute(.attachment, at: location, effectiveRange: nil) as? NoteObjectAttachment
    }

    func isBlockObject(at location: Int) -> Bool { object(at: location)?.isBlockObject ?? false }

    /// A Mono paragraph that ends the note with a line break after it, and
    /// the empty line below it is not Mono: the block ends with this line,
    /// and the empty line (TextKit's extra line) sits a block margin below.
    func monoExitsAtEnd(_ paragraph: NSRange) -> Bool {
        let string = textStorage.string as NSString
        guard paragraph.length > 0, NSMaxRange(paragraph) == string.length,
              string.character(at: NSMaxRange(paragraph) - 1) == 0x0A else { return false }
        guard let pending = pendingParagraphStyle, pending.location == string.length else { return true }
        return pending.state.style != .mono
    }

    /// What the paragraph at `location` is, for spacing and drawing.
    func paragraphKind(at location: Int) -> NoteParagraphKind {
        let line = paragraphRange(at: location)
        if line.location == 0 { return .title }
        if let pending = pendingParagraphStyle, pending.location == line.location {
            return NoteParagraphKind.of(style: pending.state.style.storageName, level: pending.state.style.level)
        }
        guard line.location < textStorage.length else { return .body }
        if isBlockObject(at: line.location) { return .blockObject }
        let attributes = textStorage.attributes(at: line.location, effectiveRange: nil)
        return NoteParagraphKind.of(style: attributes[.noteBlockStyle] as? String, level: attributes[.noteBlockLevel] as? Int)
    }

    func paragraphRange(at location: Int) -> NSRange {
        let string = textStorage.string as NSString
        return string.paragraphRange(for: NSRange(location: min(max(0, location), string.length), length: 0))
    }

    /// The paragraph without its line break.
    func lineRange(at location: Int) -> NSRange {
        var range = paragraphRange(at: location)
        let string = textStorage.string as NSString
        if range.length > 0, NSMaxRange(range) <= string.length,
           string.character(at: NSMaxRange(range) - 1) == 0x0A {
            range.length -= 1
        }
        return range
    }

    func checklistBox(inParagraphAt location: Int) -> NoteChecklistAttachment? {
        let line = lineRange(at: location)
        guard line.length > 0 else { return nil }
        return textStorage.attribute(.attachment, at: line.location, effectiveRange: nil) as? NoteChecklistAttachment
    }

    /// Finds only the layout fragment under a click, then checks its line.
    /// No document-wide object enumeration or per-checkbox layout is needed.
    func checkboxRange(near point: NSPoint) -> NSRange? {
        guard let layoutManager, let textView else { return nil }
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: containerPoint) else { return nil }
        let location = contentStorage.offset(from: contentStorage.documentRange.location,
                                             to: fragment.rangeInElement.location)
        guard location >= 0, checklistBox(inParagraphAt: location) != nil else { return nil }
        return NSRange(location: lineRange(at: location).location, length: 1)
    }

    func attributes(forParagraphAt location: Int) -> [NSAttributedString.Key: Any] {
        let paragraph = paragraphRange(at: location)
        let previous: NoteParagraphKind? = paragraph.location == 0 ? nil
            : (paragraph.location <= titleParagraphRange.length ? .title : paragraphKind(at: paragraph.location - 1))
        if let pending = pendingParagraphStyle, pending.location == paragraph.location {
            var attributes = style.paragraphAttributes(style: pending.state.style.storageName, level: pending.state.style.level,
                                                       indent: pending.state.indent, previous: previous)
            attributes[.noteBlockStyle] = pending.state.style.storageName
            attributes[.noteBlockLevel] = pending.state.style.level
            if pending.state.indent > 0 { attributes[.noteBlockIndent] = pending.state.indent }
            if let block = pending.state.block {
                if let name = block.style { attributes[.noteBlockStyle] = name }
                if let indent = block.indent { attributes[.noteBlockIndent] = indent }
                if let id = block.id { attributes[.noteBlockID] = id }
                if !block.extras.isEmpty { attributes[.noteBlockExtras] = NoteBlockExtras(block.extras) }
            }
            return attributes
        }
        guard paragraph.location > 0 else { return style.titleAttributes }
        guard paragraph.location < textStorage.length else {
            return style.paragraphAttributes(style: nil, level: nil, indent: nil, previous: previous)
        }
        let attributes = textStorage.attributes(at: paragraph.location, effectiveRange: nil)
        let name = attributes[.noteBlockStyle] as? String
        var result = style.paragraphAttributes(style: name,
                                              level: attributes[.noteBlockLevel] as? Int,
                                              indent: attributes[.noteBlockIndent] as? Int, previous: previous,
                                              isChecklist: checklistBox(inParagraphAt: paragraph.location) != nil,
                                              monoHang: name == "mono" ? style.monoHang(for: lineText(at: paragraph.location)) : 0)
        for key in [NSAttributedString.Key.noteBlockStyle, .noteBlockLevel, .noteBlockIndent] {
            result[key] = attributes[key]
        }
        return result
    }

    // MARK: Editor commands (each one undo step)

    /// Replaces `range` as one named step. Returns false when refused.
    @discardableResult
    func performEdit(_ range: NSRange, with replacement: NSAttributedString, name: String,
                     selection: NSRange? = nil) -> Bool {
        guard !isReadOnly, rangeIsInStorage(range) else { return false }
        guard activity == .idle else {
            return refuse(String(localized: "Finish Writing Tools or composing text before editing this note."))
        }
        var containsPayloadObject = false
        replacement.enumerateAttribute(.attachment, in: NSRange(location: 0, length: replacement.length)) { value, _, _ in
            if value is NoteImageAttachment || value is NoteFileAttachment { containsPayloadObject = true }
        }
        if containsPayloadObject, let gate = onFragmentAdmission {
            let candidateStorage = NSMutableAttributedString(attributedString: textStorage)
            candidateStorage.replaceCharacters(in: range, with: replacement)
            let candidate = NoteTextCodec.document(from: candidateStorage, template: template)
            if let reason = gate(candidate, stagedAttachments(for: candidate)) { return refuse(reason) }
        }
        history.breakCoalescing()
        engineEditDepth += 1
        defer { engineEditDepth -= 1 }
        if let textView {
            guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return false }
            pendingImportEdit = (range, replacement.length)
            textStorage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        } else {
            history.willChange(ranges: [range], strings: [replacement.string])
            pendingImportEdit = (range, replacement.length)
            textStorage.replaceCharacters(in: range, with: replacement)
            history.didChange()
            onTextChange?()
        }
        pendingImportEdit = nil
        history.renameLast(name)
        history.breakCoalescing()
        if let selection {
            textView?.setSelectedRange(NSRange(location: min(selection.location, textStorage.length),
                                               length: min(selection.length, max(0, textStorage.length - selection.location))))
        }
        return true
    }

    /// Adds a checkbox to the caret's line, or removes it if the line has
    /// one. On the title line a new checklist line is started below it.
    func toggleChecklistLine() {
        let selection = textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let line = lineRange(at: selection.location)
        if let box = checklistBox(inParagraphAt: selection.location) {
            _ = box
            _ = removeChecklistMarker(at: line.location, selection: selection)
            return
        }
        let box = NoteChecklistAttachment(isChecked: false)
        renderer.apply(to: box, today: today)
        if line.location == 0 {
            // The title never holds objects: start a checklist line below it.
            let insertion = NSMutableAttributedString(string: "\n", attributes: style.bodyAttributes)
            insertion.append(NoteTextCodec.attachmentString(box, attributes: style.bodyAttributes))
            let at = NSMaxRange(line)
            performEdit(NSRange(location: at, length: 0), with: insertion, name: String(localized: "Checklist"),
                        selection: NSRange(location: at + insertion.length, length: 0))
        } else {
            performEdit(NSRange(location: line.location, length: 0),
                        with: NoteTextCodec.attachmentString(box, attributes: style.bodyAttributes),
                        name: String(localized: "Checklist"),
                        selection: NSRange(location: selection.location + 1, length: selection.length))
        }
    }

    /// Removing a marker also removes checklist-only indentation. The
    /// attributed replacement keeps the line's text, marks, and inline IDs.
    @discardableResult
    private func removeChecklistMarker(at location: Int, selection: NSRange) -> Bool {
        guard checklistBox(inParagraphAt: location) != nil else { return false }
        guard applyStyle(.body, selection: NSRange(location: location, length: 0)) else { return false }
        let caret = selection.location > location ? selection.location - 1 : selection.location
        textView?.setSelectedRange(NSRange(location: min(caret, textStorage.length), length: 0))
        return true
    }

    /// Ticks or unticks the checklist line at `location` without moving the
    /// caret: the box is replaced by one with the same ID.
    func toggleCheckbox(atLineOf location: Int) {
        guard let box = checklistBox(inParagraphAt: location) else { return }
        let line = lineRange(at: location)
        let selection = textView?.selectedRange()
        let flipped = NoteChecklistAttachment(objectID: box.objectID, isChecked: !box.isChecked)
        renderer.apply(to: flipped, today: today)
        let attributes = textStorage.attributes(at: line.location, effectiveRange: nil)
        let replacement = NSMutableAttributedString(attachment: flipped)
        replacement.addAttributes(attributes.filter { $0.key != .attachment }, range: NSRange(location: 0, length: 1))
        performEdit(NSRange(location: line.location, length: 1), with: replacement,
                    name: flipped.isChecked ? String(localized: "Check") : String(localized: "Uncheck"),
                    selection: selection)
    }

    /// Inserts a date at the validated captured range (replacing a selection).
    @discardableResult
    func insertDate(_ day: NoteDay, at selection: NSRange? = nil) -> Bool {
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        guard validate(.date(day), selection: selection).enabled else { return false }
        let date = NoteDateAttachment(day: day)
        renderer.apply(to: date, today: today)
        let text = NoteTextCodec.attachmentString(date, attributes: attributes(forParagraphAt: selection.location))
        return performEdit(selection, with: text, name: String(localized: "Insert Date"),
                           selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Adds an imported image on its own line after the caret's line.
    @discardableResult
    func insertImage(_ item: StagedNoteAttachment, pixelSize: CGSize?) -> Bool {
        staged[item.id] = item
        let selection = textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let line = lineRange(at: selection.location)
        let image = NoteImageAttachment(attachmentID: item.id, preferredWidthFraction: 1, pixelSize: pixelSize, extras: item.identityExtras)
        image.filename = item.filename
        let insertion = NSMutableAttributedString(string: "\n", attributes: style.bodyAttributes)
        insertion.append(NoteTextCodec.attachmentString(image, attributes: style.bodyAttributes))
        let at = NSMaxRange(line)
        // A trailing empty line after an image at the very end keeps a place to type.
        if at == textStorage.length {
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        let inserted = performEdit(NSRange(location: at, length: 0), with: insertion,
                                   name: String(localized: "Insert Image"),
                                   selection: NSRange(location: at + insertion.length, length: 0))
        if !inserted { staged[item.id] = nil }
        return inserted
    }

    func beginImageImport(at selection: NSRange? = nil) {
        if let selection {
            importAnchor = min(selection.location, textStorage.length)
            importReplacementLength = min(selection.length, textStorage.length - importAnchor!)
            importIsBoundary = selection.length == 0
        } else {
            let caret = min(textView?.selectedRange().location ?? textStorage.length, textStorage.length)
            importAnchor = NSMaxRange(lineRange(at: caret))
            importReplacementLength = 0
            importIsBoundary = false
        }
        importNoteID = noteID
    }

    func restoreImageImport(anchor: Int, replacementLength: Int, isBoundary: Bool) {
        importAnchor = min(anchor, textStorage.length)
        importReplacementLength = min(replacementLength, textStorage.length - importAnchor!)
        importIsBoundary = isBoundary
        importNoteID = noteID
    }

    func cancelImageImport() {
        importAnchor = nil
        importReplacementLength = 0
        importNoteID = nil
        writingToolsImportTarget = nil
    }

    /// The complete batch is one document change and one Undo step.
    @discardableResult
    func insertImportedImages(_ items: [(StagedNoteAttachment, CGSize?)]) -> Bool {
        insertImportedObjects(items.map { NoteImportedObject(staged: $0.0, pixelSize: $0.1) })
    }

    /// One editor-history step for text and every accepted object. The
    /// transformed anchor follows typing while a loader works; it is never
    /// resolved from the caret at completion.
    @discardableResult
    func insertImportedObjects(_ items: [NoteImportedObject], acceptedText: String = "") -> Bool {
        guard let anchor = importAnchor, importNoteID == noteID,
              !items.isEmpty || !acceptedText.isEmpty else { return false }
        let at = min(anchor, textStorage.length)
        let replacement = NSRange(location: at, length: min(importReplacementLength, textStorage.length - at))
        let insertion = NSMutableAttributedString(string: "")
        if !acceptedText.isEmpty { insertion.append(NSAttributedString(string: acceptedText, attributes: style.bodyAttributes)) }
        for item in items {
            let priorIsNewline = insertion.length == 0
                ? at == 0 || (textStorage.string as NSString).character(at: at - 1) == 0x0A
                : (insertion.string as NSString).character(at: insertion.length - 1) == 0x0A
            if !priorIsNewline { insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes)) }
            if let stagedItem = item.staged, let pixelSize = item.pixelSize {
                let image = NoteImageAttachment(attachmentID: stagedItem.id, preferredWidthFraction: 1, pixelSize: pixelSize, extras: stagedItem.identityExtras)
                image.filename = item.filename
                insertion.append(NoteTextCodec.attachmentString(image, attributes: style.bodyAttributes))
            } else {
                let file = NoteFileAttachment(attachmentID: item.staged?.id, filename: item.filename,
                    contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                    importFailure: item.failure, extras: item.staged?.identityExtras ?? [:])
                insertion.append(NoteTextCodec.attachmentString(file, attributes: style.bodyAttributes))
            }
        }
        if !items.isEmpty && (NSMaxRange(replacement) == textStorage.length
            || (textStorage.string as NSString).character(at: NSMaxRange(replacement)) != 0x0A) {
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        let candidateStorage = NSMutableAttributedString(attributedString: textStorage)
        candidateStorage.replaceCharacters(in: replacement, with: insertion)
        let candidate = NoteTextCodec.document(from: candidateStorage, template: template)
        if let failure = onFragmentAdmission?(candidate, items.compactMap(\.staged)) {
            onNotice?(failure)
            return false
        }
        // The exact candidate was admitted against the latest draft. Release
        // the target and stage bytes only after that decision.
        importAnchor = nil
        importNoteID = nil
        importReplacementLength = 0
        for item in items { if let payload = item.staged { staged[payload.id] = payload } }
        let inserted = performEdit(replacement, with: insertion,
                                   name: String(localized: "Add Files"),
                                   selection: NSRange(location: at + insertion.length, length: 0))
        if !inserted { for item in items { if let id = item.staged?.id { staged[id] = nil } } }
        return inserted
    }

    /// The look objects are drawn in.
    var objectDesign: AtticDesignContext { renderer.currentDesign }

    /// Draws every file card and failed image again: the column's width
    /// changed (a card spans it), or an object's state did (a Locate that
    /// found the original). Never on a keystroke.
    func refreshObjectFaces() {
        var changed: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let file = value as? NoteFileAttachment {
                if let id = file.attachmentID {
                    file.originalMissing = staged[id] == nil && imageProvider?.hasAttachmentBytes(id) != true
                }
                renderer.apply(to: file, today: today)
                changed.append(range)
            } else if let image = value as? NoteImageAttachment, image.isMissing, let face = objectFace(for: image) {
                let size = image.displaySize(columnWidth: textView?.textContainer?.size.width ?? 320)
                image.renderedImage = renderer.imageFailure(size: size, face: face)
                changed.append(range)
            }
        }
        changed.forEach(invalidateLayout)
    }

    func invalidateAttachmentPresentation(_ id: UUID) {
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let object = value as? NoteObjectAttachment else { return }
            if let file = object as? NoteFileAttachment, file.attachmentID == id {
                file.originalMissing = imageProvider?.hasAttachmentBytes(id) != true
                renderer.apply(to: file, today: today)
                layoutManager?.invalidateLayout(for: contentStorage.documentRange)
                textView?.needsDisplay = true
            }
        }
    }

    // MARK: Keys with object rules

    private func isMonoParagraph(at location: Int) -> Bool {
        guard location < textStorage.length else { return false }
        return paragraphStyle(at: location) == .mono
    }

    /// Return on a checklist line continues the list; on an empty checklist
    /// line it ends the list (the box goes).
    func handleNewline() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        if slashSession != nil { return false }
        let current = textView.selectedRange()
        if current.length == 0 {
            let line = lineRange(at: current.location)
            if line.location > 0, current.location == NSMaxRange(line), convertPipeRowToTable(line: line) { return true }
            if line.location > 0, current.location == NSMaxRange(line),
               (textStorage.string as NSString).substring(with: line) == "---",
               conversionEligible(line: line) {
                let divider = NoteDividerAttachment()
                renderer.apply(to: divider, today: today)
                let replacement = NSMutableAttributedString(attributedString: NoteTextCodec.attachmentString(divider, attributes: style.bodyAttributes))
                replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
                let applied = performEdit(line, with: replacement, name: "Divider",
                                          selection: NSRange(location: line.location + replacement.length, length: 0))
                if applied { history.setLastRestoredText(NSAttributedString(string: "---\n", attributes: style.bodyAttributes)) }
                return applied
            }
            if case .heading = paragraphStyle(at: current.location) {
                history.beginGroup()
                defer { history.endGroup() }
                if current.location == line.location, line.length > 0 {
                    // Return at a heading's start adds an empty Body line above;
                    // the heading keeps its text and style.
                    let blank = NSAttributedString(string: "\n", attributes: style.bodyAttributes)
                    return performEdit(current, with: blank, name: "New Body Line",
                                       selection: NSRange(location: current.location + 1, length: 0))
                }
                let insertion = NSAttributedString(string: "\n", attributes: attributes(forParagraphAt: current.location))
                guard performEdit(current, with: insertion, name: "New Body Line",
                                  selection: NSRange(location: current.location + 1, length: 0)) else { return false }
                return perform(.paragraph(.body))
            }
            if let format = paragraphStyle(at: current.location),
               [.bullet, .number, .quote, .mono].contains(format) {
                let content = (textStorage.string as NSString).substring(with: line)
                if content.trimmingCharacters(in: .whitespaces).isEmpty,
                   format != .mono || !isMonoParagraph(at: NSMaxRange(line) + 1) {
                    // An empty list or quote line ends the block; an empty Mono
                    // line does too unless more code follows (a blank code line).
                    return perform(.paragraph(.body), selection: current)
                }
                let attributes = textView.typingAttributes
                let depth = indentAt(line.location) ?? 0
                let insertion = NSAttributedString(string: "\n", attributes: attributes)
                let finalParagraph = current.location == textStorage.length
                history.beginGroup()
                defer { history.endGroup() }
                let name = format == .quote ? "Continue Quote" : (format == .mono ? "Continue Mono" : "Continue List")
                guard performEdit(current, with: insertion, name: name,
                                  selection: NSRange(location: current.location + 1, length: 0)) else { return false }
                if finalParagraph {
                    history.recordParagraphStyleChange(location: current.location + 1,
                        before: .init(style: .body, indent: 0), after: .init(style: format, indent: depth))
                    setPendingParagraphStyle(format, indent: depth, at: current.location + 1)
                }
                history.renameLast(name)
                return true
            }
        }
        if enterBodyFromTitleEnd() { return true }
        let selection = textView.selectedRange()
        guard selection.length == 0, checklistBox(inParagraphAt: selection.location) != nil else { return false }
        let line = lineRange(at: selection.location)
        guard selection.location > line.location else { return false }
        let text = (textStorage.string as NSString).substring(with: NSRange(location: line.location + 1, length: line.length - 1))
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return removeChecklistMarker(at: line.location, selection: selection)
        }
        let box = NoteChecklistAttachment(isChecked: false)
        renderer.apply(to: box, today: today)
        let depth = indentAt(line.location) ?? 0
        var continuation = style.paragraphAttributes(style: nil, level: nil, indent: depth)
        if depth > 0 { continuation[.noteBlockIndent] = depth }
        let insertion = NSMutableAttributedString(string: "\n", attributes: continuation)
        insertion.append(NoteTextCodec.attachmentString(box, attributes: continuation))
        // Typed through the text view, so it coalesces like any Return.
        userEditDepth += 1
        textView.insertText(insertion, replacementRange: selection)
        userEditDepth -= 1
        return true
    }

    /// Backspace right after a checkbox removes the box first (the text
    /// stays); Backspace into an image line selects the image first.
    func handleDeleteBackward() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location > 0 else { return false }
        let location = selection.location
        let line = lineRange(at: location)
        if location == line.location, let format = paragraphStyle(at: location),
           format == .bullet || format == .number || format == .quote {
            return perform(.paragraph(.body), selection: selection)
        }
        // A line that starts with an image never joins the line above (the
        // title least of all): the image is selected first.
        // An empty line above (not the title) simply goes.
        if location == line.location, isBlockObject(at: location) {
            let previous = lineRange(at: location - 1)
            if previous.length > 0 || previous.location == 0 {
                textView.setSelectedRange(NSRange(location: location, length: 1))
                return true
            }
        }
        if location == line.location + 1, checklistBox(inParagraphAt: location) != nil {
            return removeChecklistMarker(at: line.location, selection: selection)
        }
        let string = textStorage.string as NSString
        if isBlockObject(at: location - 1) {
            textView.setSelectedRange(NSRange(location: location - 1, length: 1))
            return true
        }
        if string.character(at: location - 1) == 0x0A, location >= 2, isBlockObject(at: location - 2) {
            textView.setSelectedRange(NSRange(location: location - 2, length: 1))
            return true
        }
        return false
    }

    func handleDeleteForward() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let location = selection.location
        let string = textStorage.string as NSString
        if isBlockObject(at: location) {
            textView.setSelectedRange(NSRange(location: location, length: 1))
            return true
        }
        // Forward Delete at a line's end never pulls a checkbox into it:
        // the box goes first (the marker-first rule, from the other side).
        if location < string.length, string.character(at: location) == 0x0A,
           checklistBox(inParagraphAt: location + 1) != nil {
            return removeChecklistMarker(at: location + 1, selection: selection)
        }
        if location < string.length, string.character(at: location) == 0x0A, isBlockObject(at: location + 1) {
            textView.setSelectedRange(NSRange(location: location + 1, length: 1))
            return true
        }
        return false
    }

    /// Text typed on an image's line gets its own line, in the same
    /// insertion (one undo step).
    func adjustedInsertion(_ text: String, at range: NSRange) -> (before: Bool, after: Bool) {
        guard !text.isEmpty, text != "\n" else { return (false, false) }
        let string = textStorage.string as NSString
        let afterObject = range.location > 0 && isBlockObject(at: range.location - 1)
        let beforeObject = NSMaxRange(range) < string.length && isBlockObject(at: NSMaxRange(range))
            && (range.location == 0 || string.character(at: range.location - 1) == 0x0A)
        return (afterObject, beforeObject && !afterObject)
    }

    // MARK: Guard

    private func refuse(_ reason: String) -> Bool {
        refusals.append(reason)
        onNotice?(reason)
        NSSound.beep()
        return false
    }

    /// Decides whether a change may happen. Only a person's own editing and
    /// the editor's own commands may remove an object.
    func allowsChange(ranges: [NSRange]) -> Bool {
        if history.isReplaying || engineEditDepth > 0 { return true }
        if writingToolsBeganInView, writingToolsBlocked,
           textView?.isWritingToolsActive == false { writingToolsDidEnd() }
        if writingToolsBlocked, isWritingToolsSessionActive || (textView?.isWritingToolsActive ?? false) {
            return refuse(writingToolsRefusalReason ?? String(localized: "Writing Tools can’t change this note until a recovery version is saved. Retry after saving the note."))
        }
        guard ranges.contains(where: rangeContainsObject) else { return true }
        if isWritingToolsSessionActive || (textView?.isWritingToolsActive ?? false) {
            return refuse(String(localized: "Writing Tools can’t change images, checklists or dates, so that change was not made."))
        }
        if userEditDepth > 0 { return true }
        return refuse(String(localized: "Replace can’t remove images, checklists or dates, so nothing was replaced."))
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        let ranges = affectedRanges.map(\.rangeValue)
        guard allowsChange(ranges: ranges) else { return false }
        newlineEditInFlight = replacementStrings == ["\n"]
        history.willChange(ranges: ranges, strings: replacementStrings)
        if ranges.count == 1 {
            pendingImportEdit = (ranges[0], replacementStrings?.first?.utf16.count ?? 0)
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        history.didChange()
        find.refresh()
        pendingImportEdit = nil
        refreshSlashAfterEdit()
        pendingLinkTarget = nil
        guard !restoringWritingToolsSnapshot else { return }
        if !(writingToolsBlocked && isWritingToolsSessionActive) { onTextChange?() }
        if !isWritingToolsSessionActive {
            setActivity(textView?.hasMarkedText() == true ? .composing : .idle)
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        // Paragraph identity and unknown fields stay on the characters they
        // came with; typed text never copies them. Neither does an object.
        newTypingAttributes.filter { !NSAttributedString.Key.noteBookkeeping.contains($0.key) && $0.key != .attachment }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = textView else { return }
        let selection = textView.selectedRange()
        if userEditDepth == 0 && engineEditDepth == 0 && !history.isChangeInFlight {
            if let session = slashSession,
               selection != NSRange(location: NSMaxRange(session.range), length: 0) { slashSession = nil }
            if let session = pendingSlashDate,
               selection != NSRange(location: NSMaxRange(session.range), length: 0) { pendingSlashDate = nil }
            if let request = pendingSlashFile,
               selection != NSRange(location: NSMaxRange(request.target.range), length: 0) { pendingSlashFile = nil }
            if let target = pendingLinkTarget, selection != target.selection { pendingLinkTarget = nil }
        }
        if !history.isChangeInFlight, let open = history.openStep,
           !(selection.length == 0 && selection.location >= open.range.location && selection.location <= NSMaxRange(open.range)) {
            history.breakCoalescing()
        }
        let line = lineRange(at: selection.location)
        if line.length == 0 || line.location == 0 {
            textView.typingAttributes = attributes(forParagraphAt: selection.location)
        } else {
            // At a line's start use that line, never the preceding separator.
            // A selection inherits its first character's inline marks; a caret
            // within a line inherits the character immediately before it.
            let index = selection.length > 0 || selection.location == line.location
                ? selection.location : selection.location - 1
            var attributes = textStorage.attributes(at: min(index, textStorage.length - 1), effectiveRange: nil)
            for key in NSAttributedString.Key.noteBookkeeping { attributes[key] = nil }
            attributes[.attachment] = nil
            textView.typingAttributes = attributes
        }
        if selection.length == 0, selection.location == line.location, selection.location > 0,
           newlineEditInFlight, userEditDepth > 0 || engineEditDepth > 0 {
            // Return inherits explicit inline marks from the inserted separator,
            // while the destination paragraph supplies its block style and font.
            let previous = textStorage.attributes(at: selection.location - 1, effectiveRange: nil)
            let marks = Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.filter { $0 != .link }.compactMap { kind in
                previous[.noteMark(kind)].map { (kind, $0) }
            })
            var attributes = textView.typingAttributes
            for (kind, value) in marks { attributes[.noteMark(kind)] = value }
            attributes[.noteMark(.link)] = nil
            if !marks.isEmpty {
                let base = self.attributes(forParagraphAt: selection.location)[.font] as? NSFont ?? style.bodyFont
                attributes.merge(style.markedAttributes(marks: marks, baseFont: base)) { _, new in new }
            }
            textView.typingAttributes = attributes
        }
        onSelectionChange?(selection)
        updateTextChecking()
        onCaretChange?()
    }

    /// AppKit's substitutions are input settings, separate from spell
    /// checking. Change them with the insertion point, before input begins.
    func updateTextChecking() {
        guard let textView else { return }
        let literal = paragraphStyle(at: textView.selectedRange().location) == .mono
            || textView.typingAttributes[.noteMark(.code)] != nil
        textView.isContinuousSpellCheckingEnabled = !literal
        textView.isAutomaticSpellingCorrectionEnabled = !literal
        textView.isAutomaticTextReplacementEnabled = !literal
        textView.isAutomaticQuoteSubstitutionEnabled = !literal
        textView.isAutomaticDashSubstitutionEnabled = !literal
        textView.isAutomaticTextCompletionEnabled = !literal && textView.proseTextCompletionEnabled
        textView.smartInsertDeleteEnabled = !literal
    }

    /// The caret never rests between a checkbox and its line start: moving
    /// left from the text's start goes to the line above.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                  toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
        guard newSelectedCharRange.length == 0, !textView.hasMarkedText() else { return newSelectedCharRange }
        let location = newSelectedCharRange.location
        guard checklistBox(inParagraphAt: location) != nil, lineRange(at: location).location == location else {
            return newSelectedCharRange
        }
        if oldSelectedCharRange.length == 0, oldSelectedCharRange.location == location + 1, location > 0 {
            return NSRange(location: location - 1, length: 0)
        }
        return NSRange(location: location + 1, length: 0)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { (view as? NoteEditorTextView)?.undoShim }

    // MARK: Writing Tools (requirement 3)

    /// Ranges Writing Tools must not rewrite: every object, and whole
    /// checklist lines.
    func writingToolsProtectedRanges(in enclosing: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        for (object, range) in objects() {
            if object is NoteChecklistAttachment {
                ranges.append(lineRange(at: range.location))
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { NSIntersectionRange($0, enclosing) }.filter { $0.length > 0 }.sorted { $0.location < $1.location }
    }

    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        writingToolsProtectedRanges(in: enclosingRange).map { NSValue(range: $0) }
    }

    func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        writingToolsBeganInView = true
        writingToolsWillBegin()
    }

    func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        writingToolsDidEnd()
    }

    func writingToolsWillBegin() {
        guard !isWritingToolsSessionActive else { return }
        writingToolsSnapshot = NSAttributedString(attributedString: textStorage)
        writingToolsEmptyParagraph = emptyParagraphBlock()
        writingToolsHistory = history.checkpoint()
        writingToolsImportTarget = currentImportTarget
        writingToolsObjectsBefore = Set(objectIDs())
        writingToolsRefusalReason = nil
        beginningWritingTools = true
        let preserved = onWritingToolsWillBegin?() ?? true
        beginningWritingTools = false
        writingToolsBlocked = !preserved
        isWritingToolsSessionActive = true
        setActivity(preserved ? .writingToolsSafe : .writingToolsRefused)
        if !preserved {
            onNotice?(writingToolsRefusalReason ?? String(localized: "Writing Tools unavailable — couldn't save a safety copy."))
        }
    }

    /// A refused rewrite always returns to the exact starting text and Undo
    /// checkpoint. A protected object lost during a safe rewrite does too.
    func writingToolsDidEnd() {
        guard let snapshot = writingToolsSnapshot else { return }
        let wasBlocked = writingToolsBlocked
        let lostObject = !writingToolsObjectsBefore.subtracting(objectIDs()).isEmpty
        let changed = !snapshot.isEqual(to: textStorage)
        writingToolsSnapshot = nil
        writingToolsObjectsBefore = []
        isWritingToolsSessionActive = false
        writingToolsBeganInView = false
        if wasBlocked || lostObject {
            let whole = NSRange(location: 0, length: textStorage.length)
            restoringWritingToolsSnapshot = true
            history.performUnrecorded {
                engineEditDepth += 1
                if let textView, textView.shouldChangeText(in: whole, replacementString: snapshot.string) {
                    textStorage.replaceCharacters(in: whole, with: snapshot)
                    textView.didChangeText()
                } else {
                    textStorage.replaceCharacters(in: whole, with: snapshot)
                }
                engineEditDepth -= 1
            }
            restoringWritingToolsSnapshot = false
            if let checkpoint = writingToolsHistory { history.rewind(to: checkpoint) }
            restoreEmptyParagraph(writingToolsEmptyParagraph)
            if let target = writingToolsImportTarget {
                restoreImageImport(anchor: target.anchor, replacementLength: target.replacementLength,
                    isBoundary: target.isBoundary)
            }
            if changed || lostObject {
                writingToolsRecoveries += 1
                onNotice?(wasBlocked
                    ? String(localized: "Writing Tools changed this note without a safety copy, so its rewrite was not kept.")
                    : String(localized: "Writing Tools changed an image, checklist or date, so its rewrite was not kept."))
            }
        } else if changed {
            onTextChange?()
        }
        writingToolsHistory = nil
        writingToolsEmptyParagraph = nil
        writingToolsImportTarget = nil
        writingToolsBlocked = false
        writingToolsRefusalReason = nil
        setActivity(textView?.hasMarkedText() == true ? .composing : .idle)
        onWritingToolsDidEnd?()
    }

    // MARK: NSTextStorageDelegate

    /// Records the change, then the per-edit upkeep: only the edited
    /// paragraphs and their neighbours are restyled (attributes only, which
    /// processEditing allows here).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // An edit that empties the note or fills an empty one (an Undo, a
        // paste, an agent's change included): "Title" comes or goes.
        if textStorage.length == 0 || textStorage.length == delta { textView?.updatePlaceholder() }
        let emptyBefore = pendingParagraphStyle.flatMap { pending in
            pending.location == textStorage.length - delta ? block(for: pending.state) : nil
        }
        if let pending = pendingParagraphStyle, editedRange.location < pending.location {
            let oldEnd = NSMaxRange(editedRange) - delta
            if oldEnd <= pending.location {
                pendingParagraphStyle?.location += delta
            } else { pendingParagraphStyle = nil }
        }
        if pendingParagraphStyle?.location == textStorage.length, textStorage.length > 0,
           (textStorage.string as NSString).character(at: textStorage.length - 1) != 0x0A {
            pendingParagraphStyle = nil // Its paragraph separator was removed.
        }
        if let activeSlashSession, editedRange.location < activeSlashSession.range.location {
            slashSession = nil
        }
        // TextKit can replace the whole paragraph run when one character is
        // inserted at its start. The inserted prefix then lacks our semantic
        // paragraph attributes even though the surviving text still has them.
        // Recover them from the first surviving run before history records the
        // edit, so Undo and redo preserve the paragraph style as well.
        let editedLine = lineRange(at: editedRange.location)
        if editedLine.location > 0, editedLine.length > 1,
           textStorage.attribute(.noteBlockStyle, at: editedLine.location, effectiveRange: nil) == nil {
            let rest = NSRange(location: editedLine.location + 1, length: editedLine.length - 1)
            var donor: [NSAttributedString.Key: Any]?
            var leadingLength = 0
            textStorage.enumerateAttributes(in: rest) { attributes, range, stop in
                if attributes[.noteBlockStyle] != nil {
                    donor = attributes
                    leadingLength = range.location - editedLine.location
                    stop.pointee = true
                }
            }
            if let donor, leadingLength > 0 {
                let leading = NSRange(location: editedLine.location, length: leadingLength)
                for key in [NSAttributedString.Key.noteBlockStyle, .noteBlockLevel, .noteBlockIndent] {
                    if let value = donor[key] { textStorage.addAttribute(key, value: value, range: leading) }
                }
            }
        }
        if let pending = pendingParagraphStyle, editedRange.location == pending.location,
           editedRange.length > 0, editedRange.location < textStorage.length {
            let range = NSRange(location: editedRange.location,
                                length: min(editedRange.length, textStorage.length - editedRange.location))
            if let name = pending.state.style.storageName { textStorage.addAttribute(.noteBlockStyle, value: name, range: range) }
            if let level = pending.state.style.level { textStorage.addAttribute(.noteBlockLevel, value: level, range: range) }
            if pending.state.indent > 0 { textStorage.addAttribute(.noteBlockIndent, value: pending.state.indent, range: range) }
            if let metadata = pending.state.block {
                if let name = metadata.style { textStorage.addAttribute(.noteBlockStyle, value: name, range: range) }
                if let indent = metadata.indent { textStorage.addAttribute(.noteBlockIndent, value: indent, range: range) }
                if let id = metadata.id { textStorage.addAttribute(.noteBlockID, value: id, range: range) }
                if !metadata.extras.isEmpty { textStorage.addAttribute(.noteBlockExtras, value: NoteBlockExtras(metadata.extras), range: range) }
            }
            pendingParagraphStyle = nil
        }
        // A selected-range deletion, cut, or replacement can remove the box
        // without using a marker-first key route. Normalize its surviving
        // paragraph before history captures the edit.
        let nearby = paragraphs(around: editedRange)
        var nearbyStart = nearby.location
        while nearbyStart < NSMaxRange(nearby), nearbyStart < textStorage.length {
            let line = lineRange(at: nearbyStart)
            if line.location > 0, line.length > 0, checklistBox(inParagraphAt: line.location) == nil {
                let name = textStorage.attribute(.noteBlockStyle, at: line.location, effectiveRange: nil) as? String
                if !["bullet", "number", "quote"].contains(name ?? ""),
                   textStorage.attribute(.noteBlockIndent, at: line.location, effectiveRange: nil) != nil {
                    let extent = (textStorage.string as NSString).paragraphRange(for: NSRange(location: line.location, length: 0))
                    textStorage.removeAttribute(.noteBlockIndent, range: extent)
                }
            }
            let next = NSMaxRange(line) + 1
            if next <= nearbyStart { break }
            nearbyStart = next
        }
        if let anchor = importAnchor {
            // TextKit's processed range also includes neighbouring attributes,
            // so use the actual pre-edit range when a change was announced.
            let edit = pendingImportEdit?.range ?? NSRange(location: editedRange.location,
                length: max(0, editedRange.length - delta))
            let newEnd = edit.location + (pendingImportEdit?.replacementLength ?? editedRange.length)
            let oldEnd = NSMaxRange(edit)
            if importReplacementLength == 0 {
                // Insertion targets have trailing affinity. A replacement
                // spanning the boundary moves it after the replacement;
                // it can never turn into a range that removes new text.
                if oldEnd <= anchor {
                    importAnchor = max(0, anchor + delta)
                } else if edit.location <= anchor {
                    importAnchor = newEnd
                }
            } else {
                let selectionEnd = anchor + importReplacementLength
                var selectionNewEnd = selectionEnd
                if oldEnd <= anchor {
                    importAnchor = max(0, anchor + delta)
                } else if edit.location <= anchor {
                    importAnchor = edit.location
                }
                if oldEnd <= selectionEnd {
                    selectionNewEnd = selectionEnd + delta
                } else if edit.location <= selectionEnd {
                    selectionNewEnd = newEnd
                }
                importReplacementLength = max(0, selectionNewEnd - (importAnchor ?? selectionNewEnd))
            }
        }
        pendingImportEdit = nil
        if let hash = literalHashLocation {
            let oldLength = max(0, editedRange.length - delta)
            if editedRange.location + oldLength <= hash {
                literalHashLocation = hash + delta
            } else if editedRange.location > hash {
                // After the `#`: the word may grow, it stays literal.
            } else {
                literalHashLocation = nil
            }
        }
        if var cached = documentCache {
            let string = textStorage.string as NSString
            let newline = string.range(of: "\n", options: .backwards)
            let finalStart = newline.location == NSNotFound ? 0 : newline.location + 1
            if finalStart == cached.finalParagraphStart, finalStart > 0,
               editedRange.location >= finalStart,
               NSMaxRange(editedRange) <= textStorage.length {
                cached.finalParagraphDirty = true
                documentCache = cached
            } else {
                documentCache = nil
            }
        }
        let outsideRefusedEdit = activity == .writingToolsRefused && engineEditDepth == 0
            && !history.isReplaying && userEditDepth == 0
        if outsideRefusedEdit {
            let oldLength = editedRange.length - delta
            if oldLength >= 0 {
                history.breakCoalescing()
                history.rebase(editAt: NSRange(location: editedRange.location, length: oldLength),
                               newLength: editedRange.length)
            }
        } else {
            history.captureUnrecorded(newRange: editedRange, delta: delta, emptyParagraphBefore: emptyBefore)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let around = paragraphs(around: editedRange)
        restyle(around)
        if editedMask.contains(.editedCharacters), needsRenumbering(around) {
            // Numbers further down the list change: their fragments are
            // made again once this edit has been processed.
            DispatchQueue.main.async { [weak self] in self?.renumberList(after: around) }
        }
        renderObjects(in: NSIntersectionRange(editedRange, NSRange(location: 0, length: textStorage.length)))
        lastUpkeepMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// Whether an edit touched a numbered list (or the line right after one).
    private func needsRenumbering(_ range: NSRange) -> Bool {
        var found = false
        textStorage.enumerateAttribute(.noteBlockStyle, in: NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))) { value, _, stop in
            if value as? String == "number" { found = true; stop.pointee = true }
        }
        return found || (NSMaxRange(range) < textStorage.length
            && textStorage.attribute(.noteBlockStyle, at: NSMaxRange(range), effectiveRange: nil) as? String == "number")
    }

    private func didReplay(_ range: NSRange) {
        // An Undo of the note's text while a cell has the keyboard: the
        // keyboard goes to the text it changed.
        if let table = focusedTable, let textView {
            table.deactivate()
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: min(NSMaxRange(range), textStorage.length), length: 0))
        }
        onTextChange?()
    }

    // MARK: Pasteboard

    static let fragmentType = NSPasteboard.PasteboardType("com.taha.attic.note-fragment")

    func fragment(for range: NSRange) -> NoteDocument {
        var fragment = NoteTextCodec.document(from: textStorage.attributedSubstring(from: range),
                                              template: NoteDocument(blocks: []), firstBlockIsTitle: false)
        fragment.extras = ["sourceNoteID": .string(noteID.uuidString)]
        return fragment
    }

    func writeSelection(_ range: NSRange, to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard range.length > 0 else { return false }
        let fragment = fragment(for: range)
        // A whole table on its own: other apps get it as a table (HTML,
        // tab-separated, Markdown as its text), Attic as itself.
        if range.length == 1, let table = tableAttachment(at: range.location) {
            NoteTablePaste.write(table.table, to: pasteboard)
            if types.contains(Self.fragmentType), let data = try? NoteContentCodec.encode(fragment, context: .fragment) {
                pasteboard.addTypes([Self.fragmentType], owner: nil)
                pasteboard.setData(data, forType: Self.fragmentType)
            }
            return true
        }
        pasteboard.declareTypes(types, owner: nil)
        var wrote = false
        for type in types {
            switch type {
            case Self.fragmentType:
                if let data = try? NoteContentCodec.encode(fragment, context: .fragment) { wrote = pasteboard.setData(data, forType: type) || wrote }
            case .string:
                wrote = pasteboard.setString(NoteTextExport.plainText(fragment), forType: .string) || wrote
            case .rtf:
                let selected = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
                // Tables read as their rows of tab-separated text in rich text.
                var tables: [(NSRange, NoteTable)] = []
                selected.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selected.length)) { value, part, _ in
                    if let table = value as? NoteTableAttachment { tables.append((part, table.table)) }
                }
                for (part, table) in tables.reversed() {
                    selected.replaceCharacters(in: part, with: NSAttributedString(string: NoteTableText.tsv(table),
                                                                                  attributes: style.bodyAttributes))
                }
                if let data = try? selected.data(from: NSRange(location: 0, length: selected.length),
                                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    wrote = pasteboard.setData(data, forType: .rtf) || wrote
                }
            default:
                break
            }
        }
        return wrote
    }

    /// Paste identity rules: an object keeps its ID when it came from this
    /// note and is not in it now (cut then paste, a drag move); otherwise it
    /// is a new object with a new ID. An image from another note is copied
    /// into a new staged attachment for this note (committed with the text
    /// or never).
    private func preparePaste(_ fragment: NoteDocument, resolved: [UUID: StagedNoteAttachment]? = nil) -> (document: NoteDocument, copied: [StagedNoteAttachment])? {
        let sameNote = fragment.extras["sourceNoteID"]?.stringValue.flatMap(UUID.init(uuidString:)) == noteID
        var present = Set(objectIDs())
        var result = fragment
        result.extras = [:]
        var blocks: [NoteBlock] = []
        var copied: [StagedNoteAttachment] = []
        for var block in fragment.blocks {
            func fresh(_ id: UUID?) -> UUID {
                // A drag move within the note removes the originals right
                // after this insertion, so it keeps their IDs too.
                if sameNote, let id, isPerformingSelfMove || !present.contains(id) {
                    present.insert(id)
                    return id
                }
                let new = UUID()
                present.insert(new)
                return new
            }
            switch block.kind {
            case .checklist, .divider:
                block.id = fresh(block.id)
            case .table:
                let original = block.id
                block.id = fresh(block.id)
                if block.id != original { block.table = block.table?.withFreshIDs() }
            case .image, .file:
                guard let attachmentID = block.attachmentID else {
                    if block.kind == .file, block.importFailure != nil {
                        block.id = fresh(block.id)
                        break
                    }
                    continue
                }
                // An image from this note keeps its attachment (its row is
                // retained while any version or text shows it).
                if sameNote {
                    block.id = fresh(block.id)
                } else if var copy = resolved?[attachmentID] ?? imageProvider?.attachmentBytes(forAttachment: attachmentID), copy.payloadIsVerified {
                    let newID = UUID()
                    copy = copy.copying(id: newID)
                    copied.append(copy)
                    block.attachmentID = newID
                    block.id = fresh(nil)
                } else {
                    onNotice?(String(localized: "An attachment couldn’t be read. Nothing was pasted."))
                    return nil
                }
            case .text, .opaque:
                break
            }
            block.inlines = block.inlines.map { inline in
                var inline = inline
                inline.id = fresh(inline.id)
                return inline
            }
            blocks.append(block)
        }
        result.blocks = blocks
        return (result, copied)
    }

    /// Inserts a pasted fragment over the selection as one step.
    func paste(fragmentData data: Data, at selection: NSRange) -> Bool {
        guard !isReadOnly, rangeIsInStorage(selection),
              case let .editable(decoded) = NoteContentCodec.decode(data, context: .fragment) else { return false }
        return insertFragment(decoded, at: selection)
    }

    /// Resolve the whole private fragment before staging bytes or creating an
    /// Undo entry. The captured note, document, view and caret must still be
    /// current after every payload has been verified off the main actor.
    func pasteDurably(fragmentData data: Data, at selection: NSRange) async -> Bool {
        guard !isReadOnly, activity == .idle, rangeIsInStorage(selection),
              canPasteFragment?() != false else {
            onNotice?(String(localized: "The note or selection changed. Paste again at the new selection."))
            return false
        }
        guard case let .editable(decoded) = NoteContentCodec.decode(data, context: .fragment) else { return false }
        let destination = noteID
        let before = document()
        let view = textView
        let viewSelection = view?.selectedRange()
        var resolved: [UUID: StagedNoteAttachment] = [:]
        let sameNote = decoded.extras["sourceNoteID"]?.stringValue.flatMap(UUID.init(uuidString:)) == noteID
        for id in sameNote ? Set<UUID>() : Set(decoded.attachmentIDs) {
            let payload: StagedNoteAttachment?
            if let live = staged[id] { payload = live }
            else { payload = await imageProvider?.verifiedBytes(forAttachment: id) }
            guard let payload, payload.id == id, payload.payloadIsVerified else {
                onNotice?(String(localized: "An attachment couldn’t be read. Nothing was pasted."))
                return false
            }
            resolved[id] = payload
        }
        guard !Task.isCancelled, noteID == destination, activity == .idle,
              textView === view, view?.selectedRange() == viewSelection,
              canPasteFragment?() != false, document() == before,
              rangeIsInStorage(selection) else {
            onNotice?(String(localized: "The note or selection changed. Paste again at the new selection."))
            return false
        }
        return insertFragment(decoded, at: selection, resolved: resolved)
    }

    private func insertFragment(_ decoded: NoteDocument, at selection: NSRange,
                                resolved: [UUID: StagedNoteAttachment]? = nil) -> Bool {
        guard !isReadOnly, activity == .idle, rangeIsInStorage(selection),
              let prepared = preparePaste(decoded, resolved: resolved) else { return false }
        let fragment = prepared.document
        guard !fragment.blocks.isEmpty else { return false }
        let pasted = NoteTextCodec.attributedString(from: fragment, style: style, firstBlockIsTitle: false)
        let result = NSMutableAttributedString(attributedString: pasted)
        let string = textStorage.string as NSString
        let startsWithObject = fragment.blocks.first.map { $0.kind != .text } ?? false
        let endsWithBlockObject = fragment.blocks.last.map { $0.kind == .image || $0.kind == .file || $0.kind == .opaque } ?? false
        let atLineStart = selection.location == 0 || string.character(at: selection.location - 1) == 0x0A
        if startsWithObject, !atLineStart || selection.location == 0 {
            result.insert(NSAttributedString(string: "\n", attributes: style.bodyAttributes), at: 0)
        }
        if endsWithBlockObject, NSMaxRange(selection) < string.length,
           string.character(at: NSMaxRange(selection)) != 0x0A {
            result.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        let paste = pasteIncludingTail(result, replacing: selection)
        let candidateText = NSMutableAttributedString(attributedString: textStorage)
        candidateText.replaceCharacters(in: paste.range, with: paste.text)
        let candidate = NoteTextCodec.document(from: candidateText, template: template)
        if let failure = onFragmentAdmission?(candidate, prepared.copied) {
            onNotice?(failure)
            return false
        }
        for item in prepared.copied { staged[item.id] = item }
        guard performEdit(paste.range, with: paste.text, name: String(localized: "Paste"),
                          selection: NSRange(location: selection.location + result.length, length: 0)) else {
            // Refused: the images copied for it are dropped, so no row appears.
            for item in prepared.copied { staged[item.id] = nil }
            return false
        }
        return true
    }

    /// Plain text from another app, with line breaks made uniform.
    func pastePlainText(_ text: String, at selection: NSRange) -> Bool {
        if !isPastingAsPlainText, let table = NoteTablePaste.table(fromText: text) {
            return pasteTable(table, at: selection, sourceText: text)
        }
        let normalized = LegacyNoteMigration.normalizeLineBreaks(text).0
            .replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
        guard !normalized.isEmpty else { return false }
        // The destination's block style belongs to the first pasted paragraph
        // only; later lines are Body (never extra checklist/heading/quote lines).
        let destination = attributes(forParagraphAt: selection.location)
        let attributed = NSMutableAttributedString()
        let pasted = normalized as NSString
        let firstBreak = pasted.range(of: "\n")
        if firstBreak.location == NSNotFound {
            attributed.append(NSAttributedString(string: normalized, attributes: destination))
        } else {
            let head = NSRange(location: 0, length: NSMaxRange(firstBreak))
            attributed.append(NSAttributedString(string: pasted.substring(with: head), attributes: destination))
            attributed.append(NSAttributedString(string: pasted.substring(from: head.length), attributes: style.bodyAttributes))
        }
        history.beginGroup()
        defer { history.endGroup() }
        let paste = pasteIncludingTail(attributed, replacing: selection)
        guard performEdit(paste.range, with: paste.text, name: String(localized: "Paste"),
                          selection: NSRange(location: selection.location + attributed.length, length: 0)) else { return false }
        if selection.location > titleParagraphRange.length {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(location: 0, length: (normalized as NSString).length)
            for match in detector?.matches(in: normalized, range: range).reversed() ?? [] {
                guard let url = match.url?.absoluteString else { continue }
                _ = perform(.link(url), selection: NSRange(location: selection.location + match.range.location,
                                                           length: match.range.length))
            }
            textView?.setSelectedRange(NSRange(location: selection.location + attributed.length, length: 0))
        }
        return true
    }

    /// A paragraph has one block style. A multiline paste splits the old
    /// paragraph, so its surviving tail must take the final pasted line's
    /// style in this same undoable edit. Inline marks and objects survive;
    /// a block object on its own line is never swept into the replacement.
    func pasteIncludingTail(_ pasted: NSAttributedString, replacing selection: NSRange) -> (range: NSRange, text: NSAttributedString) {
        guard pasted.string.contains("\n"), NSMaxRange(selection) < textStorage.length,
              !isBlockObject(at: NSMaxRange(selection)) else { return (selection, pasted) }
        let tailStart = NSMaxRange(selection)
        let line = lineRange(at: tailStart)
        let stringBefore = textStorage.string as NSString
        let separator = NSMaxRange(line) < textStorage.length && stringBefore.character(at: NSMaxRange(line)) == 0x0A ? 1 : 0
        let tailLength = NSMaxRange(line) - tailStart + separator
        guard tailLength > 0 else { return (selection, pasted) }
        let tail = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: NSRange(location: tailStart, length: tailLength)))
        let string = pasted.string as NSString
        let lastLine = string.range(of: "\n", options: .backwards).location + 1
        let attributes = lastLine < pasted.length ? pasted.attributes(at: lastLine, effectiveRange: nil) : style.bodyAttributes
        let all = NSRange(location: 0, length: tail.length)
        for key in [NSAttributedString.Key.noteBlockStyle, .noteBlockLevel, .noteBlockIndent] {
            tail.removeAttribute(key, range: all)
            if let value = attributes[key] { tail.addAttribute(key, value: value, range: all) }
        }
        let result = NSMutableAttributedString(attributedString: pasted)
        result.append(tail)
        return (NSRange(location: selection.location, length: selection.length + tailLength), result)
    }

    // MARK: Accessibility

    /// One element per object, in reading order, for VoiceOver (stock
    /// TextKit 2 exposes none).
    func accessibilityElements(for textView: NSTextView) -> [NSAccessibilityElement] {
        objects().filter { !($0.0 is NoteTableAttachment) }.map { object, range in
            NoteObjectAccessibilityElement(engine: self, textView: textView, object: object, range: range)
        }
    }

    func lineText(at location: Int) -> String {
        let line = lineRange(at: location)
        let text = (textStorage.string as NSString).substring(with: line)
        return text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
    }

    /// The tables' hosted views, in reading order (VoiceOver reads each as
    /// a table).
    func tableViews() -> [NoteTableView] {
        objects().compactMap { ($0.0 as? NoteTableAttachment)?.hostedView }
    }

    /// The caret's rectangle at `location`, in the text view's coordinates.
    func caretRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textView, let start = textRange(for: NSRange(location: location, length: 0))?.location else { return nil }
        var rect: NSRect?
        layoutManager.enumerateTextSegments(in: NSTextRange(location: start), type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        return rect.map { $0.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y) }
    }

    /// The object's rectangle in the text view's coordinates.
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textRange = textRange(for: range), let textView else { return nil }
        var rect: NSRect?
        layoutManager.ensureLayout(for: textRange)
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rect = rect.map { $0.union(frame) } ?? frame
            return true
        }
        return rect.map { $0.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y) }
    }
}

/// VoiceOver's view of one object in the text.
final class NoteObjectAccessibilityElement: NSAccessibilityElement {
    private weak var engine: NoteEditorEngine?
    private weak var textView: NSTextView?
    private let object: NoteObjectAttachment
    private let range: NSRange

    @MainActor
    init(engine: NoteEditorEngine, textView: NSTextView, object: NoteObjectAttachment, range: NSRange) {
        self.engine = engine
        self.textView = textView
        self.object = object
        self.range = range
        super.init()
        setAccessibilityParent(textView)
        switch object {
        case let box as NoteChecklistAttachment:
            setAccessibilityRole(.checkBox)
            setAccessibilityLabel(engine.lineText(at: range.location))
            setAccessibilityValue(box.isChecked ? 1 : 0)
        case is NoteImageAttachment:
            setAccessibilityRole(.image)
            setAccessibilityLabel(object.accessibilityDescription)
        case is NoteFileAttachment:
            setAccessibilityRole(.button)
            setAccessibilityLabel(object.accessibilityDescription)
        case is NoteDateAttachment:
            setAccessibilityRole(.button)
            setAccessibilityLabel(object.accessibilityDescription)
        default:
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(object.accessibilityDescription)
        }
        if object is NoteImageAttachment || object is NoteFileAttachment {
            let state = engine.objectState(for: object)
            let actions: [(String, NoteObjectCommand)] = [
                (String(localized: "Quick Look"), .quickLook),
                (String(localized: "Open"), .open),
                (String(localized: "Copy Image"), .copyImage),
                (String(localized: "Copy File"), .copyFile),
                (String(localized: "Export Copy"), .exportCopy(nil)),
                (String(localized: "Show in Finder"), .showInFinder),
                (String(localized: "Small"), .sizePreset(.small)),
                (String(localized: "Medium"), .sizePreset(.medium)),
                (String(localized: "Full"), .sizePreset(.full)),
                (String(localized: "Retry"), .retry),
                (String(localized: "Retry Preview"), .retryPreview),
                (String(localized: "Locate"), .locate),
                // The word drawn on the object and in its menu: Remove for
                // a failure, Delete Image or Delete File otherwise.
                (state == .ready ? (object is NoteImageAttachment ? String(localized: "Delete Image")
                    : String(localized: "Delete File")) : String(localized: "Remove"), .delete)
            ]
            setAccessibilityCustomActions(actions.compactMap { title, command in
                guard engine.validate(command, object: object, state: state).enabled else { return nil }
                return NSAccessibilityCustomAction(name: title) { [weak engine, id = object.objectID] in
                    MainActor.assumeIsolated {
                        guard let engine, engine.validate(command, objectID: id).enabled else { return false }
                        Task { _ = await engine.perform(command, objectID: id) }
                        return true
                    }
                }
            })
        }
    }

    var objectID: UUID { object.objectID }

    /// Computed when asked, so listing a long note's objects never forces
    /// layout of the whole note.
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated {
            guard let engine, let textView, let window = textView.window,
                  let rect = engine.rect(for: range) else { return .zero }
            return window.convertToScreen(textView.convert(rect, to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if object is NoteChecklistAttachment {
            MainActor.assumeIsolated { engine?.toggleCheckbox(atLineOf: range.location) }
            return true
        }
        if object is NoteImageAttachment || object is NoteFileAttachment {
            return MainActor.assumeIsolated {
                guard let engine, engine.validate(.quickLook, objectID: object.objectID).enabled else { return false }
                Task { _ = await engine.perform(.quickLook, objectID: object.objectID) }
                return true
            }
        }
        return false
    }
}

// MARK: - Title and tags (Phase 2, slice 2)

/// The first paragraph is the title (UX plan § 3.3): it wraps without a
/// limit, Return moves into the body, Backspace at the body's start joins
/// ordinary text into it (an object is selected first and never joins), and
/// `#word` then Space or Return takes a tag as one Undo step. Pasted
/// hashtags stay text: only a typed Space or Return converts.
extension NoteEditorEngine {
    /// The title paragraph, without its line break.
    var titleParagraphRange: NSRange { lineRange(at: 0) }

    /// Replaces the note's tags (the tag editor, a store refresh). Not an
    /// Undo step: tags are metadata, and the title shorthand's own steps
    /// carry only the tag they added.
    func setTags(_ newTags: [String]) {
        let normalized = AtticTag.normalizedSet(newTags)
        guard normalized != tags else { return }
        tags = normalized
        notifyTagsChanged()
    }

    /// The tag picker joins the editor history; store refreshes keep using
    /// `setTags` so an external update is not an accidental Undo step.
    func setTagsFromPicker(_ newTags: [String]) {
        guard !isReadOnly, activity == .idle else { return }
        let normalized = AtticTag.normalizedSet(newTags)
        guard normalized != tags else { return }
        history.recordTagChange(before: tags, after: normalized)
        setTags(normalized)
    }

    /// The `#word` just before the caret in the title, when it would become
    /// a tag: at a word boundary, letters, numbers, `-` and `_`, with a
    /// letter (the add bar's rule, so "#42" stays text).
    /// The `#word` being typed in the title that Space or Return would take
    /// (nil when it stays text: Esc, or an Undo of its conversion).
    var activeTitleHashtag: (range: NSRange, tag: String)? {
        guard activity == .idle, let pending = pendingTitleHashtag(), literalHashLocation != pending.range.location else {
            return nil
        }
        return pending
    }

    private func pendingTitleHashtag() -> (range: NSRange, tag: String)? {
        guard !isReadOnly, let textView, !textView.hasMarkedText() else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let title = titleParagraphRange
        guard selection.location > title.location, selection.location <= NSMaxRange(title) else { return nil }
        let string = textStorage.string as NSString
        var start = selection.location
        while start > title.location {
            let unit = string.character(at: start - 1)
            if unit == 0x23 {
                start -= 1
                break
            }
            guard let scalar = UnicodeScalar(unit),
                  CharacterSet.alphanumerics.contains(scalar) || unit == 0x2D || unit == 0x5F else { return nil }
            start -= 1
        }
        guard start < selection.location, string.character(at: start) == 0x23 else { return nil }
        if start > title.location {
            guard let scalar = UnicodeScalar(string.character(at: start - 1)),
                  CharacterSet.whitespaces.contains(scalar) else { return nil }
        }
        let range = NSRange(location: start, length: selection.location - start)
        guard !rangeContainsObject(range), let tag = TaskTextParser.tag(string.substring(with: range)) else { return nil }
        return (range, tag)
    }

    /// Space or Return after `#word` in the title: the word leaves the title
    /// and joins the tags at once, as one Undo step (one ⌘Z brings the text
    /// back and removes the tag). Returns false when nothing was taken.
    /// `chosen` takes a suggested tag in place of the typed word.
    @discardableResult
    func takeTitleHashtag(as chosen: String? = nil) -> Bool {
        guard activity == .idle, let (range, typed) = pendingTitleHashtag(), literalHashLocation != range.location else {
            return false
        }
        guard let tag = chosen.flatMap(AtticTag.normalize) ?? Optional(typed) else { return false }
        let isNew = !tags.contains(tag)
        guard performEdit(range, with: NSAttributedString(), name: String(localized: "Add Tag"),
                          selection: NSRange(location: range.location, length: 0)) else { return false }
        history.attachTagToLast(tag, changesTags: isNew)
        if isNew {
            tags = AtticTag.normalizedSet(tags + [tag])
            notifyTagsChanged()
        }
        return true
    }

    /// Esc right after a `#word` that would become a tag: it stays text and
    /// does not convert again until its `#` is typed again.
    func keepTitleHashtagLiteral() -> Bool {
        guard let (range, _) = pendingTitleHashtag(), literalHashLocation != range.location else { return false }
        literalHashLocation = range.location
        return true
    }

    /// An Undo or Redo of a title shorthand step. Undo leaves the hashtag
    /// literal, so the next Space does not take it again.
    fileprivate func didFlipTag(_ tag: String, add: Bool, changesTags: Bool, range: NSRange) {
        if !add {
            let string = textStorage.string as NSString
            if range.length > 0, NSMaxRange(range) <= string.length, string.character(at: range.location) == 0x23 {
                literalHashLocation = range.location
            }
        }
        guard changesTags else { return }
        if add {
            tags = AtticTag.normalizedSet(tags + [tag])
        } else {
            tags.removeAll { $0 == tag }
        }
        notifyTagsChanged()
    }

    // MARK: Title boundaries

    /// Return at the end of the title when the body's first line is empty:
    /// the caret moves into it instead of adding another empty line.
    func enterBodyFromTitleEnd() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        let title = titleParagraphRange
        guard selection.length == 0, selection.location == NSMaxRange(title),
              NSMaxRange(title) < textStorage.length else { return false }
        let next = lineRange(at: NSMaxRange(title) + 1)
        guard next.length == 0 else { return false }
        textView.setSelectedRange(NSRange(location: next.location, length: 0))
        return true
    }

    /// Tab in the title (OD-7): the caret goes to the start of the body,
    /// as on a form; a note with no body yet gets its first body line, as
    /// Return at the title's end gives it. False outside the title (the
    /// body keeps Tab for indenting).
    func moveFromTitleToBody() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        let title = titleParagraphRange
        let selection = textView.selectedRange()
        guard selection.location <= NSMaxRange(title), NSMaxRange(selection) <= NSMaxRange(title) else { return false }
        if NSMaxRange(title) < textStorage.length {
            let body = NSRange(location: NSMaxRange(title) + 1, length: 0)
            textView.setSelectedRange(body)
            textView.scrollRangeToVisible(body)
        } else {
            textView.setSelectedRange(NSRange(location: NSMaxRange(title), length: 0))
            textView.insertNewline(nil)
        }
        return true
    }

    /// The title's first and last line, in the text view's coordinates
    /// (only the title is laid out). An empty note gives its first line.
    func titleLineRects() -> (first: NSRect, last: NSRect)? {
        guard let layoutManager, let textView else { return nil }
        let origin = textView.textContainerOrigin
        let empty = NSRect(x: origin.x, y: origin.y, width: 0, height: NoteTextStyle.titleLineHeight)
        guard textStorage.length > 0 else { return (empty, empty) }
        let start = contentStorage.documentRange.location
        layoutManager.ensureLayout(for: NSTextRange(location: start))
        guard let fragment = layoutManager.textLayoutFragment(for: start),
              let firstLine = fragment.textLineFragments.first,
              let lastLine = fragment.textLineFragments.last else { return (empty, empty) }
        let frame = fragment.layoutFragmentFrame
        func rect(_ line: NSTextLineFragment) -> NSRect {
            let bounds = line.typographicBounds
            return NSRect(x: origin.x + frame.minX + bounds.minX, y: origin.y + frame.minY + bounds.minY,
                          width: bounds.width, height: bounds.height)
        }
        return (rect(firstLine), rect(lastLine))
    }
}

// MARK: - Format (the paragraphs at the caret or selection)

/// A paragraph's format as ⋯ › Format offers it in this slice.
enum NoteParagraphFormat: Equatable {
    case body, checklist
}

extension NoteEditorEngine {
    /// The body paragraphs the caret or selection touches (never the title,
    /// never a line an image or other block object leads). A selection that
    /// ends right after a line break does not reach into the next line.
    func formattableParagraphs(in selection: NSRange) -> [NSRange] {
        let string = textStorage.string as NSString
        guard string.length > 0 else { return [] }
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= string.length,
           string.character(at: end - 1) == 0x0A { end -= 1 }
        var location = min(selection.location, string.length)
        var result: [NSRange] = []
        while true {
            let line = lineRange(at: location)
            if line.location > 0, !isBlockObject(at: line.location) { result.append(line) }
            let next = NSMaxRange(line) + 1
            guard next <= end, next <= string.length, NSMaxRange(line) < string.length else { break }
            location = next
        }
        return result
    }

    /// What the touched paragraphs are now: checklist only when every one is.
    func paragraphFormat(in selection: NSRange) -> NoteParagraphFormat? {
        let lines = formattableParagraphs(in: selection)
        guard !lines.isEmpty else { return nil }
        return lines.allSatisfy { checklistBox(inParagraphAt: $0.location) != nil } ? .checklist : .body
    }

    /// ⋯ › Format: sets the paragraphs at the caret, or every paragraph the
    /// selection touches, to `format` (one Undo step); nothing else in the
    /// note changes. The title is never formatted.
    @discardableResult
    func applyParagraphFormat(_ format: NoteParagraphFormat, to range: NSRange? = nil) -> Bool {
        guard !isReadOnly else { return false }
        let selection = range ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let lines = formattableParagraphs(in: selection)
        let changes = lines.filter { (checklistBox(inParagraphAt: $0.location) != nil) != (format == .checklist) }
        guard !changes.isEmpty else { return false }
        var newSelection = selection
        history.beginGroup()
        defer { history.endGroup() }
        // From the end, so earlier locations stay valid.
        for line in changes.reversed() {
            switch format {
            case .checklist:
                let box = NoteChecklistAttachment(isChecked: false)
                renderer.apply(to: box, today: today)
                guard performEdit(NSRange(location: line.location, length: 0),
                                  with: NoteTextCodec.attachmentString(box, attributes: style.bodyAttributes),
                                  name: String(localized: "Checklist")) else { return false }
                if line.location <= newSelection.location { newSelection.location += 1 }
                else if line.location < NSMaxRange(newSelection) { newSelection.length += 1 }
            case .body:
                guard performEdit(NSRange(location: line.location, length: 1), with: NSAttributedString(),
                                  name: String(localized: "Body")) else { return false }
                if line.location < newSelection.location { newSelection.location -= 1 }
                else if line.location < NSMaxRange(newSelection) { newSelection.length = max(0, newSelection.length - 1) }
            }
        }
        let length = textStorage.length
        textView?.setSelectedRange(NSRange(location: min(newSelection.location, length),
                                           length: min(newSelection.length, max(0, length - newSelection.location))))
        return true
    }
}
/// The structure and inline action vocabulary shared by all Notes controls.
enum NoteParagraphStyle: Hashable {
    case body, heading(Int), bullet, number, checklist, quote, mono

    var storageName: String? {
        switch self {
        case .body: nil
        case .heading: "heading"
        case .bullet: "bullet"
        case .number: "number"
        case .checklist: nil
        case .quote: "quote"
        case .mono: "mono"
        }
    }
    var level: Int? { if case let .heading(level) = self { level } else { nil } }
}

enum NoteFormatCommand: Hashable {
    case paragraph(NoteParagraphStyle)
    case mark(NoteMark.Kind)
    case link(String), removeLink
    case indent, outdent, divider, toggleChecklist, moveUp, moveDown, date(NoteDay)
    /// Insert a table (2 × 3, with its header row) after the caret's line.
    case table

    var title: String {
        switch self {
        case .paragraph(.body): "Body"
        case .paragraph(.heading(1)): "Title"
        case .paragraph(.heading(2)): "Heading"
        case .paragraph(.heading): "Subheading"
        case .paragraph(.bullet): "Bulleted List"
        case .paragraph(.number): "Numbered List"
        case .paragraph(.checklist): "Checklist"
        case .paragraph(.quote): "Quote"
        case .paragraph(.mono): "Mono"
        case .mark(.bold): "Bold"
        case .mark(.italic): "Italic"
        case .mark(.underline): "Underline"
        case .mark(.strikethrough): "Strikethrough"
        case .mark(.code): "Code"
        case .mark(.highlight): "Highlight"
        case .mark(.link), .link: "Link"
        case .removeLink: "Remove Link"
        case .indent: "Indent"
        case .outdent: "Outdent"
        case .divider: "Divider"
        case .toggleChecklist: "Check or Uncheck"
        case .moveUp: "Move Line Up"
        case .moveDown: "Move Line Down"
        case .date: "Date"
        case .table: "Table"
        }
    }

    var symbolName: String {
        switch self {
        case .paragraph(.body): "text.alignleft"
        case .paragraph(.heading): "textformat.size"
        case .paragraph(.bullet): "list.bullet"
        case .paragraph(.number): "list.number"
        case .paragraph(.checklist), .toggleChecklist: "checklist"
        case .paragraph(.quote): "text.quote"
        case .paragraph(.mono), .mark(.code): "chevron.left.forwardslash.chevron.right"
        case .mark(.bold): "bold"
        case .mark(.italic): "italic"
        case .mark(.underline): "underline"
        case .mark(.strikethrough): "strikethrough"
        case .mark(.highlight): "highlighter"
        case .mark(.link), .link, .removeLink: "link"
        case .indent: "increase.indent"
        case .outdent: "decrease.indent"
        case .divider: "minus"
        case .moveUp: "arrow.up"
        case .moveDown: "arrow.down"
        case .date: "calendar"
        case .table: "tablecells"
        }
    }

    /// Display notation for menus; `NoteEditorTextView` owns the key route.
    var shortcut: String? {
        switch self {
        case .mark(.bold): "⌘B"
        case .mark(.italic): "⌘I"
        case .mark(.underline): "⌘U"
        case .mark(.strikethrough): "⇧⌘X"
        case .mark(.link), .link: "⇧⌘K"
        case .paragraph(.heading(1)): "⌥⌘1"
        case .paragraph(.heading(2)): "⌥⌘2"
        case .paragraph(.heading): "⌥⌘3"
        case .paragraph(.body): "⌥⌘0"
        case .paragraph(.bullet): "⇧⌘7"
        case .paragraph(.number): "⇧⌘8"
        case .paragraph(.checklist): "⇧⌘9"
        case .paragraph(.quote): "⌥⌘4"
        case .paragraph(.mono): "⌥⌘5"
        case .indent: "⌘]"
        case .outdent: "⌘["
        case .toggleChecklist: "⌘Return"
        case .moveUp: "⌥⌘↑"
        case .moveDown: "⌥⌘↓"
        case .table: "⌥⌘T"
        default: nil
        }
    }
}

enum NoteFormatState: Equatable { case off, on, mixed }
struct NoteCommandValidation: Equatable {
    var enabled: Bool
    var state: NoteFormatState
}
struct NoteFormattingState {
    var paragraph: NoteParagraphStyle?
    var indent: Int?
    var marks: [NoteMark.Kind: NoteFormatState]
    var linkURL: String?
    var commands: [NoteFormatCommand: NoteCommandValidation]
}

struct NoteLinkTarget: Equatable {
    var noteID: UUID
    /// Full linked run when a caret is inside one; otherwise the selection.
    var range: NSRange
    var selection: NSRange
    var text: String
    var url: String?
    var capturedText: NoteCapturedTextTarget { .init(noteID: noteID, range: range, literal: text) }
}

struct NoteCapturedTextTarget: Equatable {
    var noteID: UUID
    var range: NSRange
    var literal: String
}

@MainActor
extension NoteEditorEngine {
    func paragraphStyle(at location: Int) -> NoteParagraphStyle? {
        let line = lineRange(at: location)
        guard line.location > 0, !isBlockObject(at: line.location) else { return nil }
        if let pending = pendingParagraphStyle, pending.location == line.location { return pending.state.style }
        if checklistBox(inParagraphAt: location) != nil { return .checklist }
        guard line.location < textStorage.length else { return .body }
        let attrs = textStorage.attributes(at: line.location, effectiveRange: nil)
        switch attrs[.noteBlockStyle] as? String {
        case "heading": return .heading(attrs[.noteBlockLevel] as? Int ?? 2)
        case "bullet": return .bullet
        case "number": return .number
        case "quote": return .quote
        case "mono": return .mono
        default: return .body
        }
    }

    func formattingState(for selection: NSRange) -> NoteFormattingState {
        let lines = formattableParagraphs(in: selection)
        let styles = lines.compactMap { paragraphStyle(at: $0.location) }
        let paragraph = styles.first.flatMap { first in styles.allSatisfy { $0 == first } ? first : nil }
        let depths = lines.map { indentAt($0.location) ?? 0 }
        let indent = depths.first.flatMap { first in depths.allSatisfy { $0 == first } ? first : nil }
        var marks: [NoteMark.Kind: NoteFormatState] = [:]
        for kind in NoteMark.Kind.allCases { marks[kind] = markState(kind, selection: selection) }
        let index = min(selection.location, max(0, textStorage.length - 1))
        let url = textStorage.length > 0 ? textStorage.attribute(.noteMark(.link), at: index, effectiveRange: nil) as? String : nil
        let commands: [NoteFormatCommand] = [
            .paragraph(.body), .paragraph(.heading(1)), .paragraph(.heading(2)), .paragraph(.heading(3)),
            .paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .paragraph(.quote), .paragraph(.mono),
            .indent, .outdent, .divider, .toggleChecklist, .moveUp, .moveDown
        ] + NoteMark.Kind.allCases.map { .mark($0) }
        return NoteFormattingState(paragraph: paragraph, indent: indent, marks: marks, linkURL: url,
                                   commands: Dictionary(uniqueKeysWithValues: commands.map { ($0, validate($0, selection: selection)) }))
    }

    func captureLinkTarget(selection: NSRange? = nil) -> NoteLinkTarget? {
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        guard !isReadOnly, activity == .idle, selection.location > titleParagraphRange.length,
              rangeIsInStorage(selection) else { return nil }
        var range = selection
        var url: String?
        if selection.length == 0 {
            guard selection.location < textStorage.length else { return nil }
            var effective = NSRange()
            url = textStorage.attribute(.noteMark(.link), at: selection.location, effectiveRange: &effective) as? String
            guard url != nil, selection.location > effective.location,
                  selection.location < NSMaxRange(effective) else { return nil }
            range = effective
        } else {
            var effective = NSRange()
            if let existing = textStorage.attribute(.noteMark(.link), at: selection.location, effectiveRange: &effective) as? String,
               NSMaxRange(selection) <= NSMaxRange(effective) {
                range = effective
                url = existing
            }
        }
        guard range.length > 0 else { return nil }
        return NoteLinkTarget(noteID: noteID, range: range, selection: selection,
                              text: (textStorage.string as NSString).substring(with: range), url: url)
    }

    @discardableResult
    func commitLink(_ url: String, target: NoteLinkTarget) -> Bool {
        guard pendingLinkTarget == target, target.noteID == noteID,
              textView?.selectedRange() == target.selection,
              validCapturedText(target.capturedText),
              validate(.link(url), selection: target.range).enabled,
              captureLinkTarget(selection: target.selection)?.url == target.url else {
            pendingLinkTarget = nil
            return false
        }
        pendingLinkTarget = nil
        let applied = applyMark(.link, url: url, selection: target.range)
        if applied { textView?.setSelectedRange(target.selection) }
        return applied
    }

    func cancelLinkRequest() { pendingLinkTarget = nil }

    func validate(_ command: NoteFormatCommand, selection: NSRange? = nil) -> NoteCommandValidation {
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        guard !isReadOnly, activity == .idle, rangeIsInStorage(selection) else {
            return NoteCommandValidation(enabled: false, state: .off)
        }
        let lines = formattableParagraphs(in: selection)
        switch command {
        case let .paragraph(style):
            let values = lines.compactMap { paragraphStyle(at: $0.location) }
            let state: NoteFormatState = values.isEmpty ? .off :
                (values.allSatisfy { $0 == style } ? .on : (values.contains(style) ? .mixed : .off))
            return NoteCommandValidation(enabled: !lines.isEmpty, state: state)
        case let .mark(kind):
            let inBody = selection.location > titleParagraphRange.length || selection.length > 0
            return NoteCommandValidation(enabled: inBody && (kind != .link || captureLinkTarget(selection: selection) != nil),
                                         state: markState(kind, selection: selection))
        case let .link(url):
            let parsed = URL(string: url)
            return NoteCommandValidation(enabled: captureLinkTarget(selection: selection) != nil &&
                                         (parsed?.scheme == "https" || parsed?.scheme == "http") && parsed?.host != nil,
                                         state: markState(.link, selection: selection))
        case .removeLink:
            return NoteCommandValidation(enabled: markState(.link, selection: selection) != .off,
                                         state: markState(.link, selection: selection))
        case .indent:
            return NoteCommandValidation(enabled: lines.contains { line in
                guard let style = paragraphStyle(at: line.location), [.bullet, .number, .checklist, .quote].contains(style) else { return false }
                return (indentAt(line.location) ?? 0) < 2
            }, state: .off)
        case .outdent:
            return NoteCommandValidation(enabled: lines.contains { (indentAt($0.location) ?? 0) > 0 }, state: .off)
        case .toggleChecklist:
            return NoteCommandValidation(enabled: lines.contains { checklistBox(inParagraphAt: $0.location) != nil }, state: .off)
        case .divider:
            return NoteCommandValidation(enabled: !lines.isEmpty, state: .off)
        case .moveUp:
            return NoteCommandValidation(enabled: !lines.isEmpty && lines[0].location > titleParagraphRange.length + 1, state: .off)
        case .moveDown:
            return NoteCommandValidation(enabled: !lines.isEmpty && NSMaxRange(lines[lines.count - 1]) < textStorage.length - 1, state: .off)
        case .date:
            return NoteCommandValidation(enabled: selection.location > titleParagraphRange.length, state: .off)
        case .table:
            // On while the keyboard is in a table (Aa's row is then the table's tools).
            return NoteCommandValidation(enabled: true, state: focusedTable != nil ? .on : .off)
        }
    }

    @discardableResult
    func perform(_ command: NoteFormatCommand, selection: NSRange? = nil) -> Bool {
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        guard validate(command, selection: selection).enabled else { return false }
        switch command {
        case let .paragraph(style): return applyStyle(style, selection: selection)
        case let .mark(kind):
            if kind == .link {
                guard let onLinkRequest, let target = captureLinkTarget(selection: selection) else { return false }
                pendingLinkTarget = target
                onLinkRequest(target)
                return true
            }
            return applyMark(kind, url: nil, selection: selection)
        case let .link(url): return applyMark(.link, url: url, selection: selection)
        case .removeLink: return removeLink(selection: selection)
        case .indent: return changeIndent(1, selection: selection)
        case .outdent: return changeIndent(-1, selection: selection)
        case .divider: return insertDivider(selection: selection)
        case .toggleChecklist:
            toggleCheckbox(atLineOf: selection.location)
            return true
        case .moveUp: return moveLine(up: true, selection: selection)
        case .moveDown: return moveLine(up: false, selection: selection)
        case let .date(day): return insertDate(day, at: selection)
        case .table:
            guard focusedTable == nil else { return false }
            return insertTable(at: selection)
        }
    }

    private func indentAt(_ location: Int) -> Int? {
        if let pending = pendingParagraphStyle, pending.location == lineRange(at: location).location {
            return pending.state.indent
        }
        guard location < textStorage.length else { return nil }
        return textStorage.attribute(.noteBlockIndent, at: location, effectiveRange: nil) as? Int
    }

    private func markState(_ kind: NoteMark.Kind, selection: NSRange) -> NoteFormatState {
        if selection.length == 0 {
            return textView?.typingAttributes[.noteMark(kind)] != nil ? .on : .off
        }
        var marked = false
        var plain = false
        let string = textStorage.string as NSString
        let substantive = CharacterSet(charactersIn: "\n\u{FFFC}").inverted
        textStorage.enumerateAttribute(.noteMark(kind), in: selection) { value, run, stop in
            guard string.rangeOfCharacter(from: substantive, options: [], range: run).location != NSNotFound else { return }
            if value == nil { plain = true } else { marked = true }
            if marked && plain { stop.pointee = true }
        }
        if !marked { return .off }
        return plain ? .mixed : .on
    }

    private func applyMark(_ kind: NoteMark.Kind, url: String?, selection: NSRange) -> Bool {
        if selection.length == 0, let textView {
            let wasOn = textView.typingAttributes[.noteMark(kind)] != nil
            history.recordTypingMarkChange(kind, before: wasOn, after: !wasOn)
            setTypingMark(kind, enabled: !wasOn)
            history.breakCoalescing()
            return true
        }
        let turnOn = kind == .link || markState(kind, selection: selection) != .on
        let original = textStorage.attributedSubstring(from: selection)
        let replacement = NSMutableAttributedString(attributedString: original)
        var start = 0
        let characters = replacement.string as NSString
        while start < replacement.length {
            let unit = characters.character(at: start)
            let isObject = unit == NoteDocument.objectUnit || unit == 0x0A
            let range = characters.rangeOfComposedCharacterSequence(at: start)
            if !isObject {
                if turnOn { replacement.addAttribute(.noteMark(kind), value: url ?? true, range: range) }
                else { replacement.removeAttribute(.noteMark(kind), range: range) }
            }
            start = NSMaxRange(range)
        }
        // Restyle will reapply surviving marks. Remove presentation attrs
        // of the turned-off mark before replacing so they cannot linger.
        if !turnOn {
            switch kind {
            case .bold, .italic, .code: replacement.removeAttribute(.font, range: NSRange(location: 0, length: replacement.length))
            case .underline, .link: replacement.removeAttribute(.underlineStyle, range: NSRange(location: 0, length: replacement.length))
            case .strikethrough: replacement.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: replacement.length))
            case .highlight: replacement.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: replacement.length))
            }
            if kind == .link { replacement.removeAttribute(.link, range: NSRange(location: 0, length: replacement.length)) }
        }
        return performEdit(selection, with: replacement, name: commandName(kind), selection: selection)
    }

    private func commandName(_ kind: NoteMark.Kind) -> String { NoteFormatCommand.mark(kind).title }

    private func setTypingMark(_ kind: NoteMark.Kind, enabled: Bool) {
        guard let textView else { return }
        var attributes = textView.typingAttributes
        attributes[.noteMark(kind)] = enabled ? true : nil
        for key in [NSAttributedString.Key.link, .underlineStyle, .strikethroughStyle, .backgroundColor] { attributes[key] = nil }
        let base = self.attributes(forParagraphAt: textView.selectedRange().location)
        let marks = Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.compactMap { mark in
            attributes[.noteMark(mark)].map { (mark, $0) }
        })
        attributes.merge(style.markedAttributes(marks: marks, baseFont: base[.font] as? NSFont ?? style.bodyFont)) { _, new in new }
        textView.typingAttributes = attributes
        updateTextChecking()
    }

    private func removeLink(selection: NSRange) -> Bool {
        var range = selection
        if range.length == 0, textStorage.length > 0 {
            var effective = NSRange()
            let index = min(range.location, textStorage.length - 1)
            guard textStorage.attribute(.noteMark(.link), at: index, effectiveRange: &effective) != nil else { return false }
            range = effective
        }
        guard range.length > 0 else { return false }
        let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        let all = NSRange(location: 0, length: replacement.length)
        replacement.removeAttribute(.noteMark(.link), range: all)
        replacement.removeAttribute(.link, range: all)
        replacement.removeAttribute(.underlineStyle, range: all)
        return performEdit(range, with: replacement, name: "Remove Link", selection: selection)
    }

    private func applyStyle(_ styleValue: NoteParagraphStyle, selection: NSRange) -> Bool {
        if styleValue == .checklist {
            history.beginGroup()
            defer { history.endGroup() }
            for line in formattableParagraphs(in: selection).reversed() {
                if let current = paragraphStyle(at: line.location), current != .body && current != .checklist {
                    _ = applyStyle(.body, selection: NSRange(location: line.location, length: 0))
                }
            }
            return applyParagraphFormat(.checklist, to: selection)
        }
        let lines = formattableParagraphs(in: selection)
        guard !lines.isEmpty else { return false }
        var newSelection = selection
        history.beginGroup()
        defer { history.endGroup() }
        for line in lines.reversed() {
            let string = textStorage.string as NSString
            let hasBreak = NSMaxRange(line) < string.length && string.character(at: NSMaxRange(line)) == 0x0A
            let range = NSRange(location: line.location, length: line.length + (hasBreak ? 1 : 0))
            if range.length == 0 {
                let before = paragraphStyle(at: line.location) ?? .body
                guard before != styleValue else { continue }
                let oldDepth = pendingParagraphStyle?.location == line.location ? pendingParagraphStyle!.state.indent : (indentAt(line.location) ?? 0)
                let newDepth = [.bullet, .number, .checklist, .quote].contains(styleValue) ? oldDepth : 0
                history.recordParagraphStyleChange(location: line.location,
                    before: pendingParagraphStyle?.state ?? .init(style: before, indent: oldDepth),
                    after: .init(style: styleValue, indent: newDepth, block: pendingParagraphStyle?.state.block))
                setPendingParagraphStyle(styleValue, indent: newDepth, at: line.location)
                continue
            }
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
            if checklistBox(inParagraphAt: line.location) != nil {
                replacement.deleteCharacters(in: NSRange(location: 0, length: 1))
                if line.location < newSelection.location { newSelection.location -= 1 }
                else if line.location < NSMaxRange(newSelection) { newSelection.length = max(0, newSelection.length - 1) }
            }
            let all = NSRange(location: 0, length: replacement.length)
            replacement.removeAttribute(.noteBlockStyle, range: all)
            replacement.removeAttribute(.noteBlockLevel, range: all)
            replacement.removeAttribute(.noteBlockIndent, range: all)
            if let name = styleValue.storageName { replacement.addAttribute(.noteBlockStyle, value: name, range: all) }
            if let level = styleValue.level { replacement.addAttribute(.noteBlockLevel, value: level, range: all) }
            if !performEdit(range, with: replacement, name: NoteFormatCommand.paragraph(styleValue).title) { return false }
        }
        textView?.setSelectedRange(newSelection)
        return true
    }

    private func block(for state: NoteUndoHistory.ParagraphState) -> NoteBlock {
        var block = state.block ?? .text("")
        block.style = state.style.storageName ?? (block.style == "body" ? "body" : nil)
        block.level = state.style.level
        block.indent = state.indent > 0 ? state.indent : (block.indent == 0 ? 0 : nil)
        return block
    }

    private func emptyParagraphBlock() -> NoteBlock? {
        guard let pending = pendingParagraphStyle, pending.location == textStorage.length,
              textStorage.length > 0,
              (textStorage.string as NSString).character(at: textStorage.length - 1) == 0x0A else { return nil }
        return block(for: pending.state)
    }

    private func restoreEmptyParagraph(_ block: NoteBlock?) {
        if let block {
            let paragraph: NoteParagraphStyle = switch block.style {
            case "heading": .heading(block.level ?? 2)
            case "bullet": .bullet
            case "number": .number
            case "quote": .quote
            case "mono": .mono
            default: .body
            }
            pendingParagraphStyle = (textStorage.length, .init(style: paragraph, indent: block.indent ?? 0, block: block))
        } else { pendingParagraphStyle = nil }
        documentCache = nil
        textView?.typingAttributes = attributes(forParagraphAt: textView?.selectedRange().location ?? textStorage.length)
    }

    private func setPendingParagraphStyle(_ value: NoteParagraphStyle, indent: Int = 0, at location: Int, metadata: NoteBlock? = nil) {
        var block = metadata ?? pendingParagraphStyle?.state.block
        block?.style = value.storageName
        block?.level = value.level
        block?.indent = indent > 0 ? indent : nil
        pendingParagraphStyle = value == .body && block == nil ? nil : (location, .init(style: value, indent: indent, block: block))
        documentCache = nil
        var typing = style.paragraphAttributes(style: value.storageName, level: value.level, indent: indent,
                                               previous: location > 0 ? paragraphKind(at: location - 1) : nil)
        // The paragraph above draws differently beside a Mono line or
        // without one (a Mono block's last line at the note's end).
        if location > 0, location <= textStorage.length {
            let above = paragraphRange(at: location - 1)
            restyle(above)
            invalidateLayout(above)
        }
        if let name = value.storageName { typing[.noteBlockStyle] = name }
        if let level = value.level { typing[.noteBlockLevel] = level }
        if indent > 0 { typing[.noteBlockIndent] = indent }
        textView?.typingAttributes = typing
        updateTextChecking()
        onTextChange?()
    }

    private func changeIndent(_ delta: Int, selection: NSRange) -> Bool {
        let lines = formattableParagraphs(in: selection)
        history.beginGroup()
        defer { history.endGroup() }
        var changed = false
        for line in lines.reversed() {
            guard let paragraphStyle = paragraphStyle(at: line.location),
                  [.bullet, .number, .checklist, .quote].contains(paragraphStyle) else { continue }
            let old = indentAt(line.location) ?? 0
            let new = min(2, max(0, old + delta))
            guard new != old else { continue }
            let string = textStorage.string as NSString
            let hasBreak = NSMaxRange(line) < string.length && string.character(at: NSMaxRange(line)) == 0x0A
            let range = NSRange(location: line.location, length: line.length + (hasBreak ? 1 : 0))
            if range.length == 0 {
                history.recordParagraphStyleChange(location: line.location,
                    before: pendingParagraphStyle?.state ?? .init(style: paragraphStyle, indent: old),
                    after: .init(style: paragraphStyle, indent: new, block: pendingParagraphStyle?.state.block))
                setPendingParagraphStyle(paragraphStyle, indent: new, at: line.location)
                changed = true
                continue
            }
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
            replacement.removeAttribute(.noteBlockIndent, range: NSRange(location: 0, length: replacement.length))
            if new > 0 { replacement.addAttribute(.noteBlockIndent, value: new, range: NSRange(location: 0, length: replacement.length)) }
            changed = performEdit(range, with: replacement, name: delta > 0 ? "Indent" : "Outdent") || changed
        }
        textView?.setSelectedRange(selection)
        return changed
    }

    private func insertDivider(selection: NSRange) -> Bool {
        let line = lineRange(at: selection.location)
        let at = NSMaxRange(line)
        let divider = NoteDividerAttachment()
        let attributes = style.bodyAttributes
        let insertion = NSMutableAttributedString(string: "\n", attributes: attributes)
        insertion.append(NoteTextCodec.attachmentString(divider, attributes: attributes))
        insertion.append(NSAttributedString(string: "\n", attributes: attributes))
        return performEdit(NSRange(location: at, length: 0), with: insertion, name: "Divider",
                           selection: NSRange(location: at + insertion.length, length: 0))
    }

    private func moveLine(up: Bool, selection: NSRange) -> Bool {
        let line = paragraphRange(at: selection.location)
        let neighbor = paragraphRange(at: up ? line.location - 1 : NSMaxRange(line))
        let first = up ? neighbor : line
        let second = up ? line : neighbor
        guard first.location > 0, NSMaxRange(second) <= textStorage.length else { return false }
        let before = textStorage.attributedSubstring(from: first)
        let after = textStorage.attributedSubstring(from: second)
        let replacement = NSMutableAttributedString(attributedString: after)
        let secondEndsWithBreak = after.length > 0 && (after.string as NSString).character(at: after.length - 1) == 0x0A
        if secondEndsWithBreak {
            replacement.append(before)
        } else {
            let attributes = after.length > 0 ? after.attributes(at: after.length - 1, effectiveRange: nil) : style.bodyAttributes
            replacement.append(NSAttributedString(string: "\n", attributes: attributes))
            replacement.append(before.attributedSubstring(from: NSRange(location: 0, length: max(0, before.length - 1))))
        }
        let offset = selection.location - line.location
        let newLocation = up ? first.location + offset : first.location + after.length + (secondEndsWithBreak ? 0 : 1) + offset
        return performEdit(NSRange(location: first.location, length: first.length + second.length),
                           with: replacement, name: up ? "Move Line Up" : "Move Line Down",
                           selection: NSRange(location: min(newLocation, textStorage.length), length: selection.length))
    }
}

// MARK: - Local typing habits and slash insertion

struct NoteSlashItem: Hashable, Identifiable {
    /// The block styles are the Aa style list's (Title, Heading, Subheading,
    /// Body, Mono; Quote is the sixth), with the same names (A39 F04).
    enum Kind: String, CaseIterable {
        case checklist, title, heading, subheading, body, bullet, number, imageOrFile, date, quote, divider, mono, table
    }
    var kind: Kind
    var id: Kind { kind }
    var title: String {
        switch kind {
        case .checklist: "Checklist"
        case .title: "Title"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .bullet: "Bulleted List"
        case .number: "Numbered List"
        case .imageOrFile: "Image or File"
        case .date: "Date"
        case .quote: "Quote"
        case .divider: "Divider"
        case .mono: "Mono"
        case .table: "Table"
        }
    }
    var aliases: [String] {
        switch kind {
        case .checklist: ["check", "todo", "box"]
        case .title: ["h1", "big"]
        case .heading: ["head", "h2"]
        case .subheading: ["subhead", "sub", "h3"]
        case .body: ["text", "paragraph", "plain"]
        case .bullet: ["list", "bul", "unordered"]
        case .number: ["list", "num", "ordered"]
        case .imageOrFile: ["image", "file", "attachment", "photo"]
        case .date: ["date", "day", "calendar"]
        case .quote: ["quote", "blockquote"]
        case .divider: ["divider", "rule", "line"]
        case .mono: ["mono", "code", "pre"]
        case .table: ["table", "grid", "cells"]
        }
    }
    static let all = Kind.allCases.map(NoteSlashItem.init(kind:))
}

/// One `/` Image or File… request: the engine it was made in, the command
/// it captured and its generation there. Equal only to itself, so a late
/// completion can never be taken for a newer request (review P2, `8008974`).
@MainActor
final class NoteSlashFileRequest: Equatable {
    private(set) weak var engine: NoteEditorEngine?
    let target: NoteSlashSession
    let generation: UInt64

    init(engine: NoteEditorEngine, target: NoteSlashSession, generation: UInt64) {
        self.engine = engine
        self.target = target
        self.generation = generation
    }

    /// Cancels this request in its engine, never a newer one.
    func cancel() { engine?.cancelSlashFile(self) }

    nonisolated static func == (lhs: NoteSlashFileRequest, rhs: NoteSlashFileRequest) -> Bool { lhs === rhs }
}

struct NoteSlashSession {
    var noteID: UUID
    var range: NSRange
    var query: String
    var literal: String { "/" + query }
    var capturedText: NoteCapturedTextTarget { .init(noteID: noteID, range: range, literal: literal) }
    var items: [NoteSlashItem] {
        guard !query.isEmpty else { return NoteSlashItem.all }
        let matches = NoteSlashItem.all.filter { item in
            item.title.localizedStandardContains(query) || item.aliases.contains { $0.localizedStandardContains(query) }
        }
        // An exact alias wins over a substring: /list means List, rather
        // than the earlier Checklist row whose name also contains "list".
        func exact(_ item: NoteSlashItem) -> Bool {
            ([item.title] + item.aliases).contains { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }
        }
        return matches.filter(exact) + matches.filter { !exact($0) }
    }
}

@MainActor
extension NoteEditorEngine {
    private func rangeIsInStorage(_ range: NSRange) -> Bool {
        range.location >= 0 && range.length >= 0 && range.location <= textStorage.length
            && range.length <= textStorage.length - range.location
    }

    private func validCapturedText(_ target: NoteCapturedTextTarget) -> Bool {
        target.noteID == noteID && !isReadOnly && activity == .idle && target.range.length > 0
            && rangeIsInStorage(target.range)
            && (textStorage.string as NSString).substring(with: target.range) == target.literal
    }

    var slashSession: NoteSlashSession? {
        get { activeSlashSession }
        set { activeSlashSession = newValue; onSlashSessionChange?(newValue) }
    }
    var pendingSlashDate: NoteSlashSession? {
        get { slashDateRequest }
        set { slashDateRequest = newValue }
    }

    private func validSlashTarget(_ session: NoteSlashSession, needsCaret: Bool) -> Bool {
        guard validCapturedText(session.capturedText),
              session.range.location > titleParagraphRange.length,
              lineRange(at: session.range.location).location <= session.range.location else { return false }
        return !needsCaret || textView?.selectedRange() == NSRange(location: NSMaxRange(session.range), length: 0)
    }

    private func refreshSlashAfterEdit() {
        pendingSlashDate = nil
        pendingSlashFile = nil
        guard let session = slashSession, let caret = textView?.selectedRange(), caret.length == 0,
              caret.location >= session.range.location, caret.location <= textStorage.length else {
            slashSession = nil
            return
        }
        let range = NSRange(location: session.range.location, length: caret.location - session.range.location)
        let literal = (textStorage.string as NSString).substring(with: range)
        guard literal.hasPrefix("/"), !literal.contains(" "), !literal.contains("\n"),
              lineRange(at: caret.location).location <= session.range.location else { slashSession = nil; return }
        slashSession = NoteSlashSession(noteID: noteID, range: range, query: String(literal.dropFirst()))
    }

    func handleTypedText(_ text: String, wasComposing: Bool) {
        guard !isReadOnly, !wasComposing, activity == .idle, let textView,
              textView.selectedRange().length == 0 else { return }
        let caret = textView.selectedRange().location
        let line = lineRange(at: caret)
        guard line.location > 0, paragraphStyle(at: caret) != .mono else { slashSession = nil; return }
        if text == " " {
            if slashSession != nil { slashSession = nil; return }
            if convertParagraphHabit(line: line) { return }
            linkURLBeforeCaret()
        } else if text == "*" || text == "_" || text == "`" {
            if convertInlineHabit(line: line, caret: caret) { return }
        }
        updateSlashSession(caret: caret, typed: text)
    }

    private func convertParagraphHabit(line: NSRange) -> Bool {
        guard conversionEligible(line: line) else { return false }
        let value = (textStorage.string as NSString).substring(with: line)
        let isBullet = paragraphStyle(at: line.location) == .bullet
        let choices: [(String, NoteParagraphStyle)] = [
            ("[ ] ", .checklist), ("[x] ", .checklist), ("[X] ", .checklist),
            ("# ", .heading(2)), ("## ", .heading(2)), ("### ", .heading(3)),
            ("``` ", .mono), ("[] ", .checklist),
            ("- ", .bullet), ("* ", .bullet), ("1. ", .number),
            ("-[] ", .checklist), ("- [ ] ", .checklist), ("- [x] ", .checklist), ("> ", .quote)
        ]
        guard let (prefix, format) = choices.first(where: { value.hasPrefix($0.0) }),
              let textView, textView.selectedRange().location == line.location + (prefix as NSString).length else { return false }
        if prefix.hasPrefix("[") && prefix != "[] " && !isBullet { return false }
        if prefix.hasPrefix("[") && prefix != "[] " {
            let checked = prefix != "[ ] "
            let box = NoteChecklistAttachment(isChecked: checked)
            renderer.apply(to: box, today: today)
            let replacement = NoteTextCodec.attachmentString(box, attributes: style.bodyAttributes)
            let applied = performEdit(line, with: replacement, name: "Checklist",
                                      selection: NSRange(location: line.location + 1, length: 0))
            if applied {
                history.setLastRestoredText(NSAttributedString(string: "- " + prefix, attributes: style.bodyAttributes))
            }
            return applied
        }
        history.beginGroup()
        defer { history.endGroup() }
        let length = (prefix as NSString).length
        guard performEdit(NSRange(location: line.location, length: length), with: NSAttributedString(), name: "Format") else { return false }
        let selected = NSRange(location: line.location, length: 0)
        let didFormat = perform(.paragraph(format), selection: selected)
        if prefix == "- [x] ", didFormat { toggleCheckbox(atLineOf: line.location) }
        textView.setSelectedRange(NSRange(location: selected.location + (format == .checklist ? 1 : 0), length: 0))
        return didFormat
    }

    private func convertInlineHabit(line: NSRange, caret: Int) -> Bool {
        guard conversionEligible(line: line) else { return false }
        let before = (textStorage.string as NSString).substring(with: NSRange(location: line.location, length: caret - line.location))
        let patterns: [(String, NoteMark.Kind)] = [("**", .bold), ("*", .italic), ("_", .italic), ("`", .code)]
        for (delimiter, kind) in patterns {
            guard before.hasSuffix(delimiter) else { continue }
            if delimiter.count == 1, let last = before.dropLast().last, String(last) == delimiter { continue }
            let end = before.index(before.endIndex, offsetBy: -delimiter.count)
            guard let open = before[..<end].range(of: delimiter, options: .backwards), open.upperBound < end else { continue }
            if delimiter.count == 1 {
                let prefix = before[..<open.lowerBound]
                if prefix.last.map(String.init) == delimiter { continue }
            }
            let content = String(before[open.upperBound..<end])
            guard !content.isEmpty, !content.contains("\n") else { continue }
            let start = line.location + (String(before[..<open.lowerBound]) as NSString).length
            let range = NSRange(location: start, length: (delimiter as NSString).length * 2 + (content as NSString).length)
            let interior = NSRange(location: start + (delimiter as NSString).length, length: (content as NSString).length)
            if textStorage.attribute(.noteMark(.code), at: max(0, min(start, textStorage.length - 1)), effectiveRange: nil) != nil { continue }
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: interior))
            replacement.addAttribute(.noteMark(kind), value: true, range: NSRange(location: 0, length: replacement.length))
            let font = attributes(forParagraphAt: start)[.font] as? NSFont ?? style.bodyFont
            var runs: [([NoteMark.Kind: Any], NSRange)] = []
            replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { values, run, _ in
                let marks = Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.compactMap { mark in
                    values[.noteMark(mark)].map { (mark, $0) }
                })
                runs.append((marks, run))
            }
            for (marks, run) in runs {
                replacement.addAttributes(style.markedAttributes(marks: marks, baseFont: font), range: run)
            }
            // The closing delimiter's attributes describe what follows the
            // marked span. Selection updates during replacement otherwise
            // inherit the just-marked character to the left of the caret.
            var following = textStorage.attributes(at: NSMaxRange(range) - 1, effectiveRange: nil)
            for key in NSAttributedString.Key.noteBookkeeping { following[key] = nil }
            following[.attachment] = nil
            let applied = performEdit(range, with: replacement, name: "Format \(kind.rawValue.capitalized)",
                                      selection: NSRange(location: start + replacement.length, length: 0))
            if applied {
                history.setLastBoundaryTypingMarks(Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.compactMap { mark in
                    following[.noteMark(mark)].map { (mark, $0) }
                }))
                textView?.typingAttributes = following
                updateTextChecking()
            }
            return applied
        }
        return false
    }

    private func conversionEligible(line: NSRange) -> Bool {
        guard line.location > 0, paragraphStyle(at: line.location) != .mono else { return false }
        var blocked = false
        if line.length > 0 {
            textStorage.enumerateAttribute(.noteMark(.code), in: line) { value, _, stop in
                if value != nil { blocked = true; stop.pointee = true }
            }
        }
        return !blocked
    }

    private func linkURLBeforeCaret() {
        guard let textView else { return }
        let caret = textView.selectedRange().location
        let line = lineRange(at: caret)
        let before = (textStorage.string as NSString).substring(with: NSRange(location: line.location, length: caret - line.location))
        let token = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let url = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
        guard (url.hasPrefix("https://") || url.hasPrefix("http://")), URL(string: url)?.host != nil else { return }
        let length = (url as NSString).length
        let location = caret - 1 - length
        guard location >= line.location else { return }
        _ = perform(.link(url), selection: NSRange(location: location, length: length))
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    private func updateSlashSession(caret: Int, typed: String) {
        let line = lineRange(at: caret)
        let string = textStorage.string as NSString
        if let session = slashSession {
            guard caret >= NSMaxRange(session.range), caret <= NSMaxRange(line),
                  !typed.contains(" "), !typed.contains("\n") else { slashSession = nil; return }
            let value = string.substring(with: NSRange(location: session.range.location, length: caret - session.range.location))
            guard value.hasPrefix("/") else { slashSession = nil; return }
            slashSession = NoteSlashSession(noteID: noteID, range: NSRange(location: session.range.location, length: (value as NSString).length),
                                            query: String(value.dropFirst()))
        } else if typed == "/", caret > line.location {
            let at = caret - 1
            let boundary = at == line.location || string.character(at: at - 1) == 0x20
            if boundary { slashSession = NoteSlashSession(noteID: noteID, range: NSRange(location: at, length: 1), query: "") }
        }
    }

    /// Non-date acceptance replaces the captured command in one editor step.
    /// Date and file requests leave the literal command intact for their UI.
    @discardableResult
    func acceptSlashItem(_ kind: NoteSlashItem.Kind) -> Bool {
        guard let session = slashSession, validSlashTarget(session, needsCaret: true),
              session.items.contains(where: { $0.kind == kind }) else { slashSession = nil; return false }
        slashSession = nil
        switch kind {
        case .date:
            pendingSlashDate = session
            onSlashDateRequest?()
            return true
        case .imageOrFile:
            // Made before the call: optional chaining would skip it.
            let request = requestSlashFile(for: session)
            onSlashFileRequest?(request)
            return true
        default:
            history.beginGroup()
            defer { history.endGroup() }
            guard performEdit(session.range, with: NSAttributedString(), name: "Insert \(kind.rawValue)",
                              selection: NSRange(location: session.range.location, length: 0)) else { return false }
            let caret = NSRange(location: session.range.location, length: 0)
            switch kind {
            case .checklist: return perform(.paragraph(.checklist), selection: caret)
            case .title: return perform(.paragraph(.heading(1)), selection: caret)
            case .heading: return perform(.paragraph(.heading(2)), selection: caret)
            case .subheading: return perform(.paragraph(.heading(3)), selection: caret)
            case .body: return perform(.paragraph(.body), selection: caret)
            case .bullet: return perform(.paragraph(.bullet), selection: caret)
            case .number: return perform(.paragraph(.number), selection: caret)
            case .quote: return perform(.paragraph(.quote), selection: caret)
            case .mono: return perform(.paragraph(.mono), selection: caret)
            case .divider: return perform(.divider, selection: caret)
            case .table: return insertTable(at: caret, name: String(localized: "Insert Table"))
            case .date, .imageOrFile: return false
            }
        }
    }

    @discardableResult
    func commitSlashDate(_ day: NoteDay) -> Bool {
        guard let session = pendingSlashDate else { return false }
        pendingSlashDate = nil
        guard validSlashTarget(session, needsCaret: false) else { return false }
        let date = NoteDateAttachment(day: day)
        renderer.apply(to: date, today: today)
        let attributed = NoteTextCodec.attachmentString(date, attributes: attributes(forParagraphAt: session.range.location))
        return performEdit(session.range, with: attributed, name: "Insert Date",
                           selection: NSRange(location: session.range.location + attributed.length, length: 0))
    }

    func cancelSlashDate() { pendingSlashDate = nil }
    /// A new `/` Image or File… request for `target`: it supersedes any
    /// older one, whose late completion then commits nothing.
    func requestSlashFile(for target: NoteSlashSession) -> NoteSlashFileRequest {
        slashFileGeneration &+= 1
        let request = NoteSlashFileRequest(engine: self, target: target, generation: slashFileGeneration)
        pendingSlashFile = request
        return request
    }

    /// `request` is still the one waiting for its file: made here, and no
    /// newer request or cancellation since.
    func isPending(_ request: NoteSlashFileRequest) -> Bool {
        request.engine === self && pendingSlashFile?.generation == request.generation
    }

    /// Cancels `request` only: a newer request stays pending.
    func cancelSlashFile(_ request: NoteSlashFileRequest) {
        if isPending(request) { pendingSlashFile = nil }
    }
    func dismissSlashSession() { slashSession = nil }
}

@MainActor
extension NoteEditorEngine {
    /// Called by the focused text view after the app-level commands have had
    /// their chance; All notes retains ⇧⌘L.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard !isReadOnly, activity == .idle, textView?.hasMarkedText() != true else { return false }
        guard let command = NoteCommandCatalog.command(for: event) else { return false }
        return NoteCommandRouter(engine: self).run(command, from: .shortcut)
    }
}

@MainActor
extension NoteEditorEngine {
    /// Rich external paste maps only attributes this note can round-trip.
    /// Unsupported attachments become readable literal placeholders.
    func pasteRichText(_ data: Data, type: NSPasteboard.PasteboardType, at selection: NSRange) -> Bool {
        guard type == .rtf || type == .html else { return false }
        let documentType: NSAttributedString.DocumentType = type == .rtf ? .rtf : .html
        guard let imported = try? NSAttributedString(data: data,
                                                     options: [.documentType: documentType],
                                                     documentAttributes: nil), imported.length > 0 else { return false }
        let source = NSMutableAttributedString(attributedString: imported)
        let raw = source.string as NSString
        for index in (0..<raw.length).reversed() where raw.character(at: index) == NoteDocument.objectUnit {
            source.replaceCharacters(in: NSRange(location: index, length: 1), with: "[Attachment]")
        }
        let result = NSMutableAttributedString(string: source.string, attributes: style.bodyAttributes)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { result.addAttribute(.noteMark(.bold), value: true, range: range) }
                if traits.contains(.italic) { result.addAttribute(.noteMark(.italic), value: true, range: range) }
                if traits.contains(.monoSpace) { result.addAttribute(.noteMark(.code), value: true, range: range) }
            }
            if attributes[.underlineStyle] != nil { result.addAttribute(.noteMark(.underline), value: true, range: range) }
            if attributes[.strikethroughStyle] != nil { result.addAttribute(.noteMark(.strikethrough), value: true, range: range) }
            if attributes[.backgroundColor] != nil { result.addAttribute(.noteMark(.highlight), value: true, range: range) }
            if let url = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String {
                result.addAttribute(.noteMark(.link), value: url, range: range)
            }
        }
        // List identity is a paragraph property. A foreign list kind or an
        // unsupported depth stays readable as literal marker text.
        var paragraphs: [(range: NSRange, lists: [NSTextList])] = []
        let sourceString = source.string as NSString
        var start = 0
        while start < sourceString.length {
            let paragraph = sourceString.paragraphRange(for: NSRange(location: start, length: 0))
            let lists = (source.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
            paragraphs.append((paragraph, lists))
            start = NSMaxRange(paragraph)
        }
        var ordinals: [Int: Int] = [:]
        var literals: [(Int, String)] = []
        for entry in paragraphs {
            guard let list = entry.lists.last else { ordinals.removeAll(); continue }
            let depth = entry.lists.count - 1
            ordinals = ordinals.filter { $0.key <= depth }
            let ordinal = (ordinals[depth] ?? 0) + 1
            ordinals[depth] = ordinal
            let supported = depth <= 2 && entry.lists.allSatisfy { $0.markerFormat == .disc || $0.markerFormat == .decimal }
            if supported {
                result.addAttribute(.noteBlockStyle, value: list.markerFormat == .decimal ? "number" : "bullet", range: entry.range)
                if depth > 0 { result.addAttribute(.noteBlockIndent, value: depth, range: entry.range) }
            } else {
                literals.append((entry.range.location, String(repeating: "  ", count: max(0, depth)) + list.marker(forItemNumber: ordinal) + " "))
            }
        }
        for (at, marker) in literals.reversed() {
            result.insert(NSAttributedString(string: marker, attributes: style.bodyAttributes), at: at)
        }
        let normalized = NoteTextCodec.document(from: result, firstBlockIsTitle: false)
        let attributed = NoteTextCodec.attributedString(from: normalized, style: style, firstBlockIsTitle: false)
        let paste = pasteIncludingTail(attributed, replacing: selection)
        return performEdit(paste.range, with: paste.text, name: "Paste", selection: NSRange(location: selection.location + attributed.length, length: 0))
    }
}

struct NoteAccessibilityParagraph {
    var range: NSRange
    var text: String
    var headingLevel: Int?
    var style: String?
    var indent: Int
    var listOrdinal: Int?
}

@MainActor
extension NoteEditorEngine {
    func accessibilityParagraphs(in range: NSRange) -> [NoteAccessibilityParagraph] {
        let string = textStorage.string as NSString
        guard string.length > 0, range.location < string.length else { return [] }
        var result: [NoteAccessibilityParagraph] = []
        var location = min(range.location, string.length - 1)
        let end = min(NSMaxRange(range), string.length)
        while location < end {
            let line = lineRange(at: location)
            let attrs = textStorage.attributes(at: line.location, effectiveRange: nil)
            let name = attrs[.noteBlockStyle] as? String
            let heading = line.location == 0 ? 1 : (name == "heading" ? attrs[.noteBlockLevel] as? Int ?? 2 : nil)
            let indent = attrs[.noteBlockIndent] as? Int ?? 0
            result.append(NoteAccessibilityParagraph(range: line,
                                                     text: string.substring(with: line).replacingOccurrences(of: String(NoteDocument.objectCharacter), with: ""),
                                                     headingLevel: heading, style: name,
                                                     indent: indent,
                                                     listOrdinal: name == "number" ? numberedOrdinal(at: line.location, indent: indent) : nil))
            let next = NSMaxRange(line) + 1
            if next <= location { break }
            location = next
        }
        return result
    }

    func numberedOrdinal(at location: Int, indent: Int) -> Int {
        var ordinal = 1
        var start = location
        while start > titleParagraphRange.length + 1 {
            let previous = lineRange(at: start - 1)
            guard previous.location < start, previous.location < textStorage.length else { break }
            let attrs = textStorage.attributes(at: previous.location, effectiveRange: nil)
            let previousDepth = attrs[.noteBlockIndent] as? Int ?? 0
            let previousKind = attrs[.noteBlockStyle] as? String
            let nested = previousDepth > indent && (["number", "bullet"].contains(previousKind ?? "") || checklistBox(inParagraphAt: previous.location) != nil)
            guard nested || (previousKind == "number" && previousDepth == indent) else { break }
            if previousDepth == indent { ordinal += 1 }
            start = previous.location
        }
        return ordinal
    }

    func headingRanges() -> [NoteAccessibilityParagraph] {
        let string = textStorage.string as NSString
        var result: [NoteAccessibilityParagraph] = []
        var location = 0
        while location < string.length {
            let line = lineRange(at: location)
            let attrs = textStorage.attributes(at: line.location, effectiveRange: nil)
            let name = attrs[.noteBlockStyle] as? String
            let level = line.location == 0 ? 1 : (name == "heading" ? attrs[.noteBlockLevel] as? Int ?? 2 : nil)
            if let level {
                let value = string.substring(with: line)
                if !value.isEmpty {
                    result.append(NoteAccessibilityParagraph(range: line, text: value, headingLevel: level,
                                                             style: name, indent: 0, listOrdinal: nil))
                }
            }
            let next = NSMaxRange(line) + 1
            if next <= location { break }
            location = next
        }
        return result
    }
}

@MainActor
extension NoteEditorEngine {
    /// The image importer calls this only after a slash Image or File request
    /// has produced a staged image. Cancel leaves the literal command intact.
    @discardableResult
    func commitSlashImage(_ item: StagedNoteAttachment, pixelSize: CGSize?, for request: NoteSlashFileRequest) -> Bool {
        commitSlashObject(NoteImportedObject(staged: item, pixelSize: pixelSize), for: request)
    }

    /// Replaces `request`'s captured command with the object. A request that
    /// is no longer pending (cancelled, or superseded by a newer `/` Image
    /// or File…) commits nothing and leaves the newer request alone.
    @discardableResult
    func commitSlashObject(_ item: NoteImportedObject, for request: NoteSlashFileRequest) -> Bool {
        guard isPending(request) else { return false }
        let session = request.target
        if let staged = item.staged, let reason = onImportAdmission?(staged) {
            onNotice?(reason)
            return false
        }
        pendingSlashFile = nil
        guard validSlashTarget(session, needsCaret: false) else { return false }
        let line = lineRange(at: session.range.location)
        let atLineStart = session.range.location == line.location
        let replacement = NSMutableAttributedString()
        if !atLineStart { replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes)) }
        if let stagedItem = item.staged, let pixelSize = item.pixelSize {
            let image = NoteImageAttachment(attachmentID: stagedItem.id, preferredWidthFraction: 1, pixelSize: pixelSize, extras: stagedItem.identityExtras)
            image.filename = item.filename
            replacement.append(NoteTextCodec.attachmentString(image, attributes: style.bodyAttributes))
        } else {
            let file = NoteFileAttachment(attachmentID: item.staged?.id, filename: item.filename,
                contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount,
                importFailure: item.failure, extras: item.staged?.identityExtras ?? [:])
            replacement.append(NoteTextCodec.attachmentString(file, attributes: style.bodyAttributes))
        }
        replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        if let stagedItem = item.staged { staged[stagedItem.id] = stagedItem }
        let applied = performEdit(session.range, with: replacement, name: "Insert File",
                                  selection: NSRange(location: session.range.location + replacement.length, length: 0))
        if !applied, let id = item.staged?.id { staged[id] = nil }
        return applied
    }
}
