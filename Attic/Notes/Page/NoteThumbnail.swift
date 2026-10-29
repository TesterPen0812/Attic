import AppKit
import SwiftUI

/// What a note's page thumbnail shows (the owner's panel design, Notes rows
/// option 4a): a mini title, a striped image block when the note has
/// images, and the note's text as greyed lines.
struct NoteThumbnailContent: Hashable, Sendable {
    let title: String
    let text: String
    let hasImages: Bool
}

/// The design's sizes, in points (the drawing is at 2×: px ÷ 2).
enum NoteThumbnailMetrics {
    /// The card: 48 × 60 px, radius 10 px, `superellipse(1.3)`.
    static let size = CGSize(width: 24, height: 30)
    static let radius: CGFloat = 5
    static let cornerExponent: CGFloat = pow(2, 1.3)
    /// Padding 6 px top and bottom, 5 px at the sides; parts 2 px apart.
    static let paddingY: CGFloat = 3
    static let paddingX: CGFloat = 2.5
    static let gap: CGFloat = 1
    /// The mini title: 6 px bold on a 7 px line.
    static let titleSize: CGFloat = 3
    static let titleLine: CGFloat = 3.5
    /// The image block: 16 px tall, radius 2 px, 2 px stripes at 135°.
    static let imageHeight: CGFloat = 8
    static let imageRadius: CGFloat = 1
    static let stripe: CGFloat = 1
    /// The text: 4.5 px on a 5.6 px line.
    static let textSize: CGFloat = 2.25
    static let textLine: CGFloat = 2.8
    /// Room around the card for its shadow (`0 1px 2px`), drawn into the
    /// same image.
    static let margin: CGFloat = 2
}

/// Rendered thumbnails, one per note, kept while the note's content (its
/// revision's title, text and images) and the appearance stay the same.
/// Rendering happens in a row's `.task`, never during layout; a row's body
/// only looks an image up.
@MainActor
final class NoteThumbnailCache {
    struct Key: Hashable {
        let content: NoteThumbnailContent
        let dark: Bool
        let scale: CGFloat
    }

    private var images: [UUID: (key: Key, image: CGImage)] = [:]
    /// How many thumbnails were drawn (tests: once per revision).
    private(set) var renderCount = 0
    /// The most notes kept; past it the cache starts again.
    static let limit = 600

    func cached(_ id: UUID, key: Key) -> CGImage? {
        guard let kept = images[id], kept.key == key else { return nil }
        return kept.image
    }

    /// The thumbnail for this note and key, drawn only when it is not kept.
    @discardableResult
    func image(_ id: UUID, key: Key) -> CGImage? {
        if let kept = cached(id, key: key) { return kept }
        guard let image = Self.render(key) else { return nil }
        renderCount += 1
        if images.count >= Self.limit, images[id] == nil { images.removeAll(keepingCapacity: true) }
        images[id] = (key, image)
        return image
    }

    /// Drops notes that are gone.
    func keep(only ids: Set<UUID>) {
        guard images.keys.contains(where: { !ids.contains($0) }) else { return }
        images = images.filter { ids.contains($0.key) }
    }

    /// The card and its contents at the key's scale, with the shadow's
    /// margin on every side.
    static func render(_ key: Key) -> CGImage? {
        let m = NoteThumbnailMetrics.self
        let scale = max(1, key.scale)
        let full = CGSize(width: m.size.width + 2 * m.margin, height: m.size.height + 2 * m.margin)
        let width = Int((full.width * scale).rounded(.up)), height = Int((full.height * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Top-left origin, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let card = CGRect(origin: CGPoint(x: m.margin, y: m.margin), size: m.size)
        let shape = Squircle(cornerRadius: m.radius, exponent: m.cornerExponent).path(in: card).cgPath
        let colours = Colours(dark: key.dark)

        // The card, its shadow and its 1 px edge.
        context.saveGState()
        // Shadow offsets are in the bitmap's own (unflipped, pixel) space.
        context.setShadow(offset: CGSize(width: 0, height: -0.5 * scale), blur: scale, color: colours.shadow)
        context.addPath(shape)
        context.setFillColor(colours.card)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let inner = card.insetBy(dx: m.paddingX, dy: m.paddingY)
        var y = inner.minY
        // The mini title: one line, cut at the card's edge.
        let title = key.content.title
        if !title.isEmpty {
            draw(title, in: CGRect(x: inner.minX, y: y, width: inner.width + m.paddingX, height: m.titleLine),
                 font: .systemFont(ofSize: m.titleSize, weight: .bold), line: m.titleLine, colour: colours.title, wraps: false)
        }
        y += m.titleLine + m.gap
        if key.content.hasImages {
            let block = CGRect(x: inner.minX, y: y, width: inner.width, height: m.imageHeight)
            drawStripes(in: block, context: context, colours: colours)
            y += m.imageHeight + m.gap
        }
        if !key.content.text.isEmpty, y < inner.maxY {
            draw(key.content.text, in: CGRect(x: inner.minX, y: y, width: inner.width, height: card.maxY - y),
                 font: .systemFont(ofSize: m.textSize), line: m.textLine, colour: colours.text, wraps: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        context.addPath(Squircle(cornerRadius: m.radius, exponent: m.cornerExponent)
            .path(in: card.insetBy(dx: 0.25, dy: 0.25)).cgPath)
        context.setStrokeColor(colours.edge)
        context.setLineWidth(0.5)
        context.strokePath()
        return context.makeImage()
    }

    private static func draw(_ string: String, in rect: CGRect, font: NSFont, line: CGFloat, colour: CGColor, wraps: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(cgColor: colour) ?? .gray, .paragraphStyle: paragraph
        ]
        let text = wraps ? string : string.replacingOccurrences(of: "\n", with: " ")
        NSAttributedString(string: text, attributes: attributes)
            .draw(with: rect, options: wraps ? [.usesLineFragmentOrigin] : [], context: nil)
    }

    private static func drawStripes(in rect: CGRect, context: CGContext, colours: Colours) {
        let m = NoteThumbnailMetrics.self
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: m.imageRadius, cornerHeight: m.imageRadius, transform: nil))
        context.clip()
        context.setFillColor(colours.stripeLight)
        context.fill(rect)
        context.setStrokeColor(colours.stripeDark)
        context.setLineWidth(m.stripe)
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            // 135°: 1 pt bands, 2 pt apart across them.
            context.move(to: CGPoint(x: x + rect.height, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += 2 * m.stripe * 2.squareRoot()
        }
        context.strokePath()
        context.restoreGState()
    }

    /// The design's light card; Dark draws a dark page with light text.
    private struct Colours {
        let card, edge, shadow, title, text, stripeLight, stripeDark: CGColor
        init(dark: Bool) {
            func grey(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: a) }
            if dark {
                card = grey(58); edge = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.1); shadow = grey(0, 0.25)
                title = grey(236); text = grey(160)
                stripeLight = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08); stripeDark = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16)
            } else {
                card = grey(255); edge = grey(0, 0.08); shadow = grey(0, 0.06)
                title = CGColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
                text = CGColor(srgbRed: 110 / 255, green: 112 / 255, blue: 116 / 255, alpha: 1)
                stripeLight = grey(0, 0.06); stripeDark = grey(0, 0.12)
            }
        }
    }
}

/// A note's page thumbnail: the cached image, looked up in the body and
/// drawn (when missing) in `.task`, so layout never renders.
struct NoteThumbnailView: View {
    let id: UUID
    let content: NoteThumbnailContent
    let cache: NoteThumbnailCache

    @Environment(\.displayScale) private var scale
    @Environment(\.atticDesign) private var design
    /// The key last drawn: a change re-reads the cache.
    @State private var drawn: NoteThumbnailCache.Key?

    var body: some View {
        let m = NoteThumbnailMetrics.self
        let key = NoteThumbnailCache.Key(content: content, dark: design.mode == .dark, scale: scale)
        // Read so that drawing it (in `.task`) shows it.
        let _ = drawn
        ZStack {
            if let image = cache.cached(id, key: key) {
                Image(decorative: image, scale: max(1, scale))
                    .resizable()
                    .frame(width: m.size.width + 2 * m.margin, height: m.size.height + 2 * m.margin)
            }
        }
        .frame(width: m.size.width, height: m.size.height)
        .task(id: key) {
            guard cache.cached(id, key: key) == nil else { return }
            cache.image(id, key: key)
            drawn = key
        }
        .accessibilityHidden(true)
    }
}
