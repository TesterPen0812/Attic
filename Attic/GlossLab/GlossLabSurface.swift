#if ATTIC_GLOSS_LAB
import AppKit
import SwiftUI

// The Gloss lab's drawing on the live panel (experimental preview only).
// Everything here is vector shapes and unit-space gradients: no geometry
// reader, no blur, no picture redrawn while the panel resizes. Hit testing
// is off on every layer.

/// 1. Bare glass at the rim: a mask for the panel's foundation fill and
/// Tint that fades them out over the last `width` pt towards the edge,
/// following the panel's curve. Built from nested insets of the panel's own
/// squircle, one per pixel at 2x, so the ramp is linear in alpha and
/// re-paths on resize like any shape.
struct GlossRimFadeMask: View {
    let cornerSize: CGFloat
    let exponent: CGFloat
    let width: CGFloat

    var body: some View {
        let steps = Self.steps(width: width)
        let shape = Squircle(cornerRadius: cornerSize, exponent: exponent)
        if steps == 0 {
            shape.fill(Color.black)
        } else {
            ZStack {
                ForEach(Array(0..<steps), id: \.self) { k in
                    shape.inset(by: width * CGFloat(k) / CGFloat(steps))
                        .fill(Color.black.opacity(Self.alpha(step: k, of: steps)))
                }
            }
        }
    }

    static func steps(width: CGFloat) -> Int {
        width < 0.25 ? 0 : max(1, Int((width * 2).rounded(.up)))
    }

    /// The opacity of step `k` so that, laid over the steps before it,
    /// the mask's alpha inside inset k is (k + 1) / steps.
    static func alpha(step k: Int, of steps: Int) -> Double {
        let before = Double(k) / Double(steps)
        let after = Double(k + 1) / Double(steps)
        return (after - before) / (1 - before)
    }
}

/// 5 and 6, drawn over the panel's surface and under its content: the
/// light from the top with its bottom shade, and the fine grain.
struct GlossLabPanelSurfaceLayer: View {
    let cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.surfaceLayer += 1
        #endif
        let lab = GlossLab.shared
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        ZStack {
            if lab.topLight {
                GlossTopLight(shape: shape, dark: design.mode == .dark, keepsOut: lab.topLightKeepsOut,
                              light: design.mode == .dark ? lab.topLightDark : lab.topLightLight,
                              shade: design.mode == .dark ? lab.bottomShadeDark : lab.bottomShadeLight)
            }
            if lab.grain {
                GlossGrain(percent: lab.grainPercent)
                    .clipShape(shape)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 5. An additive white strongest at the top and gone by two thirds of the
/// height, and a soft shade over the bottom third. With `keepsOut`, both
/// leave the top and bottom control bands, as the lift does (Accepted
/// 2026-11-13), measured in points by a stack, not a geometry reader.
struct GlossTopLight: View {
    let shape: Squircle
    let dark: Bool
    let keepsOut: Bool
    let light: Double
    let shade: Double

    var body: some View {
        ZStack {
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(light), location: 0),
                                              .init(color: .white.opacity(light * 0.45), location: 0.3),
                                              .init(color: .white.opacity(0), location: 1)],
                                      startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 2.0 / 3)))
                .mask { bands }
                .blendMode(.plusLighter)
            shape.fill(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                              .init(color: .black.opacity(shade), location: 1)],
                                      startPoint: UnitPoint(x: 0.5, y: 2.0 / 3), endPoint: .bottom))
                .mask { bands }
        }
    }

    @ViewBuilder
    private var bands: some View {
        if keepsOut {
            let clear = AtticSurfaceModel.LiftControlBands.clear
            let fade = AtticSurfaceModel.LiftControlBands.fade
            VStack(spacing: 0) {
                Color.clear.frame(height: clear)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade)
                Color.clear.frame(height: clear)
            }
        } else {
            Color.black
        }
    }
}

/// 6. Fine grain: one small noise picture, made once, tiled, never
/// animated and never regenerated. Each pixel is black or white; the layer
/// is drawn at `percent` %.
struct GlossGrain: View {
    let percent: Double

    var body: some View {
        Image(decorative: Self.tile, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(percent / 100)
    }

    static let tile: CGImage = {
        let side = 128
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let v: UInt8 = (z & 1) == 0 ? 0 : 255
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()
}

/// 3 and 4, drawn over the panel at its rim (inside the clip, like the
/// trunk's rim): the Edge light and the second inner edge.
struct GlossLabPanelRimLayer: View {
    let cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.rimLayer += 1
        #endif
        let lab = GlossLab.shared
        let dark = design.mode == .dark
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        ZStack {
            if lab.edgeLight {
                let strength = dark ? lab.edgeLightDark : lab.edgeLightLight
                // Bright along the top and the upper sides, fading down.
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(strength), location: 0),
                                                          .init(color: .white.opacity(strength * 0.4), location: 0.22),
                                                          .init(color: .white.opacity(0), location: 0.55)],
                                                  startPoint: .top, endPoint: .bottom),
                                   lineWidth: lab.edgeLightWidth)
                // A thin darker line along the bottom.
                shape.inset(by: 0.25)
                    .stroke(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.7),
                                                   .init(color: .black.opacity(lab.edgeLightShade), location: 1)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
            }
            if lab.innerEdge {
                shape.inset(by: lab.innerEdgeInset)
                    .stroke(Color.white.opacity(lab.innerEdgeStrength), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 10. One rim recipe for every control: the button's Edge light with its
/// lit runs measured from each corner over a square of the control's
/// height, so a wide control (Now · Later · Done) is lit exactly as far as
/// a square one (pin, •••, Search). The trunk's single gradient runs along
/// the bounding box's diagonal, so on a wide control the lit run stretches
/// with the width and its brightest point lies nearer the end cap.
struct GlossLabControlEdgeLight<S: InsettableShape>: View {
    let shape: S
    let light: AtticEdgeLight

    var body: some View {
        GeometryReader { proxy in
            #if DEBUG
            let _ = GlossLabCounters.controlEdgeLight += 1
            #endif
            let size = proxy.size
            let side = max(1, min(size.width, size.height))
            let ux = side / max(size.width, 1), uy = side / max(size.height, 1)
            ZStack {
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(light.topLeading), location: 0),
                                                          .init(color: .white.opacity(0), location: light.fade)],
                                                  startPoint: .topLeading, endPoint: UnitPoint(x: ux, y: uy)),
                                   lineWidth: light.lineWidth)
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0), location: 1 - light.fade),
                                                          .init(color: .white.opacity(light.bottomTrailing), location: 1)],
                                                  startPoint: UnitPoint(x: 1 - ux, y: 1 - uy), endPoint: .bottomTrailing),
                                   lineWidth: light.lineWidth)
                shape.stroke(light.hairline.color, lineWidth: light.hairlineWidth)
            }
        }
    }
}

/// 2. The ring between the panel's squircle and the same squircle inset by
/// `width`. The inner curve is the outer one inset and walked the other way
/// (mirrored about the centre), so the inside is a hole under either fill
/// rule.
struct GlossRing: Shape {
    var outer: Squircle
    var width: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = outer.path(in: rect)
        let inner = outer.inset(by: width).path(in: rect)
        let mirror = CGAffineTransform(translationX: rect.midX, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -rect.midX, y: 0)
        path.addPath(inner, transform: mirror)
        return path
    }
}

/// 2. A band of Apple's Clear glass around the edge, regular glass inside
/// it, in place of the panel's one regular glass. Two honest ways to lay
/// it, both Apple's own glass with nothing drawn to imitate it:
/// - ring: Clear on the ring only, Regular on the inset squircle; the two
///   glasses sit side by side and neither is over the other;
/// - stacked: Clear under the whole panel, Regular over its inner part
///   (glass over glass, which Apple says does not sample the glass under it).
/// Either may share one `GlassEffectContainer` (spacing 0) or not.
struct GlossClearBandGlass: View {
    let cornerSize: CGFloat
    let width: CGFloat
    let method: GlossLab.ClearBandMethod
    let sharesContainer: Bool

    var body: some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        if sharesContainer {
            GlassEffectContainer(spacing: 0) { glasses(shape) }
        } else {
            glasses(shape)
        }
    }

    private func glasses(_ shape: Squircle) -> some View {
        let inner = shape.inset(by: width)
        return ZStack {
            switch method {
            case .ring:
                let ring = GlossRing(outer: shape, width: width)
                ring.fill(Color.clear).glassEffect(.clear, in: ring)
            case .stacked:
                shape.fill(Color.clear).glassEffect(.clear, in: shape)
            }
            inner.fill(Color.clear).glassEffect(.regular, in: inner)
        }
    }
}

/// 7. The panel's exterior shadow. With 7 and its spill off it is the
/// trunk's `AtticPanelOutsideShadow`, untouched. With 7 on: a tight
/// contact shadow and a wide soft one, both cast only outside the
/// squircle, the soft one held inside the window's transparent margin
/// (the trunk's own extent rule, radius x 2 + drop). With the spill on: a
/// faint white glow under the bottom edge, cast by a band just inside it.
/// The panel's window, its margin and its geometry are the trunk's.
struct GlossLabPanelShadow: View {
    let shape: Squircle
    let cornerSize: CGFloat
    let elevation: AtticPanelSurfaceElevation
    /// The window's transparent margin around the surface, pt.
    let margin: CGFloat
    @Environment(\.atticDesign) private var design

    /// The spill's glow: radius and drop, pt (extent 2 x 8 + 4 = 20).
    static let spillRadius: CGFloat = 8
    static let spillDrop: CGFloat = 4
    static let spillCasterHeight: CGFloat = 10

    /// The soft shadow's radius, held so radius x 2 + drop fits the margin.
    static func softRadius(_ wanted: CGFloat, drop: CGFloat, margin: CGFloat) -> CGFloat {
        max(0, min(wanted, (margin - abs(drop)) / 2))
    }

    var body: some View {
        #if DEBUG
        let _ = GlossLabCounters.shadowLayer += 1
        #endif
        let lab = GlossLab.shared
        if !lab.glassShadow && !lab.glassSpill {
            AtticPanelOutsideShadow(shape: shape, elevation: elevation)
        } else {
            let dark = design.mode == .dark
            let inset = AtticPanelOutsideShadow.casterInset
            ZStack {
                if lab.glassShadow {
                    let drop = CGFloat(lab.shadowSoftDrop)
                    shape.fill(Color.black).padding(inset)
                        .shadow(color: .black.opacity(dark ? lab.shadowSoftDark : lab.shadowSoftLight),
                                radius: Self.softRadius(CGFloat(lab.shadowSoftRadius), drop: drop, margin: margin),
                                x: 0, y: drop)
                    shape.fill(Color.black).padding(inset)
                        .shadow(color: .black.opacity(dark ? lab.shadowContactDark : lab.shadowContactLight),
                                radius: 1, x: 0, y: 1)
                } else {
                    AtticPanelOutsideShadow(shape: shape, elevation: elevation)
                }
                if lab.glassSpill {
                    Rectangle().fill(Color.white)
                        .frame(height: Self.spillCasterHeight)
                        .padding(.horizontal, cornerSize)
                        .padding(.bottom, inset)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .shadow(color: .white.opacity(lab.spillStrength),
                                radius: Self.softRadius(Self.spillRadius, drop: Self.spillDrop, margin: margin),
                                x: 0, y: Self.spillDrop)
                }
                shape.fill(Color.black).blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
#endif
