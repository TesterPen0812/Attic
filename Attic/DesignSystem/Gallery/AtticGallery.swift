#if DEBUG
import AppKit
import SwiftUI

/// The component gallery: preview builds only (`#if DEBUG`; Release has no
/// trace of it). Launch a preview with `--attic-gallery` to open it instead
/// of the panel, or `--attic-gallery --capture <dir>` to run the appearance
/// check and write the contact sheets, then quit. It changes nothing in the
/// app people use: without the argument this code never runs.
@MainActor
enum AtticGalleryLaunch {
    static let argument = "--attic-gallery"
    static let captureArgument = "--capture"
    /// Opens the keyboard lab instead of the full gallery: a few live task
    /// rows for keyboard UI tests (Tab, Shift-Tab, the task keys).
    static let keyboardLabArgument = "--attic-gallery-keyboard"
    /// Opens the menu lab: a title menu and a pop-up row, for UI tests that
    /// open the native menus in the running (activatable) app.
    static let menuLabArgument = "--attic-gallery-menus"

    /// Requested and allowed (`AppRuntimeEnvironment.galleryLaunch`): only
    /// preview identities and UI tests may open the gallery.
    static var isRequested: Bool {
        AppRuntimeEnvironment().galleryLaunch == .allowed
    }

    /// `--attic-gallery --glass-lab`: a key panel of flat surface swatches
    /// (Light on the left, Dark on the right), each with a real Liquid Glass
    /// control on it, for measuring what the glass does to every surface
    /// the panel can draw (`AtticGlassModel` is fitted to these
    /// measurements). Escape quits.
    static let glassLabArgument = "--glass-lab"
    /// `--attic-gallery --glass-lab-panels`: the live panel in Light and
    /// Dark, plain and on a palette's tinted Glass surface, with Liquid
    /// Glass controls (top row) and the Craft style (bottom row), its list
    /// scrolled under the header and the add bar. With `--stand-in`, real
    /// glass at rest above the capture stand-in. Escape quits.
    static let glassLabPanelsArgument = "--glass-lab-panels"

    static var captureDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: captureArgument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static var window: NSWindow?

    /// Opens the gallery (or runs the capture) when requested. Returns true
    /// when the gallery took over this launch.
    @discardableResult
    static func startIfRequested() -> Bool {
        guard isRequested else { return false }
        if let directory = captureDirectory {
            runCapture(into: directory)
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(glassLabPanelsArgument) {
            AtticGlassLab.openPanels(standIn: ProcessInfo.processInfo.arguments.contains("--stand-in"))
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(glassLabArgument) {
            AtticGlassLab.open()
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(keyboardLabArgument) {
            openLab(AnyView(AtticGalleryKeyboardLab()), title: "Attic Keyboard Lab", height: 240)
            return true
        }
        if TasksPagePreview.isRequested {
            // The Phase 1 Tasks page on its own (Attic/Tasks), in memory.
            TasksPagePreview.open()
            return true
        }
        if ProcessInfo.processInfo.arguments.contains(menuLabArgument) {
            openLab(AnyView(AtticGalleryMenuLab()), title: "Attic Menu Lab", height: 200)
            return true
        }
        open()
        return true
    }

    static func open() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Attic Component Gallery"
        window.identifier = NSUserInterfaceItemIdentifier("AtticComponentGallery")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: AtticGalleryView())
        window.center()
        window.setFrameAutosaveName("AtticComponentGallery")
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func openLab(_ root: AnyView, title: String, height: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(title)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Switching a menu-bar (accessory) app to a regular app during
        // launch can drop the first order-front: bring the window up again
        // once the policy change has landed.
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !window.isVisible || !window.isKeyWindow else { return }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }

    private static func runCapture(into directory: URL) {
        let target: URL
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            target = directory
        } catch {
            // The app is sandboxed: fall back to its own container.
            target = FileManager.default.temporaryDirectory.appendingPathComponent("AtticAppearance", isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        let sheets = AtticAppearanceCheck.writeContactSheets(to: target)
        // At 2×, where every glyph's own pixels are read; it passes only
        // when nothing failed and every eligible glyph was measured.
        let report = AtticAppearanceCheck.run(scale: 2)
        try? report.summary.write(to: target.appendingPathComponent("appearance-check.txt"), atomically: true, encoding: .utf8)
        let passed = report.passed
        print("Attic appearance check: \(passed ? "PASS" : "FAIL") — \(report.headline)")
        print("Contact sheets:\n" + sheets.map(\.path).joined(separator: "\n"))
        exit(passed ? 0 : 1)
    }
}

/// Live task rows on the panel surface, for keyboard UI tests: a palette
/// with a coloured accent (Electric Blue) so the focus ring is unmistakable
/// in screenshots, and the last action the keys fired, shown as text.
struct AtticGalleryKeyboardLab: View {
    @State private var demo = AtticGalleryDemo()

    static let context = AtticDesignContext(mode: .light, palette: .electricBlue)
    static let rows: [AtticTaskRowModel] = [
        .init(title: "Email beta testers", priority: .medium),
        .init(title: "Book dentist"),
        .init(title: "Renew domain", priority: .high)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.rows.enumerated()), id: \.element.id) { index, row in
                AtticTaskRow(model: row, actions: demo.taskActions(row.title), onToggleExpanded: demo.record("Toggle subtasks", row.title))
                    .accessibilityIdentifier("keyboard-lab-row-\(index)")
            }
            // Controls after the rows: a standalone status circle (its own
            // Tab stop, with Attic's ring) and a raised button.
            HStack(spacing: AtticSpacing.betweenControls) {
                AtticStatusButton(state: .todo, priority: .high, onAdvance: demo.record("Advance", "standalone circle"))
                    .accessibilityIdentifier("keyboard-lab-status")
                AtticRaisedButton(systemName: "pin", label: "Pin", action: demo.record("Pin"))
                    .accessibilityIdentifier("keyboard-lab-pin")
            }
            .padding(.leading, AtticLayout.circleX - (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2)
            .padding(.top, AtticSpacing.s8)
            Text(verbatim: demo.lastAction)
                .font(.caption)
                .foregroundStyle(Self.context.tokens.color(.helper))
                .padding(.leading, AtticLayout.textX)
                .padding(.top, AtticSpacing.s8)
                .accessibilityIdentifier("keyboard-lab-last-action")
            Spacer(minLength: 0)
        }
        .padding(.vertical, AtticSpacing.s12)
        .frame(width: 360, height: 240, alignment: .topLeading)
        .background(Self.context.tokens.panel.base.color)
        .atticDesign(Self.context)
    }
}

/// A title menu and a pop-up row on the panel surface, for UI tests that
/// open the native menus as a person does and pick an item.
struct AtticGalleryMenuLab: View {
    @State private var demo = AtticGalleryDemo()
    @State private var surface = "solid"

    var body: some View {
        VStack(alignment: .leading, spacing: AtticSpacing.s12) {
            AtticTitleMenu(title: "Launch sync", commands: [
                AtticMenuCommand("Duplicate", systemImage: "plus.square.on.square", shortcut: KeyboardShortcut("d", modifiers: .command), action: demo.record("Duplicate")),
                AtticMenuCommand("Delete", systemImage: "trash", isDestructive: true, startsSection: true, action: demo.record("Delete"))
            ])
            .accessibilityIdentifier("menu-lab-title")
            AtticGroupCard {
                AtticPopUpRow(label: "Surface", choices: [("solid", "Solid"), ("glass", "Glass")], selection: $surface)
                    .accessibilityIdentifier("menu-lab-popup")
            }
            Text(verbatim: "\(demo.lastAction) · \(surface)")
                .font(.caption)
                .accessibilityIdentifier("menu-lab-state")
        }
        .padding(AtticSpacing.s16)
        .frame(width: 360, height: 200, alignment: .topLeading)
        .background(AtticDesignContext.default.tokens.panel.base.color)
        .atticDesign(.default)
    }
}

/// The gallery window's content: families on the left, the live context
/// controls on top, the board on its stage below.
struct AtticGalleryView: View {
    @State private var family: AtticGalleryFamily = .panel
    @State private var context = AtticDesignContext.default
    @State private var demo = AtticGalleryDemo()
    @State private var pinnedState: AtticControlState?

    var body: some View {
        NavigationSplitView {
            List(AtticGalleryFamily.allCases, selection: $family) { family in
                Text(family.title).tag(family)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                AtticGalleryControls(context: $context, pinnedState: $pinnedState, demo: demo)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    AtticGalleryStage(family: family, demo: demo)
                        .atticForcedState(pinnedState)
                        .atticDesign(context)
                        .padding(40)
                }
                .background(AtticStandInWallpaper(dark: context.mode == .dark))
            }
            .navigationTitle(family.title)
        }
        // Native menus (Settings pop-ups, context menus) follow the chosen
        // mode, not the Mac's.
        .atticWindowAppearance(context.mode, appWide: true)
    }
}

/// Live switches for everything a combination can vary.
private struct AtticGalleryControls: View {
    @Binding var context: AtticDesignContext
    @Binding var pinnedState: AtticControlState?
    let demo: AtticGalleryDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Picker("Mode", selection: $context.mode) {
                    ForEach(AtticDesignContext.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                Picker("Surface", selection: $context.surface) {
                    ForEach(PanelSurfaceStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Picker("Controls", selection: $context.controls) {
                    ForEach(AtticControlMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                .help("What raised controls are made of, everywhere in the gallery. Reduce transparency always uses the Craft style.")
                Picker("Palette", selection: $context.palette) {
                    ForEach(AtticPanelTheme.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 210)
            }
            HStack(spacing: 14) {
                Picker("Tint", selection: $context.tint) {
                    ForEach(PanelTintLevel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                HStack(spacing: 6) {
                    Text("Tint length")
                    Slider(value: $context.tintLength, in: PanelTintLength.range).frame(width: 110)
                }
                Picker("Pin state", selection: $pinnedState) {
                    Text("Live").tag(AtticControlState?.none)
                    ForEach(AtticControlState.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .frame(width: 190)
            }
            HStack(spacing: 14) {
                Toggle("Increase contrast", isOn: $context.increaseContrast)
                Toggle("Reduce transparency", isOn: $context.reduceTransparency)
                Toggle("Reduce motion", isOn: $context.reduceMotion)
                Toggle("Differentiate without colour", isOn: $context.differentiateWithoutColor)
                Spacer()
                Text(verbatim: "Last action: \(demo.lastAction)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                let panel = context.tokens.panel
                Text(panel.kind == .solid ? "Solid" : "Coverage \(Int((panel.foundationOpacity * 100).rounded())) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }
}

/// A board on its stage: the panel surface (or, for Settings, the window
/// chrome) in the current context. In captures the surface is drawn over
/// the capture backdrop instead of the live desktop.
struct AtticGalleryStage: View {
    let family: AtticGalleryFamily
    @Bindable var demo: AtticGalleryDemo

    @Environment(\.atticDesign) private var design

    var body: some View {
        switch family.stage {
        case .settingsWindow:
            AtticGalleryBoard(family: family, demo: demo)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .panel where family == .panel:
            AtticGalleryBoard(family: family, demo: demo)
        case .panel:
            AtticGalleryBoard(family: family, demo: demo)
                .background(AtticSurfaceBackground(model: design.tokens.panel, shape: RoundedRectangle(cornerRadius: 20, style: .continuous), tintHeight: AtticLayout.panelSize.height))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.black.opacity(design.mode == .dark ? 0.5 : 0.10), lineWidth: 0.5))
        }
    }
}

/// Flat swatches with a real glass control on each (see `glassLabArgument`).
@MainActor
enum AtticGlassLab {
    static let tile = CGSize(width: 120, height: 64)
    static let columns = 8
    static let control = CGSize(width: 64, height: 32)
    private static var windows: [NSWindow] = []

    /// Every flat colour the panel can put under a control in `mode`: the
    /// neutral ladder, each palette's surface over every desktop, and each
    /// with the Bold tint at the content top (its strongest).
    static func swatches(_ mode: AtticDesignContext.Mode) -> [AtticRGBA] {
        var colours: [AtticRGBA] = (mode == .light ? [255, 250, 243, 232, 218, 200, 180, 150] : [0, 20, 32, 44, 60, 80, 100, 130]).map { AtticRGBA.grey(Double($0)) }
        for palette in AtticPanelTheme.allCases {
            for surface in PanelSurfaceStyle.allCases {
                for tint in [PanelTintLevel.off, .bold] {
                    let model = AtticDesignContext(mode: mode, palette: palette, surface: surface, tint: tint).tokens.panel
                    for desktop in (model.kind == .solid ? [.midGrey] : AtticSurfaceModel.Desktop.allCases) {
                        colours.append(model.composite(desktop, at: AtticSurfaceModel.contentTop))
                    }
                }
            }
        }
        var seen = Set<String>()
        return colours.filter { seen.insert($0.hexString).inserted }
    }

    /// One non-activating panel (it can be key without activating the app,
    /// as Attic's own panel is), Light swatches on the left and Dark on the
    /// right, each half in its own appearance. Glass draws its resting,
    /// key-window look only in a key window.
    static func open() {
        let halves = AtticDesignContext.Mode.allCases.map { mode -> NSHostingView<AnyView> in
            let view = NSHostingView(rootView: AnyView(AtticGlassLabGrid(colours: swatches(mode)).environment(\.colorScheme, mode.colorScheme)))
            view.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
            view.frame.size = view.fittingSize
            return view
        }
        let width = halves.reduce(0) { $0 + $1.frame.width }
        let height = halves.map(\.frame.height).max() ?? 0
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var x: CGFloat = 0
        for half in halves {
            half.frame.origin = NSPoint(x: x, y: height - half.frame.height)
            content.addSubview(half)
            x += half.frame.width
        }
        present(content)
        for mode in AtticDesignContext.Mode.allCases {
            FileHandle.standardError.write(Data(("glass-lab \(mode.rawValue) swatches " + swatches(mode).map(\.hexString).joined(separator: " ") + "\n").utf8))
        }
    }

    /// The contexts `openPanels` shows, left to right.
    static let panelContexts: [AtticDesignContext] = [
        AtticDesignContext(mode: .light),
        AtticDesignContext(mode: .dark),
        AtticDesignContext(mode: .light, palette: .porcelainVapor, surface: .glass, tint: .bold),
        AtticDesignContext(mode: .dark, palette: .midnightCobalt, surface: .glass, tint: .bold)
    ]

    /// With `standIn`, the top row is real glass at rest (nothing under the
    /// controls) and the bottom row the capture stand-in drawn live, for
    /// comparing the two on screen.
    static func openPanels(standIn: Bool = false) {
        let rows = AtticControlMaterial.allCases.map { material in
            HStack(spacing: 16) {
                ForEach(Array(panelContexts.enumerated()), id: \.offset) { _, base in
                    let context = withControls(base, standIn ? .liquidGlass : material)
                    let capture = standIn && material == .craft
                        ? AtticCaptureContext(collector: nil, backdrop: .wallpaper(.matchingMode)) : nil
                    AtticGalleryPanelComposition(demo: AtticGalleryDemo(), initialScroll: standIn ? 0 : 132)
                        .environment(AtticGalleryDemo())
                        .atticDesign(context)
                        .environment(\.atticCapture, capture)
                        .padding(8)
                        .background(AtticStandInWallpaper(dark: context.mode == .dark))
                }
            }
        }
        let view = NSHostingView(rootView: VStack(spacing: 16) { ForEach(0..<rows.count, id: \.self) { rows[$0] } }.padding(16).fixedSize())
        view.frame.size = view.fittingSize
        present(view)
    }

    private static func withControls(_ context: AtticDesignContext, _ controls: AtticControlMaterial) -> AtticDesignContext {
        var context = context
        context.controls = controls
        return context
    }

    private static func present(_ content: NSView) {
        let panel = AtticGlassLabPanel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setFrameTopLeftPoint(NSPoint(x: 20, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 20))
        panel.makeKeyAndOrderFront(nil)
        windows.append(panel)
    }
}

private final class AtticGlassLabPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

private struct AtticGlassLabGrid: View {
    let colours: [AtticRGBA]

    var body: some View {
        let lab = AtticGlassLab.self
        let radius = AtticRadius.control(height: lab.control.height)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<((colours.count + lab.columns - 1) / lab.columns), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<lab.columns, id: \.self) { column in
                        let index = row * lab.columns + column
                        ZStack {
                            (index < colours.count ? colours[index] : .clear).color
                            if index < colours.count {
                                Color.clear
                                    .frame(width: lab.control.width, height: lab.control.height)
                                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                            }
                        }
                        .frame(width: lab.tile.width, height: lab.tile.height)
                    }
                }
            }
        }
        .fixedSize()
    }
}
#endif
