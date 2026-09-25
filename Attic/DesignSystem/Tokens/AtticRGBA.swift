import AppKit
import SwiftUI

/// The design system's one colour type: sRGB with alpha.
///
/// Every token is an `AtticRGBA`, so the same value is drawn by SwiftUI and
/// measured by the appearance check. Translucent tokens (hover fills, rims,
/// the Dark control overlay) are composited over what lies beneath them with
/// `over(_:)` before any contrast is judged.
struct AtticRGBA: Equatable, Hashable, Sendable, CustomStringConvertible {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `AtticRGBA(0xFAFAFA)`; `alpha` defaults to opaque.
    init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    init(_ color: AtticThemeColor, alpha: Double = 1) {
        self.init(red: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }

    static func white(_ alpha: Double) -> AtticRGBA { AtticRGBA(red: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: Double) -> AtticRGBA { AtticRGBA(red: 0, green: 0, blue: 0, alpha: alpha) }
    static func grey(_ byte: Double) -> AtticRGBA { AtticRGBA(red: byte / 255, green: byte / 255, blue: byte / 255) }
    static let clear = AtticRGBA(red: 0, green: 0, blue: 0, alpha: 0)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var themeColor: AtticThemeColor { AtticThemeColor(red: red, green: green, blue: blue) }

    func withAlpha(_ alpha: Double) -> AtticRGBA {
        AtticRGBA(red: red, green: green, blue: blue, alpha: min(max(alpha, 0), 1))
    }

    /// Source-over compositing of `self` onto `backdrop`.
    func over(_ backdrop: AtticRGBA) -> AtticRGBA {
        let a = alpha + backdrop.alpha * (1 - alpha)
        guard a > 0 else { return .clear }
        func channel(_ top: Double, _ bottom: Double) -> Double {
            (top * alpha + bottom * backdrop.alpha * (1 - alpha)) / a
        }
        return AtticRGBA(
            red: channel(red, backdrop.red),
            green: channel(green, backdrop.green),
            blue: channel(blue, backdrop.blue),
            alpha: a
        )
    }

    /// Straight mix toward `other` by `amount` (0 = self, 1 = other), alpha included.
    func mixed(with other: AtticRGBA, amount: Double) -> AtticRGBA {
        let t = min(max(amount, 0), 1)
        return AtticRGBA(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    var relativeLuminance: Double { themeColor.relativeLuminance }

    /// WCAG contrast of this colour, composited over `background`, against
    /// that background. The background must be opaque.
    func contrast(on background: AtticRGBA) -> Double {
        over(background).themeColor.contrastRatio(with: background.themeColor)
    }

    var hexString: String { "#" + themeColor.hexString + (alpha < 1 ? String(format: "@%.2f", alpha) : "") }
    var description: String { hexString }

    // MARK: HSL

    /// Hue, saturation and lightness, each 0...1.
    var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxV = max(red, green, blue)
        let minV = min(red, green, blue)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0.000_001 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if maxV == red {
            h = ((green - blue) / d).truncatingRemainder(dividingBy: 6)
        } else if maxV == green {
            h = (blue - red) / d + 2
        } else {
            h = (red - green) / d + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    init(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) {
        let l = min(max(lightness, 0), 1)
        let s = min(max(saturation, 0), 1)
        let c = (1 - abs(2 * l - 1)) * s
        let h = (hue - floor(hue)) * 6
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m, alpha: alpha)
    }

    /// The same hue and saturation at the lightest (Dark) or darkest (Light)
    /// lightness that still reaches `target` against every background:
    /// how priority, accent and warning colours are tuned per palette and
    /// mode. Moves in 0.5 % lightness steps, so a colour that already passes
    /// is returned unchanged.
    func tuned(toContrast target: Double, against backgrounds: [AtticRGBA], lighten: Bool) -> AtticRGBA {
        func passes(_ candidate: AtticRGBA) -> Bool {
            backgrounds.allSatisfy { candidate.contrast(on: $0) >= target }
        }
        if passes(self) { return self }
        let (h, s, l) = hsl
        var lightness = l
        for _ in 0..<200 {
            lightness += lighten ? 0.005 : -0.005
            guard (0...1).contains(lightness) else { break }
            let candidate = AtticRGBA(hue: h, saturation: s, lightness: lightness, alpha: alpha)
            if passes(candidate) { return candidate }
        }
        return lighten ? .white(alpha) : AtticRGBA(red: 0, green: 0, blue: 0, alpha: alpha)
    }
}
