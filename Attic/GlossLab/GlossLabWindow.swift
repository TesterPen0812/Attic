#if ATTIC_GLOSS_LAB
import AppKit
import SwiftUI

/// The Gloss lab's two windows: the lab itself (a plain utility panel with
/// the switches) and the backdrop (black, white or a picture of ours) put
/// behind the panel. Both are this app's own windows, so a click in them
/// counts as inside the panel's family and never dismisses it
/// (`CornerHoverMonitor.isAtticOwnedWindow`). Neither changes who owns the
/// panel, its geometry, its hit testing or its keyboard.
@MainActor
final class GlossLabWindows: NSObject, NSWindowDelegate {
    static let shared = GlossLabWindows()

    private var settings: AppSettings?
    private var labPanel: NSPanel?
    private var backdropWindow: NSWindow?
    private var backdropHost: NSHostingView<GlossBackdropView>?
    private var followTimer: Timer?
    private var lastPanelFrame: CGRect?
    private var lastPanelVisible: Bool?
    /// The docked panel the backdrop sits behind (a pulled-out panel is an
    /// `AtticPanel` too, so the first one in the app's list may not be it).
    private weak var dockedPanel: NSWindow?
    private var occlusionObserver: NSObjectProtocol?

    func configure(settings: AppSettings, dockedPanel: NSWindow?) {
        self.settings = settings
        self.dockedPanel = dockedPanel
        observeBackdrop()
        if UserDefaults.standard.object(forKey: GlossLab.prefix + "openAtLaunch") == nil
            || UserDefaults.standard.bool(forKey: GlossLab.prefix + "openAtLaunch") {
            show()
        }
    }

    func show() {
        guard let settings else { return }
        if labPanel == nil {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 640),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Gloss lab"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isFloatingPanel = false
            panel.level = .normal
            panel.contentView = NSHostingView(rootView: GlossLabView(lab: .shared, settings: settings))
            panel.setFrameAutosaveName("GlossLabWindow")
            if !panel.setFrameUsingName("GlossLabWindow"), let screen = NSScreen.main {
                let visible = screen.visibleFrame
                panel.setFrameTopLeftPoint(CGPoint(x: visible.minX + 40, y: visible.maxY - 40))
            }
            labPanel = panel
        }
        labPanel?.orderFrontRegardless()
    }

    // MARK: Backdrop

    private func observeBackdrop() {
        withObservationTracking {
            _ = GlossLab.shared.backdrop
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applyBackdrop()
                self?.observeBackdrop()
            }
        }
        applyBackdrop()
    }

    private func applyBackdrop() {
        let backdrop = GlossLab.shared.backdrop
        guard backdrop != .none else {
            followTimer?.invalidate(); followTimer = nil
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = nil
            backdropWindow?.orderOut(nil)
            return
        }
        if backdropWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Gloss lab backdrop"
            window.level = .normal
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: GlossBackdropView(backdrop: backdrop))
            window.contentView = host
            backdropWindow = window
            backdropHost = host
        }
        backdropHost?.rootView = GlossBackdropView(backdrop: backdrop)
        followPanel(force: true)
        if followTimer == nil {
            // Follows the panel's window if it moves or resizes; a frame
            // read, no drawing.
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followPanel(force: false) }
            }
        }
        if occlusionObserver == nil {
            // The panel hides with orderOut and keeps its frame, so the
            // frame alone never tells. Its occlusion change on orderOut and
            // orderFront makes the backdrop follow at once; the timer above
            // still catches anything this misses.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard note.object is AtticPanel else { return }
                MainActor.assumeIsolated { self?.followPanel(force: false) }
            }
        }
    }

    private func followPanel(force: Bool) {
        guard let window = backdropWindow else { return }
        let panel = dockedPanel ?? NSApp.windows.first { $0 is AtticPanel }
        let frame = panel?.frame
        let visible = panel?.isVisible == true
        if !force, frame == lastPanelFrame, visible == lastPanelVisible { return }
        lastPanelFrame = frame
        lastPanelVisible = visible
        let screen = panel?.screen ?? NSScreen.main
        guard let target = Self.backdropFrame(panelFrame: frame, panelVisible: visible, screenFrame: screen?.frame) else {
            // The panel is hidden: so is the backdrop, on every Space.
            window.orderOut(nil)
            return
        }
        window.setFrame(target, display: true)
        window.orderFrontRegardless()
        if labPanel?.isVisible == true { labPanel?.orderFrontRegardless() }
    }

    /// Where the backdrop goes for the panel's frame, or nil when it must
    /// not be on screen: the panel is hidden (or absent), so the backdrop
    /// hides with it and comes back with it.
    nonisolated static func backdropFrame(panelFrame: CGRect?, panelVisible: Bool, screenFrame: CGRect?) -> CGRect? {
        guard panelVisible, let screenFrame else { return nil }
        var target: CGRect
        if let panelFrame, panelFrame.width > 1 {
            // Generous room around the panel: glass bends what lies well
            // outside its own edge.
            target = panelFrame.insetBy(dx: -220, dy: -220).intersection(screenFrame)
        } else {
            target = CGRect(x: screenFrame.midX, y: screenFrame.minY, width: screenFrame.width / 2, height: screenFrame.height)
        }
        if target.isEmpty { target = screenFrame }
        return target
    }
}

/// The lab window's content, simplified on 23 Nov (owner: "all the controls
/// are too confusing"): mode and backdrop, the presets, then the switches in
/// three plain groups. A switch shows its sliders only while it is on, a
/// slider that differs by mode shows the current mode's value only, and the
/// rarely used ones sit under "More". The idea numbers of the brief are kept
/// in Copy values, not in the window.
struct GlossLabView: View {
    @Bindable var lab: GlossLab
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    /// The app's own glass settings, for Copy values.
    private var appValues: GlossLab.AppValues {
        GlossLab.AppValues(mode: settings.appearance.title, surface: settings.panelSurfaceStyle.title,
                           palette: settings.panelTheme.title, tint: settings.panelTint.title,
                           tintLength: settings.panelTintLength, brightenGlass: settings.brightenGlass)
    }

    /// The mode the panel draws in now: the app's setting, or the system's.
    private var dark: Bool {
        switch settings.appearance {
        case .dark: true
        case .light: false
        case .system: colorScheme == .dark
        }
    }

    private var modeName: String { dark ? "Dark" : "Light" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Mode", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Backdrop", selection: $lab.backdrop) {
                    ForEach(GlossLab.Backdrop.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                section("Presets")
                presets
                Text("A preset sets every switch and slider below. Pin the panel first if it hides when the pointer leaves it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                section("Glass")
                row("Clear glass body", $lab.clearBody,
                    note: "Apple's Clear glass in place of the regular one: more of what is behind comes through, and it bends at the edge.") {
                    slider("Fill · \(modeName)", dark ? $lab.clearBodyFillDark : $lab.clearBodyFillLight, 0...80, unit: " %")
                }
                row("Refracting rim", $lab.clearBand,
                    note: "Today's glass with a rim of Clear glass, which bends what is behind it. Width is how far in the bend reaches; Apple's glass has no strength setting. Under a Clear glass body the whole edge already bends, so this draws nothing.") {
                    slider("Width", $lab.clearBandWidth, 2...40, unit: " pt")
                    more {
                        Picker("Laid", selection: $lab.clearBandMethod) {
                            ForEach(GlossLab.ClearBandMethod.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("One glass container", isOn: $lab.clearBandContainer)
                    }
                }
                row("No colour from behind", $lab.neutralGlass,
                    note: "What shows through keeps its light and shade and loses its colour.") {
                    slider("Amount", $lab.neutralGlassAmount, 0...100, unit: " %")
                    Toggle("The controls too", isOn: $lab.neutralControls)
                }
                row("Clear glass controls", $lab.clearControls,
                    note: "The buttons and fields wear Clear glass too.") { EmptyView() }
                row("Tiles", $lab.tiles,
                    note: "On the Tasks page and the Notes list each group sits on its own piece of Clear glass, as Control Centre's tiles do, and the panel behind draws no glass. The body, rim, edge and shadow switches draw nothing there while this is on, unless Sheet behind keeps the panel.") {
                    slider("Dim · \(modeName)", dark ? $lab.tilesDimDark : $lab.tilesDimLight, 0...80, unit: " %")
                    slider("Corner", $lab.tilesCorner, 6...36, unit: " pt")
                    slider("Tile edge", $lab.tilesEdge, 0...1)
                    Toggle("Sheet behind (the panel's own glass; tiles without glass)", isOn: $lab.tilesSheet)
                    Toggle("Smoky in Light (black dim, the page drawn as in Dark)", isOn: $lab.tilesSmoky)
                    if lab.tilesSmoky {
                        slider("Smoke · Light", $lab.tilesSmokeLight, 0...60, unit: " %")
                    }
                    more {
                        slider("Gap", $lab.tilesGap, 0...20, unit: " pt")
                        slider("Shadow", $lab.tilesShadow, 0...0.5)
                        slider("Panel behind · \(modeName)", dark ? $lab.tilesPanelDark : $lab.tilesPanelLight, 0...60, unit: " %")
                    }
                }

                section("Edge")
                row("Bare glass at the rim", $lab.rimFade,
                    note: "Our own fill fades out towards the edge, so the rim is glass alone.") {
                    slider("Width", $lab.rimFadeWidth, 0...16, unit: " pt")
                }
                row("Edge light", edgeLightOn, note: "A bright line on the panel's edge, strongest at the top.") {
                    slider("Strength · \(modeName)", dark ? $lab.edgeLightDark : $lab.edgeLightLight, 0...1)
                    slider("Width", $lab.edgeLightWidth, 1...4, unit: " pt")
                    Toggle("All the way round", isOn: $lab.edgeLightAround)
                    Toggle("Leans towards the pointer", isOn: $lab.movingLight)
                    more {
                        slider("Bottom line", $lab.edgeLightShade, 0...0.5)
                        slider("Lean: tilt", $lab.movingLightTilt, 0...30, unit: "°")
                        slider("Lean: reach", $lab.movingLightReach, 0...0.2)
                    }
                }
                row("Second inner edge", $lab.innerEdge, note: "A fine line just inside the rim.") {
                    slider("Inset", $lab.innerEdgeInset, 1.5...4, unit: " pt")
                    slider("Strength", $lab.innerEdgeStrength, 0...1)
                }
                row("Same edge light on every control", $lab.oneRim,
                    note: "Wide and square controls are lit over the same length.") { EmptyView() }

                section("Depth")
                row("Glass shadow", $lab.glassShadow, note: "A tight contact shadow and a wide soft one, in place of today's.") {
                    slider("Contact · \(modeName)", dark ? $lab.shadowContactDark : $lab.shadowContactLight, 0...0.8)
                    slider("Soft · \(modeName)", dark ? $lab.shadowSoftDark : $lab.shadowSoftLight, 0...0.6)
                    more {
                        slider("Soft: radius", $lab.shadowSoftRadius, 4...18, unit: " pt")
                        slider("Soft: drop", $lab.shadowSoftDrop, 0...10, unit: " pt")
                    }
                }
                row("Light under the bottom edge", $lab.glassSpill, note: "A faint glow below the panel. Shows over a dark desktop.") {
                    slider("Strength", $lab.spillStrength, 0...0.5)
                }
                row("Fine grain", $lab.grain, note: "A very fine still texture over the glass.") {
                    slider("Strength", $lab.grainPercent, 0...4, unit: " %")
                }

                Divider()

                HStack {
                    Button("Copy values") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lab.valuesText(app: appValues), forType: .string)
                        copied = true
                    }
                    Button("All off") { lab.allOff() }
                    Button("Reset sliders") { lab.resetSliders() }
                    if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 340, minHeight: 360)
    }

    /// 3 and 9 as one switch: 9 draws 3's light, so "Edge light" is on
    /// while either is, and off turns both off.
    private var edgeLightOn: Binding<Bool> {
        Binding(get: { lab.edgeLight || lab.movingLight },
                set: { on in
                    lab.edgeLight = on
                    if !on { lab.movingLight = false }
                })
    }

    // MARK: Presets

    private var presets: some View {
        let current = lab.currentPreset?.id
        let all = GlossLab.presets
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: all.count, by: 2)), id: \.self) { index in
                GridRow {
                    presetButton(all[index], selected: all[index].id == current)
                    if index + 1 < all.count {
                        presetButton(all[index + 1], selected: all[index + 1].id == current)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }

    private func presetButton(_ preset: GlossLab.Preset, selected: Bool) -> some View {
        Button {
            if let dark = preset.dark { settings.appearance = dark ? .dark : .light }
            lab.apply(preset)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(preset.title).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                }
                Text(preset.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityHint(preset.note)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Rows

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// One switch. Its note and sliders show only while it is on.
    private func row(_ title: String, _ isOn: Binding<Bool>, note: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: isOn) { Text(title) }
            if isOn.wrappedValue {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.leading, 20)
            }
        }
    }

    private func more(@ViewBuilder content: () -> some View) -> some View {
        let inner = content()
        return DisclosureGroup("More") {
            VStack(alignment: .leading, spacing: 4) { inner }
                .padding(.top, 2)
        }
        .font(.callout)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "") -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 104, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue) + unit)
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .font(.callout)
    }
}

/// The backdrop's content: flat black, flat white, or a photo-like picture
/// drawn by us (sky, sun, hills, water and some fine sharp detail, so the
/// glass has edges to bend).
struct GlossBackdropView: View {
    let backdrop: GlossLab.Backdrop

    var body: some View {
        switch backdrop {
        case .none, .black: Color.black
        case .white: Color.white
        case .picture: GlossPicture()
        }
    }
}

struct GlossPicture: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            // Sky.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.62), Color(red: 0.55, green: 0.70, blue: 0.92),
                                  Color(red: 0.98, green: 0.78, blue: 0.55)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.62)))
            // Sun.
            let sun = CGRect(x: w * 0.62, y: h * 0.30, width: w * 0.16, height: w * 0.16)
            context.fill(Path(ellipseIn: sun.insetBy(dx: -w * 0.05, dy: -w * 0.05)),
                         with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.9, blue: 0.6).opacity(0.7), .clear]),
                                               center: CGPoint(x: sun.midX, y: sun.midY), startRadius: 0, endRadius: w * 0.14))
            context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.95, blue: 0.82)))
            // Clouds.
            for (x, y, s) in [(0.12, 0.14, 1.0), (0.42, 0.08, 0.7), (0.78, 0.18, 0.9), (0.25, 0.32, 0.6)] {
                for (dx, dy, r) in [(0.0, 0.0, 0.05), (0.05, -0.012, 0.06), (0.1, 0.004, 0.045)] {
                    let radius = w * r * s
                    context.fill(Path(ellipseIn: CGRect(x: w * (x + dx * s) - radius, y: h * (y + dy) - radius * 0.6,
                                                        width: radius * 2, height: radius * 1.2)),
                                 with: .color(.white.opacity(0.85)))
                }
            }
            // Far hills, near hills.
            func hills(_ base: Double, _ amplitude: Double, _ frequency: Double, _ phase: Double, _ color: Color) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h))
                for i in stride(from: 0.0, through: 1.0, by: 0.01) {
                    let y = base + amplitude * sin(i * frequency + phase) + amplitude * 0.4 * sin(i * frequency * 2.7 + phase * 1.3)
                    path.addLine(to: CGPoint(x: w * i, y: h * y))
                }
                path.addLine(to: CGPoint(x: w, y: h))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            hills(0.56, 0.05, 7, 0.4, Color(red: 0.36, green: 0.42, blue: 0.62))
            hills(0.64, 0.04, 11, 1.7, Color(red: 0.16, green: 0.36, blue: 0.30))
            // Water with sharp ripples.
            context.fill(Path(CGRect(x: 0, y: h * 0.72, width: w, height: h * 0.28)), with: .linearGradient(
                Gradient(colors: [Color(red: 0.20, green: 0.38, blue: 0.62), Color(red: 0.05, green: 0.12, blue: 0.25)]),
                startPoint: CGPoint(x: 0, y: h * 0.72), endPoint: CGPoint(x: 0, y: h)))
            for row in 0..<28 {
                let y = h * 0.73 + Double(row) * h * 0.0095
                for i in 0..<16 {
                    let x = w * (Double((i * 37 + row * 53) % 100) / 100)
                    context.fill(Path(CGRect(x: x, y: y, width: w * 0.05, height: 1.5)),
                                 with: .color(.white.opacity(0.18 + 0.02 * Double(row % 5))))
                }
            }
            // Trees: dark, crisp silhouettes on the near shore.
            for i in 0..<24 {
                let x = w * (0.03 + Double(i) * 0.041), base = h * (0.70 + 0.01 * sin(Double(i)))
                let height = h * (0.06 + 0.03 * Double((i * 7) % 5) / 5)
                var tree = Path()
                tree.move(to: CGPoint(x: x, y: base - height))
                tree.addLine(to: CGPoint(x: x - height * 0.22, y: base))
                tree.addLine(to: CGPoint(x: x + height * 0.22, y: base))
                tree.closeSubpath()
                context.fill(tree, with: .color(Color(red: 0.04, green: 0.14, blue: 0.10)))
            }
            // A sign with text, for fine detail behind the glass.
            let sign = CGRect(x: w * 0.06, y: h * 0.44, width: w * 0.26, height: h * 0.08)
            context.fill(Path(roundedRect: sign, cornerRadius: 6), with: .color(Color(red: 0.95, green: 0.93, blue: 0.86)))
            context.draw(Text("Attic · Gloss lab").font(.system(size: max(12, h * 0.025), weight: .bold))
                            .foregroundStyle(Color(red: 0.15, green: 0.12, blue: 0.10)),
                         at: CGPoint(x: sign.midX, y: sign.midY))
        }
    }
}
#endif
