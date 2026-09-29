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
        var listStack: [NSTextList] = []
        var previousListKind: String?
        for (index, block) in document.blocks.enumerated() {
            let isTitle = firstBlockIsTitle && index == 0
            var attributes = isTitle ? style.titleAttributes : style.paragraphAttributes(style: block.style, level: block.level, indent: block.indent)
            if !isTitle, block.kind == .text, let kind = block.style, ["bullet", "number"].contains(kind) {
                let depth = block.indent ?? 0
                let marker: NSTextList.MarkerFormat = kind == "number" ? .decimal : .disc
                if previousListKind == nil { listStack.removeAll() }
                if listStack.count > depth + 1 { listStack = Array(listStack.prefix(depth + 1)) }
                while listStack.count <= depth { listStack.append(NSTextList(markerFormat: marker, options: 0)) }
                if previousListKind != kind, listStack.count == depth + 1,
                   listStack[depth].markerFormat != marker {
                    listStack[depth] = NSTextList(markerFormat: marker, options: 0)
                }
                let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                paragraph.textLists = listStack
                attributes[.paragraphStyle] = paragraph
                previousListKind = kind
            } else {
                listStack.removeAll()
                previousListKind = nil
            }
            if let id = block.id, block.kind == .text { attributes[.noteBlockID] = id }
            if !block.extras.isEmpty { attributes[.noteBlockExtras] = NoteBlockExtras(block.extras) }
            if let blockStyle = block.style, block.kind == .text { attributes[.noteBlockStyle] = blockStyle }
            if let level = block.level { attributes[.noteBlockLevel] = level }
            if let indent = block.indent { attributes[.noteBlockIndent] = indent }
            let paragraph = NSMutableAttributedString()
            switch block.kind {
            case .text:
                paragraph.append(inlineText(block, attributes: attributes, style: style))
            case .checklist:
                let box = NoteChecklistAttachment(objectID: block.id ?? UUID(), isChecked: block.checked)
                paragraph.append(attachmentString(box, attributes: attributes))
                paragraph.append(inlineText(block, attributes: attributes, style: style))
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
            case .divider:
                paragraph.append(attachmentString(NoteDividerAttachment(objectID: block.id ?? UUID()), attributes: attributes))
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

    private static func inlineText(_ block: NoteBlock, attributes: [NSAttributedString.Key: Any], style: NoteTextStyle) -> NSAttributedString {
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
        for mark in block.marks where mark.offset >= 0 && mark.length > 0 && mark.offset + mark.length <= result.length {
            let range = NSRange(location: mark.offset, length: mark.length)
            result.addAttribute(.noteMark(mark.kind), value: mark.url ?? true, range: range)
        }
        let baseFont = attributes[.font] as? NSFont ?? style.bodyFont
        var runs: [([NoteMark.Kind: Any], NSRange)] = []
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length)) { values, range, _ in
            let marks = Dictionary(uniqueKeysWithValues: NoteMark.Kind.allCases.compactMap { kind in
                values[.noteMark(kind)].map { (kind, $0) }
            })
            runs.append((marks, range))
        }
        for (marks, range) in runs { result.addAttributes(style.markedAttributes(marks: marks, baseFont: baseFont), range: range) }
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
        if firstBlockIsTitle, !blocks.isEmpty {
            blocks[0].style = nil
            blocks[0].level = nil
            blocks[0].indent = nil
        }
        var document = template
        document.blocks = blocks.isEmpty ? [.text("")] : blocks
        document.refreshRequiredCapabilities()
        return document
    }

    private struct ParagraphMetadata {
        var id: UUID?
        var style: String?
        var level: Int?
        var indent: Int?
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
            if result.level == nil { result.level = attributes[.noteBlockLevel] as? Int }
            if result.indent == nil { result.indent = attributes[.noteBlockIndent] as? Int }
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
        var current = NoteBlock(kind: .text, id: meta.id, style: meta.style, level: meta.level,
                                indent: meta.indent, extras: meta.extras)
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
                let baseOffset = (current.text as NSString).length
                let runRange = NSRange(location: index, length: runEnd - index)
                for kind in NoteMark.Kind.allCases {
                    text.enumerateAttribute(.noteMark(kind), in: runRange) { value, markedRange, _ in
                        guard let value else { return }
                        let offset = baseOffset + markedRange.location - index
                        let url = kind == .link ? value as? String : nil
                        let mark = NoteMark(kind, offset: offset, length: markedRange.length, url: url)
                        if let last = current.marks.indices.last,
                           current.marks[last].kind == mark.kind,
                           current.marks[last].url == mark.url,
                           current.marks[last].offset + current.marks[last].length == mark.offset {
                            current.marks[last].length += mark.length
                        } else { current.marks.append(mark) }
                    }
                }
                current.text += string.substring(with: NSRange(location: index, length: runEnd - index))
                hasContent = true
                index = runEnd
                continue
            }
            switch text.attribute(.attachment, at: index, effectiveRange: nil) {
            case let box as NoteChecklistAttachment:
                let leadsParagraph = index == paragraph.location
                if !leadsParagraph { finishCurrent() }
                current = NoteBlock(kind: .checklist, id: box.objectID, indent: meta.indent, checked: box.isChecked,
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
            case let divider as NoteDividerAttachment:
                finishCurrent()
                blocks.append(.divider(id: divider.objectID))
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
