import AppKit
import QuartzCore
import SwiftUI

// MARK: - Header blur lab (owner, 2026-10-12)

/// What the Notes header does with text scrolled under it. Today is the
/// product (N-6 D: the text fades out before the header). Variable blur is
/// the Craft-style A/B: the text runs on under the header and blurs more
/// the higher it goes, into a short surface fade behind the controls.
/// Not for the Mac App Store (owner, 2026-10-12), so the private Core
/// Animation variable blur is allowed here, behind `AtticVariableBlur`.
enum AtticHeaderBlurStyle: String, CaseIterable, Sendable {
    case today
    case variableBlur

    /// The developer panel's words (preview-only, not localized).
    var title: String {
        switch self {
        case .today: "Today"
        case .variableBlur: "Variable blur"
        }
    }
}

/// The header blur choice, live. Only a strict preview identity offers it
/// (Settings › General › Motion Lab) and keeps it in its own defaults;
/// every other identity is always Today and keeps nothing. Variable blur
/// also resolves to Today where the system has no variable blur.
@MainActor
final class AtticHeaderBlurLab: ObservableObject {
    static let shared = AtticHeaderBlurLab(defaults: .standard,
                                           isPreview: AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier))

    @Published var style: AtticHeaderBlurStyle {
        didSet { defaults?.set(style.rawValue, forKey: Self.styleKey) }
    }
    /// The strongest blur, at the panel's top edge (points), tuned live.
    @Published var radius: Double {
        didSet { defaults?.set(radius, forKey: Self.radiusKey) }
    }
    /// How far below the header the blur reaches (points), tuned live.
    @Published var reach: Double {
        didSet { defaults?.set(reach, forKey: Self.reachKey) }
    }
    static let radiusRange: ClosedRange<Double> = 1...20
    static let reachRange: ClosedRange<Double> = 0...48

    let offersChoice: Bool
    private let defaults: UserDefaults?
    static let styleKey = "AtticHeaderBlurStyle"
    static let radiusKey = "AtticHeaderBlurRadius"
    static let reachKey = "AtticHeaderBlurReach"

    init(defaults: UserDefaults, isPreview: Bool, blurAvailable: Bool = AtticVariableBlur.isAvailable) {
        offersChoice = isPreview && blurAvailable
        self.defaults = offersChoice ? defaults : nil
        style = offersChoice
            ? (defaults.string(forKey: Self.styleKey).flatMap(AtticHeaderBlurStyle.init(rawValue:)) ?? .today)
            : .today
        let storedRadius = offersChoice ? defaults.object(forKey: Self.radiusKey) as? Double : nil
        radius = storedRadius.map { min(max($0, Self.radiusRange.lowerBound), Self.radiusRange.upperBound) }
            ?? Double(AtticHeaderBlurMetrics.radius)
        let storedReach = offersChoice ? defaults.object(forKey: Self.reachKey) as? Double : nil
        reach = storedReach.map { min(max($0, Self.reachRange.lowerBound), Self.reachRange.upperBound) }
            ?? Double(AtticHeaderBlurMetrics.reachBelowHeader)
    }

    var blursHeader: Bool { style == .variableBlur }
}

/// The variable blur's shape, in points.
enum AtticHeaderBlurMetrics {
    /// How far below the header's bottom edge the blur reaches, where it
    /// is back to sharp text.
    static let reachBelowHeader: CGFloat = 22
    /// The strongest blur, at the panel's top edge.
    static let radius: CGFloat = 6
    /// The surface fade over the top of the blur, as a share of its height:
    /// text never reads through behind the controls.
    static let fadeShare: CGFloat = 0.55
    static let fadeOpacity: Double = 0.85
    /// With the blur on, the text dissolves only into the panel's own top
    /// edge, over this band, so the rounded corner never slices a line.
    static let edgeRamp: CGFloat = 8

    /// With the blur on, where the scrolled text is fully gone and how far
    /// it fades back in below that. Opaque panel: only the panel's own top
    /// edge (the surface fade hides the rest). See-through panel: the text
    /// itself fades out behind the controls, so nothing reads through the
    /// glass and no colour is painted over it.
    static func textFade(headerBottom: CGFloat, translucent: Bool) -> (top: CGFloat, ramp: CGFloat) {
        translucent ? (headerBottom * 0.6, headerBottom * 0.4) : (0, edgeRamp)
    }
}

// MARK: - Variable blur

/// A backdrop that blurs what is behind it, strongest at its top edge and
/// clear at its bottom edge (Core Animation's private `variableBlur` filter
/// on a backdrop layer). `isAvailable` is false where either class is
/// missing; the view then draws nothing, and the lab stays on Today.
struct AtticVariableBlur: NSViewRepresentable {
    var radius: CGFloat = AtticHeaderBlurMetrics.radius

    nonisolated static var isAvailable: Bool { AtticVariableBlurView.makeFilter() != nil && AtticVariableBlurView.backdropClass != nil }

    func makeNSView(context: Context) -> AtticVariableBlurView {
        AtticVariableBlurView(radius: radius)
    }

    func updateNSView(_ view: AtticVariableBlurView, context: Context) {
        view.radius = radius
    }
}

final class AtticVariableBlurView: NSView {
    nonisolated static let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type

    var radius: CGFloat {
        didSet { if radius != oldValue { applyFilter() } }
    }

    private let backdrop: CALayer?
    private var maskSize: CGSize = .zero

    init(radius: CGFloat) {
        self.radius = radius
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
              let filter = Self.makeFilter(), let mask = Self.maskImage(height: bounds.height) else { return }
        maskSize = bounds.size
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.filters = [filter]
    }

    /// One column, opaque at the top (full blur) easing to clear at the
    /// bottom (no blur). The filter stretches it across the width.
    nonisolated static func maskImage(height: CGFloat) -> CGImage? {
        let rows = max(2, Int(height.rounded(.up)))
        guard let context = CGContext(data: nil, width: 1, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Bitmap rows run top to bottom in memory; black at the eased alpha.
        for row in 0..<rows {
            let t = Double(row) / Double(rows - 1)        // 0 top … 1 bottom
            let strength = 1 - t
            let eased = strength * strength * (3 - 2 * strength)
            let offset = row * context.bytesPerRow
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 0
            data[offset + 3] = UInt8((eased * 255).rounded())
        }
        return context.makeImage()
    }
}

// MARK: - The Notes header backdrop

/// The variable blur over the top of the note, plus a short surface fade at
/// the very top, behind the header's controls.
struct AtticHeaderBlurBackdrop: View {
    let height: CGFloat
    var radius: CGFloat = AtticHeaderBlurMetrics.radius
    let design: AtticDesignContext

    var body: some View {
        let surface = design.tokens.panel.base.color
        ZStack(alignment: .top) {
            AtticVariableBlur(radius: radius)
            // Only an opaque panel gets the surface-coloured fade: over a
            // see-through panel it painted a white band (owner, 2026-10-14).
            // There the text itself fades out instead (`textFadeTop`).
            if !design.isTranslucent {
                LinearGradient(stops: [
                    .init(color: surface.opacity(AtticHeaderBlurMetrics.fadeOpacity), location: 0),
                    .init(color: surface.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: height * AtticHeaderBlurMetrics.fadeShare)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
