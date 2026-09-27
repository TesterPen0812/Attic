import AppKit

/// Maps a document to the editor's attributed text and back. Paragraph i is
/// block i; objects are `NoteObjectAttachment`s; a text paragraph's id,
/// style and unknown fields ride on its characters.
@MainActor
enum NoteTextCodec {
    // MARK: Document → text

    static func attributedString(
        from document: NoteDocument,
        style: NoteTextStyle,
        firstBlockIsTitle: Bool = true
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            let isTitle = firstBlockIsTitle && index == 0
            var attributes = isTitle ? style.titleAttributes : style.bodyAttributes
            if let id = block.id, block.kind == .text { attributes[.noteBlockID] = id }
            if !block.extras.isEmpty { attributes[.noteBlockExtras] = NoteBlockExtras(block.extras) }
            if let blockStyle = block.style, block.kind == .text { attributes[.noteBlockStyle] = blockStyle }
            let paragraph = NSMutableAttributedString()
            switch block.kind {
            case .text:
                paragraph.append(inlineText(block, attributes: attributes))
            case .checklist:
                let box = NoteChecklistAttachment(objectID: block.id ?? UUID(), isChecked: block.checked)
                paragraph.append(attachmentString(box, attributes: attributes))
                paragraph.append(inlineText(block, attributes: attributes))
            case .image:
                let image = NoteImageAttachment(
                    objectID: block.id ?? UUID(),
                    attachmentID: block.attachmentID ?? UUID(),
                    preferredWidth: block.width,
                    preferredWidthFraction: block.widthFraction,
                    pixelSize: pixelSize(block),
                    extras: block.extras
                )
                paragraph.append(attachmentString(image, attributes: attributes))
            case .opaque:
                let opaque = NoteOpaqueAttachment(objectID: block.opaqueID ?? UUID(), value: block.opaque ?? .null, isInline: false)
                paragraph.append(attachmentString(opaque, attributes: attributes))
            }
            if index < document.blocks.count - 1 {
                paragraph.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            result.append(paragraph)
        }
        return result
    }

    private static func pixelSize(_ block: NoteBlock) -> CGSize? {
        guard let width = block.pixelWidth, let height = block.pixelHeight else { return nil }
        return CGSize(width: width, height: height)
    }

    static func attachmentString(_ attachment: NoteObjectAttachment,
                                 attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    private static func inlineText(_ block: NoteBlock, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var run = ""
        var inlineIndex = 0
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: attributes))
            run = ""
        }
        for character in block.text {
            guard character == NoteDocument.objectCharacter, inlineIndex < block.inlines.count else {
                run.append(character)
                continue
            }
            flush()
            let inline = block.inlines[inlineIndex]
            inlineIndex += 1
            let attachment: NoteObjectAttachment = switch inline.kind {
            case let .date(day): NoteDateAttachment(objectID: inline.id, day: day, extras: inline.extras)
            case let .opaque(value): NoteOpaqueAttachment(objectID: inline.id, value: value, isInline: true)
            }
            result.append(attachmentString(attachment, attributes: attributes))
        }
        flush()
        return result
    }

    // MARK: Text → document

    /// `template` supplies the document-level fields (format, requires,
    /// unknown fields). Objects that sit mid-line (only possible through a
    /// path the editor did not shape) are split onto their own blocks, never
    /// dropped. A U+FFFC with no note object behind it is dropped.
    static func document(
        from text: NSAttributedString,
        template: NoteDocument = .blank,
        firstBlockIsTitle: Bool = true
    ) -> NoteDocument {
        let string = text.string as NSString
        var blocks: [NoteBlock] = []
        var usedIDs = Set<UUID>()
        var usedExtras = Set<ObjectIdentifier>()
        var location = 0
        repeat {
            let newline = string.range(of: "\n", options: .literal,
                                       range: NSRange(location: location, length: string.length - location))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let paragraph = NSRange(location: location, length: end - location)
            let withBreak = NSRange(location: location, length: min(string.length, end + 1) - location)
            blocks += blocksForParagraph(text, paragraph: paragraph, metadataRange: withBreak,
                                         usedIDs: &usedIDs, usedExtras: &usedExtras)
            location = end + 1
        } while location <= string.length

        if firstBlockIsTitle, blocks.first?.kind != .text {
            blocks.insert(.text(""), at: 0)
        }
        var document = template
        document.blocks = blocks.isEmpty ? [.text("")] : blocks
        return document
    }

    private struct ParagraphMetadata {
        var id: UUID?
        var style: String?
        var extras: [String: NoteJSON] = [:]
    }

    private static func metadata(
        _ text: NSAttributedString,
        in range: NSRange,
        usedIDs: inout Set<UUID>,
        usedExtras: inout Set<ObjectIdentifier>
    ) -> ParagraphMetadata {
        var result = ParagraphMetadata()
        guard range.length > 0 else { return result }
        text.enumerateAttributes(in: range) { attributes, _, stop in
            if result.id == nil, let id = attributes[.noteBlockID] as? UUID, !usedIDs.contains(id) {
                result.id = id
            }
            if result.style == nil, let style = attributes[.noteBlockStyle] as? String { result.style = style }
            if result.extras.isEmpty, let box = attributes[.noteBlockExtras] as? NoteBlockExtras,
               !usedExtras.contains(ObjectIdentifier(box)) {
                result.extras = box.fields
                usedExtras.insert(ObjectIdentifier(box))
            }
            if result.id != nil, result.style != nil, !result.extras.isEmpty { stop.pointee = true }
        }
        if let id = result.id { usedIDs.insert(id) }
        return result
    }

    private static func blocksForParagraph(
        _ text: NSAttributedString,
        paragraph: NSRange,
        metadataRange: NSRange,
        usedIDs: inout Set<UUID>,
        usedExtras: inout Set<ObjectIdentifier>
    ) -> [NoteBlock] {
        let meta = metadata(text, in: metadataRange, usedIDs: &usedIDs, usedExtras: &usedExtras)
        var blocks: [NoteBlock] = []
        // The block being built; the paragraph's own fields go to the first.
        var current = NoteBlock(kind: .text, id: meta.id, style: meta.style, extras: meta.extras)
        var hasContent = false

        func finishCurrent() {
            if hasContent || current.kind == .checklist { blocks.append(current) }
            current = NoteBlock(kind: .text)
            hasContent = false
        }

        let string = text.string as NSString
        var index = paragraph.location
        while index < NSMaxRange(paragraph) {
            guard string.character(at: index) == NoteDocument.objectUnit else {
                // A run of plain characters up to the next object.
                let rest = NSRange(location: index, length: NSMaxRange(paragraph) - index)
                let next = string.range(of: "\u{FFFC}", options: .literal, range: rest)
                let runEnd = next.location == NSNotFound ? NSMaxRange(paragraph) : next.location
                current.text += string.substring(with: NSRange(location: index, length: runEnd - index))
                hasContent = true
                index = runEnd
                continue
            }
            switch text.attribute(.attachment, at: index, effectiveRange: nil) {
            case let box as NoteChecklistAttachment:
                let leadsParagraph = index == paragraph.location
                if !leadsParagraph { finishCurrent() }
                current = NoteBlock(kind: .checklist, id: box.objectID, checked: box.isChecked,
                                    extras: leadsParagraph ? meta.extras : [:])
                hasContent = false
            case let image as NoteImageAttachment:
                finishCurrent()
                var block = NoteBlock.image(id: image.objectID, attachmentID: image.attachmentID,
                                            width: image.preferredWidth,
                                            widthFraction: image.preferredWidthFraction,
                                            pixelWidth: image.pixelSize.map { Int($0.width) },
                                            pixelHeight: image.pixelSize.map { Int($0.height) })
                block.extras = image.extras
                blocks.append(block)
            case let opaque as NoteOpaqueAttachment where !opaque.isInline:
                finishCurrent()
                blocks.append(.opaque(opaque.value))
            case let date as NoteDateAttachment:
                current.text.append(NoteDocument.objectCharacter)
                current.inlines.append(NoteInline(id: date.objectID, kind: .date(date.day), extras: date.extras))
                hasContent = true
            case let opaque as NoteOpaqueAttachment:
                current.text.append(NoteDocument.objectCharacter)
                current.inlines.append(NoteInline(id: opaque.objectID, kind: .opaque(opaque.value)))
                hasContent = true
            default:
                // A bare U+FFFC (or a foreign attachment) is not an object.
                break
            }
            index += 1
        }
        if hasContent || current.kind == .checklist || blocks.isEmpty { blocks.append(current) }
        return blocks
    }
}
