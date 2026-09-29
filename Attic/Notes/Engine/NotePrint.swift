import AppKit

/// An immutable print snapshot. It uses the same block-to-TextKit projection
/// as the editor, with light tokens and decoded thumbnails supplied off the
/// main actor. NSTextView paginates paragraphs and keeps an attachment line
/// together. The print panel supplies Save as PDF.
@MainActor
enum NotePrint {
    static let paperSize = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 54
    static var columnWidth: CGFloat { paperSize.width - 2 * margin }
    static var pageHeight: CGFloat { paperSize.height - 2 * margin }

    static func printView(document: NoteDocument, thumbnails: [UUID: CGImage] = [:]) -> NSTextView {
        var printable = document
        // A very tall portrait must fit on a page; this is a print-only
        // clamp and never rewrites the stored column fraction.
        for index in printable.blocks.indices where printable.blocks[index].kind == .image {
            let block = printable.blocks[index]
            guard let width = block.pixelWidth, let height = block.pixelHeight,
                  width > 0, height > 0 else { continue }
            let maxFraction = Double(pageHeight * 0.82 / (columnWidth * CGFloat(height) / CGFloat(width)))
            printable.blocks[index].widthFraction = min(block.widthFraction ?? 1, max(0.1, maxFraction))
        }
        let style = NoteTextStyle(design: .default)
        let content = NoteTextCodec.attributedString(from: printable, style: style)
        let renderer = NoteObjectRenderer(design: .default)
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            guard let object = value as? NoteObjectAttachment else { return }
            if let image = object as? NoteImageAttachment {
                if let cg = thumbnails[image.attachmentID] {
                    image.renderedImage = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                } else {
                    image.renderedImage = renderer.placeholder(
                        size: image.displaySize(columnWidth: columnWidth), text: String(localized: "Image unavailable"))
                }
            } else {
                renderer.apply(to: object, today: NoteDay(date: Date()))
            }
        }
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: columnWidth, height: pageHeight))
        view.appearance = NSAppearance(named: .aqua)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = true
        view.backgroundColor = .white
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.maxSize = CGSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(content)
        view.sizeToFit()
        view.frame.size.width = columnWidth
        return view
    }

    static func pageCount(for view: NSTextView) -> Int {
        max(1, Int(ceil(view.frame.height / pageHeight)))
    }

    static func operation(for view: NSTextView) -> NSPrintOperation {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = paperSize
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.verticalPagination = .automatic
        info.horizontalPagination = .clip
        return NSPrintOperation(view: view, printInfo: info)
    }
}

@MainActor
extension NoteEditorEngine {
    func printNote() async -> Bool {
        let snapshot = document()
        var sources: [(UUID, Data)] = []
        for block in snapshot.blocks where block.kind == .image {
            guard let id = block.attachmentID else { continue }
            if let data = staged[id]?.data ?? imageProvider?.attachmentBytes(forAttachment: id)?.data {
                sources.append((id, data))
            } else if let url = await imageProvider?.fileURL(forAttachment: id),
                      let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value {
                sources.append((id, data))
            }
        }
        let thumbnails = await Task.detached(priority: .userInitiated) {
            Dictionary(sources.compactMap { id, data in
                NoteImageDecoder.thumbnail(of: data, maxPixel: 1800).map { (id, $0) }
            }, uniquingKeysWith: { first, _ in first })
        }.value
        let view = NotePrint.printView(document: snapshot, thumbnails: thumbnails)
        return NotePrint.operation(for: view).run()
    }
}
