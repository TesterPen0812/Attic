import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notes images and files (Phase 2 slice 3b; UX plan § 3.5, p2-13)

/// What a note's file card or failed image shows: plain data, so the note's
/// renderer draws it as an image (nothing in the text is a live view) and a
/// click finds the same action where it was drawn
/// (`AtticNoteObjectLayout`).
struct AtticNoteObjectFace: Equatable {
    enum Kind: Equatable { case file, image }
    /// `failure` draws in the warning ink; `quiet` (a preview that could not
    /// be made, the bytes safe) in the helper grey.
    enum Tone: Equatable { case normal, quiet, failure }

    var kind: Kind
    /// The file's name (user content: it may truncate).
    var name: String
    /// The size, or the state's short message ("Import failed").
    var detail: String
    var tone: Tone = .normal
    var systemImage: String
    /// The actions drawn on the object, most important first. Those that do
    /// not fit are left off the face; the menu and VoiceOver have them all.
    var actions: [String] = []

    /// The type's glyph for a file card.
    static func systemImage(forContentType identifier: String) -> String {
        guard let type = UTType(identifier) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Where each part of a face sits, in the object's own coordinates (top
/// left origin, as the text view is flipped). The drawing and the click
/// handling both read it, so a chip is hit exactly where it is drawn.
enum AtticNoteObjectLayout {
    struct Placement: Equatable {
        /// The message line's frame (the detail on a card).
        var message: CGRect
        /// The glyph's centre (a failed image's face).
        var glyph: CGPoint?
        /// One frame per drawn action, in `face.actions` order; the ones
        /// that did not fit are absent from the end.
        var chips: [CGRect]
    }

    private static var chipFont: NSFont { AtticTextStyle.chipLabel.nsFont }

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: chipFont]).width)
    }

    static func chipWidth(_ title: String) -> CGFloat {
        textWidth(title) + AtticNoteObjectMetrics.chipPadding * 2
    }

    /// Chips from `x`, centred on `centerY`, while they fit before `maxX`.
    static func chips(_ titles: [String], from x: CGFloat, centerY: CGFloat, maxX: CGFloat) -> [CGRect] {
        let m = AtticNoteObjectMetrics.self
        var frames: [CGRect] = []
        var cursor = x
        for title in titles {
            let width = chipWidth(title)
            guard cursor + width <= maxX else { break }
            frames.append(CGRect(x: cursor, y: (centerY - m.chipHeight / 2).rounded(), width: width, height: m.chipHeight))
            cursor += width + m.chipGap
        }
        return frames
    }

    static func placement(of face: AtticNoteObjectFace, in size: CGSize) -> Placement {
        face.kind == .file ? card(face, size: size) : imageFailure(face, size: size)
    }

    /// A file card: the name on the first line, the detail on the second,
    /// the actions after the detail.
    private static func card(_ face: AtticNoteObjectFace, size: CGSize) -> Placement {
        let m = AtticNoteObjectMetrics.self
        let x = m.cardPadding + m.cardIconSlot + m.cardIconGap
        let maxX = size.width - m.cardPadding
        let width = min(textWidth(face.detail), max(0, maxX - x))
        let message = CGRect(x: x, y: m.cardSecondLine - 8, width: width, height: 16)
        let chips = chips(face.actions, from: x + width + m.messageGap, centerY: m.cardSecondLine, maxX: maxX)
        return Placement(message: message, glyph: nil, chips: chips)
    }

    /// A failed image in its reserved space: the glyph, the message and the
    /// actions stacked and centred, or in one centred row when the space is
    /// short.
    private static func imageFailure(_ face: AtticNoteObjectFace, size: CGSize) -> Placement {
        let m = AtticNoteObjectMetrics.self
        let inner = max(0, size.width - m.cardPadding * 2)
        let messageWidth = min(textWidth(face.detail), inner)
        if size.height >= m.failureStackMinHeight {
            let block = m.failureGlyph + m.failureRowGap + 16 + m.failureRowGap + m.chipHeight
            let top = ((size.height - block) / 2).rounded()
            let glyph = CGPoint(x: size.width / 2, y: top + m.failureGlyph / 2)
            let messageY = top + m.failureGlyph + m.failureRowGap
            let message = CGRect(x: ((size.width - messageWidth) / 2).rounded(), y: messageY, width: messageWidth, height: 16)
            let chipsY = messageY + 16 + m.failureRowGap + m.chipHeight / 2
            let fitting = chips(face.actions, from: 0, centerY: chipsY, maxX: inner)
            let total = fitting.last.map(\.maxX) ?? 0
            let offset = ((size.width - total) / 2).rounded()
            return Placement(message: message, glyph: glyph, chips: fitting.map { $0.offsetBy(dx: offset, dy: 0) })
        }
        let centerY = size.height / 2
        let fitting = chips(face.actions, from: messageWidth + m.messageGap, centerY: centerY, maxX: inner)
        let total = fitting.last.map(\.maxX) ?? messageWidth
        let offset = ((size.width - total) / 2).rounded()
        let message = CGRect(x: offset, y: (centerY - 8).rounded(), width: messageWidth, height: 16)
        return Placement(message: message, glyph: nil, chips: fitting.map { $0.offsetBy(dx: offset, dy: 0) })
    }

    /// The action under `point`, as an index into `face.actions`.
    static func action(at point: CGPoint, face: AtticNoteObjectFace, size: CGSize) -> Int? {
        placement(of: face, in: size).chips.firstIndex { $0.insetBy(dx: -2, dy: -3).contains(point) }
    }
}

private extension AtticNoteObjectFace {
    var ink: AtticInk {
        switch tone {
        case .normal: .helper
        case .quiet: .helper
        case .failure: .warningText
        }
    }

    var glyphInk: AtticInk { tone == .failure ? .warningText : .icon }
}

/// A file in a note (p2-13): a quiet content card with the type's glyph,
/// the name and the size; a failure says so on its second line, with its
/// actions after it.
struct AtticNoteFileCard: View {
    let face: AtticNoteObjectFace
    var width: CGFloat = 300

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteObjectMetrics.self
        let size = CGSize(width: width, height: AtticNoteObjectMetrics.cardHeight)
        let placement = AtticNoteObjectLayout.placement(of: face, in: size)
        let shape = RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
        let nameX = m.cardPadding + m.cardIconSlot + m.cardIconGap
        ZStack(alignment: .topLeading) {
            shape.fill(design.tokens.contentCard.color)
            shape.strokeBorder(design.tokens.contentCardRim.color, lineWidth: AtticHairline.width)
            AtticIcon(systemName: face.systemImage, size: m.cardIcon, weight: .regular, ink: face.glyphInk)
                .frame(width: m.cardIconSlot, height: size.height)
                .offset(x: m.cardPadding)
            AtticText(verbatim: face.name, style: .chipLabel, ink: .body, truncates: true)
                .frame(width: max(0, size.width - nameX - m.cardPadding), height: 16, alignment: .leading)
                .offset(x: nameX, y: m.cardFirstLine - 8)
            AtticText(verbatim: face.detail, style: .chipLabel, ink: face.ink)
                .frame(width: placement.message.width + 1, height: placement.message.height, alignment: .leading)
                .offset(x: placement.message.minX, y: placement.message.minY)
            AtticNoteObjectChips(titles: face.actions, frames: placement.chips)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// An image that cannot be shown, in the space kept for it: the glyph, the
/// message and its actions on a quiet fill.
struct AtticNoteImageFailure: View {
    let face: AtticNoteObjectFace
    let size: CGSize

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteObjectMetrics.self
        let placement = AtticNoteObjectLayout.placement(of: face, in: size)
        let shape = RoundedRectangle(cornerRadius: AtticRadius.image, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(design.tokens.recessed.color)
            shape.strokeBorder(design.tokens.contentCardRim.color, lineWidth: AtticHairline.width)
            if let glyph = placement.glyph {
                AtticIcon(systemName: face.systemImage, size: m.failureGlyph, weight: .medium, ink: face.glyphInk)
                    .frame(width: m.failureGlyph + 4, height: m.failureGlyph + 4)
                    .offset(x: glyph.x - (m.failureGlyph + 4) / 2, y: glyph.y - (m.failureGlyph + 4) / 2)
            }
            AtticText(verbatim: face.detail, style: .chipLabel, ink: face.ink)
                .frame(width: placement.message.width + 1, height: placement.message.height, alignment: .leading)
                .offset(x: placement.message.minX, y: placement.message.minY)
            AtticNoteObjectChips(titles: face.actions, frames: placement.chips)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The drawn actions: quiet chips, the first in the heading ink.
private struct AtticNoteObjectChips: View {
    let titles: [String]
    let frames: [CGRect]

    @Environment(\.atticDesign) private var design

    var body: some View {
        let radius = AtticRadius.control(height: AtticNoteObjectMetrics.chipHeight)
        ForEach(Array(zip(titles, frames).enumerated()), id: \.offset) { index, pair in
            AtticText(verbatim: pair.0, style: .chipLabel, ink: index == 0 ? .heading : .body)
                .frame(width: pair.1.width, height: pair.1.height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(design.tokens.chipHover.color))
                .offset(x: pair.1.minX, y: pair.1.minY)
        }
    }
}

/// What travels with the pointer while files are dragged over a note: the
/// file card's look on the pop-over surface, "+N" when there are more.
struct AtticNoteCarryCard: View {
    let name: String
    let systemImage: String
    var more = 0

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteObjectMetrics.self
        let shape = RoundedRectangle(cornerRadius: m.cardRadius, style: .continuous)
        let tokens = design.tokens
        HStack(spacing: m.cardIconGap) {
            AtticIcon(systemName: systemImage, size: 17, weight: .regular, ink: .icon)
                .frame(width: m.cardIconSlot)
            AtticText(verbatim: name, style: .chipLabel, ink: .body, truncates: true)
            Spacer(minLength: 0)
            if more > 0 {
                AtticText(verbatim: "+\(more)", style: .count, ink: .body)
                    .padding(.horizontal, AtticTagMetrics.horizontalPadding)
                    .frame(height: AtticControlSize.tagHeight)
                    .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: AtticControlSize.tagHeight),
                                                 style: .continuous).fill(tokens.chipHover.color))
            }
        }
        .padding(.horizontal, m.cardPadding)
        .frame(width: m.carryWidth, height: m.carryHeight)
        .background {
            ZStack {
                shape.fill(tokens.popoverFill.color)
                shape.inset(by: AtticHairline.innerRim / 2).stroke(tokens.popoverInnerRim.color, lineWidth: AtticHairline.innerRim)
                shape.stroke(tokens.popoverOuterRim.color, lineWidth: AtticHairline.width)
            }
        }
    }
}
