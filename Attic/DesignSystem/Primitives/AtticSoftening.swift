import AppKit
import SwiftUI

// MARK: - Softening behind floating controls (owner, 2026-10-01: B)

/// Content that scrolls under a floating control (the page tabs, the add
/// bar, the header's buttons, Notes' buttons) is softened behind the control
/// only: still plainly there, passing beneath, but quieter, so the control
/// reads crisply. Around and between the controls it stays clearly visible.
/// One value sets it all (`AtticEdgeBlur.softening`; a preview's Motion Lab
/// can tune it live).
///
/// - **The dim** is the content's own opacity, lowered in a feathered mask
///   of each control's footprint (`AtticSofteningMask`, applied to the
///   scrolling content: about 57 % stays visible at the core). It needs no
///   colour: whatever surface is behind (Solid, Glass, Frosted, any Tint)
///   shows through exactly, so no tone or box appears over empty space.
/// - **The blur** is the panel's own content blurred as it passes a
///   control's line (`atticSoftenedByControls`, the scroll edge fade's
///   per-item effect: up to about 5 pt, by how deep the item is in the
///   line). It works on the content itself, never on a backdrop: on CI's
///   macOS 26 a Core Animation background filter sampled what is behind the
///   window, not the panel (it punched a faint hole and flattened the Pin).
///   AppKit text (the legacy note editor) takes the dim only.
/// - **Reduce Transparency** hides the content behind a control completely:
///   the real surface is the solid backing.
///
/// The system's soft scroll edge was evaluated first and not used: it
/// softens a whole band at the scroll view's edge and fades it out (the cut
/// the owner turned down), draws nothing under Liquid Glass bars, and
/// AppKit's `NSScrollEdgeEffectStyle` applies only to title-bar and
/// split-view accessories.
enum AtticSoftening {
    /// The coordinate space footprints and bands are measured in; the view
    /// that collects them (a page) declares it.
    static let space = NamedCoordinateSpace.named("AtticSoftening")

    /// How much of the content stays visible at the core of a control's
    /// footprint at `strength`; nothing under Reduce Transparency.
    static func visible(strength: Double, reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0 : 1 - clamped(strength) * AtticEdgeBlur.softeningMaximumDim
    }

    /// The blur of content in the middle of a control's line, at `strength`.
    static func blur(strength: Double) -> CGFloat {
        AtticEdgeBlur.softeningMaximumBlur * CGFloat(clamped(strength))
    }

    private static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Where a control sits, for the softening behind it.
struct AtticControlFootprint: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat
    /// How much content stays visible at its core when not the softening's
    /// own share: 0 for small bare glyphs (Find, View Options), which take
    /// the real surface as their backing.
    var visible: Double?
}

struct AtticControlFootprintsKey: PreferenceKey {
    static let defaultValue: [AtticControlFootprint] = []

    static func reduce(value: inout [AtticControlFootprint], nextValue: () -> [AtticControlFootprint]) {
        value.append(contentsOf: nextValue())
    }
}

/// The softening's one value, live: release builds use the default; a
/// preview's Motion Lab tunes it (kept in the preview's own defaults); UI
/// tests can set it with `ATTIC_UI_TEST_SOFTENING_STRENGTH`.
@MainActor
final class AtticSofteningLab: ObservableObject {
    static let shared = AtticSofteningLab(defaults: AtticMotionLab.isAvailable ? .standard : nil,
                                          environment: ProcessInfo.processInfo.environment)

    @Published var strength: Double {
        didSet { defaults?.set(strength, forKey: Self.strengthKey) }
    }

    private let defaults: UserDefaults?
    static let strengthKey = "AtticSofteningStrength"

    init(defaults: UserDefaults?, environment: [String: String] = [:]) {
        self.defaults = defaults
        var strength = defaults?.object(forKey: Self.strengthKey) as? Double ?? AtticEdgeBlur.softening
        #if DEBUG
        if let forced = environment["ATTIC_UI_TEST_SOFTENING_STRENGTH"].flatMap(Double.init) { strength = forced }
        #endif
        self.strength = strength
    }

    func reset() {
        strength = AtticEdgeBlur.softening
    }
}

// MARK: Footprints

extension View {
    /// Marks this view as a floating control: content scrolling under it is
    /// softened behind it (its footprint, grown by `outset` for bare labels
    /// whose frame is only their text). `dims` false (a strip or bar that
    /// comes and goes with typing) reports nothing, so typing never
    /// re-masks the content.
    func atticControlFootprint(cornerRadius: CGFloat, outset: CGFloat = 0, dims: Bool = true) -> some View {
        background {
            if dims {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: AtticControlFootprintsKey.self,
                        value: [AtticControlFootprint(frame: proxy.frame(in: AtticSoftening.space).insetBy(dx: -outset, dy: -outset),
                                                      cornerRadius: cornerRadius + outset)]
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    /// Blurs this scrolling item as it passes a floating control's line
    /// (`bands`, measured in `AtticSoftening.space`), by how deep it is in
    /// the line: the scroll edge fade's per-item effect, run while drawing,
    /// so scrolling never rebuilds the item.
    func atticSoftenedByControls(_ bands: [AtticSofteningBand], blur: CGFloat) -> some View {
        modifier(AtticSoftenedByControls(bands: bands, blur: blur))
    }
}

/// `atticSoftenedByControls`, as a value: an item re-evaluates it only when
/// the bands or the blur change, never when its row updates.
private struct AtticSoftenedByControls: ViewModifier, Equatable {
    let bands: [AtticSofteningBand]
    let blur: CGFloat

    func body(content: Content) -> some View {
        content.visualEffect { [bands, blur] effect, proxy in
            let frame = proxy.frame(in: AtticSoftening.space)
            let depth = bands.reduce(0) { max($0, $1.depth(of: frame)) }
            return effect.blur(radius: blur * depth)
        }
    }
}

/// A floating control's line across the page (the header's buttons, the
/// tabs, the add bar), for the blur of what passes it.
struct AtticSofteningBand: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat

    /// How deep an item is in the line (0 clear of it, 1 when the line is
    /// all over the item, or the item all over the line): the share of the
    /// shorter of the two that they overlap.
    func depth(of frame: CGRect) -> CGFloat {
        let overlap = min(frame.maxY, bottom) - max(frame.minY, top)
        guard overlap > 0 else { return 0 }
        return min(1, overlap / max(1, min(frame.height, bottom - top)))
    }
}

// MARK: The dim

/// The content's mask behind floating controls: opaque everywhere except
/// each control's footprint, where the content keeps only `visible` of its
/// opacity at the core and fades back in over `feather` (smoothstep, no
/// line). Static while nothing moves the controls; applied to a view that
/// does not move with its content (the Tasks pager), so it stays on the
/// controls during a swipe.
struct AtticSofteningMask<Halo: View>: View {
    let footprints: [AtticControlFootprint]
    let visible: Double
    var feather: CGFloat = AtticEdgeBlur.softeningFeather
    /// Bare labels' halo, in `AtticSoftening.space`: the content gives way
    /// completely right around their letters (drawn opaque here), so each
    /// letter has the real surface behind it while the content shows
    /// between and around them.
    @ViewBuilder var halo: () -> Halo

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: AtticSoftening.space).origin
            ZStack(alignment: .topLeading) {
                Color.black
                if visible < 1 {
                    ForEach(Array(footprints.enumerated()), id: \.offset) { _, footprint in
                        Self.hole(footprint, feather: feather)
                            .opacity(1 - min(footprint.visible ?? visible, visible))
                            .offset(x: footprint.frame.minX - feather - origin.x, y: footprint.frame.minY - feather - origin.y)
                            .blendMode(.destinationOut)
                    }
                    halo()
                        .offset(x: -origin.x, y: -origin.y)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The feathered shape, as a stretched nine-part image the size of the
    /// footprint plus `feather` on every side.
    @ViewBuilder
    static func hole(_ footprint: AtticControlFootprint, feather: CGFloat) -> some View {
        let radius = max(0, min(footprint.cornerRadius, footprint.frame.height / 2, footprint.frame.width / 2)).rounded()
        let size = CGSize(width: footprint.frame.width + feather * 2, height: footprint.frame.height + feather * 2)
        if let mask = AtticSofteningShape.image(radius: radius, feather: feather, scale: 2) {
            let inset = radius + feather
            Image(decorative: mask.image, scale: 2)
                .resizable(capInsets: EdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset), resizingMode: .stretch)
                .frame(width: size.width, height: size.height)
        }
    }
}

extension AtticSofteningMask where Halo == EmptyView {
    init(footprints: [AtticControlFootprint], visible: Double, feather: CGFloat = AtticEdgeBlur.softeningFeather) {
        self.init(footprints: footprints, visible: visible, feather: feather, halo: { EmptyView() })
    }
}

/// The softening mask at the live strength (Reduce Transparency hides the
/// content there).
struct AtticLiveSofteningMask<Halo: View>: View {
    let footprints: [AtticControlFootprint]
    @ViewBuilder var halo: () -> Halo
    @ObservedObject private var lab = AtticSofteningLab.shared
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticSofteningMask(footprints: footprints,
                           visible: AtticSoftening.visible(strength: lab.strength, reduceTransparency: design.reduceTransparency),
                           halo: halo)
    }
}

extension AtticLiveSofteningMask where Halo == EmptyView {
    init(footprints: [AtticControlFootprint]) {
        self.init(footprints: footprints, halo: { EmptyView() })
    }
}

/// Bare labels' halo for `AtticSofteningMask`: the labels' own letters,
/// in their heaviest weight, grown by `AtticEdgeBlur.haloRadius` and
/// softened at the edge, placed where the labels are drawn.
struct AtticLabelHalo: View {
    let titles: [String]
    let style: AtticTextStyle
    var spacing: CGFloat
    var lineHeight: CGFloat
    var origin: CGPoint
    /// A line under the labels (an underline that travels between them).
    var underline: (gap: CGFloat, height: CGFloat)?

    private var labels: some View {
        HStack(spacing: spacing) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                AtticText(verbatim: title, style: style, ink: .heading)
                    .fixedSize()
                    .overlay(alignment: .bottom) {
                        if let underline {
                            Rectangle()
                                .frame(height: underline.height)
                                .offset(y: underline.height + underline.gap)
                        }
                    }
            }
        }
        .frame(height: lineHeight)
    }

    var body: some View {
        // Rings of copies one point apart out to `haloRadius`, in eight
        // directions: thin strokes leave no gap between rings.
        let rings = stride(from: CGFloat(1), through: AtticEdgeBlur.haloRadius, by: 1).map { $0 }
            + [AtticEdgeBlur.haloRadius]
        let directions = (0..<8).map { Double($0) * .pi / 4 }
        let offsets: [CGSize] = [.zero] + rings.flatMap { radius in
            directions.map { CGSize(width: radius * CGFloat(cos($0)), height: radius * CGFloat(sin($0))) }
        }
        // The letters grown on every side, then softened at the outer edge.
        ZStack(alignment: .topLeading) {
            ForEach(Array(offsets.enumerated()), id: \.offset) { _, shift in
                labels.offset(shift)
            }
        }
        .blur(radius: 0.75)
        .offset(x: origin.x, y: origin.y)
        .environment(\.atticCapture, nil)
    }
}

// MARK: The shape

/// A control's footprint feathered: opaque inside its rounded shape,
/// falling smoothly to nothing `feather` outside it.
enum AtticSofteningShape {
    private struct Key: Hashable {
        var radius: CGFloat
        var feather: CGFloat
        var scale: CGFloat
    }

    @MainActor private static var cache: [Key: (image: CGImage, centre: CGRect)] = [:]

    /// The shape as a nine-part image: corners of `radius` with `feather`
    /// of fall-off outside, around a one-point middle that stretches.
    @MainActor
    static func image(radius: CGFloat, feather: CGFloat, scale: CGFloat) -> (image: CGImage, centre: CGRect)? {
        let key = Key(radius: radius, feather: feather, scale: scale)
        if let cached = cache[key] { return cached }
        let side = (radius + feather) * 2 + 1
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0, let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                                  bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let size = CGFloat(pixels) / scale
        for row in 0..<pixels {
            for column in 0..<pixels {
                let point = CGPoint(x: (CGFloat(column) + 0.5) / scale, y: (CGFloat(row) + 0.5) / scale)
                let alpha = Self.alpha(at: point, size: CGSize(width: size, height: size), radius: radius, feather: feather)
                let value = UInt8((alpha * 255).rounded())
                let index = (row * pixels + column) * 4
                data[index] = value
                data[index + 1] = value
                data[index + 2] = value
                data[index + 3] = value
            }
        }
        guard let image = context.makeImage() else { return nil }
        let edge = (radius + feather) / side
        let result = (image, CGRect(x: edge, y: edge, width: 1 / side, height: 1 / side))
        cache[key] = result
        return result
    }

    /// The opacity at `point` in a view of `size`: 1 inside the rounded
    /// shape inset by `feather`, falling smoothly to 0 at `feather` outside.
    nonisolated static func alpha(at point: CGPoint, size: CGSize, radius: CGFloat, feather: CGFloat) -> CGFloat {
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: feather, dy: feather)
        guard inner.width > 0, inner.height > 0 else { return 0 }
        let r = min(radius, inner.width / 2, inner.height / 2)
        let dx = max(abs(point.x - inner.midX) - (inner.width / 2 - r), 0)
        let dy = max(abs(point.y - inner.midY) - (inner.height / 2 - r), 0)
        let outside = max(0, (dx * dx + dy * dy).squareRoot() - r)
        guard feather > 0 else { return outside > 0 ? 0 : 1 }
        let t = min(outside / feather, 1)
        return 1 - t * t * (3 - 2 * t)
    }
}
