import AppKit
import QuartzCore
import SwiftUI

// MARK: - Floating controls over a variable blur (owner, 2026-10-12 / 2026-10-14 / 2026-10-22)

/// Every page's fixed controls float over its scrolling content: the
/// content runs on to the panel's edge, under the controls, and a variable
/// blur sits behind the top controls, strongest at the panel's edge and
/// clear `reach` points inside the controls (the owner's lab settings,
/// "perfect": 1.5 pt, 28 pt). It replaces N-6 D
/// (content fades out before the controls, 2026-10-11) and Clean cut
/// (2026-10-03). Attic is not for the Mac App Store (owner, 2026-10-12),
/// so the private Core Animation variable blur is allowed, behind
/// `AtticVariableBlur`, with a plain fade where it is missing.
///
/// Content stays visible under every control, blurred, with no fade
/// hiding it (owner, 2026-10-17): the Tasks tabs line, the composer, the
/// corner buttons, the Notes header and footer rows, every plain line among
/// them. It supersedes T-03 C (content gone behind the controls on a
/// see-through panel, 10-15), the opaque panel's surface fade over the
/// blur, and the rule that content is gone above (and 3 pt below) a plain
/// top line or behind the composer's plain strip (10-06, o16). The scroll
/// insets still let the first and last rows rest clear of the controls.
///
/// No blur at the bottom (owner, 2026-10-22, Tasks and Notes): content
/// scrolls under the bottom controls sharp, with no blur and no fade; the
/// controls keep their own glass. It supersedes the bottom half of the
/// 10-12/10-14 blur and S3-01 (the blur held at full strength under the
/// Tasks composer's plain Date, Tag and Priority row). The top is
/// unchanged.
///
/// - Reduce Transparency, or no variable blur: the blur gives way to an
///   opaque surface under the controls and a short fade past them (U-02),
///   so content never shows sharp behind a control.
enum AtticEdgeBlurMetrics {
    /// The strongest blur, at the panel's edge (points). Slight (owner,
    /// 2026-10-22, with the top controls on glass: "keep it slightly"); it
    /// was 1.5 (2026-10-12).
    static let radius: CGFloat = 0.5
    /// How far past the controls the blur reaches, where content is sharp
    /// again (points): none, it ends with the controls (owner, 2026-10-22;
    /// it was 28).
    static let reach: CGFloat = 0
    /// With no blur (Reduce Transparency): the panel's surface is solid
    /// under the controls, out to their inner edge, then fades out over
    /// this much (U-02: no text ever shows sharp behind a control, and the
    /// title's and the last line's resting places stay clear of the fade).
    static let solidFade: CGFloat = 12
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

// MARK: - Where the controls are

/// Where a page's fixed controls are, in its scrolling content's space.
/// The content runs on under them, whole (owner, 2026-10-17); the blur
/// behind them is `AtticEdgeBlurBackdrops`.
struct AtticFloatingEdges: Equatable, Sendable {
    /// The top controls' lower edge, down from the panel's top (0: none).
    var top: CGFloat = 0
    /// The bottom controls' upper edge, up from the panel's bottom (0: none).
    var bottom: CGFloat = 0

    /// These edges with bottom controls `bottom` deep.
    func with(bottom: CGFloat) -> AtticFloatingEdges {
        var edges = self
        edges.bottom = bottom
        return edges
    }
}

// MARK: - The blur behind the controls

/// One edge's backdrop. At the top: the variable blur, strongest at the
/// panel's edge and clear at its inner end; content shows through it,
/// blurred, on every surface (owner, 2026-10-17). At the bottom: nothing,
/// so content shows sharp (owner, 2026-10-22). `extent` is the controls'
/// depth from the edge (a plain line among them included); the backdrop
/// reaches the lab's `reach` past it. With no blur (Reduce Transparency,
/// or a system without the filter) an opaque panel draws its solid surface
/// under the controls instead, at both edges (U-02).
struct AtticEdgeBlurBackdrop: View {
    let edge: VerticalEdge
    let extent: CGFloat
    @ObservedObject private var lab = AtticEdgeBlurLab.shared
    @Environment(\.atticDesign) private var design

    init(edge: VerticalEdge, extent: CGFloat) {
        self.edge = edge
        self.extent = extent
    }

    /// Which edge carries the variable blur: the top only (owner,
    /// 2026-10-22: content runs under the bottom controls sharp).
    static func blursEdge(_ edge: VerticalEdge) -> Bool { edge == .top }

    /// With no blur: solid to the controls' inner edge, clear `solidFade`
    /// past it (locations in a backdrop `height` tall).
    static func solidStops(height: CGFloat, extent: CGFloat) -> (solid: CGFloat, clear: CGFloat) {
        guard height > 0 else { return (1, 1) }
        let solid = min(1, max(0, extent / height))
        return (solid, min(1, max(solid, (extent + AtticEdgeBlurMetrics.solidFade) / height)))
    }

    /// Whether the variable blur can draw (not with Reduce Transparency,
    /// nor where the system has none); only `blursEdge` edges draw it.
    static func blurs(_ design: AtticDesignContext, available: Bool = AtticVariableBlur.isAvailable) -> Bool {
        available && !design.reduceTransparency
    }

    /// Whether the solid surface stands in for the blur: no blur, on an
    /// opaque panel (Reduce Transparency makes the panel opaque).
    static func drawsSolidSurface(_ design: AtticDesignContext, available: Bool = AtticVariableBlur.isAvailable) -> Bool {
        !blurs(design, available: available) && !design.isTranslucent
    }

    var body: some View {
        // The blur reaches the lab's `reach` past the controls; the solid
        // surface (U-02) always keeps room for its own fade, whatever the
        // reach (2026-10-22: the slight top blur reaches 0).
        let reach = Self.blurs(design) ? CGFloat(lab.reach) : max(CGFloat(lab.reach), AtticEdgeBlurMetrics.solidFade)
        let height = max(0, extent + reach)
        let alignment: Alignment = edge == .top ? .top : .bottom
        ZStack(alignment: alignment) {
            if Self.blurs(design) {
                if Self.blursEdge(edge) { AtticVariableBlur(radius: CGFloat(lab.radius), edge: edge) }
            } else if Self.drawsSolidSurface(design) {
                solidSurface(height: height)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The panel's surface, solid under the controls and gone `solidFade`
    /// past them (U-02).
    private func solidSurface(height: CGFloat) -> some View {
        let surface = design.tokens.panel.base.color
        let solid = Self.solidStops(height: height, extent: extent)
        return LinearGradient(stops: [.init(color: surface, location: 0), .init(color: surface, location: solid.solid),
                                      .init(color: surface.opacity(0), location: solid.clear)],
                              startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }
}

/// The top and bottom backdrops for one page (an edge with no controls has
/// none; the bottom one draws only the Reduce Transparency surface). The page draws them as its own layer between its content and
/// its controls, never as an overlay of the content: an AppKit view
/// overlaid on the text view's AppKit host re-hosted it, and the text lost
/// the key (NotesKeyboardUndoTests on CI).
struct AtticEdgeBlurBackdrops: View {
    let top: CGFloat
    let bottom: CGFloat

    init(top: CGFloat, bottom: CGFloat) {
        self.top = top
        self.bottom = bottom
    }

    init(_ edges: AtticFloatingEdges) {
        self.init(top: edges.top, bottom: edges.bottom)
    }

    var body: some View {
        ZStack {
            if top > 0 { AtticEdgeBlurBackdrop(edge: .top, extent: top) }
            if bottom > 0 { AtticEdgeBlurBackdrop(edge: .bottom, extent: bottom) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The bottom controls' band takes every press across their height, as
/// Apple's toolbars do: content scrolled under the gaps between the
/// controls is never clicked, right-clicked or dragged through them (the
/// Tasks rule, round 7 R4). The content past the controls is its own.
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
        let span = Double(rows - 1)
        for row in 0..<rows {
            let fromEdge = edge == .top ? Double(row) : Double(rows - 1 - row)
            let strength = max(0, 1 - fromEdge / span)
            let eased = strength * strength * (3 - 2 * strength)
            let offset = row * context.bytesPerRow
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 0
            data[offset + 3] = UInt8((eased * 255).rounded())
        }
        return context.makeImage()
    }
}
