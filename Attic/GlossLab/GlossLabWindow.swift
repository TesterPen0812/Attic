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
        GlossSamplesWindows.shared.configure()
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

                section("Material samples")
                row("Sample cards", $lab.samplesShown,
                    note: "Six cards of Apple's glass in a window of their own, over whatever is behind it. Drag them next to the real Control Centre. A Regular glass, as in Dark. B the same with a black veil. C the same with the veil as the glass's own tint. D Clear glass. E Clear with the veil (the lab's tiles now). F Regular glass as in Light, with the veil. White text on all. The light row, G to L, is the same six drawn as in Light, with dark text and a white veil (L is glass as in Dark under it).") {
                    slider("Veil", $lab.samplesSmoke, 0...60, unit: " %")
                    Toggle("Light row (G to L: the same six as in Light, dark text)", isOn: $lab.samplesLight)
                    Toggle("System variants (0 to 23) in place of A to L", isOn: $lab.samplesSystem)
                    if lab.samplesSystem {
                        Text("The glass the system keeps to itself: AppKit's glass view with its hidden variant number set, one number per card. Unsupported, for looking only. Lensing and Scrim are two more hidden settings, put on every card; 0 is what the system starts with.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Stack test (in place of every card set)", isOn: $lab.samplesStack)
                    if lab.samplesSystem || lab.samplesStack {
                        Stepper(value: $lab.samplesLensing, in: 0...3, step: 1) {
                            Text("Lensing \(Int(lab.samplesLensing.rounded()))")
                        }
                        Stepper(value: $lab.samplesScrim, in: 0...3, step: 1) {
                            Text("Scrim \(Int(lab.samplesScrim.rounded()))")
                        }
                    }
                    if lab.samplesStack { stackControls }
                }

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

    // MARK: Stack test

    /// The stack test's controls, one per part of the stack.
    @ViewBuilder private var stackControls: some View {
        Text("Control Centre's three pieces, each AppKit's glass view with one hidden variant number. Each part of the stack is its own control: the ground under the pieces, the veil (smoke) on them, more hidden settings, and the key window. Unsupported settings, for looking only.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Stepper(value: $lab.samplesStackVariant, in: 0...23, step: 1) {
            Text("Variant \(Int(lab.samplesStackVariant.rounded()))")
        }
        Picker("Ground", selection: $lab.samplesGround) {
            ForEach(GlossLab.StackGround.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("Ground material", selection: $lab.samplesGroundMaterial) {
            ForEach(GlossLab.StackGroundMaterial.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        slider("Ground dim", $lab.samplesGroundDim, 0...30, unit: " %")
        Toggle("Smoke as the glass's tint (the Veil above)", isOn: $lab.samplesStackTint)
        Stepper(value: $lab.samplesSubdued, in: 0...3, step: 1) {
            Text("Subdued \(Int(lab.samplesSubdued.rounded()))")
        }
        Stepper(value: $lab.samplesAdaptive, in: 0...3, step: 1) {
            Text("Adaptive \(Int(lab.samplesAdaptive.rounded()))")
        }
        Toggle("Reduced tint opacity", isOn: $lab.samplesTintReduced)
        TextField("Subvariant (empty: not set)", text: $lab.samplesSubvariant)
            .textFieldStyle(.roundedBorder)
        Toggle("Key window (the cards window may take the keyboard)", isOn: $lab.samplesStackKey)
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
// MARK: Material samples

/// One sample card's material (23 Nov, owner: "do the sample cards side by
/// side"). Each differs from its neighbour in one thing: the glass variant,
/// or what of ours lies over it.
enum GlossSample: String, CaseIterable, Identifiable {
    /// Apple's Regular glass (it blurs what is behind), nothing over it.
    case regular
    /// Regular glass with a black veil over it.
    case regularSmoke
    /// Regular glass with the veil given to the glass as its own tint.
    case regularTint
    /// Apple's Clear glass, nothing over it.
    case clear
    /// Clear glass with the black veil: what the lab's tiles use.
    case clearSmoke
    /// Regular glass drawn as in Light (pale), with the black veil over it
    /// and white text: over a white window at a 25 % veil it comes near
    /// the grey of the real Control Centre's pieces in Light (184 to 187
    /// in the owner's screenshot; the lead's arithmetic, to be seen).
    case lightSmoke

    var id: String { rawValue }

    var letter: String {
        switch self {
        case .regular: "A"
        case .regularSmoke: "B"
        case .regularTint: "C"
        case .clear: "D"
        case .clearSmoke: "E"
        case .lightSmoke: "F"
        }
    }

    var title: String {
        switch self {
        case .regular: "Regular"
        case .regularSmoke: "Regular + veil"
        case .regularTint: "Regular, tinted"
        case .clear: "Clear"
        case .clearSmoke: "Clear + veil"
        case .lightSmoke: "Light + veil"
        }
    }

    /// The card's letter in the light row.
    var lightLetter: String {
        switch self {
        case .regular: "G"
        case .regularSmoke: "H"
        case .regularTint: "I"
        case .clear: "J"
        case .clearSmoke: "K"
        case .lightSmoke: "L"
        }
    }

    /// The card's name in the light row: the same material drawn as in
    /// Light, and for the last one the other way round (glass as in Dark
    /// under the white veil).
    var lightTitle: String {
        self == .lightSmoke ? "Dark + veil" : title
    }

    /// Whether the Veil slider changes this card.
    var usesSmoke: Bool {
        switch self {
        case .regular, .clear: false
        case .regularSmoke, .regularTint, .clearSmoke, .lightSmoke: true
        }
    }
}

/// The sample cards' sizes, pt, and where their window goes.
enum GlossSamples {
    static let card: CGFloat = 150
    static let corner: CGFloat = 28
    static let gap: CGFloat = 14
    static let margin: CGFloat = 20
    static let closeButton: CGFloat = 28

    /// The window's size: the cards in one row, the close button after
    /// them, a margin all round.
    static var windowSize: CGSize {
        let count = CGFloat(GlossSample.allCases.count)
        return CGSize(width: margin * 2 + card * count + gap * count + closeButton,
                      height: margin * 2 + card)
    }

    /// The window's size with or without the light row under the first.
    static func windowSize(lightRow: Bool) -> CGSize {
        let one = windowSize
        return lightRow ? CGSize(width: one.width, height: one.height + gap + card) : one
    }

    /// How many of the system's variants go in one row: as many as the
    /// first row has cards, so the window keeps its width.
    static var systemColumns: Int { GlossSample.allCases.count }

    /// The window's size for what it shows: the system's variants in rows
    /// of `systemColumns` when they are on (the light row does not apply
    /// then), else A to F with or without the light row.
    static func windowSize(lightRow: Bool, systemVariants: Bool) -> CGSize {
        guard systemVariants else { return windowSize(lightRow: lightRow) }
        let rows = CGFloat((GlossSystemGlass.variants.count + systemColumns - 1) / systemColumns)
        return CGSize(width: windowSize.width, height: margin * 2 + card * rows + gap * (rows - 1))
    }

    // The stack test (24 Nov): Control Centre's three pieces, a column of
    // two capsules and a round square, with clear room round them where the
    // ground lies.
    static let stackCapsule = CGSize(width: 138, height: 62)
    static let stackSquare: CGFloat = 138
    static let stackSquareCorner: CGFloat = 30
    static let stackGap: CGFloat = 14
    static let stackRoom: CGFloat = 60
    /// How far the ground reaches beyond the pieces, and the width of its
    /// fade (Blur); a glass ground, which cannot be faded, is a round
    /// rectangle of `stackGroundCorner`.
    static let stackGroundReach: CGFloat = 40
    static let stackGroundFade: CGFloat = 30
    static let stackGroundCorner: CGFloat = 44

    /// The three pieces together: 290 x 138.
    static var stackGroup: CGSize {
        CGSize(width: stackCapsule.width + stackGap + stackSquare,
               height: max(stackCapsule.height * 2 + stackGap, stackSquare))
    }

    /// The window in stack test: the pieces with the clear room round
    /// them, 410 x 258.
    static var stackWindowSize: CGSize {
        CGSize(width: stackGroup.width + stackRoom * 2, height: stackGroup.height + stackRoom * 2)
    }

    /// The ground in the window, from its top left corner: 40 pt beyond
    /// the pieces on every side.
    static var stackGroundRect: CGRect {
        CGRect(x: stackRoom - stackGroundReach, y: stackRoom - stackGroundReach,
               width: stackGroup.width + stackGroundReach * 2, height: stackGroup.height + stackGroundReach * 2)
    }

    /// The window's size for what it shows; the stack test, when on,
    /// replaces every card set.
    static func windowSize(lightRow: Bool, systemVariants: Bool, stack: Bool) -> CGSize {
        stack ? stackWindowSize : windowSize(lightRow: lightRow, systemVariants: systemVariants)
    }

    /// The ground window's frame on screen for the cards window's `frame`.
    static func stackGroundFrame(under frame: CGRect) -> CGRect {
        let ground = stackGroundRect
        return CGRect(x: frame.minX + ground.minX, y: frame.maxY - ground.maxY, width: ground.width, height: ground.height)
    }

    /// The ground's soft edge for Blur: opaque inside, fading to nothing
    /// over `fade` towards the rim, its corners concentric round ones.
    static func fadeMask(size: CGSize, fade: CGFloat = stackGroundFade, corner: CGFloat = stackGroundCorner) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSGraphicsContext.current?.compositingOperation = .copy
            let steps = max(Int(fade * 2), 1)
            for step in 0...steps {
                let inset = fade * CGFloat(step) / CGFloat(steps)
                let t = inset / fade
                NSColor(white: 0, alpha: t * t * (3 - 2 * t)).setFill()
                let radius = max(corner - inset, 0)
                NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
    }

    /// `frame` moved up or down by the least that brings it wholly inside
    /// `visible`, when it is no taller than `visible`; left alone if it is.
    /// For the moment the window grows or shrinks: a set that is taller
    /// than the last must not hang off the bottom of the screen.
    static func raised(_ frame: CGRect, into visible: CGRect) -> CGRect {
        guard frame.height <= visible.height else { return frame }
        var moved = frame
        if moved.minY < visible.minY { moved.origin.y = visible.minY }
        if moved.maxY > visible.maxY { moved.origin.y = visible.maxY - moved.height }
        return moved
    }

    /// The saved place as an origin for a window of `size`. What is kept
    /// is the window's top left corner, so the light row coming or going
    /// leaves the top edge where it was. An origin saved before there was
    /// a light row is the one-row window's.
    static func origin(savedTopLeft: CGPoint?, savedOneRowOrigin: CGPoint?, size: CGSize) -> CGPoint? {
        let topLeft = savedTopLeft ?? savedOneRowOrigin.map { CGPoint(x: $0.x, y: $0.y + windowSize.height) }
        return topLeft.map { CGPoint(x: $0.x, y: $0.y - size.height) }
    }

    /// Where the window goes: its saved origin while at least half of it
    /// is on `visible` (a screen's visible frame), else the top centre.
    /// Its size is always `size`.
    static func frame(savedOrigin: CGPoint?, size: CGSize, visible: CGRect) -> CGRect {
        if let savedOrigin {
            let saved = CGRect(origin: savedOrigin, size: size)
            let shown = saved.intersection(visible)
            if !shown.isNull, shown.width * shown.height >= size.width * size.height / 2 { return saved }
        }
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.maxY - 60 - size.height).rounded(),
                      width: size.width, height: size.height)
    }
}

/// What every card carries, whatever its material: its letter or number,
/// its name, and a task's two lines and three symbols.
struct GlossSampleCardFace: View {
    let letter: String
    let title: String
    var light = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(letter).font(.system(size: 22, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold)).opacity(0.8)
            }
            Spacer(minLength: 6)
            Text("Book dentist").font(.system(size: 15, weight: .semibold))
            Text("Tomorrow · #health").font(.system(size: 12)).opacity(0.6)
            HStack(spacing: 18) {
                Image(systemName: "backward.fill")
                Image(systemName: "play.fill")
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 17))
            .padding(.top, 10)
        }
        .lineLimit(1)
        .foregroundStyle(light ? Color.black : Color.white)
        .padding(14)
        .frame(width: GlossSamples.card, height: GlossSamples.card, alignment: .topLeading)
    }
}

/// The system's hidden glass settings (24 Nov). Apple's kit gives apps two
/// glasses, Regular and Clear. AppKit's `NSGlassEffectView` also answers
/// to settings its header does not list (seen on macOS 27.0, 26A5425a:
/// `set_variant:`, `set_contentLensing:`, `set_scrimState:`). These are
/// unsupported and can change with any macOS update: they are here so the
/// owner can see, beside the real Control Centre, whether one of them is
/// its glass. Nothing outside the sample cards uses them.
enum GlossSystemGlass {
    /// The variant numbers shown, one card each. Which is which is not
    /// documented anywhere; the cards carry the number only.
    static let variants = Array(0...23)

    static let variantKey = "_variant"
    static let lensingKey = "_contentLensing"
    static let scrimKey = "_scrimState"

    /// Whether the glass view on this system has the hidden setting `key`
    /// (asked of the view, so a system without it is left alone).
    static func answers(_ view: NSView, _ key: String) -> Bool {
        view.responds(to: NSSelectorFromString("set" + key + ":")) && view.responds(to: NSSelectorFromString(key))
    }

    /// The setting's value now, nil where the system has no such setting.
    static func value(_ key: String, of view: NSView) -> Int? {
        guard answers(view, key) else { return nil }
        return (view.value(forKey: key) as? NSNumber)?.intValue
    }

    /// Puts the three settings on `view`, each only where the system has
    /// it and only when it differs.
    static func apply(variant: Int, lensing: Int, scrim: Int, to view: NSView) {
        for (key, wanted) in [(variantKey, variant), (lensingKey, lensing), (scrimKey, scrim)] {
            guard let now = value(key, of: view), now != wanted else { continue }
            view.setValue(NSNumber(value: wanted), forKey: key)
        }
    }

    // The stack test's further hidden settings (24 Nov). On 26.4.1 the
    // glass view answers to `_subduedState`, `_adaptiveAppearance` (2 to
    // start with) and `_subvariant` (a string, nil to start with), but not
    // to `_tintOpacityReduced`, which was seen on 27.0; a system without
    // one leaves the pieces as they are.
    static let subduedKey = "_subduedState"
    static let adaptiveKey = "_adaptiveAppearance"
    static let tintReducedKey = "_tintOpacityReduced"
    static let subvariantKey = "_subvariant"

    /// Everything the stack test puts on a piece's glass.
    struct PieceSettings: Equatable {
        var variant = 11
        var lensing = 0
        var scrim = 0
        var subdued = 0
        var adaptive = 2
        var tintReduced = false
        /// Empty: not set.
        var subvariant = ""
    }

    /// A switch setting's value now, nil where the system has no such setting.
    static func flag(_ key: String, of view: NSView) -> Bool? {
        guard answers(view, key) else { return nil }
        return (view.value(forKey: key) as? NSNumber)?.boolValue
    }

    /// The subvariant now; nil where it is not set or the system has none.
    static func subvariant(of view: NSView) -> String? {
        guard answers(view, subvariantKey) else { return nil }
        return view.value(forKey: subvariantKey) as? String
    }

    /// Puts every piece setting on `view`, each only where the system has
    /// it and only when it differs.
    static func apply(_ settings: PieceSettings, to view: NSView) {
        apply(variant: settings.variant, lensing: settings.lensing, scrim: settings.scrim, to: view)
        for (key, wanted) in [(subduedKey, settings.subdued), (adaptiveKey, settings.adaptive)] {
            guard let now = value(key, of: view), now != wanted else { continue }
            view.setValue(NSNumber(value: wanted), forKey: key)
        }
        if let now = flag(tintReducedKey, of: view), now != settings.tintReduced {
            view.setValue(NSNumber(value: settings.tintReduced), forKey: tintReducedKey)
        }
        if answers(view, subvariantKey) {
            let wanted: String? = settings.subvariant.isEmpty ? nil : settings.subvariant
            if subvariant(of: view) != wanted { view.setValue(wanted, forKey: subvariantKey) }
        }
    }
}

/// AppKit's glass view with one hidden variant set on it, as a card's
/// material.
struct GlossSystemGlassView: NSViewRepresentable {
    let variant: Int
    let lensing: Int
    let scrim: Int

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = GlossSamples.corner
        view.contentView = NSView()
        GlossSystemGlass.apply(variant: variant, lensing: lensing, scrim: scrim, to: view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        GlossSystemGlass.apply(variant: variant, lensing: lensing, scrim: scrim, to: view)
    }
}

/// One of the system's variants as a card: its number, white text.
struct GlossSystemCard: View {
    let variant: Int
    let lensing: Int
    let scrim: Int

    var body: some View {
        GlossSampleCardFace(letter: "\(variant)", title: "variant")
            .background { GlossSystemGlassView(variant: variant, lensing: lensing, scrim: scrim) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("System variant \(variant)")
    }
}

/// A stack test piece's glass: AppKit's glass view with the hidden
/// settings on it, as `GlossSystemGlassView` does it, and the smoke as its
/// public tint when that switch is on.
struct GlossStackGlassView: NSViewRepresentable {
    let settings: GlossSystemGlass.PieceSettings
    let corner: CGFloat
    let tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.contentView = NSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        if view.cornerRadius != corner { view.cornerRadius = corner }
        if view.tintColor != tint { view.tintColor = tint }
        GlossSystemGlass.apply(settings, to: view)
    }
}

/// One stack test piece: its content over the glass, and the smoke between
/// them as a black veil, or on the glass as its tint.
struct GlossStackPiece<Content: View>: View {
    let size: CGSize
    let corner: CGFloat
    let settings: GlossSystemGlass.PieceSettings
    /// 0 to 1.
    let smoke: Double
    let smokeAsTint: Bool
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background {
                ZStack {
                    GlossStackGlassView(settings: settings, corner: corner,
                                        tint: smokeAsTint ? NSColor.black.withAlphaComponent(smoke) : nil)
                    if !smokeAsTint { shape.fill(Color.black.opacity(smoke)) }
                }
            }
    }
}

/// The stack test's blurred ground: a public behind-window blur faded
/// towards its rim, or Apple's Regular or Clear glass as a round
/// rectangle (a glass view cannot be faded), with black over it at the dim.
/// The same view lies under the pieces in the cards window or fills the
/// window below it. It takes no clicks.
final class GlossStackGroundView: NSView {
    /// The public material Blur uses: the least tinted over white and over
    /// black on the Air (24 Nov; levels in the round's report).
    static let blurMaterial: NSVisualEffectView.Material = .hudWindow

    private let blur = NSVisualEffectView()
    private let dimView = NSView()
    private var glass: NSGlassEffectView?
    private(set) var material: GlossLab.StackGroundMaterial = .blur
    /// -1 until the first `configure`, so the first dim is always drawn.
    private(set) var dim: Double = -1
    private var maskSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        blur.material = Self.blurMaterial
        blur.blendingMode = .behindWindow
        blur.state = .active
        dimView.layer = CALayer()
        dimView.wantsLayer = true
        addSubview(blur)
        addSubview(dimView)
        needsLayout = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(material: GlossLab.StackGroundMaterial, dim: Double) {
        if material != self.material {
            self.material = material
            maskSize = .zero
            needsLayout = true
        }
        if dim != self.dim {
            self.dim = dim
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(dim).cgColor
        }
    }

    override func layout() {
        super.layout()
        let glassStyle: NSGlassEffectView.Style? = switch material {
        case .blur: nil
        case .regular: .regular
        case .clear: .clear
        }
        if let glassStyle {
            let view = glass ?? {
                let made = NSGlassEffectView()
                made.contentView = NSView()
                made.cornerRadius = GlossSamples.stackGroundCorner
                addSubview(made, positioned: .below, relativeTo: dimView)
                glass = made
                return made
            }()
            if view.style != glassStyle { view.style = glassStyle }
            view.frame = bounds
            view.isHidden = false
            blur.isHidden = true
        } else {
            glass?.isHidden = true
            blur.isHidden = false
            blur.frame = bounds
        }
        dimView.frame = bounds
        guard maskSize != bounds.size, bounds.width > 0, bounds.height > 0 else { return }
        maskSize = bounds.size
        if glassStyle == nil {
            let mask = GlossSamples.fadeMask(size: bounds.size)
            blur.maskImage = mask
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: bounds.size)
            layer.contents = mask.cgImage(forProposedRect: nil, context: nil, hints: nil)
            dimView.layer?.mask = layer
            dimView.layer?.cornerRadius = 0
        } else {
            dimView.layer?.mask = nil
            dimView.layer?.cornerRadius = GlossSamples.stackGroundCorner
            dimView.layer?.cornerCurve = .continuous
        }
    }
}

/// The ground as a view under the pieces in the cards window.
struct GlossStackGround: NSViewRepresentable {
    let material: GlossLab.StackGroundMaterial
    let dim: Double

    func makeNSView(context: Context) -> GlossStackGroundView {
        let view = GlossStackGroundView(frame: .zero)
        view.configure(material: material, dim: dim)
        return view
    }

    func updateNSView(_ view: GlossStackGroundView, context: Context) {
        view.configure(material: material, dim: dim)
    }
}

/// The stack test: Control Centre's three pieces as it arranges them, a
/// column of two capsules and a round square, over the ground when it is
/// in this window, with the close button in the top right corner.
struct GlossStackTest: View {
    @Bindable var lab: GlossLab
    let closeButton: AnyView

    private var settings: GlossSystemGlass.PieceSettings {
        GlossSystemGlass.PieceSettings(
            variant: Int(lab.samplesStackVariant.rounded()), lensing: Int(lab.samplesLensing.rounded()),
            scrim: Int(lab.samplesScrim.rounded()), subdued: Int(lab.samplesSubdued.rounded()),
            adaptive: Int(lab.samplesAdaptive.rounded()), tintReduced: lab.samplesTintReduced,
            subvariant: lab.samplesSubvariant)
    }

    var body: some View {
        let size = GlossSamples.stackWindowSize
        let ground = GlossSamples.stackGroundRect
        let room = GlossSamples.stackRoom
        ZStack(alignment: .topLeading) {
            if lab.samplesGround == .same {
                GlossStackGround(material: lab.samplesGroundMaterial, dim: lab.samplesGroundDim / 100)
                    .frame(width: ground.width, height: ground.height)
                    .padding(.leading, ground.minX)
                    .padding(.top, ground.minY)
            }
            HStack(alignment: .top, spacing: GlossSamples.stackGap) {
                VStack(spacing: GlossSamples.stackGap) {
                    capsule(symbol: "wifi", title: "Wi-Fi", subtitle: "Home")
                    capsule(symbol: "moon.fill", title: "Focus", subtitle: "Do Not Disturb")
                }
                square
            }
            .padding(.leading, room)
            .padding(.top, room)
            closeButton
                .padding(.leading, size.width - 10 - GlossSamples.closeButton)
                .padding(.top, 10)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stack test")
    }

    private func piece<Content: View>(_ size: CGSize, corner: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        GlossStackPiece(size: size, corner: corner, settings: settings, smoke: lab.samplesSmoke / 100,
                        smokeAsTint: lab.samplesStackTint, content: content)
    }

    private func capsule(symbol: String, title: String, subtitle: String) -> some View {
        let size = GlossSamples.stackCapsule
        return piece(size, corner: size.height / 2) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(Color.white)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).opacity(0.6)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
        }
    }

    private var square: some View {
        let side = GlossSamples.stackSquare
        return piece(CGSize(width: side, height: side), corner: GlossSamples.stackSquareCorner) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Not Playing").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "play.fill")
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 17))
                .opacity(0.5)
                .frame(maxWidth: .infinity)
            }
            .lineLimit(1)
            .padding(14)
            .frame(width: side, height: side, alignment: .topLeading)
        }
    }
}

/// One card: white text, as on a Control Centre card, over its material;
/// in the light row, dark text over the material drawn as in Light.
struct GlossSampleCard: View {
    let sample: GlossSample
    /// The veil, 0 to 1: black, and white in the light row.
    let smoke: Double
    /// Whether this is the light row's card.
    var light = false

    private var letter: String { light ? sample.lightLetter : sample.letter }
    private var title: String { light ? sample.lightTitle : sample.title }

    var body: some View {
        GlossSampleCardFace(letter: letter, title: title, light: light)
            .background { material }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample \(letter), \(title)")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlossSamples.corner, style: .continuous)
    }

    /// The mode the card's glass is drawn in: the row's (Dark for the
    /// first row, Light for the light row), and the other one for the
    /// row's last card.
    private var glassScheme: ColorScheme {
        (sample == .lightSmoke) != light ? .light : .dark
    }

    private func glass(_ glass: Glass) -> some View {
        shape.fill(Color.clear).glassEffect(glass, in: shape)
            .environment(\.colorScheme, glassScheme)
    }

    @ViewBuilder private var material: some View {
        let veil = (light ? Color.white : Color.black).opacity(smoke)
        switch sample {
        case .regular:
            glass(.regular)
        case .regularSmoke, .lightSmoke:
            glass(.regular).overlay { shape.fill(veil) }
        case .regularTint:
            glass(.regular.tint(veil))
        case .clear:
            glass(.clear)
        case .clearSmoke:
            glass(.clear).overlay { shape.fill(veil) }
        }
    }
}

/// The sample cards in one row, drawn as in Dark (F's glass alone as in
/// Light), with a close button after them, and under it the light row
/// while its switch is on. The window is dragged by any card.
struct GlossSamplesView: View {
    @Bindable var lab: GlossLab

    var body: some View {
        let size = GlossSamples.windowSize(lightRow: lab.samplesLight, systemVariants: lab.samplesSystem, stack: lab.samplesStack)
        Group {
            if lab.samplesStack {
                GlossStackTest(lab: lab, closeButton: AnyView(closeButton))
            } else {
                cardSets
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .gesture(WindowDragGesture())
    }

    /// Every card set, as before the stack test.
    private var cardSets: some View {
        VStack(alignment: .leading, spacing: GlossSamples.gap) {
            if lab.samplesSystem {
                systemRows
            } else {
                firstRow
                if lab.samplesLight {
                    HStack(alignment: .top, spacing: GlossSamples.gap) {
                        ForEach(GlossSample.allCases) { sample in
                            GlossSampleCard(sample: sample, smoke: lab.samplesSmoke / 100, light: true)
                        }
                    }
                }
            }
        }
        .padding(GlossSamples.margin)
    }

    /// The system's variants in rows, the close button after the first.
    @ViewBuilder private var systemRows: some View {
        let columns = GlossSamples.systemColumns
        let all = GlossSystemGlass.variants
        let lensing = Int(lab.samplesLensing.rounded())
        let scrim = Int(lab.samplesScrim.rounded())
        ForEach(Array(stride(from: 0, to: all.count, by: columns)), id: \.self) { start in
            HStack(alignment: .top, spacing: GlossSamples.gap) {
                ForEach(all[start..<min(start + columns, all.count)], id: \.self) { variant in
                    GlossSystemCard(variant: variant, lensing: lensing, scrim: scrim)
                }
                if start == 0 { closeButton }
            }
        }
    }

    private var firstRow: some View {
        HStack(alignment: .top, spacing: GlossSamples.gap) {
            ForEach(GlossSample.allCases) { sample in
                GlossSampleCard(sample: sample, smoke: lab.samplesSmoke / 100)
            }
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            lab.samplesShown = false
        } label: {
            let circle = Circle()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: GlossSamples.closeButton, height: GlossSamples.closeButton)
                .background { circle.fill(Color.clear).glassEffect(.regular, in: circle) }
                .contentShape(circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close the sample cards")
    }
}

/// The sample cards' window: borderless and clear, so the cards' glass
/// has only what is behind the window under it, floating over other apps'
/// windows and staying up while another app is in front. It is this app's
/// own window, like the lab's two; it changes nothing about the panel.
@MainActor
final class GlossSamplesWindows {
    static let shared = GlossSamplesWindows()

    static let title = "Gloss samples"
    static let backdropTitle = "Gloss samples backdrop"
    static let groundTitle = "Gloss samples ground"

    /// The cards window, which never takes the keyboard unless the stack
    /// test's Key window switch lets it (to test whether glass in a window
    /// that is not key is drawn flatter).
    final class Panel: NSPanel {
        var keyAllowed = false {
            didSet { becomesKeyOnlyIfNeeded = !keyAllowed }
        }

        override var canBecomeKey: Bool { keyAllowed || super.canBecomeKey }
    }

    /// Whether the cards window may become key: only in the stack test,
    /// with its Key window switch on.
    static func keyAllowed(for lab: GlossLab) -> Bool { lab.samplesStack && lab.samplesStackKey }

    /// Whether the ground has a window of its own under the cards window.
    static func groundWindowWanted(for lab: GlossLab) -> Bool { lab.samplesStack && lab.samplesGround == .below }
    /// The one-row window's origin, as saved before there was a light row.
    private static let originKey = GlossLab.prefix + "samplesOrigin"
    private static let topLeftKey = GlossLab.prefix + "samplesTopLeft"

    private var window: Panel?
    private var backdropWindow: NSWindow?
    private var groundWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var checkReported = false

    /// Shows or hides the window with the lab's switch, and sizes it for
    /// the light row, from now on.
    func configure() {
        withObservationTracking {
            _ = GlossLab.shared.samplesShown
            _ = GlossLab.shared.samplesLight
            _ = GlossLab.shared.samplesSystem
            _ = GlossLab.shared.samplesStack
            _ = GlossLab.shared.samplesStackKey
            _ = GlossLab.shared.samplesGround
            _ = GlossLab.shared.samplesGroundMaterial
            _ = GlossLab.shared.samplesGroundDim
        } onChange: { [weak self] in
            Task { @MainActor in self?.configure() }
        }
        apply()
    }

    /// The window, made and not yet shown.
    static func makeWindow() -> Panel {
        let panel = Panel(contentRect: CGRect(origin: .zero, size: GlossSamples.windowSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        // The window is sized here, for one row or two; the cards' view
        // never resizes it.
        let host = NSHostingView(rootView: GlossSamplesView(lab: .shared))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func apply() {
        let lab = GlossLab.shared
        guard lab.samplesShown else {
            window?.orderOut(nil)
            groundWindow?.orderOut(nil)
            backdropWindow?.orderOut(nil)
            return
        }
        if window == nil {
            let panel = Self.makeWindow()
            // Where it was last left, kept as a plain origin in this
            // preview's defaults (a borderless window has no frame autosave
            // of its own worth trusting across screens).
            moveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveOrigin() }
            }
            window = panel
        }
        guard let window else { return }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = GlossSamples.windowSize(lightRow: lab.samplesLight, systemVariants: lab.samplesSystem, stack: lab.samplesStack)
        let wasVisible = window.isVisible
        // The Key window switch: going off, a key window gives the keyboard
        // up by leaving the screen for a moment (it is shown again below).
        let keyAllowed = Self.keyAllowed(for: lab)
        let keyTurnedOn = keyAllowed && !window.keyAllowed
        if window.keyAllowed != keyAllowed {
            window.keyAllowed = keyAllowed
            if !keyAllowed, window.isKeyWindow { window.orderOut(nil) }
        }
        if !wasVisible {
            let saved = GlossSamples.origin(
                savedTopLeft: UserDefaults.standard.string(forKey: Self.topLeftKey).map(NSPointFromString),
                savedOneRowOrigin: UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString),
                size: size)
            window.setFrame(GlossSamples.frame(savedOrigin: saved, size: size, visible: visible), display: true)
        } else if window.frame.size != size {
            // Rows came or went: the top edge stays where it is, unless
            // the taller window would then hang off the screen.
            let frame = window.frame
            let grown = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(GlossSamples.raised(grown, into: window.screen?.visibleFrame ?? visible), display: true)
        }
        applyTestBackdrop(under: window)
        window.orderFrontRegardless()
        applyGroundWindow(under: window, lab: lab)
        if keyAllowed, keyTurnedOn || !wasVisible, !window.isKeyWindow { window.makeKey() }
        reportForCheck(window)
    }

    /// The stack test's "Window below" ground: a clear borderless window of
    /// its own, a child of the cards window kept right under it, so it moves
    /// with it. Taken away when the ground is anything else.
    private func applyGroundWindow(under window: Panel, lab: GlossLab) {
        guard Self.groundWindowWanted(for: lab) else {
            if let groundWindow {
                groundWindow.parent?.removeChildWindow(groundWindow)
                groundWindow.orderOut(nil)
            }
            return
        }
        let ground = groundWindow ?? Self.makeGroundWindow()
        groundWindow = ground
        (ground.contentView as? GlossStackGroundView)?.configure(material: lab.samplesGroundMaterial, dim: lab.samplesGroundDim / 100)
        if ground.parent !== window {
            ground.setFrame(GlossSamples.stackGroundFrame(under: window.frame), display: false)
            window.addChildWindow(ground, ordered: .below)
        }
        ground.setFrame(GlossSamples.stackGroundFrame(under: window.frame), display: true)
    }

    /// The ground's own window: clear, borderless, without a shadow, and
    /// taking no clicks; it is never key.
    static func makeGroundWindow() -> NSWindow {
        let ground = NSWindow(contentRect: CGRect(origin: .zero, size: GlossSamples.stackGroundRect.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        ground.title = groundTitle
        ground.isReleasedWhenClosed = false
        ground.isOpaque = false
        ground.backgroundColor = .clear
        ground.hasShadow = false
        ground.ignoresMouseEvents = true
        ground.level = .floating
        ground.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ground.appearance = NSAppearance(named: .darkAqua)
        ground.contentView = GlossStackGroundView(frame: CGRect(origin: .zero, size: GlossSamples.stackGroundRect.size))
        return ground
    }

    /// A check's seam, never in the lab window, only with a test backdrop
    /// (`-GlossLab.samplesBackdrop`): once, 2 s after the window is shown,
    /// writes the window order, the frames and the key state to standard
    /// output; with `-GlossLab.samplesMoveBy "{dx, dy}"` it then moves the
    /// cards window by that much, as a drag would, and writes them again.
    private func reportForCheck(_ window: Panel) {
        guard !checkReported, UserDefaults.standard.string(forKey: GlossLab.prefix + "samplesBackdrop") != nil else { return }
        checkReported = true
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .seconds(2))
            guard let window else { return }
            self?.writeCheckLine("shown", window)
            guard let move = UserDefaults.standard.string(forKey: GlossLab.prefix + "samplesMoveBy") else { return }
            let by = NSPointFromString(move)
            window.setFrameOrigin(CGPoint(x: window.frame.minX + by.x, y: window.frame.minY + by.y))
            try? await Task.sleep(for: .seconds(1))
            self?.writeCheckLine("moved", window)
        }
    }

    private func writeCheckLine(_ when: String, _ window: Panel) {
        let order = NSWindow.windowNumbers(options: [])?.compactMap { NSApp.window(withWindowNumber: $0.intValue)?.title } ?? []
        let ground = groundWindow.flatMap { $0.isVisible ? NSStringFromRect($0.frame) : nil } ?? "none"
        let expected = NSStringFromRect(GlossSamples.stackGroundFrame(under: window.frame))
        print("GLOSS_STACK \(when) key=\(window.isKeyWindow) canBecomeKey=\(window.canBecomeKey) appActive=\(NSApp.isActive) "
              + "cards=\(NSStringFromRect(window.frame)) ground=\(ground) groundExpected=\(expected) "
              + "groundIsChild=\(groundWindow?.parent === window) frontToBack=\(order)")
        fflush(stdout)
    }

    private func saveOrigin() {
        guard let window, window.isVisible else { return }
        let frame = window.frame
        UserDefaults.standard.set(NSStringFromPoint(CGPoint(x: frame.minX, y: frame.maxY)), forKey: Self.topLeftKey)
    }

    /// A check's seam, never in the lab window: `-GlossLab.samplesBackdrop
    /// <picture|white|black|text>` puts one of our own backdrops in a
    /// window of its own right under the cards, so a still of our own
    /// windows shows the glass over something. It does not follow a drag.
    private func applyTestBackdrop(under window: NSWindow) {
        guard let name = UserDefaults.standard.string(forKey: GlossLab.prefix + "samplesBackdrop") else { return }
        if backdropWindow == nil {
            let backdrop = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            backdrop.title = Self.backdropTitle
            backdrop.level = .floating
            backdrop.isOpaque = true
            backdrop.hasShadow = false
            backdrop.ignoresMouseEvents = true
            backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if name == "text" {
                let lab = GlossLab.shared
                // The stack test's text has no coloured shapes, so a piece's
                // middle has only lines of text behind it to measure.
                backdrop.contentView = NSHostingView(rootView: lab.samplesStack
                    ? GlossSamplesTextBackdrop(lines: 14, shapes: false)
                    : GlossSamplesTextBackdrop(lines: lab.samplesSystem ? 30 : lab.samplesLight ? 17 : 10))
            } else {
                backdrop.contentView = NSHostingView(rootView: GlossBackdropView(backdrop: GlossLab.Backdrop(rawValue: name) ?? .black))
            }
            backdropWindow = backdrop
        }
        backdropWindow?.setFrame(window.frame.insetBy(dx: -30, dy: -30), display: true)
        backdropWindow?.orderFrontRegardless()
    }
}

/// The check's "text" backdrop: black lines of text on white with a few
/// strong colours, like a busy window behind the cards.
struct GlossSamplesTextBackdrop: View {
    var lines = 10
    var shapes = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<lines, id: \.self) { index in
                    Text(index.isMultiple(of: 2)
                         ? "Write path: measure and design the quick brown fox 0123456789 jumps over the lazy dog and keeps on running"
                         : "Thu 26 Nov  Table with while into  #focus #preview  When move link sidebar date with launch settings")
                        .font(.system(size: 15, weight: index.isMultiple(of: 4) ? .semibold : .regular))
                        .foregroundStyle(.black)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 8)
            if shapes {
                Circle().fill(Color(red: 0.55, green: 0.15, blue: 0.85)).frame(width: 90, height: 90).offset(x: 250, y: 70)
                Capsule().fill(Color(red: 0.1, green: 0.45, blue: 0.95)).frame(width: 220, height: 22).offset(x: 480, y: 120)
                Rectangle().fill(Color(red: 0.12, green: 0.12, blue: 0.14)).frame(width: 150, height: 250).offset(x: 790, y: 0)
            }
        }
        .clipped()
    }
}
#endif
