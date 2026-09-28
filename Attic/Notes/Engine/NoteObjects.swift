import AppKit
import ImageIO
import SwiftUI

/// Every object in note text is one of these attachments. Each carries its
/// stable ID; an attachment's fields never change after it is made (a tick
/// replaces the attachment with a new one of the same ID through the
/// editor's own undo), so an undo step that holds an attachment holds
/// exactly the object as it was.
class NoteObjectAttachment: NSTextAttachment {
    let objectID: UUID

    init(objectID: UUID) {
        self.objectID = objectID
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Note objects are not archived; they are encoded as note fragments.") }

    /// Drawn image, set by the editor (the design system renders it on the
    /// main actor; drawing never renders). Also the attachment's `image`,
    /// which is what TextKit 2 draws for an attachment without a view.
    var renderedImage: NSImage? {
        didSet { image = renderedImage }
    }

    /// Lines of their own (images, unsupported blocks) as opposed to objects
    /// that flow with text (dates) or lead a line (checkboxes).
    var isBlockObject: Bool { false }

    /// What VoiceOver reads for the object.
    var accessibilityDescription: String { "" }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any] = [:],
                        location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        renderedImage
    }
}

/// The checkbox that leads a checklist line.
final class NoteChecklistAttachment: NoteObjectAttachment {
    let isChecked: Bool

    init(objectID: UUID = UUID(), isChecked: Bool) {
        self.isChecked = isChecked
        super.init(objectID: objectID)
    }

    /// The box plus the gap before the line's text.
    static let boxSize: CGFloat = AtticControlSize.subtaskCheckbox
    static let trailingGap: CGFloat = 8

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let font = (attributes[.font] as? NSFont) ?? AtticTextStyle.noteBody.nsFont
        // Centre the box on the text's cap height.
        let y = (font.capHeight - Self.boxSize) / 2
        return CGRect(x: 0, y: y.rounded(), width: Self.boxSize + Self.trailingGap, height: Self.boxSize)
    }

    override var accessibilityDescription: String { isChecked ? "checked" : "not checked" }
}

/// A structural rule occupying a whole paragraph, with stable identity.
final class NoteDividerAttachment: NoteObjectAttachment {
    override init(objectID: UUID = UUID()) { super.init(objectID: objectID) }
    override var isBlockObject: Bool { true }
    override var accessibilityDescription: String { String(localized: "Divider") }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        CGRect(x: 0, y: 0, width: max(40, proposedLineFragment.width - (textContainer?.lineFragmentPadding ?? 0) * 2),
               height: NoteTextStyle.bodyLineHeight)
    }
}

/// A date inside a line of text.
final class NoteDateAttachment: NoteObjectAttachment {
    let day: NoteDay
    let extras: [String: NoteJSON]
    /// Measured size of the rendered chip.
    var chipSize = CGSize(width: 72, height: AtticControlSize.tagHeight)

    init(objectID: UUID = UUID(), day: NoteDay, extras: [String: NoteJSON] = [:]) {
        self.day = day
        self.extras = extras
        super.init(objectID: objectID)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let font = (attributes[.font] as? NSFont) ?? AtticTextStyle.noteBody.nsFont
        let y = (font.capHeight - chipSize.height) / 2
        return CGRect(x: 0, y: y.rounded(), width: chipSize.width, height: chipSize.height)
    }

    /// "Today", "Tomorrow", "Yesterday", or the absolute day (the year only
    /// when it isn't this year).
    static func label(for day: NoteDay, today: NoteDay, calendar: Calendar = .current) -> String {
        let date = day.date(in: calendar)
        let days = calendar.dateComponents([.day], from: today.date(in: calendar), to: date).day ?? 0
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate(day.year == today.year ? "EEE d MMM" : "EEE d MMM yyyy")
            return formatter.string(from: date)
        }
    }

    static func spokenLabel(for day: NoteDay, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day.date(in: calendar))
    }

    override var accessibilityDescription: String {
        String(localized: "Date, \(Self.spokenLabel(for: day))")
    }
}

/// An image on its own line. Its size comes from the stored pixel size, so
/// the space is reserved before any byte is read; the downscaled copy is
/// decoded off the main thread and only for display.
final class NoteImageAttachment: NoteObjectAttachment {
    let attachmentID: UUID
    let preferredWidth: Double?
    let preferredWidthFraction: Double?
    /// Known from the stored block, or read from the file's header once.
    var pixelSize: CGSize?
    let extras: [String: NoteJSON]
    var filename: String = ""
    /// Missing: the row or its bytes are gone; a placeholder keeps its place.
    var isMissing = false

    init(objectID: UUID = UUID(), attachmentID: UUID, preferredWidth: Double? = nil,
         preferredWidthFraction: Double? = nil,
         pixelSize: CGSize? = nil, extras: [String: NoteJSON] = [:]) {
        self.attachmentID = attachmentID
        self.preferredWidth = preferredWidth
        self.preferredWidthFraction = preferredWidthFraction
        self.pixelSize = pixelSize
        self.extras = extras
        super.init(objectID: objectID)
    }

    override var isBlockObject: Bool { true }

    static let placeholderHeight: CGFloat = 96

    func displaySize(columnWidth: CGFloat) -> CGSize {
        let column = max(40, columnWidth)
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            let reserved = preferredWidthFraction.map { column * CGFloat($0) }
                ?? preferredWidth.map { CGFloat($0) } ?? column
            return CGSize(width: min(column, max(40, reserved)), height: Self.placeholderHeight)
        }
        // Points at 2x, never upscaled past the image's own size.
        let natural = pixelSize.width / 2
        let wanted = preferredWidthFraction.map { column * CGFloat($0) }
            ?? preferredWidth.map { CGFloat($0) } ?? natural
        let width = min(column, max(40, min(wanted, max(natural, 40))))
        return CGSize(width: width.rounded(), height: (width * pixelSize.height / pixelSize.width).rounded())
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let padding = textContainer?.lineFragmentPadding ?? 0
        let size = displaySize(columnWidth: proposedLineFragment.width - padding * 2)
        return CGRect(origin: .zero, size: size)
    }

    override var accessibilityDescription: String {
        filename.isEmpty ? String(localized: "Image") : String(localized: "Image, \(filename)")
    }
}

/// A block or inline object this build cannot read: shown as a placeholder,
/// written back verbatim.
final class NoteOpaqueAttachment: NoteObjectAttachment {
    let value: NoteJSON
    let isInline: Bool

    init(objectID: UUID = UUID(), value: NoteJSON, isInline: Bool) {
        self.value = value
        self.isInline = isInline
        super.init(objectID: objectID)
    }

    override var isBlockObject: Bool { !isInline }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        if isInline { return CGRect(x: 0, y: -4, width: 24, height: AtticControlSize.tagHeight) }
        let padding = textContainer?.lineFragmentPadding ?? 0
        return CGRect(x: 0, y: 0, width: max(40, proposedLineFragment.width - padding * 2), height: 28)
    }

    override var accessibilityDescription: String {
        String(localized: "Content from a newer version of Attic")
    }
}

// MARK: - Rendering (design system only)

/// Renders objects from design-system views. Main actor; cached per look.
@MainActor
final class NoteObjectRenderer {
    private var design: AtticDesignContext
    private var checkboxes: [Bool: NSImage] = [:]
    private var chips: [String: NSImage] = [:]
    private var scale: CGFloat

    init(design: AtticDesignContext, scale: CGFloat = 2) {
        self.design = design
        self.scale = scale
    }

    /// True when objects must be drawn again: only a change of colours (the
    /// colour key). The panel becoming key or not swaps the controls'
    /// material, and Reduce Motion or haptics change nothing drawn here, so
    /// none of those redraws the note (the "blink" the owner saw).
    func update(design: AtticDesignContext) -> Bool {
        let changed = design.colourKey != self.design.colourKey
        self.design = design
        guard changed else { return false }
        checkboxes.removeAll()
        chips.removeAll()
        return true
    }

    func checkbox(checked: Bool) -> NSImage {
        if let image = checkboxes[checked] { return image }
        // The attachment is the box plus its gap before the text: the image
        // is that wide too, so the box is never stretched.
        let size = CGSize(width: NoteChecklistAttachment.boxSize + NoteChecklistAttachment.trailingGap,
                          height: NoteChecklistAttachment.boxSize)
        let image = render(AtticSubtaskCheckbox(isDone: checked).frame(width: size.width, height: size.height, alignment: .leading))
            ?? NSImage(size: size)
        checkboxes[checked] = image
        return image
    }

    func dateChip(_ label: String) -> NSImage {
        if let image = chips[label] { return image }
        let image = render(AtticDateChip(label: label))
            ?? NSImage(size: CGSize(width: 60, height: AtticControlSize.tagHeight))
        chips[label] = image
        return image
    }

    func placeholder(size: CGSize, text: String) -> NSImage {
        render(NoteObjectPlaceholder(text: text).frame(width: size.width, height: size.height))
            ?? NSImage(size: size)
    }

    private func render<Content: View>(_ view: Content) -> NSImage? {
        let renderer = ImageRenderer(content: view.atticDesign(design))
        renderer.scale = scale
        return renderer.nsImage
    }

    func apply(to attachment: NoteObjectAttachment, today: NoteDay) {
        switch attachment {
        case let box as NoteChecklistAttachment:
            box.renderedImage = checkbox(checked: box.isChecked)
        case let date as NoteDateAttachment:
            let image = dateChip(NoteDateAttachment.label(for: date.day, today: today))
            date.chipSize = image.size
            date.renderedImage = image
        case let opaque as NoteOpaqueAttachment:
            opaque.renderedImage = placeholder(
                size: opaque.isInline ? CGSize(width: 24, height: AtticControlSize.tagHeight) : CGSize(width: 240, height: 28),
                text: opaque.isInline ? "…" : String(localized: "Content from a newer Attic")
            )
        case let divider as NoteDividerAttachment:
            divider.renderedImage = render(Rectangle().fill(design.tokens.ink(.helper).color)
                .frame(height: 1).frame(height: NoteTextStyle.bodyLineHeight))
        default:
            break
        }
    }
}

private struct NoteObjectPlaceholder: View {
    let text: String
    @Environment(\.atticDesign) private var design

    var body: some View {
        let radius = AtticRadius.control(height: AtticControlSize.tagHeight)
        AtticText(verbatim: text, style: .chipLabel, ink: .helper)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(design.tokens.tagFill.color))
    }
}

/// Reads an image's pixel size from its header and decodes a downscaled
/// copy, both off the main thread.
enum NoteImageDecoder {
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(source)
    }

    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(source)
    }

    private static func pixelSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5–8 swap width and height.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    static func thumbnail(of data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source, maxPixel: maxPixel)
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ] as CFDictionary)
    }
}
