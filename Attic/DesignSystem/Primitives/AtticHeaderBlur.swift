import AppKit
import QuartzCore
import SwiftUI

// MARK: - Floating controls over a variable blur (owner, 2026-10-12 / 2026-10-14)

/// Every page's fixed controls float over its scrolling content: the
/// content runs on to the panel's edge, under the controls, and a variable
/// blur sits behind the controls at the top and the bottom, strongest at
/// the panel's edge and clear `reach` points inside the controls (the
/// owner's lab settings, "perfect": 1.5 pt, 28 pt). It replaces N-6 D
/// (content fades out before the controls, 2026-10-11) and Clean cut
/// (2026-10-03). Attic is not for the Mac App Store (owner, 2026-10-12),
/// so the private Core Animation variable blur is allowed, behind
/// `AtticVariableBlur`, with a plain fade where it is missing.
///
/// - Opaque panel: a short surface-coloured fade over the outer part of
///   each blur, so text never reads through behind the controls.
/// - See-through panel: no colour fade (it drew a white band over the
///   glass, O14-06); the content itself fades out behind the controls.
/// - Reduce Transparency, or no variable blur: the blur gives way to an
///   opaque surface fade.
/// - A line of plain text among the top controls (Tasks' Now · Later ·
///   Done, Done's and search results' lines, All notes' labels, history's
///   version line) has no surface of its own, so content never sits behind
///   it (owner, 2026-10-06): the line counts as part of the top controls,
///   content is gone from the panel's edge to the line's lower edge and
///   fades in below it, and the blur starts at the line's lower edge, so
///   rows blur as they near the line and are gone before they touch it.
///   Behind the composer's plain strip (Date · Tag · Priority) content is
///   gone too (o16).
enum AtticEdgeBlurMetrics {
    /// The strongest blur, at the panel's edge (points).
    static let radius: CGFloat = 1.5
    /// How far past the controls the blur reaches, where content is sharp
    /// again (points).
    static let reach: CGFloat = 28
    /// The opaque panel's surface fade: over the outer share of the blur.
    static let fadeShare: CGFloat = 0.55
    static let fadeOpacity: Double = 0.85
    /// Increase Contrast: the surface fade starts fully opaque.
    static let contrastFadeOpacity: Double = 1
    /// With no blur (Reduce Transparency): the panel's surface is solid
    /// under the controls, out to their inner edge, then fades out over
    /// this much (U-02: no text ever shows sharp behind a control, and the
    /// title's and the last line's resting places stay clear of the fade).
    static let solidFade: CGFloat = 12
    /// See-through panel: the content is gone this far into the controls
    /// (a share of their extent from the panel's edge: by their middle)
    /// and whole again at their inner edge.
    static let translucentGoneShare: CGFloat = 0.6
    /// Content is still gone this far below a plain top line, so a row
    /// never touches the line (it is gone before it gets there).
    static let plainClearance: CGFloat = 3
}

/// The blur's live tuning. Only a strict preview identity offers it
/// (Settings › General › Motion Lab) and keeps it in its own defaults;
/// every other identity uses the approved values and keeps nothing.
@MainActor
final class AtticEdgeBlurLab: ObservableObject {
    static let shared = AtticEdgeBlurLab(defaults: .standard,
                                         isPreview: AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier))

    /// The strongest blur, at the panel's edge (points).
    @Published var radius: Double {
        didSet { defaults?.set(radius, forKey: Self.radiusKey) }
    }
    /// How far past the controls the blur reaches (points).
    @Published var reach: Double {
        didSet { defaults?.set(reach, forKey: Self.reachKey) }
    }
    static let radiusRange: ClosedRange<Double> = 0.5...20
    static let reachRange: ClosedRange<Double> = 0...48

    let offersTuning: Bool
    private let defaults: UserDefaults?
    static let radiusKey = "AtticEdgeBlurRadius"
    static let reachKey = "AtticEdgeBlurReach"

    init(defaults: UserDefaults, isPreview: Bool, blurAvailable: Bool = AtticVariableBlur.isAvailable) {
        offersTuning = isPreview && blurAvailable
        self.defaults = offersTuning ? defaults : nil
        let storedRadius = offersTuning ? defaults.object(forKey: Self.radiusKey) as? Double : nil
        radius = storedRadius.map { min(max($0, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) }
            ?? Double(AtticEdgeBlurMetrics.radius)
        let storedReach = offersTuning ? defaults.object(forKey: Self.reachKey) as? Double : nil
        reach = storedReach.map { min(max($0, Self.reachRange.lowerBound), Self.reachRange.upperBound) }
            ?? Double(AtticEdgeBlurMetrics.reach)
    }
}

// MARK: - The content's own fade

/// Where a page's fixed controls are, in its scrolling content's space.
struct AtticFloatingEdges: Equatable, Sendable {
    /// The top controls' lower edge, down from the panel's top (0: none).
    var top: CGFloat = 0
    /// The bottom controls' upper edge, up from the panel's bottom (0: none).
    var bottom: CGFloat = 0
    /// A plain-text line among the top controls, down from the top:
    /// content is gone above its lower edge and `plainClearance` below it,
    /// then whole `topRamp` further down.
    var topPlain: ClosedRange<CGFloat>? = nil
    /// Plain controls among the bottom controls (Tasks' composer strip),
    /// up from the bottom: content is gone behind them (o16, F-13).
    var bottomPlain: ClosedRange<CGFloat>? = nil
    /// Below a plain top line: from gone to whole (to the first row's rest).
    var topRamp: CGFloat = AtticLayout.pageTabsToList - AtticEdgeBlurMetrics.plainClearance

    /// Where the top blur begins: the plain line's lower edge, or the
    /// panel's edge.
    var topBlurStart: CGFloat { topPlain?.upperBound ?? 0 }

    /// These edges with bottom controls `bottom` deep.
    func with(bottom: CGFloat) -> AtticFloatingEdges {
        var edges = self
        edges.bottom = bottom
        return edges
    }

    /// The content's opacity at `y` in a view `height` tall: whole, except
    /// gone above a plain top line's lower edge (whole `topRamp` below it),
    /// gone behind plain bottom controls and, on a see-through panel, gone
    /// by the controls' middle (back to whole at their inner edge).
    func opacity(at y: CGFloat, height: CGFloat, translucent: Bool) -> Double {
        var value = 1.0
        if translucent {
            if top > 0 { value = min(value, Self.ramp(y, gone: top * AtticEdgeBlurMetrics.translucentGoneShare, whole: top)) }
            if bottom > 0 {
                value = min(value, Self.ramp(height - y, gone: bottom * AtticEdgeBlurMetrics.translucentGoneShare, whole: bottom))
            }
        }
        if let topPlain {
            let gone = topPlain.upperBound + AtticEdgeBlurMetrics.plainClearance
            value = min(value, Self.ramp(y, gone: gone, whole: gone + topRamp))
        }
        if let bottomPlain { value = min(value, Self.faint(height - y, behind: bottomPlain, floor: 0)) }
        return value
    }

    /// The mask's stops for a view `height` tall (locations 0…1).
    func stops(height: CGFloat, translucent: Bool) -> [(location: CGFloat, opacity: Double)] {
        guard height > 0 else { return [(0, 1), (1, 1)] }
        var ys: [CGFloat] = [0, height]
        let samples: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        if translucent {
            if top > 0 {
                let gone = top * AtticEdgeBlurMetrics.translucentGoneShare
                ys += samples.map { gone + $0 * (top - gone) }
            }
            if bottom > 0 {
                let gone = bottom * AtticEdgeBlurMetrics.translucentGoneShare
                ys += samples.map { height - gone - $0 * (bottom - gone) }
            }
        }
        let ramp = AtticScrollUnderFade.textRamp
        if let topPlain {
            ys += samples.map { topPlain.upperBound + AtticEdgeBlurMetrics.plainClearance + $0 * topRamp }
        }
        if let bottomPlain {
            ys += [bottomPlain.lowerBound - ramp, bottomPlain.lowerBound, bottomPlain.upperBound, bottomPlain.upperBound + ramp]
                .map { height - $0 }
        }
        return Set(ys.filter { $0 >= 0 && $0 <= height }).sorted().map {
            ($0 / height, opacity(at: $0, height: height, translucent: translucent))
        }
    }

    /// 0 at or before `gone` (measured from the edge), eased to 1 at `whole`.
    private static func ramp(_ distance: CGFloat, gone: CGFloat, whole: CGFloat) -> Double {
        if distance <= gone { return 0 }
        return AtticScrollUnderFade.ease(min(1, (distance - gone) / max(whole - gone, 1)))
    }

    private static func faint(_ y: CGFloat, behind band: ClosedRange<CGFloat>, floor faint: Double) -> Double {
        if band.contains(y) { return faint }
        let distance = y < band.lowerBound ? band.lowerBound - y : y - band.upperBound
        let ramp = AtticScrollUnderFade.textRamp
        return distance < ramp ? faint + (1 - faint) * Double(distance / ramp) : 1
    }
}

/// The content's mask (`AtticFloatingEdges`), sized to the view it masks.
/// Static geometry: no per-scroll state.
struct AtticFloatingEdgesMask: View {
    let edges: AtticFloatingEdges
    @Environment(\.atticDesign) private var design

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                stops: edges.stops(height: proxy.size.height, translucent: design.isTranslucent)
                    .map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.location) },
                startPoint: .top, endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The blur behind the controls

/// One edge's backdrop: the variable blur, strongest at the panel's edge
/// and clear at its inner end, plus the opaque panel's surface fade over
/// its outer part. `extent` is the controls' depth from the edge; the
/// backdrop reaches the lab's `reach` past it. With a plain top line,
/// `start` is the line's lower edge: the blur begins there (nothing is
/// drawn above it, where the content is gone) and has no surface fade.
struct AtticEdgeBlurBackdrop: View {
    let edge: VerticalEdge
    let extent: CGFloat
    let start: CGFloat
    @ObservedObject private var lab = AtticEdgeBlurLab.shared
    @Environment(\.atticDesign) private var design

    init(edge: VerticalEdge, extent: CGFloat, start: CGFloat = 0) {
        self.edge = edge
        self.extent = extent
        self.start = start
    }

    /// With no blur: solid to the controls' inner edge, clear `solidFade`
    /// past it (locations in a backdrop `height` tall).
    static func solidStops(height: CGFloat, extent: CGFloat) -> (solid: CGFloat, clear: CGFloat) {
        guard height > 0 else { return (1, 1) }
        let solid = min(1, max(0, extent / height))
        return (solid, min(1, max(solid, (extent + AtticEdgeBlurMetrics.solidFade) / height)))
    }

    /// Whether the variable blur draws (not with Reduce Transparency, nor
    /// where the system has none).
    static func blurs(_ design: AtticDesignContext, available: Bool = AtticVariableBlur.isAvailable) -> Bool {
        available && !design.reduceTransparency
    }

    var body: some View {
        let height = max(0, extent - start + CGFloat(lab.reach))
        let blurs = Self.blurs(design)
        let alignment: Alignment = edge == .top ? .top : .bottom
        ZStack(alignment: alignment) {
            if blurs {
                AtticVariableBlur(radius: CGFloat(lab.radius), edge: edge)
            }
            if start <= 0 { surfaceFade(height: height, extent: extent, blurs: blurs) }
        }
        .frame(height: height)
        .padding(edge == .top ? .top : .bottom, max(0, start))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Opaque panel (Reduce Transparency included): the short fade over the
    /// blur's outer part, or, with no blur, the solid surface under the
    /// controls and a short fade past them (`solidFade`, U-02).
    /// See-through panel: none, blur or not (the content fades itself).
    @ViewBuilder
    private func surfaceFade(height: CGFloat, extent: CGFloat, blurs: Bool) -> some View {
        if !design.isTranslucent {
            let surface = design.tokens.panel.base.color
            let strength = design.increaseContrast ? AtticEdgeBlurMetrics.contrastFadeOpacity : AtticEdgeBlurMetrics.fadeOpacity
            let solid = Self.solidStops(height: height, extent: extent)
            let stops: [Gradient.Stop] = blurs
                ? [.init(color: surface.opacity(strength), location: 0), .init(color: surface.opacity(0), location: 1)]
                : [.init(color: surface, location: 0), .init(color: surface, location: solid.solid),
                   .init(color: surface.opacity(0), location: solid.clear)]
            LinearGradient(stops: stops, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
                .frame(height: blurs ? height * AtticEdgeBlurMetrics.fadeShare : height)
        }
    }
}

extension View {
    /// This scrolling content runs on under the page's floating controls
    /// (`AtticFloatingEdges`): its own fade. The blur is drawn separately,
    /// by `AtticEdgeBlurBackdrops`, as the page's own layer between its
    /// content and its controls, never as an overlay of the content: an
    /// AppKit view overlaid on the text view's AppKit host re-hosted it,
    /// and the text lost the key (NotesKeyboardUndoTests on CI).
    func atticFloatingEdgesMask(_ edges: AtticFloatingEdges) -> some View {
        mask { AtticFloatingEdgesMask(edges: edges) }
    }
}

/// The top and bottom backdrops for one page (an edge with no controls has none).
struct AtticEdgeBlurBackdrops: View {
    let top: CGFloat
    let bottom: CGFloat
    var topStart: CGFloat = 0

    init(top: CGFloat, bottom: CGFloat, topStart: CGFloat = 0) {
        self.top = top
        self.bottom = bottom
        self.topStart = topStart
    }

    init(_ edges: AtticFloatingEdges) {
        self.init(top: edges.top, bottom: edges.bottom, topStart: edges.topBlurStart)
    }

    var body: some View {
        ZStack {
            if top > 0 { AtticEdgeBlurBackdrop(edge: .top, extent: top, start: topStart) }
            if bottom > 0 { AtticEdgeBlurBackdrop(edge: .bottom, extent: bottom) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The bottom controls' band takes every press across their height, as
/// Apple's toolbars do: content scrolled under the gaps between the
/// controls is never clicked, right-clicked or dragged through them (the
/// Tasks rule, round 7 R4). The blur's reach beyond the controls is the
/// content's own.
struct AtticFloatingControlsBand: View {
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(height: max(0, height))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {}
            .gesture(DragGesture(minimumDistance: 0))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .accessibilityHidden(true)
    }
}

// MARK: - Variable blur

/// A backdrop that blurs what is behind it, strongest at its `edge` and
/// clear at the other end (Core Animation's private `variableBlur` filter
/// on a backdrop layer). `isAvailable` is false where either class is
/// missing; the backdrop then draws only its fade.
struct AtticVariableBlur: NSViewRepresentable {
    var radius: CGFloat = AtticEdgeBlurMetrics.radius
    var edge: VerticalEdge = .top

    nonisolated static var isAvailable: Bool { AtticVariableBlurView.makeFilter() != nil && AtticVariableBlurView.backdropClass != nil }

    func makeNSView(context: Context) -> AtticVariableBlurView {
        AtticVariableBlurView(radius: radius, edge: edge)
    }

    func updateNSView(_ view: AtticVariableBlurView, context: Context) {
        view.radius = radius
        view.edge = edge
    }
}

final class AtticVariableBlurView: NSView {
    nonisolated static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type

    var radius: CGFloat {
        didSet { if radius != oldValue { applyFilter() } }
    }
    var edge: VerticalEdge {
        didSet { if edge != oldValue { applyFilter() } }
    }

    private let backdrop: CALayer?
    private var maskSize: CGSize = .zero

    init(radius: CGFloat, edge: VerticalEdge) {
        self.radius = radius
        self.edge = edge
        backdrop = Self.backdropClass?.init()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        if let backdrop {
            // Within the window: blur this window's content under the view.
            backdrop.setValue(false, forKey: "windowServerAware")
            layer?.addSublayer(backdrop)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        CATransaction.commit()
        // Only a new size makes a new mask: scrolling never does.
        if bounds.size != maskSize { applyFilter() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backdrop?.setValue(window?.backingScaleFactor ?? 2, forKey: "scale")
        applyFilter()
    }

    nonisolated static func makeFilter() -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")) else { return nil }
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
            .takeUnretainedValue() as? NSObject
    }

    private func applyFilter() {
        guard let backdrop, bounds.width > 0, bounds.height > 0,
              let filter = Self.makeFilter(), let mask = Self.maskImage(height: bounds.height, edge: edge) else { return }
        maskSize = bounds.size
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.filters = [filter]
    }

    /// One column, opaque at `edge` (full blur) easing to clear at the
    /// other end (no blur). The filter stretches it across the width.
    nonisolated static func maskImage(height: CGFloat, edge: VerticalEdge = .top) -> CGImage? {
        let rows = max(2, Int(height.rounded(.up)))
        guard let context = CGContext(data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Bitmap rows run top to bottom in memory; black at the eased alpha.
        for row in 0..<rows {
            let t = Double(row) / Double(rows - 1)        // 0 top … 1 bottom
            let strength = edge == .top ? 1 - t : t
            let eased = strength * strength * (3 - 2 * strength)
            let offset = row * context.bytesPerRow
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 0
            data[offset + 3] = UInt8((eased * 255).rounded())
        }
        return context.makeImage()
    }
}
