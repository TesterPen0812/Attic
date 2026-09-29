import AppKit
import Carbon

/// Where the editor gets image bytes that are already stored.
@MainActor
protocol NoteImageProviding: AnyObject {
    /// The stored row's file (materialised off the main thread), or nil when
    /// the row or its bytes are gone.
    func fileURL(forAttachment id: UUID) async -> URL?
    func filename(forAttachment id: UUID) -> String?
    /// Bytes of another note's image, for a paste that copies it here.
    func imageBytes(forAttachment id: UUID) -> StagedNoteAttachment?
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
    var onSlashFileRequest: (() -> Void)?
    var onLinkRequest: ((String?) -> Void)?
    private var activeSlashSession: NoteSlashSession?
    private var slashDateRequest: NoteSlashSession?
    private var pendingSlashFile: NoteSlashSession?
    private var pendingParagraphStyle: (location: Int, style: NoteParagraphStyle)?

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

    // Guard state.
    var userEditDepth = 0
    private var engineEditDepth = 0
    private(set) var isWritingToolsSessionActive = false
    private(set) var writingToolsBeganInView = false
    private(set) var activity: Activity = .idle
    private func setActivity(_ next: Activity) {
        guard next != activity else { return }
        let previous = activity
        activity = next
        onActivityChanged?(previous, next)
    }
    private var writingToolsBlocked = false
    var isWritingToolsBlocked: Bool { writingToolsBlocked }
    var writingToolsRefusalReason: String?
    private var writingToolsSnapshot: NSAttributedString?
    private var writingToolsHistory: NoteUndoHistory.Checkpoint?
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
        textStorage.setAttributedString(NoteTextCodec.attributedString(from: document, style: style))
        textStorage.delegate = self
        renderObjects(in: NSRange(location: 0, length: textStorage.length))
        history.onReplay = { [weak self] range in self?.didReplay(range) }
        history.onTagFlip = { [weak self] tag, add, changesTags, range in
            self?.didFlipTag(tag, add: add, changesTags: changesTags, range: range)
        }
        history.onTagSnapshot = { [weak self] tags in self?.setTags(tags) }
        history.onParagraphStyleSnapshot = { [weak self] location, paragraphStyle in
            self?.setPendingParagraphStyle(paragraphStyle, at: location)
        }
        history.onTypingMarkSnapshot = { [weak self] kind, enabled in self?.setTypingMark(kind, enabled: enabled) }
        history.canReplay = { [weak self] in self?.activity == .idle }
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
            result.blocks[last].style = pending.style.storageName
            result.blocks[last].level = pending.style.level
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
            return NoteTextCodec.document(from: writingToolsSnapshot, template: template)
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
        let scrollView = NSScrollView(frame: textView.frame)
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
        return (scrollView, textView)
    }

    func detachView() {
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
    func setTitleReserves(tagLine: CGFloat, trailing: CGFloat) {
        guard style.tagLineHeight != tagLine || style.titleTrailingReserve != trailing else { return }
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
                let base = style.paragraphAttributes(style: metadata[.noteBlockStyle] as? String,
                                                     level: metadata[.noteBlockLevel] as? Int,
                                                     indent: metadata[.noteBlockIndent] as? Int)
                textStorage.addAttributes(base, range: actual)
                restyleMarks(in: actual, base: base)
                position = NSMaxRange(paragraph)
                if position <= actual.location { break }
            }
        }
    }

    private func restyleMarks(in range: NSRange, base: [NSAttributedString.Key: Any]) {
        for kind in NoteMark.Kind.allCases {
            var runs: [(Any, NSRange)] = []
            textStorage.enumerateAttribute(.noteMark(kind), in: range) { value, markRange, _ in
                if let value { runs.append((value, markRange)) }
            }
            for (value, markRange) in runs {
                let font = base[.font] as? NSFont ?? style.bodyFont
                textStorage.addAttributes(style.markedAttributes(kind: kind, baseFont: font,
                                                                  url: value as? String), range: markRange)
            }
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

    private func renderObjects(in range: NSRange, force: Bool = false) {
        guard range.length > 0 else { return }
        textStorage.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let object = value as? NoteObjectAttachment else { return }
            if let image = object as? NoteImageAttachment {
                // A decoded image looks the same in every appearance: only a
                // missing one's placeholder is drawn again.
                if image.renderedImage == nil || (force && image.isMissing) { loadImage(image) }
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
            let decoded: (CGImage?, CGSize?) = await Task.detached(priority: .userInitiated) {
                if let stagedData {
                    return (NoteImageDecoder.thumbnail(of: stagedData, maxPixel: maxPixel),
                            NoteImageDecoder.pixelSize(of: stagedData))
                }
                guard let url else { return (nil, nil) }
                return (NoteImageDecoder.thumbnail(at: url, maxPixel: maxPixel), NoteImageDecoder.pixelSize(at: url))
            }.value
            guard let self, let image else { return }
            self.pendingImageLoads.remove(ObjectIdentifier(image))
            if self.staged[attachmentID]?.data != stagedData {
                self.loadImage(image)
                return
            }
            self.finishImageLoad(image, cgImage: decoded.0, pixelSize: decoded.1)
        }
    }

    private func finishImageLoad(_ image: NoteImageAttachment, cgImage: CGImage?, pixelSize: CGSize?) {
        var sizeChanged = false
        if image.pixelSize == nil, let pixelSize {
            image.pixelSize = pixelSize
            sizeChanged = true
        }
        if let cgImage {
            image.isMissing = false
            image.renderedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            image.isMissing = true
            image.renderedImage = renderer.placeholder(
                size: image.displaySize(columnWidth: textView?.textContainer?.size.width ?? 320),
                text: String(localized: "Image unavailable")
            )
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
        if let pending = pendingParagraphStyle, pending.location == paragraph.location {
            return style.paragraphAttributes(style: pending.style.storageName, level: pending.style.level, indent: nil)
        }
        guard paragraph.location > 0, paragraph.location < textStorage.length else { return style.titleAttributes }
        let attributes = textStorage.attributes(at: paragraph.location, effectiveRange: nil)
        return style.paragraphAttributes(style: attributes[.noteBlockStyle] as? String,
                                         level: attributes[.noteBlockLevel] as? Int,
                                         indent: attributes[.noteBlockIndent] as? Int)
    }

    // MARK: Editor commands (each one undo step)

    /// Replaces `range` as one named step. Returns false when refused.
    @discardableResult
    func performEdit(_ range: NSRange, with replacement: NSAttributedString, name: String,
                     selection: NSRange? = nil) -> Bool {
        guard !isReadOnly, NSMaxRange(range) <= textStorage.length else { return false }
        guard activity == .idle else {
            return refuse(String(localized: "Finish Writing Tools or composing text before editing this note."))
        }
        history.breakCoalescing()
        engineEditDepth += 1
        defer { engineEditDepth -= 1 }
        if let textView {
            guard textView.shouldChangeText(in: range, replacementString: replacement.string) else { return false }
            textStorage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        } else {
            history.willChange(ranges: [range], strings: [replacement.string])
            textStorage.replaceCharacters(in: range, with: replacement)
            history.didChange()
            onTextChange?()
        }
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
            performEdit(NSRange(location: line.location, length: 1), with: NSAttributedString(), name: String(localized: "Remove Checkbox"),
                        selection: NSRange(location: max(line.location, selection.location - 1), length: 0))
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

    /// Inserts a date at the caret (replacing a selection).
    func insertDate(_ day: NoteDay) {
        let selection = textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let date = NoteDateAttachment(day: day)
        renderer.apply(to: date, today: today)
        let text = NoteTextCodec.attachmentString(date, attributes: attributes(forParagraphAt: selection.location))
        performEdit(selection, with: text, name: String(localized: "Insert Date"),
                    selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Adds an imported image on its own line after the caret's line.
    @discardableResult
    func insertImage(_ item: StagedNoteAttachment, pixelSize: CGSize?) -> Bool {
        staged[item.id] = item
        let selection = textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        let line = lineRange(at: selection.location)
        let image = NoteImageAttachment(attachmentID: item.id, preferredWidthFraction: 1, pixelSize: pixelSize)
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

    func beginImageImport() {
        importAnchor = textView?.selectedRange().location ?? textStorage.length
    }

    func cancelImageImport() { importAnchor = nil }

    /// The complete batch is one document change and one Undo step.
    @discardableResult
    func insertImportedImages(_ items: [(StagedNoteAttachment, CGSize?)]) -> Bool {
        guard let anchor = importAnchor, !items.isEmpty else { return false }
        importAnchor = nil
        let at = NSMaxRange(lineRange(at: min(anchor, textStorage.length)))
        let insertion = NSMutableAttributedString(string: "")
        for (item, pixelSize) in items {
            staged[item.id] = item
            let image = NoteImageAttachment(attachmentID: item.id, preferredWidthFraction: 1, pixelSize: pixelSize)
            image.filename = item.filename
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
            insertion.append(NoteTextCodec.attachmentString(image, attributes: style.bodyAttributes))
        }
        if at == textStorage.length {
            insertion.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        let inserted = performEdit(NSRange(location: at, length: 0), with: insertion,
                                   name: String(localized: "Add Images"),
                                   selection: NSRange(location: at + insertion.length, length: 0))
        if !inserted { for (item, _) in items { staged[item.id] = nil } }
        return inserted
    }

    // MARK: Keys with object rules

    /// Return on a checklist line continues the list; on an empty checklist
    /// line it ends the list (the box goes).
    func handleNewline() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
        if slashSession != nil { return false }
        let current = textView.selectedRange()
        if current.length == 0 {
            let line = lineRange(at: current.location)
            if line.location > 0, current.location == NSMaxRange(line),
               (textStorage.string as NSString).substring(with: line) == "---" {
                let divider = NoteDividerAttachment()
                renderer.apply(to: divider, today: today)
                let replacement = NSMutableAttributedString(attributedString: NoteTextCodec.attachmentString(divider, attributes: style.bodyAttributes))
                replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
                return performEdit(line, with: replacement, name: "Divider",
                                   selection: NSRange(location: line.location + replacement.length, length: 0))
            }
            if let format = paragraphStyle(at: current.location), format == .bullet || format == .number {
                let content = (textStorage.string as NSString).substring(with: line)
                if content.trimmingCharacters(in: .whitespaces).isEmpty {
                    return perform(.paragraph(.body), selection: current)
                }
                let attributes = textStorage.attributes(at: line.location, effectiveRange: nil)
                let insertion = NSAttributedString(string: "\n", attributes: attributes)
                let finalParagraph = current.location == textStorage.length
                history.beginGroup()
                defer { history.endGroup() }
                guard performEdit(current, with: insertion, name: "Continue List",
                                  selection: NSRange(location: current.location + 1, length: 0)) else { return false }
                if finalParagraph {
                    history.recordParagraphStyleChange(location: current.location + 1, before: .body, after: format)
                    setPendingParagraphStyle(format, at: current.location + 1)
                }
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
            performEdit(NSRange(location: line.location, length: 1), with: NSAttributedString(),
                        name: String(localized: "Remove Checkbox"), selection: NSRange(location: line.location, length: 0))
            return true
        }
        let box = NoteChecklistAttachment(isChecked: false)
        renderer.apply(to: box, today: today)
        let insertion = NSMutableAttributedString(string: "\n", attributes: style.bodyAttributes)
        insertion.append(NoteTextCodec.attachmentString(box, attributes: style.bodyAttributes))
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
            performEdit(NSRange(location: line.location, length: 1), with: NSAttributedString(),
                        name: String(localized: "Remove Checkbox"), selection: NSRange(location: line.location, length: 0))
            return true
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
            performEdit(NSRange(location: location + 1, length: 1), with: NSAttributedString(),
                        name: String(localized: "Remove Checkbox"), selection: NSRange(location: location, length: 0))
            return true
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
        history.willChange(ranges: ranges, strings: replacementStrings)
        return true
    }

    func textDidChange(_ notification: Notification) {
        history.didChange()
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
        if !history.isChangeInFlight, let open = history.openStep,
           !(selection.length == 0 && selection.location >= open.range.location && selection.location <= NSMaxRange(open.range)) {
            history.breakCoalescing()
        }
        if selection.length == 0, selection.location > 0, textStorage.length > 0 {
            let index = min(selection.location - 1, textStorage.length - 1)
            var attributes = textStorage.attributes(at: index, effectiveRange: nil)
            for key in NSAttributedString.Key.noteBookkeeping { attributes[key] = nil }
            attributes[.attachment] = nil
            textView.typingAttributes = attributes
        } else {
            textView.typingAttributes = attributes(forParagraphAt: selection.location)
        }
        onSelectionChange?(selection)
        onCaretChange?()
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
        writingToolsHistory = history.checkpoint()
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
            if let name = pending.style.storageName { textStorage.addAttribute(.noteBlockStyle, value: name, range: range) }
            if let level = pending.style.level { textStorage.addAttribute(.noteBlockLevel, value: level, range: range) }
            pendingParagraphStyle = nil
        }
        if let anchor = importAnchor {
            let oldLength = max(0, editedRange.length - delta)
            let oldEnd = editedRange.location + oldLength
            if oldLength == 0, editedRange.location <= anchor {
                importAnchor = max(0, anchor + delta)
            } else if oldEnd <= anchor {
                importAnchor = max(0, anchor + delta)
            } else if editedRange.location <= anchor {
                importAnchor = editedRange.location
            }
        }
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
            history.captureUnrecorded(newRange: editedRange, delta: delta)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        restyle(paragraphs(around: editedRange))
        renderObjects(in: NSIntersectionRange(editedRange, NSRange(location: 0, length: textStorage.length)))
        lastUpkeepMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func didReplay(_ range: NSRange) {
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
        pasteboard.declareTypes(types, owner: nil)
        var wrote = false
        for type in types {
            switch type {
            case Self.fragmentType:
                if let data = try? NoteContentCodec.encode(fragment) { wrote = pasteboard.setData(data, forType: type) || wrote }
            case .string:
                wrote = pasteboard.setString(NoteTextExport.plainText(fragment), forType: .string) || wrote
            case .rtf:
                let selected = textStorage.attributedSubstring(from: range)
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
    func preparePaste(_ fragment: NoteDocument) -> NoteDocument {
        let sameNote = fragment.extras["sourceNoteID"]?.stringValue.flatMap(UUID.init(uuidString:)) == noteID
        var present = Set(objectIDs())
        var result = fragment
        result.extras = [:]
        var blocks: [NoteBlock] = []
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
            case .image:
                guard let attachmentID = block.attachmentID else { continue }
                // An image from this note keeps its attachment (its row is
                // retained while any version or text shows it).
                if sameNote {
                    block.id = fresh(block.id)
                } else if var copy = imageProvider?.imageBytes(forAttachment: attachmentID) {
                    let newID = UUID()
                    copy = StagedNoteAttachment(id: newID, filename: copy.filename, contentTypeIdentifier: copy.contentTypeIdentifier,
                                                byteCount: copy.byteCount, digest: copy.digest, data: copy.data)
                    staged[newID] = copy
                    block.attachmentID = newID
                    block.id = fresh(nil)
                } else {
                    onNotice?(String(localized: "An image couldn’t be copied, so it was left out."))
                    continue
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
        return result
    }

    /// Inserts a pasted fragment over the selection as one step.
    func paste(fragmentData data: Data, at selection: NSRange) -> Bool {
        guard !isReadOnly, case let .editable(decoded) = NoteContentCodec.decode(data) else { return false }
        let before = Set(staged.keys)
        let fragment = preparePaste(decoded)
        guard !fragment.blocks.isEmpty else { return false }
        let pasted = NoteTextCodec.attributedString(from: fragment, style: style, firstBlockIsTitle: false)
        let result = NSMutableAttributedString(attributedString: pasted)
        let string = textStorage.string as NSString
        let startsWithObject = fragment.blocks.first.map { $0.kind != .text } ?? false
        let endsWithBlockObject = fragment.blocks.last.map { $0.kind == .image || $0.kind == .opaque } ?? false
        let atLineStart = selection.location == 0 || string.character(at: selection.location - 1) == 0x0A
        if startsWithObject, !atLineStart || selection.location == 0 {
            result.insert(NSAttributedString(string: "\n", attributes: style.bodyAttributes), at: 0)
        }
        if endsWithBlockObject, NSMaxRange(selection) < string.length,
           string.character(at: NSMaxRange(selection)) != 0x0A {
            result.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        }
        guard performEdit(selection, with: result, name: String(localized: "Paste"),
                          selection: NSRange(location: selection.location + result.length, length: 0)) else {
            // Refused: the images copied for it are dropped, so no row appears.
            for key in staged.keys where !before.contains(key) { staged[key] = nil }
            return false
        }
        return true
    }

    /// Plain text from another app, with line breaks made uniform.
    func pastePlainText(_ text: String, at selection: NSRange) -> Bool {
        let normalized = LegacyNoteMigration.normalizeLineBreaks(text).0
            .replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
        guard !normalized.isEmpty else { return false }
        let attributed = NSAttributedString(string: normalized, attributes: attributes(forParagraphAt: selection.location))
        history.beginGroup()
        defer { history.endGroup() }
        guard performEdit(selection, with: attributed, name: String(localized: "Paste"),
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

    // MARK: Accessibility

    /// One element per object, in reading order, for VoiceOver (stock
    /// TextKit 2 exposes none).
    func accessibilityElements(for textView: NSTextView) -> [NSAccessibilityElement] {
        objects().map { object, range in
            NoteObjectAccessibilityElement(engine: self, textView: textView, object: object, range: range)
        }
    }

    func lineText(at location: Int) -> String {
        let line = lineRange(at: location)
        let text = (textStorage.string as NSString).substring(with: line)
        return text.replacingOccurrences(of: String(NoteDocument.objectCharacter), with: "")
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
        case is NoteDateAttachment:
            setAccessibilityRole(.button)
            setAccessibilityLabel(object.accessibilityDescription)
        default:
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(object.accessibilityDescription)
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
        guard object is NoteChecklistAttachment else { return false }
        MainActor.assumeIsolated { engine?.toggleCheckbox(atLineOf: range.location) }
        return true
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
        case .indent: "⌘]"
        case .outdent: "⌘["
        case .toggleChecklist: "⌘Return"
        case .moveUp: "⌥⌘↑"
        case .moveDown: "⌥⌘↓"
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
    var marks: [NoteMark.Kind: NoteFormatState]
    var linkURL: String?
    var commands: [NoteFormatCommand: NoteCommandValidation]
}

@MainActor
extension NoteEditorEngine {
    func paragraphStyle(at location: Int) -> NoteParagraphStyle? {
        let line = lineRange(at: location)
        guard line.location > 0, !isBlockObject(at: line.location) else { return nil }
        if let pending = pendingParagraphStyle, pending.location == line.location { return pending.style }
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
        var marks: [NoteMark.Kind: NoteFormatState] = [:]
        for kind in NoteMark.Kind.allCases { marks[kind] = markState(kind, selection: selection) }
        let index = min(selection.location, max(0, textStorage.length - 1))
        let url = textStorage.length > 0 ? textStorage.attribute(.noteMark(.link), at: index, effectiveRange: nil) as? String : nil
        let commands: [NoteFormatCommand] = [
            .paragraph(.body), .paragraph(.heading(1)), .paragraph(.heading(2)), .paragraph(.heading(3)),
            .paragraph(.bullet), .paragraph(.number), .paragraph(.checklist), .paragraph(.quote), .paragraph(.mono),
            .indent, .outdent, .divider, .toggleChecklist, .moveUp, .moveDown
        ] + NoteMark.Kind.allCases.map { .mark($0) }
        return NoteFormattingState(paragraph: paragraph, marks: marks, linkURL: url,
                                   commands: Dictionary(uniqueKeysWithValues: commands.map { ($0, validate($0, selection: selection)) }))
    }

    func validate(_ command: NoteFormatCommand, selection: NSRange? = nil) -> NoteCommandValidation {
        let selection = selection ?? textView?.selectedRange() ?? NSRange(location: textStorage.length, length: 0)
        guard !isReadOnly, activity == .idle, NSMaxRange(selection) <= textStorage.length else {
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
            return NoteCommandValidation(enabled: inBody && (kind != .link || selection.length > 0),
                                         state: markState(kind, selection: selection))
        case let .link(url):
            let parsed = URL(string: url)
            return NoteCommandValidation(enabled: selection.length > 0 && selection.location > titleParagraphRange.length &&
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
                guard let onLinkRequest else { return false }
                onLinkRequest(formattingState(for: selection).linkURL)
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
        case let .date(day): insertDate(day); return true
        }
    }

    private func indentAt(_ location: Int) -> Int? {
        guard location < textStorage.length else { return nil }
        return textStorage.attribute(.noteBlockIndent, at: location, effectiveRange: nil) as? Int
    }

    private func markState(_ kind: NoteMark.Kind, selection: NSRange) -> NoteFormatState {
        if selection.length == 0 {
            return textView?.typingAttributes[.noteMark(kind)] != nil ? .on : .off
        }
        var marked = 0
        var plain = 0
        let string = textStorage.string as NSString
        for index in selection.location..<NSMaxRange(selection) {
            let unit = string.character(at: index)
            guard unit != NoteDocument.objectUnit, unit != 0x0A else { continue }
            if textStorage.attribute(.noteMark(kind), at: index, effectiveRange: nil) != nil { marked += 1 }
            else { plain += 1 }
        }
        if marked == 0 { return .off }
        return plain == 0 ? .on : .mixed
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
        if enabled {
            let font = attributes[.font] as? NSFont ?? style.bodyFont
            attributes.merge(style.markedAttributes(kind: kind, baseFont: font)) { _, new in new }
        } else {
            switch kind {
            case .bold, .italic, .code: attributes[.font] = self.attributes(forParagraphAt: textView.selectedRange().location)[.font]
            case .underline: attributes[.underlineStyle] = nil
            case .strikethrough: attributes[.strikethroughStyle] = nil
            case .highlight: attributes[.backgroundColor] = nil
            case .link: attributes[.link] = nil
            }
        }
        textView.typingAttributes = attributes
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
                history.recordParagraphStyleChange(location: line.location, before: before, after: styleValue)
                setPendingParagraphStyle(styleValue, at: line.location)
                continue
            }
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
            if checklistBox(inParagraphAt: line.location) != nil {
                replacement.deleteCharacters(in: NSRange(location: 0, length: 1))
                if line.location < newSelection.location { newSelection.location -= 1 }
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

    private func setPendingParagraphStyle(_ value: NoteParagraphStyle, at location: Int) {
        pendingParagraphStyle = value == .body ? nil : (location, value)
        documentCache = nil
        var typing = style.paragraphAttributes(style: value.storageName, level: value.level, indent: nil)
        if let name = value.storageName { typing[.noteBlockStyle] = name }
        if let level = value.level { typing[.noteBlockLevel] = level }
        textView?.typingAttributes = typing
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
    enum Kind: String, CaseIterable { case checklist, heading, bullet, number, imageOrFile, date, quote, divider, mono }
    var kind: Kind
    var id: Kind { kind }
    var title: String {
        switch kind {
        case .checklist: "Checklist"
        case .heading: "Heading"
        case .bullet: "Bulleted List"
        case .number: "Numbered List"
        case .imageOrFile: "Image or File"
        case .date: "Date"
        case .quote: "Quote"
        case .divider: "Divider"
        case .mono: "Mono"
        }
    }
    var aliases: [String] {
        switch kind {
        case .checklist: ["check", "todo", "box"]
        case .heading: ["head", "title"]
        case .bullet: ["list", "bul", "unordered"]
        case .number: ["list", "num", "ordered"]
        case .imageOrFile: ["image", "file", "attachment", "photo"]
        case .date: ["date", "day", "calendar"]
        case .quote: ["quote", "blockquote"]
        case .divider: ["divider", "rule", "line"]
        case .mono: ["mono", "code", "pre"]
        }
    }
    static let all = Kind.allCases.map(NoteSlashItem.init(kind:))
}

struct NoteSlashSession {
    var range: NSRange
    var query: String
    var items: [NoteSlashItem] {
        guard !query.isEmpty else { return NoteSlashItem.all }
        return NoteSlashItem.all.filter { item in
            item.title.localizedStandardContains(query) || item.aliases.contains { $0.localizedStandardContains(query) }
        }
    }
}

@MainActor
extension NoteEditorEngine {
    var slashSession: NoteSlashSession? {
        get { activeSlashSession }
        set { activeSlashSession = newValue; onSlashSessionChange?(newValue) }
    }
    var pendingSlashDate: NoteSlashSession? {
        get { slashDateRequest }
        set { slashDateRequest = newValue }
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
        let value = (textStorage.string as NSString).substring(with: line)
        let choices: [(String, NoteParagraphStyle)] = [
            ("# ", .heading(2)), ("- ", .bullet), ("* ", .bullet), ("1. ", .number),
            ("-[] ", .checklist), ("- [ ] ", .checklist), ("- [x] ", .checklist), ("> ", .quote)
        ]
        guard let (prefix, format) = choices.first(where: { value.hasPrefix($0.0) }),
              let textView, textView.selectedRange().location == line.location + (prefix as NSString).length else { return false }
        history.beginGroup()
        defer { history.endGroup() }
        let length = (prefix as NSString).length
        guard performEdit(NSRange(location: line.location, length: length), with: NSAttributedString(), name: "Format") else { return false }
        let selected = NSRange(location: line.location, length: 0)
        let didFormat = perform(.paragraph(format), selection: selected)
        if prefix == "- [x] ", didFormat { toggleCheckbox(atLineOf: line.location) }
        textView.setSelectedRange(selected)
        return didFormat
    }

    private func convertInlineHabit(line: NSRange, caret: Int) -> Bool {
        let before = (textStorage.string as NSString).substring(with: NSRange(location: line.location, length: caret - line.location))
        let patterns: [(String, NoteMark.Kind)] = [("**", .bold), ("*", .italic), ("_", .italic), ("`", .code)]
        for (delimiter, kind) in patterns {
            guard before.hasSuffix(delimiter) else { continue }
            if delimiter == "*", before.hasPrefix("**"), !before.hasSuffix("**") { continue }
            let end = before.index(before.endIndex, offsetBy: -delimiter.count)
            guard let open = before[..<end].range(of: delimiter, options: .backwards), open.upperBound < end else { continue }
            let content = String(before[open.upperBound..<end])
            guard !content.isEmpty, !content.contains("\n") else { continue }
            let start = line.location + (String(before[..<open.lowerBound]) as NSString).length
            let range = NSRange(location: start, length: (delimiter as NSString).length * 2 + (content as NSString).length)
            let interior = NSRange(location: start + (delimiter as NSString).length, length: (content as NSString).length)
            if textStorage.attribute(.noteMark(.code), at: max(0, min(start, textStorage.length - 1)), effectiveRange: nil) != nil { continue }
            let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: interior))
            replacement.addAttribute(.noteMark(kind), value: true, range: NSRange(location: 0, length: replacement.length))
            let font = textStorage.attribute(.font, at: start, effectiveRange: nil) as? NSFont ?? style.bodyFont
            replacement.addAttributes(style.markedAttributes(kind: kind, baseFont: font), range: NSRange(location: 0, length: replacement.length))
            return performEdit(range, with: replacement, name: "Format \(kind.rawValue.capitalized)",
                               selection: NSRange(location: start + replacement.length, length: 0))
        }
        return false
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
            slashSession = NoteSlashSession(range: NSRange(location: session.range.location, length: (value as NSString).length),
                                            query: String(value.dropFirst()))
        } else if typed == "/", caret > line.location {
            let at = caret - 1
            let boundary = at == line.location || string.character(at: at - 1) == 0x20
            if boundary { slashSession = NoteSlashSession(range: NSRange(location: at, length: 1), query: "") }
        }
    }

    /// Non-date acceptance replaces the captured command in one editor step.
    /// Date and file requests leave the literal command intact for their UI.
    @discardableResult
    func acceptSlashItem(_ kind: NoteSlashItem.Kind) -> Bool {
        guard let session = slashSession, session.items.contains(where: { $0.kind == kind }) else { return false }
        slashSession = nil
        switch kind {
        case .date:
            pendingSlashDate = session
            onSlashDateRequest?()
            return true
        case .imageOrFile:
            pendingSlashFile = session
            onSlashFileRequest?()
            return true
        default:
            history.beginGroup()
            defer { history.endGroup() }
            guard performEdit(session.range, with: NSAttributedString(), name: "Insert \(kind.rawValue)",
                              selection: NSRange(location: session.range.location, length: 0)) else { return false }
            let caret = NSRange(location: session.range.location, length: 0)
            switch kind {
            case .checklist: return perform(.paragraph(.checklist), selection: caret)
            case .heading: return perform(.paragraph(.heading(2)), selection: caret)
            case .bullet: return perform(.paragraph(.bullet), selection: caret)
            case .number: return perform(.paragraph(.number), selection: caret)
            case .quote: return perform(.paragraph(.quote), selection: caret)
            case .mono: return perform(.paragraph(.mono), selection: caret)
            case .divider: return perform(.divider, selection: caret)
            case .date, .imageOrFile: return false
            }
        }
    }

    @discardableResult
    func commitSlashDate(_ day: NoteDay) -> Bool {
        guard let session = pendingSlashDate else { return false }
        pendingSlashDate = nil
        guard (textStorage.string as NSString).substring(with: session.range) == "/" + session.query else { return false }
        let date = NoteDateAttachment(day: day)
        renderer.apply(to: date, today: today)
        let attributed = NoteTextCodec.attachmentString(date, attributes: attributes(forParagraphAt: session.range.location))
        return performEdit(session.range, with: attributed, name: "Insert Date",
                           selection: NSRange(location: session.range.location + attributed.length, length: 0))
    }

    func cancelSlashDate() { pendingSlashDate = nil }
    func cancelSlashFile() { pendingSlashFile = nil }
    func dismissSlashSession() { slashSession = nil }
}

@MainActor
extension NoteEditorEngine {
    /// Called by the focused text view after the app-level commands have had
    /// their chance; All notes retains ⇧⌘L.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard !isReadOnly, activity == .idle, textView?.hasMarkedText() != true else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let key = Self.unshiftedKey(for: event) ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        var command: NoteFormatCommand?
        switch (flags, key) {
        case ([.command], "b"): command = .mark(.bold)
        case ([.command], "i"): command = .mark(.italic)
        case ([.command], "u"): command = .mark(.underline)
        case ([.command, .shift], "x"): command = .mark(.strikethrough)
        case ([.command, .shift], "k"): command = .mark(.link)
        case ([.command, .option], "0"): command = .paragraph(.body)
        case ([.command, .option], "1"): command = .paragraph(.heading(1))
        case ([.command, .option], "2"): command = .paragraph(.heading(2))
        case ([.command, .option], "3"): command = .paragraph(.heading(3))
        case ([.command, .shift], "7"): command = .paragraph(.bullet)
        case ([.command, .shift], "8"): command = .paragraph(.number)
        case ([.command, .shift], "9"): command = .paragraph(.checklist)
        case ([.command], "]"): command = .indent
        case ([.command], "["): command = .outdent
        default: break
        }
        if flags == [.command], event.keyCode == 36 { command = .toggleChecklist }
        if flags == [.command, .option], event.keyCode == 126 { command = .moveUp }
        if flags == [.command, .option], event.keyCode == 125 { command = .moveDown }
        guard let command else { return false }
        return perform(command)
    }

    /// Translate the physical event through the active keyboard layout with
    /// no modifiers. Shifted 7/8/9 yield punctuation in NSEvent.characters.
    private static func unshiftedKey(for event: NSEvent) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallbackDigit(for: event.keyCode)
        }
        let data = unsafeBitCast(property, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return fallbackDigit(for: event.keyCode) }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var count = 0
        let status = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &dead, chars.count, &count, &chars)
        guard status == noErr, count > 0 else { return fallbackDigit(for: event.keyCode) }
        return String(utf16CodeUnits: chars, count: count).lowercased()
    }

    private static func fallbackDigit(for keyCode: UInt16) -> String? {
        // Only used when the OS exposes no layout data (for example in a
        // headless test host); the normal path translates the active layout.
        switch keyCode {
        case 26: "7"
        case 28: "8"
        case 25: "9"
        default: nil
        }
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
                if font.pointSize >= 16 {
                    result.addAttribute(.noteBlockStyle, value: "heading", range: range)
                    result.addAttribute(.noteBlockLevel, value: font.pointSize >= 18 ? 1 : 2, range: range)
                }
            }
            if attributes[.underlineStyle] != nil { result.addAttribute(.noteMark(.underline), value: true, range: range) }
            if attributes[.strikethroughStyle] != nil { result.addAttribute(.noteMark(.strikethrough), value: true, range: range) }
            if attributes[.backgroundColor] != nil { result.addAttribute(.noteMark(.highlight), value: true, range: range) }
            if let url = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String {
                result.addAttribute(.noteMark(.link), value: url, range: range)
            }
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle,
               let list = paragraph.textLists.last {
                result.addAttribute(.noteBlockStyle, value: list.markerFormat == .decimal ? "number" : "bullet", range: range)
                result.addAttribute(.noteBlockIndent, value: min(2, max(0, paragraph.textLists.count - 1)), range: range)
            }
        }
        let normalized = NoteTextCodec.document(from: result, firstBlockIsTitle: false)
        let attributed = NoteTextCodec.attributedString(from: normalized, style: style, firstBlockIsTitle: false)
        return performEdit(selection, with: attributed, name: "Paste", selection: NSRange(location: selection.location + attributed.length, length: 0))
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

    private func numberedOrdinal(at location: Int, indent: Int) -> Int {
        var ordinal = 1
        var start = location
        while start > titleParagraphRange.length + 1 {
            let previous = lineRange(at: start - 1)
            guard previous.location < start, previous.location < textStorage.length else { break }
            let attrs = textStorage.attributes(at: previous.location, effectiveRange: nil)
            guard attrs[.noteBlockStyle] as? String == "number",
                  (attrs[.noteBlockIndent] as? Int ?? 0) == indent else { break }
            ordinal += 1
            start = previous.location
        }
        return ordinal
    }

    func headingRanges() -> [NoteAccessibilityParagraph] {
        accessibilityParagraphs(in: NSRange(location: 0, length: textStorage.length))
            .filter { $0.headingLevel != nil && !$0.text.isEmpty }
    }
}

@MainActor
extension NoteEditorEngine {
    /// The image importer calls this only after a slash Image or File request
    /// has produced a staged image. Cancel leaves the literal command intact.
    @discardableResult
    func commitSlashImage(_ item: StagedNoteAttachment, pixelSize: CGSize?) -> Bool {
        guard let session = pendingSlashFile else { return false }
        pendingSlashFile = nil
        guard NSMaxRange(session.range) <= textStorage.length,
              (textStorage.string as NSString).substring(with: session.range) == "/" + session.query else { return false }
        let line = lineRange(at: session.range.location)
        let atLineStart = session.range.location == line.location
        let image = NoteImageAttachment(attachmentID: item.id, preferredWidthFraction: 1, pixelSize: pixelSize)
        image.filename = item.filename
        var replacement = NSMutableAttributedString()
        if !atLineStart { replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes)) }
        replacement.append(NoteTextCodec.attachmentString(image, attributes: style.bodyAttributes))
        replacement.append(NSAttributedString(string: "\n", attributes: style.bodyAttributes))
        staged[item.id] = item
        let applied = performEdit(session.range, with: replacement, name: "Insert Image",
                                  selection: NSRange(location: session.range.location + replacement.length, length: 0))
        if !applied { staged[item.id] = nil }
        return applied
    }
}
