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
    private var layoutManager: NSTextLayoutManager?

    weak var imageProvider: NoteImageProviding?
    /// The text changed through editing, undo or an editor command.
    var onTextChange: (() -> Void)?
    /// Approved engine commands are durable even while rewrite notifications are suppressed.
    var onApprovedMutation: (() -> Void)?
    var onWritingToolsDidEnd: (() -> Void)?
    /// A short explanation for the status slot (a refused change).
    var onNotice: ((String) -> Void)?
    /// Called before a Writing Tools session starts (the session saves and
    /// keeps a version first).
    var onWritingToolsWillBegin: (() -> Bool)?
    /// Called before a copy or cut, so staged images become stored rows
    /// another note can copy.
    var onBeforeCopy: (() -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    /// Images imported in this session but not yet saved.
    private(set) var staged: [UUID: StagedNoteAttachment] = [:]

    // Guard state.
    var userEditDepth = 0
    private var engineEditDepth = 0
    private(set) var isWritingToolsSessionActive = false
    private var writingToolsBlocked = false
    var isWritingToolsBlocked: Bool { writingToolsBlocked }
    var writingToolsRefusalReason: String?
    private var writingToolsSnapshot: NSAttributedString?
    private var writingToolsHistory: NoteUndoHistory.Checkpoint?
    private var writingToolsObjectsBefore = Set<UUID>()
    private var writingToolsBypassDetected = false
    private var approvedWritingToolsShadow: NSMutableAttributedString?
    private enum ApprovedEdit {
        case command(NSRange, NSAttributedString, String)
        case undo, redo
        case unrecorded(NSRange, NSAttributedString)
    }
    private var approvedWritingToolsEdits: [ApprovedEdit] = []
    private var approvedReplayPending = false
    var isPerformingSelfMove = false
    private(set) var refusals: [String] = []
    private(set) var writingToolsRecoveries = 0

    /// Diagnostic: time spent in the last per-edit upkeep (ms).
    private(set) var lastUpkeepMilliseconds: Double = 0
    private(set) var documentExtractionCount = 0
    private var documentCache: (document: NoteDocument, finalParagraphStart: Int, finalParagraphDirty: Bool)?
    private var pendingImageLoads = Set<ObjectIdentifier>()

    init(noteID: UUID, document: NoteDocument, readOnly: Bool = false,
         design: AtticDesignContext = .default, today: NoteDay = NoteDay(date: Date()),
         imageProvider: NoteImageProviding? = nil,
         stagedAttachments: [StagedNoteAttachment] = []) {
        self.noteID = noteID
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
        history.onWillReplay = { [weak self] range, replacement in
            self?.willReplay(range, replacement: replacement) ?? true
        }
        history.onReplayCompleted = { [weak self] direction in self?.completedReplay(direction) }
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
        let result = NoteTextCodec.document(from: textStorage, template: template)
        let string = textStorage.string as NSString
        let newline = string.range(of: "\n", options: .backwards)
        let finalStart = newline.location == NSNotFound ? 0 : newline.location + 1
        documentCache = (result, finalStart, false)
        documentExtractionCount += 1
        return result
    }

    /// Recovery checkpoints during a refused Writing Tools session contain
    /// approved commands, never a rewrite that bypassed the refusal guard.
    func checkpointDocument() -> NoteDocument {
        if writingToolsBlocked, isWritingToolsSessionActive, let approvedWritingToolsShadow {
            return NoteTextCodec.document(from: approvedWritingToolsShadow, template: template)
        }
        return document()
    }

    private static func isSimpleTextBlock(_ block: NoteBlock) -> Bool {
        block.kind == .text && block.id == nil && block.style == nil && block.extras.isEmpty
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
        if let layoutManager { contentStorage.removeTextLayoutManager(layoutManager) }
        textView?.engine = nil
        textView?.delegate = nil
        layoutManager = nil
        textView = nil
        scrollView = nil
        history.textView = nil
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
        textView.writingToolsBehavior = .complete
        textView.allowedWritingToolsResultOptions = [.plainText]
        textView.setAccessibilityLabel(String(localized: "Note"))
    }

    // MARK: Look

    func update(design: AtticDesignContext) {
        guard renderer.update(design: design) else { return }
        style = NoteTextStyle(design: design)
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
    private func restyle(_ range: NSRange) {
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
            }
        }
        let bodyStart = max(titleEnd, clamped.location)
        let bodyEnd = NSMaxRange(clamped)
        if bodyEnd > bodyStart {
            textStorage.addAttributes(style.bodyAttributes, range: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
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
                if force || image.renderedImage == nil { loadImage(image) }
            } else if force || object.renderedImage == nil {
                renderer.apply(to: object, today: today)
            }
        }
    }

    private func invalidateLayout(_ range: NSRange) {
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

    private func attributes(forParagraphAt location: Int) -> [NSAttributedString.Key: Any] {
        paragraphRange(at: location).location == 0 ? style.titleAttributes : style.bodyAttributes
    }

    // MARK: Editor commands (each one undo step)

    /// Replaces `range` as one named step. Returns false when refused.
    @discardableResult
    func performEdit(_ range: NSRange, with replacement: NSAttributedString, name: String,
                     selection: NSRange? = nil) -> Bool {
        guard !isReadOnly, NSMaxRange(range) <= textStorage.length else { return false }
        let blocked = writingToolsBlocked && isWritingToolsSessionActive
        let approvedRange = blocked ? rangeInApprovedWritingToolsText(range) : nil
        if blocked && approvedRange == nil {
            return refuse(String(localized: "This command’s target changed during Writing Tools, so it was not applied."))
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
        if let approvedRange, let shadow = approvedWritingToolsShadow {
            shadow.replaceCharacters(in: approvedRange, with: replacement)
            approvedWritingToolsEdits.append(.command(approvedRange, NSAttributedString(attributedString: replacement), name))
            onApprovedMutation?()
        }
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

    /// Import placeholders reserve their final positions before the file
    /// reads yield. The store never sees them until every file has bytes.
    func completeImageImport(_ items: [StagedNoteAttachment]) {
        for item in items { staged[item.id] = item }
        renderObjects(in: NSRange(location: 0, length: textStorage.length), force: true)
        if writingToolsBlocked && isWritingToolsSessionActive { onApprovedMutation?() }
    }

    func cancelImageImport(_ ids: Set<UUID>) {
        var ranges: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let image = value as? NoteImageAttachment, ids.contains(image.attachmentID) else { return }
            let start = range.location > 0 && (textStorage.string as NSString).character(at: range.location - 1) == 0x0A
                ? range.location - 1 : range.location
            ranges.append(NSRange(location: start, length: NSMaxRange(range) - start))
        }
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            history.performUnrecorded {
                engineEditDepth += 1
                textStorage.replaceCharacters(in: range, with: "")
                textView?.didChangeText()
                engineEditDepth -= 1
            }
            history.rebase(editAt: range, newLength: 0)
        }
        if writingToolsBlocked && isWritingToolsSessionActive, let shadow = approvedWritingToolsShadow {
            var approvedRanges: [NSRange] = []
            shadow.enumerateAttribute(.attachment, in: NSRange(location: 0, length: shadow.length)) { value, range, _ in
                guard let image = value as? NoteImageAttachment, ids.contains(image.attachmentID) else { return }
                let start = range.location > 0 && (shadow.string as NSString).character(at: range.location - 1) == 0x0A
                    ? range.location - 1 : range.location
                approvedRanges.append(NSRange(location: start, length: NSMaxRange(range) - start))
            }
            for range in approvedRanges.sorted(by: { $0.location > $1.location }) {
                shadow.replaceCharacters(in: range, with: "")
                approvedWritingToolsEdits.append(.unrecorded(range, NSAttributedString(string: "")))
            }
            onApprovedMutation?()
        }
        for id in ids { staged[id] = nil }
    }

    // MARK: Keys with object rules

    /// Return on a checklist line continues the list; on an empty checklist
    /// line it ends the list (the box goes).
    func handleNewline() -> Bool {
        guard let textView, !textView.hasMarkedText() else { return false }
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
        guard !(writingToolsBlocked && isWritingToolsSessionActive) else { return }
        onTextChange?()
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
        textView.typingAttributes = attributes(forParagraphAt: selection.location)
        onSelectionChange?(selection)
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
        let preserved = onWritingToolsWillBegin?() ?? true
        writingToolsBlocked = !preserved
        isWritingToolsSessionActive = true
        writingToolsBypassDetected = false
        approvedWritingToolsShadow = writingToolsBlocked ? NSMutableAttributedString(attributedString: textStorage) : nil
        approvedWritingToolsEdits = []
        guard preserved else {
            onNotice?(writingToolsRefusalReason ?? String(localized: "Writing Tools can’t change this note until a recovery version is saved."))
            return
        }
    }

    /// If an object disappeared anyway (a path that never asked), the text
    /// goes back to how it was before the session and the session's steps
    /// leave the history: Undo can't return to the loss, Redo has nothing.
    func writingToolsDidEnd() {
        let wasBlocked = writingToolsBlocked
        isWritingToolsSessionActive = false
        guard let snapshot = writingToolsSnapshot else { return }
        writingToolsSnapshot = nil
        let lost = writingToolsObjectsBefore.subtracting(objectIDs())
        writingToolsObjectsBefore = []
        let bypass = wasBlocked && writingToolsBypassDetected
        writingToolsBypassDetected = false
        let approvedEdits = approvedWritingToolsEdits
        approvedWritingToolsEdits = []
        approvedWritingToolsShadow = nil
        guard bypass || (!wasBlocked && !lost.isEmpty) else {
            writingToolsBlocked = false
            writingToolsRefusalReason = nil
            writingToolsHistory = nil
            onWritingToolsDidEnd?()
            return
        }
        let whole = NSRange(location: 0, length: textStorage.length)
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
        // The text is exactly as it was before the session, so the history
        // goes back exactly too: none of the session's steps (nor any step
        // rebased around its changes) survives to redo or undo into loss.
        if let checkpoint = writingToolsHistory { history.rewind(to: checkpoint) }
        writingToolsHistory = nil
        writingToolsBlocked = false
        writingToolsRefusalReason = nil
        if bypass {
            for edit in approvedEdits {
                switch edit {
                case let .command(range, replacement, name):
                    performEdit(range, with: replacement, name: name)
                case .undo: history.undo()
                case .redo: history.redo()
                case let .unrecorded(range, replacement):
                    history.performUnrecorded {
                        textStorage.replaceCharacters(in: range, with: replacement)
                    }
                    history.rebase(editAt: range, newLength: replacement.length)
                }
            }
            renderObjects(in: NSRange(location: 0, length: textStorage.length), force: true)
        }
        writingToolsRecoveries += 1
        if !wasBlocked { onTextChange?() }
        onWritingToolsDidEnd?()
        onNotice?(wasBlocked
            ? String(localized: "Writing Tools changed this note without approval, so its rewrite was not kept.")
            : String(localized: "Writing Tools changed an image, checklist or date, so its rewrite was not kept."))
    }

    // MARK: NSTextStorageDelegate

    /// Records the change, then the per-edit upkeep: only the edited
    /// paragraphs and their neighbours are restyled (attributes only, which
    /// processEditing allows here).
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if editedMask.contains(.editedAttributes), writingToolsBlocked && isWritingToolsSessionActive,
           engineEditDepth == 0 && !history.isReplaying && userEditDepth == 0 {
            writingToolsBypassDetected = true
        }
        guard editedMask.contains(.editedCharacters) else { return }
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
        let bypass = writingToolsBlocked && isWritingToolsSessionActive && engineEditDepth == 0
            && !history.isReplaying && userEditDepth == 0
        if bypass {
            writingToolsBypassDetected = true
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

    /// Resolve an approved command against the recovery shadow. Object IDs
    /// identify object targets; plain-text edits need one unique nearby anchor.
    /// The latter is capped so a rewrite cannot trigger an expensive diff on
    /// the main actor or silently widen a deletion.
    private func rangeInApprovedWritingToolsText(_ range: NSRange) -> NSRange? {
        guard let shadow = approvedWritingToolsShadow else { return nil }
        guard NSMaxRange(range) <= textStorage.length else { return nil }
        if !writingToolsBypassDetected { return range }
        var liveObjects: [(NoteObjectAttachment, NSRange)] = []
        if range.length > 0 {
            textStorage.enumerateAttribute(.attachment, in: range) { value, found, _ in
                if let object = value as? NoteObjectAttachment { liveObjects.append((object, found)) }
            }
        }
        if liveObjects.count == 1 {
            let (object, objectRange) = liveObjects[0]
            var matches: [NSRange] = []
            shadow.enumerateAttribute(.attachment, in: NSRange(location: 0, length: shadow.length)) { value, found, _ in
                if (value as? NoteObjectAttachment)?.objectID == object.objectID { matches.append(found) }
            }
            guard matches.count == 1 else { return nil }
            let start = matches[0].location + range.location - objectRange.location
            guard start >= 0, start + range.length <= shadow.length else { return nil }
            let mapped = NSRange(location: start, length: range.length)
            guard shadow.attributedSubstring(from: mapped).string == textStorage.attributedSubstring(from: range).string else {
                return nil
            }
            return mapped
        }
        guard liveObjects.isEmpty, shadow.length <= 65_536 else { return nil }
        let live = textStorage.string as NSString
        let clean = shadow.string as NSString
        for span in [24, 16, 8, 4] {
            let before = min(span, range.location)
            let after = min(span, live.length - NSMaxRange(range))
            guard before + after > 0 else { continue }
            let probe = live.substring(with: NSRange(location: range.location - before,
                                                     length: before + range.length + after))
            let first = clean.range(of: probe)
            guard first.location != NSNotFound else { continue }
            let remainder = NSRange(location: NSMaxRange(first), length: clean.length - NSMaxRange(first))
            guard clean.range(of: probe, range: remainder).location == NSNotFound else { return nil }
            return NSRange(location: first.location + before, length: range.length)
        }
        return nil
    }

    private func willReplay(_ range: NSRange, replacement: NSAttributedString) -> Bool {
        guard writingToolsBlocked && isWritingToolsSessionActive else { return true }
        guard let approved = rangeInApprovedWritingToolsText(range), let shadow = approvedWritingToolsShadow else {
            return refuse(String(localized: "Undo’s target changed during Writing Tools, so it was not applied."))
        }
        shadow.replaceCharacters(in: approved, with: replacement)
        approvedReplayPending = true
        return true
    }

    private func didReplay(_ range: NSRange) {
        if writingToolsBlocked && isWritingToolsSessionActive {
            return
        }
        onTextChange?()
    }

    private func completedReplay(_ direction: NoteUndoHistory.ReplayDirection) {
        guard writingToolsBlocked && isWritingToolsSessionActive, approvedReplayPending else { return }
        approvedWritingToolsEdits.append(direction == .undo ? .undo : .redo)
        approvedReplayPending = false
        onApprovedMutation?()
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
        onBeforeCopy?()
        let fragment = fragment(for: range)
        pasteboard.declareTypes(types, owner: nil)
        var wrote = false
        for type in types {
            switch type {
            case Self.fragmentType:
                if let data = try? NoteContentCodec.encode(fragment) { wrote = pasteboard.setData(data, forType: type) || wrote }
            case .string:
                wrote = pasteboard.setString(NoteTextExport.plainText(fragment), forType: .string) || wrote
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
            case .checklist:
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
        return performEdit(selection, with: attributed, name: String(localized: "Paste"),
                           selection: NSRange(location: selection.location + attributed.length, length: 0))
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
