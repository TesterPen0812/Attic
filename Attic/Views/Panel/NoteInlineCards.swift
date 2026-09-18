import AppKit
import SwiftUI

struct NoteAttachmentDragHandle: NSViewRepresentable {
    let id: UUID
    func makeNSView(context: Context) -> NoteAttachmentDragView { NoteAttachmentDragView() }
    func updateNSView(_ view: NoteAttachmentDragView, context: Context) { view.attachmentID = id }
}

final class NoteAttachmentDragView: NSView, NSDraggingSource {
    var attachmentID = UUID()
    private var dragEvent: NSEvent?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move attachment")?
            .draw(in: bounds.insetBy(dx: 4, dy: 14), from: .zero, operation: .sourceOver, fraction: 0.55)
    }
    override func mouseDown(with event: NSEvent) { dragEvent = event }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragEvent else { return }
        dragEvent = nil
        let item = NSPasteboardItem()
        item.setString(attachmentID.uuidString, forType: NoteInlineCardsLayout.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(CGRect(x: 0, y: 0, width: 32, height: 32),
            contents: NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
        beginDraggingSession(with: [draggingItem], event: start, source: self)
    }
    override func mouseUp(with event: NSEvent) { dragEvent = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

struct NoteAttachmentResizeHandle: NSViewRepresentable {
    let onPreview: (CGSize) -> Void
    let onCommit: (CGSize) -> Void
    func makeNSView(context: Context) -> NoteAttachmentResizeView { NoteAttachmentResizeView() }
    func updateNSView(_ view: NoteAttachmentResizeView, context: Context) {
        view.onPreview = onPreview; view.onCommit = onCommit
    }
}

final class NoteAttachmentResizeView: NSView {
    var onPreview: (CGSize) -> Void = { _ in }
    var onCommit: (CGSize) -> Void = { _ in }
    private var start: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize attachment")?
            .draw(in: bounds.insetBy(dx: 5, dy: 5), from: .zero, operation: .sourceOver, fraction: 0.55)
    }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onPreview(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        onCommit(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y))
    }
}

struct NoteMovableAttachmentCard: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController
    let attachment: NoteAttachment
    @State private var selected: UUID?
    @State private var resizeDelta = CGSize.zero
    @State private var isTargeted = false
    @State private var dismissedRecoveryMessage: String?

    /// Recovery choices get their own line, so the card grows by exactly that
    /// line while an attachment needs attention (NOTES-011).
    private var recoveryHeight: CGFloat {
        guard let failure = noteStore.attachmentFailures[attachment.id],
              failure != dismissedRecoveryMessage else { return 0 }
        return NoteInlineCard.recoveryRowHeight
    }

    /// A new attachment starts as a compact card (NOTES-005) and only grows
    /// when the reader asks for a larger preview or drags the resize handle.
    private var size: CGSize {
        CGSize(width: max(150, (attachment.displayWidth ?? NoteMovableAttachmentCard.compactWidth) + resizeDelta.width),
               height: max(NoteInlineCard.compactHeight,
                           (attachment.displayHeight ?? NoteInlineCard.compactHeight) + resizeDelta.height))
    }

    static let compactWidth: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            if attachment.isImage, size.height > NoteInlineCard.compactHeight + 44 {
                AttachmentPreviewImage(noteStore: noteStore, attachment: attachment,
                                       presentation: .inlineImage,
                                       displayHeight: size.height - NoteInlineCard.compactHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: size.height - NoteInlineCard.compactHeight)
                    .clipped()
            }
            HStack(spacing: 0) {
                NoteAttachmentDragHandle(id: attachment.id).frame(width: 18, height: 40)
                NoteFileAttachmentCard(noteStore: noteStore, attachment: attachment,
                    selectedAttachmentID: $selected,
                    dismissedRecoveryMessage: $dismissedRecoveryMessage,
                    placementActions: AnyView(placementActions))
            }
        }
        .frame(maxWidth: size.width, alignment: .leading)
        .frame(height: size.height + recoveryHeight, alignment: .top)
        .background(.primary.opacity(isTargeted ? 0.09 : 0.02), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            NoteAttachmentResizeHandle(onPreview: { resizeDelta = $0 }, onCommit: { delta in
                resizeDelta = .zero
                place(size: CGSize(
                    width: (attachment.displayWidth ?? NoteMovableAttachmentCard.compactWidth) + delta.width,
                    height: (attachment.displayHeight ?? NoteInlineCard.compactHeight) + delta.height
                ))
            })
            .frame(width: 20, height: 20)
            .accessibilityLabel("Resize \(attachment.originalFilename)")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 30 : -30
                place(size: CGSize(width: size.width + step, height: size.height + step))
            }
        }
        .onDrop(of: [NoteInlineCardsLayout.dragType.rawValue], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: NoteInlineCardsLayout.dragType.rawValue) { item, _ in
                let value = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let value, let id = UUID(uuidString: value) else { return }
                Task { @MainActor in
                    guard noteDraft.flush() else { return }
                    _ = noteStore.placeAttachment(id, in: attachment.noteID, offset: attachment.inlineOffset, before: attachment.id)
                }
            }
            return true
        }
        .contextMenu { placementActions }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var placementActions: some View {
            Button("Place at text cursor") {
                guard noteDraft.flush() else { return }
                _ = noteStore.placeAttachment(attachment.id, in: attachment.noteID,
                    offset: noteDraft.editorViewState.selectionLocation)
            }
            Button("Move to end of note") {
                guard noteDraft.flush() else { return }
                _ = noteStore.placeAttachment(attachment.id, in: attachment.noteID, offset: nil)
            }
            Button("Move up") { move(by: -1) }
            Button("Move down") { move(by: 1) }
            Divider()
            Button("Compact card") {
                place(size: CGSize(width: NoteMovableAttachmentCard.compactWidth,
                                   height: NoteInlineCard.compactHeight))
            }
            if attachment.isImage {
                Button("Large preview") { place(size: CGSize(width: 280, height: 220)) }
            }
    }

    private func place(size: CGSize) {
        guard noteDraft.flush() else { return }
        _ = noteStore.placeAttachment(attachment.id, in: attachment.noteID, offset: attachment.inlineOffset, size: size)
    }

    private func move(by step: Int) {
        guard noteDraft.flush() else { return }
        let cards = noteStore.attachments(for: attachment.noteID)
        guard let index = cards.firstIndex(where: { $0.id == attachment.id }) else { return }
        let destination = min(max(index + step, 0), cards.count - 1)
        guard destination != index else { return }
        let before = step < 0 ? cards[destination].id : (destination + 1 < cards.count ? cards[destination + 1].id : nil)
        _ = noteStore.placeAttachment(attachment.id, in: attachment.noteID,
            offset: cards[destination].inlineOffset, before: before)
    }
}

/// Identity of an inline card's rendered subtree. Replacing an
/// `NSHostingView`'s root view re-renders everything inside it, so typing —
/// which moves anchors, not card contents — must not change this.
struct NoteInlineCardRevision: Equatable {
    var attachment: ObjectIdentifier?
    var updatedAt: Date?
    var displayWidth: Double?
    var displayHeight: Double?
    var retryVersion: UInt64 = 0
    var failure: String?
}

struct NoteInlineCard {
    /// The compact default card height (NOTES-005). A new attachment starts
    /// compact and only grows when the reader asks for a larger preview.
    static let compactHeight: CGFloat = 56
    /// The single recovery line a broken attachment adds (NOTES-011).
    static let recoveryRowHeight: CGFloat = 34

    let id: UUID
    let offset: Int
    let height: CGFloat
    let revision: NoteInlineCardRevision
    let content: AnyView

    init(
        id: UUID,
        offset: Int,
        height: CGFloat,
        revision: NoteInlineCardRevision = NoteInlineCardRevision(),
        content: AnyView
    ) {
        self.id = id
        self.offset = offset
        self.height = height
        self.revision = revision
        self.content = content
    }
}

/// Keeps the note body's edit history as an ordered list of replacements so
/// inline anchors rebase in O(#edits) per card instead of diffing the whole
/// document per card on every keystroke (PERF-12). Disjoint edits stay
/// separate elements: text that survives between them is never folded into a
/// replaced span, so an anchored paragraph keeps its anchor.
///
/// The ledger is deliberately conservative: it only answers incrementally when
/// its recorded history describes exactly the pair of bodies being rebased, and
/// it self-checks every recorded edit against the resulting text length. Any
/// disagreement drops back to the full diff, so anchor correctness never
/// depends on the editor delivering a perfect edit stream.
///
/// Deliberately un-isolated: `NSTextStorage` and `NSTextView` delegate
/// callbacks deliver edits on the UI thread synchronously, and the ledger is
/// neither `Sendable` nor reachable from another actor.
final class NoteBodyEditLedger {
    private var anchorText: String?
    private var currentText: String?
    private var currentLength = 0
    /// The ordered edits applied since `anchorText`. Empty means "nothing has
    /// been edited since the anchor".
    private var pendingEdits: [NoteTextReplacement] = []

    /// Test/diagnostic seams: how often the incremental path was used.
    private(set) var incrementalRebases = 0
    private(set) var fullDiffs = 0

    /// Records one applied storage edit. `text` is the storage's new contents.
    func record(_ edit: NoteTextReplacement, resulting text: String) {
        record([edit], resulting: text)
    }

    /// Records the ordered storage edits applied in one published body.
    /// Every edit is checked against the running intermediate length and the
    /// batch against `text`'s length, so a missed, duplicated, or
    /// out-of-order edit drops back to the full diff instead of moving a card
    /// to the wrong paragraph.
    func record(_ edits: [NoteTextReplacement], resulting text: String) {
        guard anchorText != nil, currentText != nil else {
            invalidate()
            return
        }
        var length = currentLength
        for edit in edits {
            guard edit.location <= length, edit.oldLength <= length - edit.location else {
                invalidate()
                return
            }
            length += edit.delta
        }
        // An empty batch only describes unchanged text; a length match alone
        // cannot prove content did not change under it.
        guard length == text.utf16.count,
              !edits.isEmpty || NoteTextReplacement.utf16Equal(text, currentText ?? "") else {
            invalidate()
            return
        }
        pendingEdits.append(contentsOf: edits)
        currentText = text
        currentLength = length
    }

    /// Drops incremental tracking; the next rebase falls back to a full diff.
    func invalidate() {
        anchorText = nil
        currentText = nil
        pendingEdits = []
    }

    func reset(to text: String) {
        anchorText = text
        currentText = text
        currentLength = text.utf16.count
        pendingEdits = []
    }

    /// The ordered edits mapping `oldText` to `newText`.
    func edits(from oldText: String, to newText: String) -> [NoteTextReplacement] {
        if let anchorText, let currentText,
           NoteTextReplacement.utf16Equal(anchorText, oldText),
           NoteTextReplacement.utf16Equal(currentText, newText) {
            incrementalRebases += 1
            return pendingEdits
        }
        fullDiffs += 1
        anchorText = oldText
        currentText = newText
        currentLength = newText.utf16.count
        pendingEdits = NoteTextReplacement.edits(from: oldText, to: newText)
        return pendingEdits
    }


    func batch(from oldText: String, to newText: String) -> NoteBodyEditBatch {
        NoteBodyEditBatch(
            baseText: oldText,
            resultText: newText,
            edits: edits(from: oldText, to: newText)
        )
    }
}

/// Resolves the composer's inline cards and tray rows once per meaningful
/// change instead of once per `noteDraft` publish (PERF-12d). The panel
/// republishes several times per keystroke — selection, scroll, autosave
/// status — and none of those move an anchor.
@MainActor
final class NoteInlineCardResolver {
    struct Resolution {
        var cards: [NoteInlineCard] = []
        /// Attachments that are not currently placed inline, so the document
        /// tray still owns exactly the cards the body does not show.
        var trayAttachments: [NoteAttachment] = []
    }

    /// Test/diagnostic seam: how often the memo missed.
    private(set) var rebuilds = 0

    private struct Key: Equatable {
        let noteID: UUID?
        let revision: UInt64
        let failures: [UUID: String]
        let retryVersions: [UUID: UInt64]
        let savedBody: String
        let body: String

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.noteID == rhs.noteID
                && lhs.revision == rhs.revision
                && lhs.failures == rhs.failures
                && lhs.retryVersions == rhs.retryVersions
                && NoteTextReplacement.utf16Equal(lhs.savedBody, rhs.savedBody)
                && NoteTextReplacement.utf16Equal(lhs.body, rhs.body)
        }
    }

    private var cachedKey: Key?
    private var cached = Resolution()

    func resolve(noteStore: NoteStore, noteDraft: NoteDraftController) -> Resolution {
        let noteID = noteDraft.activeNoteID
        let body = noteDraft.body
        let savedBody = noteID.flatMap { noteStore.note(withID: $0)?.body } ?? body
        let key = Key(
            noteID: noteID,
            revision: noteStore.revision,
            failures: noteStore.attachmentFailures,
            retryVersions: noteStore.attachmentRetryVersions,
            savedBody: savedBody,
            body: body
        )
        if key == cachedKey { return cached }
        rebuilds += 1
        cachedKey = key

        guard let noteID else {
            cached = Resolution()
            return cached
        }
        let edits = noteDraft.bodyEditLedger.edits(from: savedBody, to: body)
        let length = (body as NSString).length
        var resolution = Resolution()
        for attachment in noteStore.attachments(for: noteID) {
            guard let storedOffset = attachment.inlineOffset else {
                resolution.trayAttachments.append(attachment)
                continue
            }
            let offset = NoteInlineAnchor.moved(storedOffset, by: edits, in: body)
            guard offset < length else {
                resolution.trayAttachments.append(attachment)
                continue
            }
            resolution.cards.append(NoteInlineCard(
                id: attachment.id,
                offset: offset,
                height: (attachment.displayHeight ?? NoteInlineCard.compactHeight)
                    + (noteStore.attachmentFailures[attachment.id] == nil
                        ? 0 : NoteInlineCard.recoveryRowHeight),
                revision: NoteInlineCardRevision(
                    attachment: ObjectIdentifier(attachment),
                    updatedAt: attachment.updatedAt,
                    displayWidth: attachment.displayWidth,
                    displayHeight: attachment.displayHeight,
                    retryVersion: noteStore.attachmentRetryVersions[attachment.id] ?? 0,
                    failure: noteStore.attachmentFailures[attachment.id]
                ),
                content: AnyView(NoteMovableAttachmentCard(
                    noteStore: noteStore, noteDraft: noteDraft, attachment: attachment
                ))
            ))
        }
        cached = resolution
        return resolution
    }
}

/// A small native layout adapter reserves paragraph space without putting image bytes,
/// object replacement characters, or formatting markup into the plain note body.
@MainActor
final class NoteInlineCardsLayout {
    /// A constant, so pasteboard classification off the main actor may read it.
    nonisolated static let dragType = NSPasteboard.PasteboardType("com.taha.Attic.note-attachment-move")

    /// One paragraph's reserved spacing, as it was last written into storage.
    private struct ReservedParagraph: Equatable {
        let range: NSRange
        let spacing: CGFloat
    }

    private var hosts: [UUID: NSHostingView<AnyView>] = [:]
    private var hostRevisions: [UUID: NoteInlineCardRevision] = [:]
    private var cards: [NoteInlineCard] = []
    private var appliedSignature = ""
    private var reserved: [ReservedParagraph] = []
    private var baseTextInset: NSSize?
    var frames: [UUID: CGRect] { hosts.mapValues(\.frame) }

    /// Test/diagnostic seams for the PERF-12 gates: per-keystroke work must be
    /// O(edit), not O(document).
    private(set) var restyledParagraphCount = 0
    private(set) var rootViewReplacementCount = 0

    @discardableResult
    func update(_ cards: [NoteInlineCard], in textView: NSTextView) -> Bool {
        let previous = appliedSignature
        self.cards = cards
        let ids = Set(cards.map(\.id))
        for id in Array(hosts.keys) where !ids.contains(id) {
            hosts.removeValue(forKey: id)?.removeFromSuperview()
            hostRevisions.removeValue(forKey: id)
        }
        for card in cards {
            guard let host = hosts[card.id] else {
                let host = NSHostingView(rootView: card.content)
                host.sizingOptions = []
                hosts[card.id] = host
                hostRevisions[card.id] = card.revision
                rootViewReplacementCount += 1
                // NSTextView owns its event/accessibility tree. Sibling cards
                // participate normally in both, while sharing the document scroll.
                (textView.superview ?? textView).addSubview(host)
                continue
            }
            // Assigning rootView re-renders the card's whole SwiftUI subtree.
            // A keystroke moves the anchor, not the card, so only a changed
            // card identity justifies that cost.
            guard hostRevisions[card.id] != card.revision else { continue }
            host.rootView = card.content
            hostRevisions[card.id] = card.revision
            rootViewReplacementCount += 1
        }
        let reapplied = reserveSpace(in: textView)
        return previous != appliedSignature || reapplied
    }

    @discardableResult
    func reserveSpace(in textView: NSTextView) -> Bool {
        guard !cards.isEmpty || !appliedSignature.isEmpty else { return false }
        guard let storage = textView.textStorage else { return false }
        let string = textView.string
        let text = string as NSString
        // The signature describes the cards and the paragraphs they anchor to —
        // never the whole document string, which changes on every keystroke.
        var signature = ""
        var desired: [ReservedParagraph] = []
        var leadingHeight = CGFloat(0)
        let grouped = Dictionary(grouping: cards) { NoteInlineAnchor.paragraphStart($0.offset, in: string) }
        for offset in grouped.keys.sorted() {
            let group = grouped[offset] ?? []
            let spacing = group.reduce(CGFloat(0)) { $0 + $1.height + 8 }
            signature += "@\(offset)=\(spacing)["
            signature += group.map { "\($0.id.uuidString):\($0.offset):\($0.height)" }.joined(separator: ",")
            signature += "]"
            if offset == 0 { leadingHeight = spacing }
            guard offset > 0, offset < storage.length else { continue }
            let range = text.paragraphRange(for: NSRange(location: offset, length: 0))
            signature += "r\(range.location),\(range.length)"
            desired.append(ReservedParagraph(range: range, spacing: spacing))
        }
        // Reopening a plain NSTextView can replace attributes without changing
        // its string. Presentation spacing must be repaired independently.
        let spacingSurvived = desired.allSatisfy { paragraph in
            let style = storage.attribute(
                .paragraphStyle, at: paragraph.range.location, effectiveRange: nil
            ) as? NSParagraphStyle
            return style?.paragraphSpacingBefore == paragraph.spacing
        }
        guard signature != appliedSignature || !spacingSurvived else { return false }
        appliedSignature = cards.isEmpty ? "" : signature

        // Only paragraphs whose reserved spacing actually changed are touched.
        let reusable = spacingSurvived ? reserved.filter { desired.contains($0) } : []
        textView.undoManager?.disableUndoRegistration()
        defer { textView.undoManager?.enableUndoRegistration() }
        storage.beginEditing()
        for paragraph in reserved where !reusable.contains(paragraph) {
            let location = min(paragraph.range.location, storage.length)
            let length = min(paragraph.range.length, storage.length - location)
            guard length > 0 else { continue }
            storage.removeAttribute(.paragraphStyle, range: NSRange(location: location, length: length))
            restyledParagraphCount += 1
        }
        for paragraph in desired where !reusable.contains(paragraph) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = paragraph.spacing
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            restyledParagraphCount += 1
        }
        storage.endEditing()
        reserved = desired
        if baseTextInset == nil { baseTextInset = textView.textContainerInset }
        let base = baseTextInset ?? .zero
        textView.textContainerInset = NSSize(width: base.width, height: base.height + leadingHeight)
        // Formatting must never leak into newly typed paragraphs.
        textView.typingAttributes.removeValue(forKey: .paragraphStyle)
        return true
    }

    func layout(in textView: NSTextView) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let grouped = Dictionary(grouping: cards) { NoteInlineAnchor.paragraphStart($0.offset, in: textView.string) }
        for (offset, group) in grouped {
            guard offset < (textView.string as NSString).length else {
                for card in group { hosts[card.id]?.isHidden = true }
                continue
            }
            let glyph = manager.glyphIndexForCharacter(at: offset)
            let line = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let total = group.reduce(CGFloat(0)) { $0 + $1.height + 8 }
            var y = line.minY + textView.textContainerOrigin.y - total
            for card in group {
                hosts[card.id]?.isHidden = false
                let local = CGRect(x: textView.textContainerOrigin.x, y: max(0, y),
                    width: max(1, textView.bounds.width - textView.textContainerOrigin.x * 2), height: card.height)
                if let host = hosts[card.id], let parent = host.superview {
                    host.frame = parent === textView ? local : textView.convert(local, to: parent)
                }
                y += card.height + 8
            }
        }
    }
}
