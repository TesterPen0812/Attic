import SwiftUI

/// Capture mode: set only by the component gallery's `--capture` run and the
/// appearance check. It swaps AppKit-backed pieces (text fields, switches,
/// native materials) for faithful SwiftUI drawings, since `ImageRenderer`
/// cannot draw them, and lets components report where their text, icons
/// and controls landed. Outside capture mode none of this runs.
struct AtticCaptureContext {
    enum Backdrop: Equatable {
        /// A stand-in wallpaper, blurred as glass would blur it (contact
        /// sheets and the decision sheet).
        case wallpaper(AtticWallpaperTone)
        /// A flat grey desktop, drawn as its measured native render under
        /// each translucent surface (the check).
        case desktop(AtticSurfaceModel.Desktop)
    }

    let collector: AtticProbeCollector?
    let backdrop: Backdrop

    static let coordinateSpace = "atticCapture"
}

private struct AtticCaptureContextKey: EnvironmentKey {
    static let defaultValue: AtticCaptureContext? = nil
}

private struct AtticSpecimenKey: EnvironmentKey {
    static let defaultValue = ""
}

private struct AtticProbesDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var atticCapture: AtticCaptureContext? {
        get { self[AtticCaptureContextKey.self] }
        set { self[AtticCaptureContextKey.self] = newValue }
    }

    /// The gallery specimen a view belongs to (probe grouping).
    var atticSpecimen: String {
        get { self[AtticSpecimenKey.self] }
        set { self[AtticSpecimenKey.self] = newValue }
    }

    /// Content deliberately drawn under a bar or veil (the edge-blur
    /// demonstration): it is meant to be faded and overlapped, so it reports
    /// nothing to the check.
    var atticProbesDisabled: Bool {
        get { self[AtticProbesDisabledKey.self] }
        set { self[AtticProbesDisabledKey.self] = newValue }
    }
}

/// One thing a component reported while being captured.
struct AtticProbe: Identifiable {
    enum Kind {
        /// A text run: its style, string, ink and natural (untruncated) size.
        case text(style: AtticTextStyle, string: String)
        case icon(name: String)
        /// A control and the size and corner radius the tokens require.
        case control(name: String, expectedSize: CGSize?, radius: CGFloat, expectedRadius: CGFloat)
        /// A specimen's own bounds.
        case specimen
    }

    let id: UUID
    var kind: Kind
    var ink: AtticInk?
    var foreground: AtticRGBA?
    var specimen: String
    var frame: CGRect = .null
    var idealSize: CGSize?
    /// Deliberate overlap (a badge on a stack, a label inside an outline).
    var allowsOverlap = false
    /// User content that may truncate with an ellipsis.
    var allowsTruncation = false
}

/// Collects probes during one render. Layout can run more than once; the
/// last frame reported for an id wins.
final class AtticProbeCollector: @unchecked Sendable {
    private(set) var order: [UUID] = []
    private var probes: [UUID: AtticProbe] = [:]
    private var idealSizes: [UUID: CGSize] = [:]
    private let lock = NSLock()

    var all: [AtticProbe] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { id in
            guard var probe = probes[id] else { return nil }
            probe.idealSize = idealSizes[id]
            return probe
        }
    }

    func reset() {
        lock.lock()
        order.removeAll()
        probes.removeAll()
        idealSizes.removeAll()
        lock.unlock()
    }

    func record(_ probe: AtticProbe, frame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        if var existing = probes[probe.id] {
            existing.frame = frame
            existing.kind = probe.kind
            existing.ink = probe.ink
            existing.foreground = probe.foreground
            probes[probe.id] = existing
        } else {
            var copy = probe
            copy.frame = frame
            probes[probe.id] = copy
            order.append(probe.id)
        }
    }

    func recordIdealSize(_ size: CGSize, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        idealSizes[id] = size
    }
}

/// Reports a view's frame (in the capture space) to the collector.
private struct AtticProbeReporter: ViewModifier {
    let probe: (String) -> AtticProbe
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticSpecimen) private var specimen
    @Environment(\.atticProbesDisabled) private var disabled

    func body(content: Content) -> some View {
        if let collector = capture?.collector, !disabled {
            content.background {
                GeometryReader { proxy in
                    let _ = collector.record(
                        probe(specimen),
                        frame: proxy.frame(in: .named(AtticCaptureContext.coordinateSpace))
                    )
                    Color.clear
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func atticProbe(_ make: @escaping (String) -> AtticProbe) -> some View {
        modifier(AtticProbeReporter(probe: make))
    }

    /// Reports a control's frame and radius, so the check can compare them
    /// with the tokens.
    func atticControlProbe(_ name: String, id: UUID, expectedSize: CGSize?, radius: CGFloat, expectedRadius: CGFloat) -> some View {
        atticProbe { specimen in
            AtticProbe(
                id: id,
                kind: .control(name: name, expectedSize: expectedSize, radius: radius, expectedRadius: expectedRadius),
                specimen: specimen
            )
        }
    }
}

/// Measures the natural size of a text run, only while capturing.
struct AtticIdealSizeReporter: View {
    let id: UUID
    let text: Text
    let collector: AtticProbeCollector

    var body: some View {
        text
            .fixedSize()
            .hidden()
            .background {
                GeometryReader { proxy in
                    let _ = collector.recordIdealSize(proxy.size, for: id)
                    Color.clear
                }
            }
            .accessibilityHidden(true)
    }
}

/// Which stand-in wallpaper sits behind a capture.
enum AtticWallpaperTone: String, Hashable, Sendable {
    /// The mockups' pastel gradient, darkened for Dark mode.
    case matchingMode
    /// The pastel gradient, lifted: a light desktop.
    case light
    /// The same hues, deep: a dark desktop.
    case dark
}
