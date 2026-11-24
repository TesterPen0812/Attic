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
        GlossMatchWindows.shared.configure()
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

                section("Match")
                row("Calibration backdrop", $lab.calibration,
                    note: "A test pattern of our own over the whole screen under the menu bar: flat fields, hard edges, checkers and text, the same everywhere, so a screenshot with the real Control Centre open over it can be measured. It covers this window too. To take it down: Escape, or \"Close test pattern\" in its bottom left corner; it also takes itself down 3 minutes after the last click on it, and it never comes back at the next launch.") {
                    Picker("Pattern", selection: $lab.calibrationPattern) {
                        ForEach(GlossLab.CalibrationPattern.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                row("Match sheet", $lab.match,
                    note: "Our pieces in Control Centre's arrangement at its sizes, in a window of their own, with Apple's blur as the ground. Copies apart by \"/\", each with its own settings (radius=1 / radius=2, variant=7), or a walk through one setting (walk variant; walk radius 0.5 1 2 / dim=10). Settings: ground, radius, dim, hold, curve, smoke, tint, variant, lensing, scrim, subdued, adaptive, reduced. What a copy does not name is the stack test's value, below.") {
                    matchControls
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
                row("Blur behind", $lab.panelBlur,
                    note: "A light blur of what is behind the whole panel, under its glass: Apple's blur, the kind Control Centre's ground uses, at one strength everywhere. Blur see-through is how much of the sharp backdrop still shows through the blur. A private layer, unsupported: for looking in the lab. Not drawn on a page where Tiles stand in for the panel.") {
                    if !GlossBackdropGround.isAvailable {
                        Text(GlossBackdropGround.unavailableLine).font(.caption).foregroundStyle(.secondary)
                    }
                    fineSlider("Strength", $lab.panelBlurRadius, 0...20)
                    slider("Blur see-through", $lab.panelBlurSeeThrough, 0...100, unit: " %")
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
        // Four materials do not fit beside their label in the lab window's
        // width (Air still lab-ground-row, 24 Nov), so the label is above.
        VStack(alignment: .leading, spacing: 4) {
            Text("Ground material")
            Picker("Ground material", selection: $lab.samplesGroundMaterial) {
                ForEach(GlossLab.StackGroundMaterial.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if lab.samplesGroundMaterial == .variable {
            if let line = GlossBackdropGround.line(for: lab.samplesGroundMaterial) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            fineSlider("Blur radius", $lab.samplesGroundRadius, 0...40)
            slider("Reach", $lab.samplesGroundReach, 20...160, unit: " pt")
            slider("Fade start", $lab.samplesGroundHold, 0...60, unit: " pt")
            slider("Fade curve", $lab.samplesGroundCurve, 1...4)
            TextField("Extra filter inputs (key=value; …)", text: $lab.samplesGroundExtras)
                .textFieldStyle(.roundedBorder)
            if let line = GlossBackdropGround.extrasLine(lab.samplesGroundExtras) {
                Text(line).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        slider("Ground dim", $lab.samplesGroundDim, 0...30, unit: " %")
        Toggle("Smoke as the glass's tint (the Veil above)", isOn: $lab.samplesStackTint)
        Stepper(value: $lab.samplesSubdued, in: 0...3, step: 1) {
            Text("Subdued \(Int(lab.samplesSubdued.rounded()))")
        }
        Stepper(value: $lab.samplesAdaptive, in: GlossSystemGlass.adaptiveRange, step: 1) {
            Text("Adaptive \(Int(lab.samplesAdaptive.rounded()))")
        }
        Toggle("Reduced tint opacity", isOn: $lab.samplesTintReduced)
        TextField("Subvariant (empty: not set)", text: $lab.samplesSubvariant)
            .textFieldStyle(.roundedBorder)
        Toggle("Key window (the cards window may take the keyboard)", isOn: $lab.samplesStackKey)
    }

    // MARK: Match sheet

    /// The match sheet's controls: what it shows, where it stands, and the
    /// stack test's values its copies start from (the same stored values;
    /// shown here so the stack test need not be up to set them).
    @ViewBuilder private var matchControls: some View {
        TextField("Copies (radius=1 / radius=2) or a walk (walk variant)", text: $lab.matchSpec)
            .textFieldStyle(.roundedBorder)
        if let line = GlossMatch.ignoredLine(GlossMatch.sheet(for: lab)) {
            Text(line).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        TextField("First corner x,y from the screen's top left (empty: by guess)", text: $lab.matchOrigin)
            .textFieldStyle(.roundedBorder)
        if !GlossBackdropGround.isAvailable {
            Text("Apple's blur is not on this system: the ground is the public Blur.")
                .font(.caption).foregroundStyle(.secondary)
        }
        fineSlider("Blur radius", $lab.samplesGroundRadius, 0...40)
        slider("Ground dim", $lab.samplesGroundDim, 0...30, unit: " %")
        slider("Veil", $lab.samplesSmoke, 0...60, unit: " %")
        Toggle("Veil as the glass's tint", isOn: $lab.samplesStackTint)
        Stepper(value: $lab.samplesStackVariant, in: 0...23, step: 1) {
            Text("Variant \(Int(lab.samplesStackVariant.rounded()))")
        }
        more {
            Stepper(value: $lab.samplesLensing, in: 0...3, step: 1) {
                Text("Lensing \(Int(lab.samplesLensing.rounded()))")
            }
            Stepper(value: $lab.samplesScrim, in: 0...3, step: 1) {
                Text("Scrim \(Int(lab.samplesScrim.rounded()))")
            }
            Stepper(value: $lab.samplesSubdued, in: 0...3, step: 1) {
                Text("Subdued \(Int(lab.samplesSubdued.rounded()))")
            }
            Stepper(value: $lab.samplesAdaptive, in: GlossSystemGlass.adaptiveRange, step: 1) {
                Text("Adaptive \(Int(lab.samplesAdaptive.rounded()))")
            }
            Toggle("Reduced tint opacity", isOn: $lab.samplesTintReduced)
            slider("Fade start", $lab.samplesGroundHold, 0...60, unit: " pt")
            slider("Fade curve", $lab.samplesGroundCurve, 1...4)
        }
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

    /// A slider with a number field and a stepper beside it, so a value can
    /// be set to 0.1 (24 Nov: the real Control Centre's ground blur reads as
    /// a small number, and a slider alone cannot land on one). All three
    /// write the value held inside `range` and rounded to one decimal.
    private func fineSlider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        let held = Binding<Double>(
            get: { value.wrappedValue },
            set: { value.wrappedValue = GlossLabView.tenths($0, in: range) })
        return HStack(spacing: 8) {
            Text(label).frame(width: 104, alignment: .leading)
            Slider(value: held, in: range)
            TextField(label, value: held, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Stepper(label, value: held, in: range, step: 0.1)
                .labelsHidden()
        }
        .font(.callout)
    }

    /// `value` held inside `range` and rounded to one decimal.
    nonisolated static func tenths(_ value: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return (min(max(value, range.lowerBound), range.upperBound) * 10).rounded() / 10
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
        stackGroundFrame(under: frame, room: stackRoom, reach: stackGroundReach)
    }

    // Apple's blur (24 Nov): its ground reaches as far as its Reach slider,
    // so in the cards window the room round the pieces grows with it, and
    // the window below is as large as the ground. Every other material keeps
    // the 60 pt room and the 40 pt ground above, exactly.

    /// The material the ground is drawn with: Apple's blur where this system
    /// has its pieces, the public Blur where it does not.
    @MainActor static func drawnGroundMaterial(_ material: GlossLab.StackGroundMaterial) -> GlossLab.StackGroundMaterial {
        material == .variable && !GlossBackdropGround.isAvailable ? .blur : material
    }

    /// How far the ground reaches beyond the pieces.
    @MainActor static func stackGroundReach(for lab: GlossLab) -> CGFloat {
        drawnGroundMaterial(lab.samplesGroundMaterial) == .variable ? CGFloat(lab.samplesGroundReach) : stackGroundReach
    }

    /// The clear room round the pieces in the cards window: 60 pt, or the
    /// ground's reach where that is more and the ground is in this window.
    @MainActor static func stackRoom(for lab: GlossLab) -> CGFloat {
        lab.samplesStack && lab.samplesGround == .same ? max(stackRoom, stackGroundReach(for: lab)) : stackRoom
    }

    static func stackWindowSize(room: CGFloat) -> CGSize {
        CGSize(width: stackGroup.width + room * 2, height: stackGroup.height + room * 2)
    }

    /// The ground in the window, from its top left corner, `reach` beyond
    /// the pieces, which lie `room` in from the window's sides.
    static func stackGroundRect(room: CGFloat, reach: CGFloat) -> CGRect {
        CGRect(x: room - reach, y: room - reach, width: stackGroup.width + reach * 2, height: stackGroup.height + reach * 2)
    }

    static func stackGroundFrame(under frame: CGRect, room: CGFloat, reach: CGFloat) -> CGRect {
        let ground = stackGroundRect(room: room, reach: reach)
        return CGRect(x: frame.minX + ground.minX, y: frame.maxY - ground.maxY, width: ground.width, height: ground.height)
    }

    /// The cards window's size for the lab's values.
    @MainActor static func windowSize(for lab: GlossLab) -> CGSize {
        lab.samplesStack ? stackWindowSize(room: stackRoom(for: lab))
            : windowSize(lightRow: lab.samplesLight, systemVariants: lab.samplesSystem)
    }

    /// The share of the reach over which Apple's blur stays at full
    /// strength before it falls: the real ground's blur fades out between
    /// about 25 and 60 pt from the pieces (`ops/reviews/
    /// gloss-lab-control-centre-analysis-24nov.md` §1), so 25 of 60.
    static let variableHold: CGFloat = 25.0 / 60.0

    /// Apple's blur's strength at `point` in a ground of `size` whose pieces
    /// lie `reach` in from every side: 1 over the pieces and for the first
    /// part of the reach, then a smooth fall to 0 at the rim, by the distance
    /// from the pieces' round rectangle (corner as the square's), so the
    /// corners fall off evenly.
    static func variableStrength(at point: CGPoint, size: CGSize, reach: CGFloat) -> CGFloat {
        variableStrength(at: point, size: size, reach: reach, hold: reach * variableHold, curve: 1)
    }

    /// The fade (24 Nov, "Fix the fade"): the blur is full to `hold` pt from
    /// the pieces (kept `variableHoldGap` under the reach), then falls by
    /// the smoothstep raised to `curve`. A curve over 1 drops the radius
    /// early and spends most of the distance going from a little blur to
    /// none, since a small radius still reads as blurred (Air, step 0 of
    /// the fade round: at curve 1 the text came back only in the last 12 pt).
    /// At curve 1 this is the first round's function, value for value.
    static func variableStrength(at point: CGPoint, size: CGSize, reach: CGFloat, hold: CGFloat, curve: CGFloat) -> CGFloat {
        let halfWidth = max(size.width / 2 - reach, 0), halfHeight = max(size.height / 2 - reach, 0)
        let corner = min(stackSquareCorner, halfWidth, halfHeight)
        let qx = max(abs(point.x - size.width / 2) - (halfWidth - corner), 0)
        let qy = max(abs(point.y - size.height / 2) - (halfHeight - corner), 0)
        let distance = max((qx * qx + qy * qy).squareRoot() - corner, 0)
        let hold = variableFadeStart(hold, reach: reach)
        guard distance > hold, reach > hold else { return 1 }
        let left = 1 - min((distance - hold) / (reach - hold), 1)
        let smooth = left * left * (3 - 2 * left)
        return curve == 1 ? smooth : pow(smooth, max(curve, 1))
    }

    /// How far under the reach the fade start is kept at least.
    static let variableHoldGap: CGFloat = 5

    /// The fade start in use: `hold`, at least 0 and `variableHoldGap`
    /// under the reach.
    static func variableFadeStart(_ hold: CGFloat, reach: CGFloat) -> CGFloat {
        max(min(hold, reach - variableHoldGap), 0)
    }

    /// Apple's blur's mask at `scale` pixels per point: white whose alpha is
    /// the strength (the variable blur reads the mask's alpha; Air prototype,
    /// 24 Nov), premultiplied.
    static func variableMask(size: CGSize, reach: CGFloat, scale: CGFloat) -> CGImage? {
        variableMask(size: size, reach: reach, hold: reach * variableHold, curve: 1, scale: scale)
    }

    static func variableMask(size: CGSize, reach: CGFloat, hold: CGFloat, curve: CGFloat, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                let value = UInt8((variableStrength(at: point, size: size, reach: reach, hold: hold, curve: curve) * 255).rounded())
                let index = (y * width + x) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value; pixels[index + 3] = value
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
    /// The adaptive values the lab puts on a glass view. 3 ends the process
    /// inside the system's glass view on 26.4.1 (seen 24 Nov, off-app), so the
    /// stepper, a copy's text and `apply` all stop at 2.
    static let adaptiveRange: ClosedRange<Double> = 0...2
    static func heldAdaptive(_ value: Int) -> Int {
        min(max(value, Int(adaptiveRange.lowerBound)), Int(adaptiveRange.upperBound))
    }
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
        for (key, wanted) in [(subduedKey, settings.subdued), (adaptiveKey, heldAdaptive(settings.adaptive))] {
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

/// Apple's blur: Control Centre's kind of ground, a private backdrop layer
/// (`CABackdropLayer`) that samples what lies behind the window, carrying
/// a private variable-blur filter (`CAFilter`, type `variableBlur`) whose
/// mask sets the radius point by point. Lifted for the lab's stack test
/// only (owner, 24 Nov: "Lift it, Opus builds"); nothing outside the sample
/// cards' ground uses it. Unsupported: every class, selector, filter type,
/// input key and layer setting is looked up by name and used only if it
/// answers, so a system without one draws the public Blur instead.
/// Step 0 probe (24 Nov): all present on macOS 26.4.1 and 27.0; AppKit's
/// own behind-window blur is a backdrop layer with `windowServerAware` on.
@MainActor
enum GlossBackdropGround {
    static let backdropClassName = "CABackdropLayer"
    static let filterClassName = "CAFilter"
    static let filterType = "variableBlur"
    static let radiusKey = "inputRadius"
    static let maskKey = "inputMaskImage"
    static let normalizeKey = "inputNormalizeEdges"
    /// The layer setting that makes it sample what lies behind the window.
    static let behindWindowKey = "windowServerAware"
    static let unavailableLine = "Apple's blur is not available on this macOS"

    /// A test seam, nil in production: a class name looked up in place of
    /// `CABackdropLayer`, to make it unavailable.
    static var backdropClassNameForTesting: String?

    /// The layer with its filter, or nil where this system lacks a piece.
    struct Parts {
        let layer: CALayer
        /// Made again when the extra inputs change, so a cleared input does
        /// not stay set (fade round, 24 Nov).
        var filter: NSObject
        /// Whether the filter takes `inputNormalizeEdges` (it is set on where so).
        let normalizes: Bool
    }

    static func make() -> Parts? { make(backdropClass: backdropClassNameForTesting ?? backdropClassName) }

    private static func make(backdropClass name: String) -> Parts? {
        guard let layerClass = NSClassFromString(name) as? CALayer.Type, let made = makeFilter() else { return nil }
        let layer = layerClass.init()
        guard answers(layer, behindWindowKey) else { return nil }
        layer.setValue(true, forKey: behindWindowKey)
        return Parts(layer: layer, filter: made.filter, normalizes: made.keys.contains(normalizeKey))
    }

    /// A new variable blur filter with its input keys, `inputNormalizeEdges`
    /// set on where it takes it; nil where this system lacks a piece.
    static func makeFilter() -> (filter: NSObject, keys: [String])? {
        guard let filterClass = NSClassFromString(filterClassName) else { return nil }
        let maker = NSSelectorFromString("filterWithType:")
        let filters = filterClass as AnyObject
        guard filters.responds(to: maker) else { return nil }
        let typesSelector = NSSelectorFromString("filterTypes")
        if filters.responds(to: typesSelector) {
            guard let types = filters.perform(typesSelector)?.takeUnretainedValue() as? [String], types.contains(filterType) else { return nil }
        }
        guard let filter = filters.perform(maker, with: filterType)?.takeUnretainedValue() as? NSObject,
              let keys = inputKeys(of: filter), keys.contains(radiusKey), keys.contains(maskKey) else { return nil }
        if keys.contains(normalizeKey) { filter.setValue(true, forKey: normalizeKey) }
        return (filter, keys)
    }

    /// The filter's own list of input keys, or nil where it gives none.
    static func inputKeys(of filter: NSObject) -> [String]? {
        let keysSelector = NSSelectorFromString("inputKeys")
        guard filter.responds(to: keysSelector) else { return nil }
        return filter.perform(keysSelector)?.takeUnretainedValue() as? [String]
    }

    // MARK: Extra inputs (fade round, 24 Nov)

    /// What an extras text gives: the pairs applied, in order, and what was
    /// ignored (a key, or the whole piece where it has no `=`).
    struct Extras: Equatable {
        struct Pair: Equatable { let key: String; let value: Double }
        var applied: [Pair] = []
        var ignored: [String] = []
        static let none = Extras()
        /// "Applied: inputFade=1.0. Ignored: foo."
        var line: String {
            let applied = applied.isEmpty ? "none" : applied.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            return "Applied: \(applied). Ignored: \(ignored.isEmpty ? "none" : ignored.joined(separator: ", "))."
        }
    }

    /// Inputs the lab's own controls set (the radius slider, the mask), so
    /// an extra pair never takes them over.
    static let ownKeys: Set<String> = [radiusKey, maskKey]

    /// Reads `key=value` pairs, split by `;` or new lines. A pair is kept
    /// only where `keys` (the filter's own `inputKeys`) lists the key, the
    /// lab's controls do not set it, its value is a finite number and the
    /// filter's current value for it is a number or unset. Everything else
    /// is ignored; an empty text gives nothing.
    static func extras(_ text: String, keys: [String], current: (String) -> Any?) -> Extras {
        var result = Extras()
        for piece in text.split(whereSeparator: { $0 == ";" || $0.isNewline }) {
            let pair = piece.trimmingCharacters(in: .whitespaces)
            if pair.isEmpty { continue }
            guard let equals = pair.firstIndex(of: "=") else { result.ignored.append(pair); continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let raw = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, keys.contains(key), !ownKeys.contains(key),
                  let value = Double(raw), value.isFinite else { result.ignored.append(key.isEmpty ? pair : key); continue }
            if let now = current(key), !(now is NSNumber) { result.ignored.append(key); continue }
            result.applied.append(Extras.Pair(key: key, value: value))
        }
        return result
    }

    /// Reads `text` against `filter` and sets the pairs it keeps on it by
    /// key-value coding.
    @discardableResult
    static func applyExtras(_ text: String, to filter: NSObject) -> Extras {
        guard let keys = inputKeys(of: filter) else { return .none }
        let extras = extras(text, keys: keys) { filter.value(forKey: $0) }
        for pair in extras.applied { filter.setValue(NSNumber(value: pair.value), forKey: pair.key) }
        return extras
    }

    /// The quiet line under the extras field: the keys applied and ignored,
    /// against a new filter as the ground makes one; nil for an empty text.
    static func extrasLine(_ text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let made = makeFilter() else { return unavailableLine }
        let extras = extras(text, keys: made.keys) { made.filter.value(forKey: $0) }
        return extras.line
    }

    /// Every numeric input `filter` holds, as `key=value`, in its own order.
    static func numericInputs(_ filter: NSObject) -> [String] {
        (inputKeys(of: filter) ?? []).compactMap { key in
            (filter.value(forKey: key) as? NSNumber).map { "\(key)=\($0)" }
        }
    }

    /// The check file (fade round): the ground's check line, written to the
    /// app's own temporary folder (inside a preview's sandbox container)
    /// whenever Apple's blur is configured, so it can be read where nobody
    /// captures the screen.
    static var checkFileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("gloss-ground-check.txt") }

    /// Whether `layer` has the setting `key`, its setter and its getter.
    static func answers(_ layer: CALayer, _ key: String) -> Bool {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        return layer.responds(to: NSSelectorFromString(setter)) && layer.responds(to: NSSelectorFromString(key))
    }

    /// Asked of this system once; a test that sets the seam asks again.
    private static let systemHasIt = make(backdropClass: backdropClassName) != nil
    static var isAvailable: Bool { backdropClassNameForTesting == nil ? systemHasIt : make() != nil }

    /// The quiet line the Sample cards row shows when Apple's blur is chosen
    /// and this system cannot draw it; nil otherwise.
    static func line(for material: GlossLab.StackGroundMaterial) -> String? {
        material == .variable && !isAvailable ? unavailableLine : nil
    }

    /// Puts the radius and the mask on the filter and the filter on the layer
    /// (the layer keeps its own copy, so it is put on again each time).
    static func apply(_ parts: Parts, radius: CGFloat, mask: CGImage?) {
        parts.filter.setValue(NSNumber(value: Double(radius)), forKey: radiusKey)
        parts.filter.setValue(mask, forKey: maskKey)
        parts.layer.filters = [parts.filter]
    }

    /// The radius and the mask as the layer holds them, for the checks.
    static func readBack(_ layer: CALayer) -> (radius: Double?, mask: CGImage?) {
        guard let filterClass = NSClassFromString(filterClassName),
              let filter = layer.filters?.first as? NSObject, filter.isKind(of: filterClass) else { return (nil, nil) }
        let radius = (filter.value(forKey: radiusKey) as? NSNumber)?.doubleValue
        var mask: CGImage?
        if let any = filter.value(forKey: maskKey) {
            let value = any as AnyObject
            if CFGetTypeID(value) == CGImage.typeID { mask = (value as! CGImage) }
        }
        return (radius, mask)
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
    // Apple's blur: its radius and reach, the private layer (made the first
    // time it is drawn; nil where this system lacks a piece) in a view of
    // its own under the dim, and what its mask was made for.
    private(set) var radius: Double = 20
    private(set) var reach: CGFloat = GlossSamples.stackGroundReach
    private var backdrop: GlossBackdropGround.Parts?
    private var backdropTried = false
    private var backdropHost: NSView?
    private var variableMask: CGImage?
    private var variableMaskMade: [CGFloat]?
    private var appliedRadius: Double?
    // The fade (24 Nov): fade start (pt), curve, the extra inputs' text, the
    // text the filter was made with, what it gave, and the last check line
    // written to the check file.
    private(set) var hold: CGFloat = 25
    private(set) var curve: CGFloat = 1
    private(set) var extras = ""
    private var filterExtras = ""
    private(set) var appliedExtras = GlossBackdropGround.Extras.none
    private var checkWritten: String?
    /// What is drawn: the chosen material, or the public Blur where Apple's
    /// blur was chosen and this system cannot draw it.
    private(set) var drawnMaterial: GlossLab.StackGroundMaterial = .blur
    /// Apple's blur's layer, for the checks.
    var backdropLayer: CALayer? { backdrop?.layer }

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

    /// `radius`, `reach`, `hold`, `curve` and `extras` are Apple's blur's;
    /// the other materials leave them unused.
    func configure(material: GlossLab.StackGroundMaterial, dim: Double, radius: Double = 20,
                   reach: CGFloat = GlossSamples.stackGroundReach, hold: CGFloat = 25, curve: CGFloat = 1, extras: String = "") {
        if material != self.material {
            self.material = material
            maskSize = .zero
            variableMaskMade = nil
            needsLayout = true
        }
        if radius != self.radius || reach != self.reach || hold != self.hold || curve != self.curve || extras != self.extras {
            self.radius = radius
            self.reach = reach
            self.hold = hold
            self.curve = curve
            self.extras = extras
            needsLayout = true
        }
        if dim != self.dim {
            self.dim = dim
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(dim).cgColor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Apple's blur chosen: its check line goes to the check file after
        // this pass (fade round); nothing for the other materials.
        defer { if material == .variable { writeCheckFile() } }
        if material == .variable, !backdropTried {
            backdropTried = true
            backdrop = GlossBackdropGround.make()
        }
        let drawn: GlossLab.StackGroundMaterial = material == .variable && backdrop == nil ? .blur : material
        drawnMaterial = drawn
        if drawn != .variable { backdropHost?.isHidden = true }
        let glassStyle: NSGlassEffectView.Style? = switch drawn {
        case .blur, .variable: nil
        case .regular: .regular
        case .clear: .clear
        }
        if drawn == .variable, backdrop != nil {
            layoutVariable()
            return
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

    /// Apple's blur: the private layer fills the ground; its mask (full
    /// near the pieces, nothing at the rim) sets the blur radius point by
    /// point, and the same mask fades the dim, so neither has a border.
    private func layoutVariable() {
        guard var parts = backdrop else { return }
        glass?.isHidden = true
        blur.isHidden = true
        let host = backdropHost ?? {
            let made = NSView()
            made.wantsLayer = true
            made.layer?.addSublayer(parts.layer)
            addSubview(made, positioned: .below, relativeTo: dimView)
            backdropHost = made
            return made
        }()
        host.isHidden = false
        host.frame = bounds
        dimView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        parts.layer.frame = host.bounds
        guard bounds.width > 0, bounds.height > 0 else { CATransaction.commit(); return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let made = [bounds.width, bounds.height, reach, scale, hold, curve]
        var maskChanged = false
        // New extra inputs: a new filter, so an input taken out of the text
        // goes back to unset (none: the filter made with the layer, as before).
        if filterExtras != extras {
            if let fresh = GlossBackdropGround.makeFilter() { parts.filter = fresh.filter }
            appliedExtras = GlossBackdropGround.applyExtras(extras, to: parts.filter)
            filterExtras = extras
            backdrop = parts
            maskChanged = true
        }
        if variableMaskMade != made {
            variableMaskMade = made
            variableMask = GlossSamples.variableMask(size: bounds.size, reach: reach, hold: hold, curve: curve, scale: scale)
            let fade = CALayer()
            fade.frame = CGRect(origin: .zero, size: bounds.size)
            fade.contents = variableMask
            dimView.layer?.mask = fade
            dimView.layer?.cornerRadius = 0
            maskChanged = true
        }
        if maskChanged || appliedRadius != radius {
            appliedRadius = radius
            GlossBackdropGround.apply(parts, radius: CGFloat(radius), mask: variableMask)
        }
        CATransaction.commit()
    }

    /// The ground's state as one line: the material chosen and drawn, and
    /// for Apple's blur what its layer holds, the fade and every numeric
    /// input of the layer's filter.
    func checkLine() -> String {
        var text = "groundChosen=\(material.rawValue) groundDrawn=\(drawnMaterial.rawValue) groundView=\(NSStringFromSize(bounds.size))"
        if let layer = backdropLayer {
            let back = GlossBackdropGround.readBack(layer)
            let aware = GlossBackdropGround.answers(layer, GlossBackdropGround.behindWindowKey)
                ? "\(layer.value(forKey: GlossBackdropGround.behindWindowKey) ?? "nil")" : "-"
            text += " layer=\(NSStringFromClass(type(of: layer))) windowServerAware=\(aware) radius=\(back.radius.map { "\($0)" } ?? "nil") "
                + "mask=\(back.mask.map { "\($0.width)x\($0.height)" } ?? "nil")"
        }
        if material == .variable {
            let inputs = (backdropLayer?.filters?.first as? NSObject).map(GlossBackdropGround.numericInputs) ?? []
            text += " hold=\(hold) holdUsed=\(GlossSamples.variableFadeStart(hold, reach: reach)) curve=\(curve) reach=\(reach) "
                + "extrasApplied=[\(appliedExtras.applied.map { "\($0.key)=\($0.value)" }.joined(separator: ","))] "
                + "extrasIgnored=[\(appliedExtras.ignored.joined(separator: ","))] inputs=[\(inputs.joined(separator: ","))]"
        }
        return text
    }

    /// Writes the check line to the check file when it changed.
    private func writeCheckFile() {
        let line = checkLine()
        guard line != checkWritten else { return }
        checkWritten = line
        try? (line + "\n").write(to: GlossBackdropGround.checkFileURL, atomically: true, encoding: .utf8)
    }
}

/// The ground as a view under the pieces in the cards window.
struct GlossStackGround: NSViewRepresentable {
    let material: GlossLab.StackGroundMaterial
    let dim: Double
    let radius: Double
    let reach: CGFloat
    let hold: CGFloat
    let curve: CGFloat
    let extras: String

    func makeNSView(context: Context) -> GlossStackGroundView {
        let view = GlossStackGroundView(frame: .zero)
        view.configure(material: material, dim: dim, radius: radius, reach: reach, hold: hold, curve: curve, extras: extras)
        return view
    }

    func updateNSView(_ view: GlossStackGroundView, context: Context) {
        view.configure(material: material, dim: dim, radius: radius, reach: reach, hold: hold, curve: curve, extras: extras)
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
        let room = GlossSamples.stackRoom(for: lab)
        let reach = GlossSamples.stackGroundReach(for: lab)
        let size = GlossSamples.stackWindowSize(room: room)
        let ground = GlossSamples.stackGroundRect(room: room, reach: reach)
        ZStack(alignment: .topLeading) {
            if lab.samplesGround == .same {
                GlossStackGround(material: lab.samplesGroundMaterial, dim: lab.samplesGroundDim / 100,
                                 radius: lab.samplesGroundRadius, reach: reach, hold: CGFloat(lab.samplesGroundHold),
                                 curve: CGFloat(lab.samplesGroundCurve), extras: lab.samplesGroundExtras)
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
        // The window's own size, which grows with Apple's blur's reach.
        let size = GlossSamples.windowSize(for: lab)
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
    /// The cards window's room round the pieces beyond the usual 60 pt, as
    /// it is now; the saved place is kept without it.
    private var shownExtra: CGFloat = 0

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
            _ = GlossLab.shared.samplesGroundRadius
            _ = GlossLab.shared.samplesGroundReach
            _ = GlossLab.shared.samplesGroundHold
            _ = GlossLab.shared.samplesGroundCurve
            _ = GlossLab.shared.samplesGroundExtras
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
        let size = GlossSamples.windowSize(for: lab)
        // Room beyond the usual 60 pt (Apple's blur's reach in this window):
        // the window grows round the pieces, so they stay where they are.
        let extra = lab.samplesStack ? GlossSamples.stackRoom(for: lab) - GlossSamples.stackRoom : 0
        let grew = extra - shownExtra
        shownExtra = extra
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
            // Placed as the window without the extra room would be, saved
            // or not, then grown round the pieces.
            let base = CGSize(width: size.width - extra * 2, height: size.height - extra * 2)
            let saved = GlossSamples.origin(
                savedTopLeft: UserDefaults.standard.string(forKey: Self.topLeftKey).map(NSPointFromString),
                savedOneRowOrigin: UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString),
                size: base)
            window.setFrame(GlossSamples.frame(savedOrigin: saved, size: base, visible: visible).insetBy(dx: -extra, dy: -extra), display: true)
        } else if window.frame.size != size {
            // Rows came or went: the top edge stays where it is, unless
            // the taller window would then hang off the screen. Room that
            // came or went round the pieces moves the corner by as much.
            let frame = window.frame
            let grown = CGRect(x: frame.minX - grew, y: frame.maxY + grew - size.height, width: size.width, height: size.height)
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
        let reach = GlossSamples.stackGroundReach(for: lab)
        (ground.contentView as? GlossStackGroundView)?.configure(material: lab.samplesGroundMaterial, dim: lab.samplesGroundDim / 100,
                                                                 radius: lab.samplesGroundRadius, reach: reach,
                                                                 hold: CGFloat(lab.samplesGroundHold), curve: CGFloat(lab.samplesGroundCurve),
                                                                 extras: lab.samplesGroundExtras)
        let frame = GlossSamples.stackGroundFrame(under: window.frame, room: GlossSamples.stackRoom(for: lab), reach: reach)
        if ground.parent !== window {
            ground.setFrame(frame, display: false)
            window.addChildWindow(ground, ordered: .below)
        }
        ground.setFrame(frame, display: true)
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
    /// output; with `-GlossLab.samplesMoveX <pt> -GlossLab.samplesMoveY <pt>`
    /// it then moves the cards window by that much, as a drag would, and
    /// writes them again. (Two numbers, because a launch value in braces
    /// is read as a dictionary, not a string.)
    private func reportForCheck(_ window: Panel) {
        let defaults = UserDefaults.standard
        guard !checkReported, defaults.string(forKey: GlossLab.prefix + "samplesBackdrop") != nil else { return }
        checkReported = true
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .seconds(2))
            guard let window else { return }
            self?.writeCheckLine("shown", window)
            let dx = UserDefaults.standard.double(forKey: GlossLab.prefix + "samplesMoveX")
            let dy = UserDefaults.standard.double(forKey: GlossLab.prefix + "samplesMoveY")
            if dx != 0 || dy != 0 {
                window.setFrameOrigin(CGPoint(x: window.frame.minX + dx, y: window.frame.minY + dy))
                try? await Task.sleep(for: .seconds(1))
                self?.writeCheckLine("moved", window)
            }
            try? await Task.sleep(for: .seconds(2))
            await self?.closeForCheck()
        }
    }

    private func writeCheckLine(_ when: String, _ window: Panel) {
        let order = NSWindow.windowNumbers(options: [])?.compactMap { NSApp.window(withWindowNumber: $0.intValue)?.title } ?? []
        let lab = GlossLab.shared
        let ground = groundWindow.flatMap { $0.isVisible ? NSStringFromRect($0.frame) : nil } ?? "none"
        let expected = NSStringFromRect(GlossSamples.stackGroundFrame(
            under: window.frame, room: GlossSamples.stackRoom(for: lab), reach: GlossSamples.stackGroundReach(for: lab)))
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        print("GLOSS_STACK \(when) key=\(window.isKeyWindow) canBecomeKey=\(window.canBecomeKey) appActive=\(NSApp.isActive) "
              + "reduceTransparency=\(reduceTransparency) "
              + "cards=\(NSStringFromRect(window.frame)) ground=\(ground) groundExpected=\(expected) "
              + "groundIsChild=\(groundWindow?.parent === window) frontToBack=\(order) \(groundCheck(window))")
        fflush(stdout)
    }

    /// The live ground view's state for the check line: the material chosen
    /// and drawn, and, for Apple's blur, what its layer holds.
    private func groundCheck(_ window: Panel) -> String {
        func find(_ view: NSView?) -> GlossStackGroundView? {
            guard let view else { return nil }
            if let ground = view as? GlossStackGroundView { return ground }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let view = GlossLab.shared.samplesGround == .below ? find(groundWindow?.contentView) : find(window.contentView)
        return view?.checkLine() ?? "groundView=none"
    }

    /// The check seam's close (`-GlossLab.samplesCloseCheck YES`): shuts
    /// the cards as their close button does, then lists the windows still up.
    private func closeForCheck() async {
        guard UserDefaults.standard.bool(forKey: GlossLab.prefix + "samplesCloseCheck") else { return }
        GlossLab.shared.samplesShown = false
        try? await Task.sleep(for: .seconds(1))
        let up = NSApp.windows.filter(\.isVisible).map(\.title)
        print("GLOSS_STACK closed visible=\(up)")
        fflush(stdout)
    }

    private func saveOrigin() {
        guard let window, window.isVisible else { return }
        let frame = window.frame
        UserDefaults.standard.set(NSStringFromPoint(CGPoint(x: frame.minX + shownExtra, y: frame.maxY - shownExtra)), forKey: Self.topLeftKey)
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
        // It covers the ground window as well where Apple's blur's reach
        // makes that larger than the cards (fade round; the same frame as
        // before at a reach of 60 pt or less).
        let lab = GlossLab.shared
        var covered = window.frame
        if Self.groundWindowWanted(for: lab) {
            covered = covered.union(GlossSamples.stackGroundFrame(under: window.frame, room: GlossSamples.stackRoom(for: lab),
                                                                  reach: GlossSamples.stackGroundReach(for: lab)))
        }
        backdropWindow?.setFrame(covered.insetBy(dx: -30, dy: -30), display: true)
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

// MARK: Calibration backdrop and match sheet (24 Nov, the match round)

/// The calibration backdrop's pattern (brief
/// `ops/design/gloss-lab-match-brief-2026-11-24.md`, step 2): a tile of
/// 6 x 4 cells of 64 pt, repeated from the window's top left corner, so a
/// picture of the real Control Centre and of our pieces over it can be
/// measured against the sharp pattern beside them in the same picture
/// (`ops/reviews/gloss-lab-match-24nov/scripts/calib.py`). Flat white, black
/// and mid grey, three colours, checkers of 2, 4, 8 and 16 pt squares (hard
/// edges in both directions, at periods that tell a blur of 1 pt from one
/// of 3 and one of 10), hard white to black edges both ways between the
/// flat cells, and text at two sizes, black on white and white on black.
/// The tile is 384 pt wide and the match sheet's copies stand 384 pt
/// apart, so every copy lies over the same part of the pattern.
enum GlossCalibration {
    static let cell: CGFloat = 64
    static let tileSize = CGSize(width: 384, height: 256)

    enum Cell: Equatable {
        case white, black, grey, red, green, blue
        /// A checker of squares this many pt wide; its top left square is black.
        case checker(Int)
        /// Text of this size: black on white, or white on black.
        case text(CGFloat, onBlack: Bool)
    }

    /// The tile's cells, top row first.
    static let layout: [[Cell]] = [
        [.white, .white, .black, .black, .checker(2), .text(11, onBlack: false)],
        [.black, .checker(8), .text(17, onBlack: false), .white, .grey, .red],
        [.checker(4), .text(11, onBlack: true), .white, .white, .black, .black],
        [.green, .blue, .grey, .text(17, onBlack: true), .checker(16), .white],
    ]

    /// A flat cell's colour (sRGB bytes); nil for a checker or text.
    static func colour(_ cell: Cell) -> (UInt8, UInt8, UInt8)? {
        switch cell {
        case .white: (255, 255, 255)
        case .black: (0, 0, 0)
        case .grey: (128, 128, 128)
        case .red: (224, 48, 48)
        case .green: (40, 168, 72)
        case .blue: (40, 88, 224)
        case .checker, .text: nil
        }
    }

    /// A flat pattern's colour; nil for the tile.
    static func colour(_ pattern: GlossLab.CalibrationPattern) -> (UInt8, UInt8, UInt8)? {
        switch pattern {
        case .tile: nil
        case .white: colour(Cell.white)
        case .grey: colour(Cell.grey)
        case .black: colour(Cell.black)
        }
    }

    static let textLine = "Hamburg 0123456789 quick brown fox jumps over"

    /// The tile as pixels, top row first, `scale` px per pt (1 or 2 on our
    /// displays), sRGB. Fields and checkers are written pixel by pixel, so
    /// every edge is hard; the text is drawn over its cells.
    static func tileImage(scale: Int) -> CGImage? {
        let scale = max(1, scale)
        let width = Int(tileSize.width) * scale, height = Int(tileSize.height) * scale, cellSide = Int(cell) * scale
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for (row, cells) in layout.enumerated() {
            for (column, kind) in cells.enumerated() {
                for y in 0..<cellSide {
                    for x in 0..<cellSide {
                        let rgb: (UInt8, UInt8, UInt8)
                        if let flat = colour(kind) {
                            rgb = flat
                        } else if case .checker(let points) = kind {
                            let square = points * scale
                            rgb = ((x / square) + (y / square)).isMultiple(of: 2) ? (0, 0, 0) : (255, 255, 255)
                        } else if case .text(_, let onBlack) = kind {
                            rgb = onBlack ? (0, 0, 0) : (255, 255, 255)
                        } else {
                            rgb = (255, 255, 255)
                        }
                        let index = ((row * cellSide + y) * width + column * cellSide + x) * 4
                        pixels[index] = rgb.0; pixels[index + 1] = rgb.1; pixels[index + 2] = rgb.2; pixels[index + 3] = 255
                    }
                }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            // The buffer's first row is the picture's top row; the context's
            // origin is its bottom left.
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setShouldSmoothFonts(false)
            for (row, cells) in layout.enumerated() {
                for (column, kind) in cells.enumerated() {
                    guard case .text(let size, let onBlack) = kind else { continue }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: size),
                        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                    ]
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: textLine, attributes: attributes))
                    let pitch = (size * 1.3).rounded()
                    let top = CGFloat(row) * cell, left = CGFloat(column) * cell
                    context.saveGState()
                    context.clip(to: CGRect(x: left + 3, y: tileSize.height - top - cell + 2, width: cell - 6, height: cell - 4))
                    context.setFillColor(gray: onBlack ? 1 : 0, alpha: 1)
                    var baseline = top + 4 + size
                    var shift: CGFloat = 0
                    while baseline < top + cell - 3 {
                        context.textPosition = CGPoint(x: left + 4 - shift, y: tileSize.height - baseline)
                        CTLineDraw(line, context)
                        baseline += pitch
                        // Each line starts further into the sentence, so the lines differ.
                        shift += size * 2.5
                    }
                    context.restoreGState()
                }
            }
            return context.makeImage()
        }
    }
}

/// How long the calibration backdrop may still stand: a deadline against
/// the clock, pushed on by every click on the backdrop.
struct GlossCalibrationWatch: Equatable {
    let timeout: TimeInterval
    private(set) var lastClick: Date

    init(timeout: TimeInterval, now: Date) {
        self.timeout = timeout
        lastClick = now
    }

    mutating func clicked(_ now: Date) { lastClick = now }
    func remaining(_ now: Date) -> TimeInterval { max(0, timeout - now.timeIntervalSince(lastClick)) }
    func expired(_ now: Date) -> Bool { remaining(now) <= 0 }
}

/// The backdrop's own controls, drawn by hand on an opaque black plate with
/// a white rim, in fixed colours: "Close test pattern (Esc)", the four
/// patterns, and the time left before the backdrop takes itself down. On
/// 24 Nov the stock button and picker stood here; their plates are
/// see-through and their text one colour, so over white (or, in a light
/// system, over black) they could not be read and the owner could not close
/// the backdrop. Nothing here depends on the system's look or on what the
/// backdrop shows. It takes no clicks itself: the backdrop's view hands
/// them over (`click(at:)`).
final class GlossCalibrationBar: NSView {
    enum Cell: Equatable {
        case close
        case pattern(GlossLab.CalibrationPattern)
        case countdown
    }

    static let closeTitle = "Close test pattern (Esc)"
    static let height: CGFloat = 32
    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let padding: CGFloat = 12
    private static let rim: CGFloat = 2

    /// "closes itself in 2:59"; nothing while no time is set.
    static func countdownText(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        let left = max(seconds, 0)
        return "closes itself in \(left / 60):" + String(format: "%02d", left % 60)
    }

    static func title(_ cell: Cell, remaining: Int? = nil) -> String {
        switch cell {
        case .close: closeTitle
        case .pattern(let pattern): pattern.title
        case .countdown: countdownText(remaining)
        }
    }

    private static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + padding * 2
    }

    /// Every cell with its frame in the bar (top left origin), left to
    /// right. The widths are fixed, so the bar does not change size as the
    /// time runs down.
    static let cells: [(cell: Cell, frame: CGRect)] = {
        var x = rim
        var out: [(cell: Cell, frame: CGRect)] = []
        let all: [Cell] = [.close] + GlossLab.CalibrationPattern.allCases.map { .pattern($0) } + [.countdown]
        for cell in all {
            let wide = cell == .countdown ? width("closes itself in 00:00") : width(title(cell))
            out.append((cell, CGRect(x: x, y: rim, width: wide, height: height - rim * 2)))
            x += wide
        }
        return out
    }()

    static let size = CGSize(width: (cells.last?.frame.maxX ?? 0) + rim, height: height)

    var pattern: GlossLab.CalibrationPattern = .tile {
        didSet { if pattern != oldValue { needsDisplay = true } }
    }
    /// Whole seconds until the backdrop takes itself down.
    var remaining: Int? {
        didSet { if remaining != oldValue { needsDisplay = true } }
    }
    var onClose: (() -> Void)?
    var onPattern: ((GlossLab.CalibrationPattern) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Test pattern controls: \(Self.closeTitle), and the pattern")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    /// Clicks go to the backdrop's view, which counts every one of them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func cell(at point: CGPoint) -> Cell? {
        Self.cells.first { $0.frame.contains(point) }?.cell
    }

    /// A click at a point of the bar: Close calls back, a pattern calls
    /// back with it. True when a control was hit.
    @discardableResult
    func click(at point: CGPoint) -> Bool {
        switch cell(at: point) {
        case .close:
            onClose?()
            return true
        case .pattern(let picked):
            onPattern?(picked)
            return true
        case .countdown, nil:
            return false
        }
    }

    private static func grey(_ level: CGFloat) -> NSColor { NSColor(srgbRed: level, green: level, blue: level, alpha: 1) }

    override func draw(_ dirtyRect: NSRect) {
        Self.grey(1).setFill()
        bounds.fill()
        Self.grey(0).setFill()
        bounds.insetBy(dx: Self.rim, dy: Self.rim).fill()
        for (cell, frame) in Self.cells {
            var ink = Self.grey(1)
            switch cell {
            case .close:
                // The one white plate: black on white, the strongest there is.
                Self.grey(1).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
                ink = Self.grey(0)
            case .pattern(let one) where one == pattern:
                Self.grey(0.38).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 3), xRadius: 5, yRadius: 5).fill()
            case .pattern:
                break
            case .countdown:
                ink = Self.grey(0.8)
            }
            let text = Self.title(cell, remaining: remaining) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ink]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: frame.minX + Self.padding, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// The calibration backdrop's view: the tile repeated from its top left
/// corner, pixel for pixel (or one flat colour), and in its bottom left
/// corner its own controls (`GlossCalibrationBar`; the backdrop covers the
/// lab window, so what closes it and what is switched between two
/// screenshots is here). It takes every click inside it and does nothing
/// with one outside the bar (it is not click-through, so nothing hidden
/// under it is clicked by mistake); every click pushes its closing time on.
/// Escape closes it while its window has the keyboard.
final class GlossCalibrationView: NSView {
    /// "Close test pattern" was clicked.
    var onClose: (() -> Void)?
    /// Escape was pressed while the window had the keyboard.
    var onEscape: (() -> Void)?
    var onPattern: ((GlossLab.CalibrationPattern) -> Void)?
    /// Any click on the backdrop, the bar included.
    var onClick: (() -> Void)?
    var pattern: GlossLab.CalibrationPattern = .tile {
        didSet {
            guard pattern != oldValue else { return }
            needsDisplay = true
            bar.pattern = pattern
        }
    }
    let bar = GlossCalibrationBar(frame: CGRect(origin: .zero, size: GlossCalibrationBar.size))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        bar.onClose = { [weak self] in self?.onClose?() }
        bar.onPattern = { [weak self] in self?.onPattern?($0) }
        addSubview(bar)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked(at: convert(event.locationInWindow, from: nil)) }

    /// A click at a point of the view.
    func clicked(at point: CGPoint) {
        onClick?()
        guard bar.frame.contains(point) else { return }
        bar.click(at: CGPoint(x: point.x - bar.frame.minX, y: point.y - bar.frame.minY))
    }

    /// Escape closes; every other key is taken and does nothing (the
    /// windows under the backdrop cannot be seen, so nothing is typed into
    /// them through it).
    override func keyDown(with event: NSEvent) {
        if GlossMatchWindows.isEscape(event) { (onEscape ?? onClose)?() }
    }

    override func cancelOperation(_ sender: Any?) { (onEscape ?? onClose)?() }

    override func layout() {
        super.layout()
        bar.frame = CGRect(origin: CGPoint(x: 12, y: bounds.height - GlossCalibrationBar.size.height - 12), size: GlossCalibrationBar.size)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let flat = GlossCalibration.colour(pattern) {
            NSColor(srgbRed: CGFloat(flat.0) / 255, green: CGFloat(flat.1) / 255, blue: CGFloat(flat.2) / 255, alpha: 1).setFill()
            bounds.fill()
            return
        }
        let scale = Int((window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2).rounded())
        guard let image = GlossCalibration.tileImage(scale: scale) else {
            NSColor.white.setFill(); bounds.fill(); return
        }
        context.interpolationQuality = .none
        let tile = GlossCalibration.tileSize
        var y: CGFloat = 0
        while y < bounds.height {
            var x: CGFloat = 0
            while x < bounds.width {
                if dirtyRect.intersects(CGRect(x: x, y: y, width: tile.width, height: tile.height)) {
                    // A flipped view draws an image upside down: each tile is turned back.
                    context.saveGState()
                    context.translateBy(x: x, y: y + tile.height)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(origin: .zero, size: tile))
                    context.restoreGState()
                }
                x += tile.width
            }
            y += tile.height
        }
    }
}

/// The match sheet: our pieces in the real Control Centre's arrangement at
/// its sizes (read from the owner's screenshot of macOS 27 at 2 px per pt:
/// capsules 141 x 64, the large tile 141 x 140 with 32 pt corners, round
/// buttons 65 across, the pill 95 x 24, 12 pt between pieces), in up to
/// four copies one tile width apart, each with its own overrides of the
/// stack test's values, so one picture brackets the real one. Or a walk:
/// one capsule and one round button per value of one setting, up to 24 to
/// a picture. Shapes and plain labels only.
@MainActor
enum GlossMatch {
    static let column: CGFloat = 141
    static let row: CGFloat = 64
    static let gap: CGFloat = 12
    static let round: CGFloat = 65
    static let largeTile = CGSize(width: 141, height: 140)
    static let largeTileCorner: CGFloat = 32
    static let pill = CGSize(width: 95, height: 24)
    static let pillGap: CGFloat = 14
    /// The pieces' bounding box.
    static let group = CGSize(width: 294, height: 406)
    /// From one copy to the next: the calibration tile's width.
    static let pitch = GlossCalibration.tileSize.width
    /// The clear room beside and above a copy's pieces, how far its ground
    /// reaches beyond them, and the caption's row under it.
    static let roomX = (pitch - group.width) / 2
    static let roomY: CGFloat = 36
    static let reach: CGFloat = 30
    static let caption: CGFloat = 22
    static let maxCopies = 4
    /// A walk's piece pair (a capsule and a round button), its ground's
    /// reach, the cell one pair stands in, and how many stand in a row.
    static let walkPair = CGSize(width: column + gap + round, height: round)
    static let walkReach: CGFloat = 20
    static let walkCell = CGSize(width: walkPair.width + walkReach * 2, height: walkPair.height + walkReach * 2)
    static let walkColumns = 4
    static let maxWalk = 24

    enum Kind: Equatable {
        case toggle(String, String)
        case media
        case round
        case slider(String)
        case pill
    }

    struct Piece: Identifiable, Equatable {
        let id: String
        /// In the group, from its top left corner.
        let rect: CGRect
        let corner: CGFloat
        let kind: Kind
    }

    static let pieces: [Piece] = {
        let pitch = row + gap, right = column + gap
        func capsule(_ id: String, _ x: CGFloat, _ index: CGFloat, _ kind: Kind) -> Piece {
            Piece(id: id, rect: CGRect(x: x, y: index * pitch, width: column, height: row), corner: row / 2, kind: kind)
        }
        func circle(_ id: String, _ x: CGFloat, _ index: CGFloat) -> Piece {
            Piece(id: id, rect: CGRect(x: x, y: index * pitch - (round - row) / 2, width: round, height: round), corner: round / 2, kind: .round)
        }
        return [
            capsule("wifi", 0, 0, .toggle("Wi-Fi", "Home")),
            capsule("bluetooth", 0, 1, .toggle("Bluetooth", "On")),
            capsule("airdrop", 0, 2, .toggle("AirDrop", "Everyone")),
            Piece(id: "media", rect: CGRect(origin: CGPoint(x: right, y: 0), size: largeTile), corner: largeTileCorner, kind: .media),
            circle("round3", group.width - round, 2),
            circle("round1", 0, 3),
            circle("round2", column - round, 3),
            capsule("focus", right, 3, .toggle("Focus", "")),
            capsule("display", 0, 4, .slider("Display")),
            capsule("sound", right, 4, .slider("Sound")),
            Piece(id: "pill", rect: CGRect(x: ((group.width - pill.width) / 2).rounded(), y: 5 * row + 4 * gap + pillGap,
                                           width: pill.width, height: pill.height),
                  corner: pill.height / 2, kind: .pill),
        ]
    }()

    /// One copy of the pieces and their ground.
    struct Copy: Identifiable, Equatable {
        var id = 0
        /// What the copy's own text asked for, for its caption.
        var label = "as set"
        var ground = true
        var radius: Double = 20
        /// 0 to 30 %.
        var dim: Double = 8
        var hold: CGFloat = 25
        var curve: CGFloat = 1
        /// 0 to 60 %.
        var smoke: Double = 25
        var smokeAsTint = false
        var extras = ""
        var settings = GlossSystemGlass.PieceSettings()
        /// The parts of the copy's text that were not understood.
        var ignored: [String] = []
    }

    /// What the sheet shows: whole copies side by side, or a walk's pairs.
    struct Sheet: Equatable {
        var walk = false
        var copies: [Copy] = []
    }

    /// The stack test's values as a copy.
    @MainActor static func base(for lab: GlossLab) -> Copy {
        Copy(radius: lab.samplesGroundRadius, dim: lab.samplesGroundDim, hold: CGFloat(lab.samplesGroundHold),
             curve: CGFloat(lab.samplesGroundCurve), smoke: lab.samplesSmoke, smokeAsTint: lab.samplesStackTint,
             extras: lab.samplesGroundExtras,
             settings: GlossSystemGlass.PieceSettings(
                variant: Int(lab.samplesStackVariant.rounded()), lensing: Int(lab.samplesLensing.rounded()),
                scrim: Int(lab.samplesScrim.rounded()), subdued: Int(lab.samplesSubdued.rounded()),
                adaptive: Int(lab.samplesAdaptive.rounded()), tintReduced: lab.samplesTintReduced,
                subvariant: lab.samplesSubvariant))
    }

    /// The settings a copy's text may name, each with the range it is held in.
    static let keys: [String: ClosedRange<Double>] = [
        "ground": 0...1, "radius": 0...40, "dim": 0...30, "hold": 0...60, "curve": 1...4, "smoke": 0...60, "tint": 0...1,
        "variant": 0...23, "lensing": 0...3, "scrim": 0...3, "subdued": 0...3, "adaptive": GlossSystemGlass.adaptiveRange, "reduced": 0...1,
    ]

    /// Sets one named setting on a copy; false for a name that is not one.
    static func set(_ key: String, _ value: Double, on copy: inout Copy) -> Bool {
        guard let range = keys[key], value.isFinite else { return false }
        let held = min(max(value, range.lowerBound), range.upperBound)
        switch key {
        case "ground": copy.ground = held >= 0.5
        case "radius": copy.radius = held
        case "dim": copy.dim = held
        case "hold": copy.hold = CGFloat(held)
        case "curve": copy.curve = CGFloat(held)
        case "smoke": copy.smoke = held
        case "tint": copy.smokeAsTint = held >= 0.5
        case "variant": copy.settings.variant = Int(held.rounded())
        case "lensing": copy.settings.lensing = Int(held.rounded())
        case "scrim": copy.settings.scrim = Int(held.rounded())
        case "subdued": copy.settings.subdued = Int(held.rounded())
        case "adaptive": copy.settings.adaptive = Int(held.rounded())
        case "reduced": copy.settings.tintReduced = held >= 0.5
        default: return false
        }
        return true
    }

    /// Applies a list of `key=value` apart by "," to a copy; what was not
    /// understood goes to its `ignored`.
    static func apply(_ text: String, to copy: inout Copy) {
        for pair in text.split(separator: ",") {
            let whole = pair.trimmingCharacters(in: .whitespaces)
            guard !whole.isEmpty else { continue }
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Double(parts[1]), set(parts[0], value, on: &copy) else {
                copy.ignored.append(whole); continue
            }
        }
    }

    /// The sheet `spec` asks for, over `base`. Parts are apart by "/".
    /// Copies: each part is one copy, a list of `key=value` apart by ","
    /// (`radius=1 / radius=2 / radius=3`); an empty spec is one copy as
    /// set; at most four. A walk: `walk <key> [values]`, one pair of
    /// pieces per value (without values: every whole value of the key's
    /// range), then, after a "/", settings for all of them
    /// (`walk variant / lensing=1`, `walk radius 0.5 1 1.5 2 3 / dim=10`);
    /// at most 24.
    static func sheet(spec: String, base: Copy) -> Sheet {
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let words = (parts.first ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if words.first == "walk" {
            var common = base
            for part in parts.dropFirst() { apply(part, to: &common) }
            guard words.count >= 2, let range = keys[words[1]] else {
                common.ignored.insert(words.count >= 2 ? "walk \(words[1])" : "walk", at: 0)
                return Sheet(walk: false, copies: [common])
            }
            let key = words[1]
            var values = words.dropFirst(2).compactMap { Double($0) }.filter(\.isFinite)
            common.ignored.append(contentsOf: words.dropFirst(2).filter { Double($0) == nil })
            if values.isEmpty { values = Array(stride(from: range.lowerBound, through: range.upperBound, by: 1)) }
            let copies = values.prefix(maxWalk).enumerated().map { index, value in
                var copy = common
                copy.id = index
                _ = set(key, value, on: &copy)
                copy.label = "\(key) \(GlossLab.fine(min(max(value, range.lowerBound), range.upperBound)))"
                return copy
            }
            return Sheet(walk: true, copies: copies)
        }
        let wanted = parts.allSatisfy(\.isEmpty) ? [""] : parts.filter { !$0.isEmpty }
        let copies = wanted.prefix(maxCopies).enumerated().map { index, text in
            var copy = base
            copy.id = index
            copy.label = text.isEmpty ? "as set" : text
            apply(text, to: &copy)
            return copy
        }
        return Sheet(walk: false, copies: copies)
    }

    @MainActor static func sheet(for lab: GlossLab) -> Sheet { sheet(spec: lab.matchSpec, base: base(for: lab)) }

    /// The quiet line under the copies field: what was not understood; nil
    /// when everything was.
    static func ignoredLine(_ sheet: Sheet) -> String? {
        var seen: [String] = []
        for text in sheet.copies.flatMap(\.ignored) where !seen.contains(text) { seen.append(text) }
        return seen.isEmpty ? nil : "Not understood: " + seen.joined(separator: ", ")
    }

    /// One copy's cell in the sheet.
    static let cellSize = CGSize(width: pitch, height: group.height + roomY * 2 + caption)

    static func sheetSize(_ sheet: Sheet) -> CGSize {
        let count = max(1, sheet.copies.count)
        if sheet.walk {
            let columns = min(count, walkColumns), rows = (count + walkColumns - 1) / walkColumns
            return CGSize(width: walkCell.width * CGFloat(columns), height: walkCell.height * CGFloat(rows))
        }
        return CGSize(width: cellSize.width * CGFloat(count), height: cellSize.height)
    }

    /// The ground in a copy's cell, from its top left corner.
    static let groundRect = CGRect(x: roomX - reach, y: roomY - reach, width: group.width + reach * 2, height: group.height + reach * 2)

    /// A corner given as text, "x,y" in pt from the screen's top left
    /// corner; nil for anything else.
    static func corner(_ text: String) -> CGPoint? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// From the sheet's top left corner to its first pieces' top left corner.
    static func inset(_ sheet: Sheet) -> CGPoint {
        sheet.walk ? CGPoint(x: walkReach, y: walkReach) : CGPoint(x: roomX, y: roomY)
    }

    /// Where the first copy's pieces (a walk: the first pair) have their
    /// top left corner, in pt from the screen's top left corner: `corner`
    /// when it is given. Else, for copies, as many tile widths to the left
    /// of where Control Centre is taken to stand (its pieces 12 pt in from
    /// the screen's right edge and 12 pt under the menu bar: a first guess,
    /// replaced by the corner once a screenshot shows the real place), so
    /// the copies and the real one lie over the same part of the pattern;
    /// a walk starts near the top left corner.
    static func firstCorner(_ sheet: Sheet, corner: CGPoint?, screen: CGRect, visible: CGRect) -> CGPoint {
        if let corner { return corner }
        let top = screen.maxY - visible.maxY
        if sheet.walk { return CGPoint(x: visible.minX - screen.minX + 8 + walkReach, y: top + 8 + walkReach) }
        let real = visible.maxX - screen.minX - 12 - group.width
        let count = CGFloat(max(1, sheet.copies.count))
        return CGPoint(x: max(roomX, real - pitch * count), y: top + 12)
    }

    /// The sheet's window frame, in AppKit's screen coordinates, on whole points.
    static func sheetFrame(_ sheet: Sheet, corner: CGPoint?, screen: CGRect, visible: CGRect) -> CGRect {
        let first = firstCorner(sheet, corner: corner, screen: screen, visible: visible)
        let size = sheetSize(sheet), lead = inset(sheet)
        return CGRect(x: (screen.minX + first.x - lead.x).rounded(), y: (screen.maxY - first.y + lead.y - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    /// A copy as one line, for the check file.
    static func checkText(_ copy: Copy) -> String {
        let s = copy.settings
        return "\(copy.id + 1): \"\(copy.label)\" ground=\(copy.ground ? 1 : 0) radius=\(GlossLab.fine(copy.radius)) dim=\(GlossLab.fine(copy.dim)) "
            + "hold=\(copy.hold) curve=\(copy.curve) smoke=\(GlossLab.fine(copy.smoke)) tint=\(copy.smokeAsTint ? 1 : 0) variant=\(s.variant) "
            + "lensing=\(s.lensing) scrim=\(s.scrim) subdued=\(s.subdued) adaptive=\(s.adaptive) reduced=\(s.tintReduced ? 1 : 0) "
            + "subvariant=\"\(s.subvariant)\" extras=\"\(copy.extras)\""
            + (copy.ignored.isEmpty ? "" : " ignored=[\(copy.ignored.joined(separator: ","))]")
    }

    static var checkFileURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("gloss-match-check.txt") }
}

/// One copy: its ground (Apple's blur, `reach` beyond the pieces), its
/// pieces, and a plain caption under them saying what it was given.
struct GlossMatchCopyView: View {
    let copy: GlossMatch.Copy

    var body: some View {
        let ground = GlossMatch.groundRect
        ZStack(alignment: .topLeading) {
            if copy.ground {
                GlossStackGround(material: .variable, dim: copy.dim / 100, radius: copy.radius, reach: GlossMatch.reach,
                                 hold: copy.hold, curve: copy.curve, extras: copy.extras)
                    .frame(width: ground.width, height: ground.height)
                    .padding(.leading, ground.minX)
                    .padding(.top, ground.minY)
            }
            ForEach(GlossMatch.pieces) { piece in
                GlossStackPiece(size: piece.rect.size, corner: piece.corner, settings: copy.settings, smoke: copy.smoke / 100,
                                smokeAsTint: copy.smokeAsTint) { face(piece) }
                    .padding(.leading, GlossMatch.roomX + piece.rect.minX)
                    .padding(.top, GlossMatch.roomY + piece.rect.minY)
            }
            Text("\(copy.id + 1)  \(copy.label)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Color.black, in: Capsule())
                .padding(.leading, GlossMatch.roomX)
                .padding(.top, GlossMatch.cellSize.height - 20)
        }
        .frame(width: GlossMatch.cellSize.width, height: GlossMatch.cellSize.height, alignment: .topLeading)
    }

    @ViewBuilder private func face(_ piece: GlossMatch.Piece) -> some View {
        switch piece.kind {
        case .toggle(let title, let subtitle):
            HStack(spacing: 9) {
                Circle().fill(Color.white).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).opacity(0.6) }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
        case .media:
            Text("Not Playing").font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .padding(14)
                .frame(width: piece.rect.width, height: piece.rect.height, alignment: .topLeading)
        case .round:
            Color.clear
        case .slider(let title):
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Capsule().fill(Color.white.opacity(0.5)).frame(height: 4)
            }
            .padding(.horizontal, 18)
        case .pill:
            Text("Edit Controls").font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }
}

/// A walk's pair: a capsule, labelled with its value, and a round button,
/// over a ground of their own.
struct GlossMatchPairView: View {
    let copy: GlossMatch.Copy

    var body: some View {
        let reach = GlossMatch.walkReach
        ZStack(alignment: .topLeading) {
            if copy.ground {
                GlossStackGround(material: .variable, dim: copy.dim / 100, radius: copy.radius, reach: reach,
                                 hold: copy.hold, curve: copy.curve, extras: copy.extras)
                    .frame(width: GlossMatch.walkCell.width, height: GlossMatch.walkCell.height)
            }
            GlossStackPiece(size: CGSize(width: GlossMatch.column, height: GlossMatch.row), corner: GlossMatch.row / 2, settings: copy.settings,
                            smoke: copy.smoke / 100, smokeAsTint: copy.smokeAsTint) {
                Text(copy.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, reach)
            .padding(.top, reach + (GlossMatch.round - GlossMatch.row) / 2)
            GlossStackPiece(size: CGSize(width: GlossMatch.round, height: GlossMatch.round), corner: GlossMatch.round / 2, settings: copy.settings,
                            smoke: copy.smoke / 100, smokeAsTint: copy.smokeAsTint) { Color.clear }
                .padding(.leading, reach + GlossMatch.column + GlossMatch.gap)
                .padding(.top, reach)
        }
        .frame(width: GlossMatch.walkCell.width, height: GlossMatch.walkCell.height, alignment: .topLeading)
    }
}

struct GlossMatchView: View {
    @Bindable var lab: GlossLab

    var body: some View {
        let sheet = GlossMatch.sheet(for: lab)
        let size = GlossMatch.sheetSize(sheet)
        Group {
            if sheet.walk {
                let rows = stride(from: 0, to: sheet.copies.count, by: GlossMatch.walkColumns).map {
                    Array(sheet.copies[$0..<min($0 + GlossMatch.walkColumns, sheet.copies.count)])
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(rows[index]) { GlossMatchPairView(copy: $0) }
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(sheet.copies) { GlossMatchCopyView(copy: $0) }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Match sheet")
    }
}

/// The backdrop's window: a borderless panel that can take the keyboard
/// without bringing the app forward, so Escape reaches it after a click on
/// it (a plain borderless window never becomes key).
final class GlossCalibrationPanel: NSPanel {
    /// It takes the keyboard everywhere but in the invisible unit test
    /// host, where no window of the app's may (as the app's own panels).
    static func takesKeyboard(invisibleTestHost: Bool) -> Bool { !invisibleTestHost }
    override var canBecomeKey: Bool { Self.takesKeyboard(invisibleTestHost: TestPresentationPolicy.isInvisible) }
    override var canBecomeMain: Bool { false }
}

/// One showing of the backdrop, from up to down: its closing time, the
/// claim on the Escape key, and why it went. It holds no window, so every
/// way down is tried in tests; whatever way it ends, the Escape key is
/// given back exactly once and `close` is called at most once.
@MainActor
final class GlossCalibrationSession {
    enum Reason: String {
        /// "Close test pattern" was clicked.
        case button
        /// Escape, with the backdrop's window or another of ours holding the keyboard.
        case escape
        /// Escape through the system-wide claim, from any app.
        case hotKey
        /// Nobody clicked on it for the set time.
        case timeout
        /// The lab's switch, or the app's own state, turned it off.
        case switchedOff
    }

    /// How Escape is claimed from every app while the backdrop is up.
    /// `claim` is given what to do on a press and says how it went
    /// ("registered", or the refusal); `release` gives the key back.
    struct EscapeKey {
        var claim: @MainActor (@escaping @MainActor () -> Void) -> String
        var release: @MainActor () -> Void

        /// The app's own Carbon hot key (`GlobalHotKey`), on Escape alone.
        /// No permission is asked for; the system may refuse a key without
        /// modifiers, which the claim's text then says.
        @MainActor static let system: EscapeKey = {
            final class Holder { var key: GlobalHotKey? }
            let holder = Holder()
            return EscapeKey(claim: { action in
                let key = GlobalHotKey(combination: GlobalHotKeyCombination(keyCode: GlossMatchWindows.escapeKeyCode, modifiers: 0),
                                       action: action)
                holder.key = key
                switch key.register() {
                case .registered: return "registered"
                case .failed(let failure): return "refused(status \(failure.status))"
                case .notRegistered: return "notRegistered"
                }
            }, release: {
                holder.key?.unregister()
                holder.key = nil
            })
        }()
    }

    private(set) var watch: GlossCalibrationWatch
    /// How the claim on Escape went.
    private(set) var escapeClaim: String
    private(set) var ended: Reason?
    private let escapeKey: EscapeKey
    private let close: @MainActor (Reason) -> Void

    init(timeout: TimeInterval, now: Date, escapeKey: EscapeKey, close: @escaping @MainActor (Reason) -> Void) {
        watch = GlossCalibrationWatch(timeout: timeout, now: now)
        self.escapeKey = escapeKey
        self.close = close
        escapeClaim = ""
        escapeClaim = escapeKey.claim { [weak self] in self?.end(.hotKey) }
    }

    /// A click on the backdrop: the closing time starts again.
    func clicked(_ now: Date) {
        guard ended == nil else { return }
        watch.clicked(now)
    }

    /// The clock's tick: whole seconds left, and down when none is.
    @discardableResult
    func tick(_ now: Date) -> Int {
        guard ended == nil else { return 0 }
        if watch.expired(now) {
            end(.timeout)
            return 0
        }
        return Int(watch.remaining(now).rounded(.up))
    }

    /// Down, for a reason: Escape is given back, then `close` is told.
    /// Only the first call counts.
    func end(_ reason: Reason) {
        guard ended == nil else { return }
        ended = reason
        escapeKey.release()
        if reason != .switchedOff { close(reason) }
    }
}

/// The calibration backdrop's window and the match sheet's: two windows of
/// the lab's own, shown by their switches (launch arguments
/// `-GlossLab.calibration YES`, `-GlossLab.calibrationPattern
/// tile|white|grey|black`, `-GlossLab.match YES`, `-GlossLab.matchSpec
/// "radius=1 / radius=2 / radius=3"`, `-GlossLab.matchOrigin "x,y"`). Off,
/// neither exists.
@MainActor
final class GlossMatchWindows {
    static let shared = GlossMatchWindows()

    static let calibrationTitle = "Gloss calibration"
    static let sheetTitle = "Gloss match"

    private(set) var calibrationWindow: NSPanel?
    private(set) var sheetWindow: NSPanel?
    private var moveObserver: NSObjectProtocol?
    /// What the sheet was last placed for: its size and the corner's text.
    private var placedFor: String?
    private var checkWritten: String?
    /// The backdrop's showing now, its clock, and the key watch for Escape
    /// while one of our windows has the keyboard.
    private(set) var session: GlossCalibrationSession?
    private var clock: Timer?
    private var keyMonitor: Any?
    /// Why the backdrop last went down, with the time: for the check file.
    private(set) var lastClose: String?
    /// How Escape is claimed from every app (tests put their own in).
    lazy var escapeKey = GlossCalibrationSession.EscapeKey.system

    /// Escape's key code, and what counts as Escape: the key alone, or
    /// with Shift.
    static let escapeKeyCode: UInt32 = 53
    static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && UInt32(event.keyCode) == escapeKeyCode
            && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    func configure() {
        withObservationTracking {
            let lab = GlossLab.shared
            _ = lab.calibration
            _ = lab.calibrationPattern
            _ = lab.match
            _ = lab.matchSpec
            _ = lab.matchOrigin
            // The stack test's values the copies start from, for the check file.
            _ = GlossMatch.base(for: lab)
        } onChange: { [weak self] in
            Task { @MainActor in self?.configure() }
        }
        apply()
    }

    /// The backdrop's window: opaque, right under the lab's floating
    /// windows and over ordinary ones (level 2: far under the Dock, the
    /// menu bar and the system's own panels), and not click-through: it
    /// takes every click inside its frame. It can take the keyboard, so
    /// Escape reaches it.
    static func makeCalibrationWindow() -> NSPanel {
        let size = CGSize(width: GlossCalibration.tileSize.width * 2, height: GlossCalibration.tileSize.height * 2)
        let panel = GlossCalibrationPanel(contentRect: CGRect(origin: .zero, size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = calibrationTitle
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .white
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Any click on it gives it the keyboard, so Escape works after one.
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = calibrationLevel
        panel.collectionBehavior = [.fullScreenAuxiliary]
        let view = GlossCalibrationView(frame: CGRect(origin: .zero, size: size))
        panel.contentView = view
        panel.initialFirstResponder = view
        return panel
    }

    /// The sheet's window: clear, floating, never key, moved by its background.
    static func makeSheetWindow() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: GlossMatch.cellSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = sheetTitle
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
        let host = NSHostingView(rootView: GlossMatchView(lab: .shared))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The backdrop's level: one under the lab's floating windows.
    static let calibrationLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// The backdrop's "Close calibration": both windows go, since the
    /// sheet's other switch is in the lab's window, which lies under the
    /// backdrop.
    static func closeBoth(_ lab: GlossLab) {
        lab.calibration = false
        lab.match = false
    }

    /// Whether the sheet moves by its background: not over the backdrop,
    /// where a drag takes the copies off the part of the pattern they are
    /// measured over.
    static func sheetMoves(calibrating: Bool) -> Bool { !calibrating }

    /// The backdrop's frame on a screen: its visible part (under the menu
    /// bar, clear of the Dock), on whole points.
    static func calibrationFrame(visible: CGRect) -> CGRect { visible.integral }

    private func apply() {
        let lab = GlossLab.shared
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? screenFrame
        if lab.calibration {
            let window = calibrationWindow ?? Self.makeCalibrationWindow()
            let view = window.contentView as? GlossCalibrationView
            let isNew = calibrationWindow == nil
            if isNew {
                calibrationWindow = window
                startSession(lab, view: view)
            }
            view?.pattern = lab.calibrationPattern
            window.setFrame(Self.calibrationFrame(visible: visible), display: true)
            window.orderFrontRegardless()
            // The keyboard at once, so Escape works before any click.
            if isNew { window.makeKey() }
        } else {
            endSession()
            calibrationWindow?.orderOut(nil)
            calibrationWindow = nil
        }
        if lab.match {
            let window = sheetWindow ?? Self.makeSheetWindow()
            if sheetWindow == nil {
                sheetWindow = window
                moveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.writeCheckFile(GlossLab.shared) }
                }
            }
            let sheet = GlossMatch.sheet(for: lab)
            let frame = GlossMatch.sheetFrame(sheet, corner: GlossMatch.corner(lab.matchOrigin), screen: screenFrame, visible: visible)
            // Placed again only when its size or its corner's text changed,
            // so a sheet dragged elsewhere stays there while values change.
            let placing = "\(NSStringFromSize(frame.size)) \(lab.matchOrigin)"
            if placedFor != placing {
                placedFor = placing
                window.setFrame(frame, display: true)
            }
            window.isMovableByWindowBackground = Self.sheetMoves(calibrating: lab.calibration)
            window.orderFrontRegardless()
        } else {
            if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
            moveObserver = nil
            placedFor = nil
            sheetWindow?.orderOut(nil)
            sheetWindow = nil
        }
        writeCheckFile(lab)
    }

    /// The backdrop is up: its closing time starts, Escape is claimed
    /// (from every app, and by a watch on our own windows' keys), and its
    /// controls are wired. Every way down goes through the session, which
    /// turns both switches off.
    private func startSession(_ lab: GlossLab, view: GlossCalibrationView?) {
        let session = GlossCalibrationSession(timeout: lab.calibrationTimeout, now: Date(), escapeKey: escapeKey) { [weak self] reason in
            self?.lastClose = "\(reason.rawValue) \(GlossMatchWindows.clockText(Date()))"
            GlossMatchWindows.closeBoth(.shared)
        }
        self.session = session
        lastClose = nil
        view?.onClose = { [weak session] in session?.end(.button) }
        view?.onEscape = { [weak session] in session?.end(.escape) }
        view?.onClick = { [weak session] in session?.clicked(Date()) }
        view?.onPattern = { GlossLab.shared.calibrationPattern = $0 }
        view?.bar.remaining = session.tick(Date())
        let clock = Timer(timeInterval: 1, repeats: true) { [weak session, weak view] _ in
            MainActor.assumeIsolated {
                guard let session else { return }
                view?.bar.remaining = session.tick(Date())
            }
        }
        // In the common modes, so it also runs while a control is tracked.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak session] event in
            let taken = MainActor.assumeIsolated {
                guard GlossMatchWindows.isEscape(event), let session, session.ended == nil else { return false }
                session.end(.escape)
                return true
            }
            return taken ? nil : event
        }
    }

    /// The backdrop is down: the clock and the key watch stop, and Escape
    /// is given back if the session has not done so already.
    private func endSession() {
        clock?.invalidate()
        clock = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        session?.end(.switchedOff)
        if let session, session.ended == .switchedOff, lastClose == nil {
            lastClose = "\(GlossCalibrationSession.Reason.switchedOff.rawValue) \(GlossMatchWindows.clockText(Date()))"
        }
        session = nil
    }

    static func clockText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// The backdrop's line of the check file.
    static func calibrationCheckLine(pattern: GlossLab.CalibrationPattern, frame: CGRect, scale: CGFloat, level: Int,
                                     escapeClaim: String, timeout: Double) -> String {
        "calibration=on pattern=\(pattern.rawValue) frame=\(NSStringFromRect(frame)) "
            + "scale=\(scale) tile=\(NSStringFromSize(GlossCalibration.tileSize)) "
            + "cell=\(Int(GlossCalibration.cell)) level=\(level) escapeKey=\(escapeClaim) closesAfter=\(Int(timeout.rounded()))s"
    }

    /// The two windows' state as text: whether each is up, its frame and
    /// scale, where the first copy's pieces stand, and every copy as it
    /// was understood.
    func checkText(_ lab: GlossLab) -> String {
        var lines: [String] = []
        if let window = calibrationWindow {
            lines.append(Self.calibrationCheckLine(pattern: lab.calibrationPattern, frame: window.frame, scale: window.backingScaleFactor,
                                                   level: window.level.rawValue, escapeClaim: session?.escapeClaim ?? "none",
                                                   timeout: session?.watch.timeout ?? lab.calibrationTimeout))
        } else {
            lines.append("calibration=off" + (lastClose.map { " closed=\($0)" } ?? ""))
        }
        if let window = sheetWindow {
            let sheet = GlossMatch.sheet(for: lab)
            let screen = (window.screen ?? NSScreen.main)?.frame ?? .zero
            let inset = GlossMatch.inset(sheet)
            let first = CGPoint(x: window.frame.minX - screen.minX + inset.x, y: screen.maxY - window.frame.maxY + inset.y)
            lines.append("match=on mode=\(sheet.walk ? "walk" : "copies") count=\(sheet.copies.count) frame=\(NSStringFromRect(window.frame)) "
                         + "scale=\(window.backingScaleFactor) firstCornerFromScreenTopLeft=\(NSStringFromPoint(first)) "
                         + "pitch=\(sheet.walk ? NSStringFromSize(GlossMatch.walkCell) : "\(GlossMatch.pitch)") "
                         + "appleBlur=\(GlossBackdropGround.isAvailable)")
            lines.append(contentsOf: sheet.copies.map(GlossMatch.checkText))
        } else {
            lines.append("match=off")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func writeCheckFile(_ lab: GlossLab) {
        // Nothing is written while neither was ever shown.
        guard calibrationWindow != nil || sheetWindow != nil || checkWritten != nil else { return }
        let text = checkText(lab)
        guard text != checkWritten else { return }
        checkWritten = text
        try? text.write(to: GlossMatch.checkFileURL, atomically: true, encoding: .utf8)
    }
}
#endif
