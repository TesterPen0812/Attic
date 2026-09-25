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

    /// `--attic-gallery --raised-controls <dir>`: renders the panel with the
    /// current raised controls and the Craft-matched candidates
    /// (`AtticRaisedCandidates`), Light and Dark, prints each candidate's
    /// control contrast, then quits. Capture only: no token changes.
    static let raisedControlsArgument = "--raised-controls"

    static var raisedControlsDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: raisedControlsArgument), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

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
        if let directory = raisedControlsDirectory {
            let target = (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
                ? directory
                : FileManager.default.temporaryDirectory.appendingPathComponent("AtticRaisedControls", isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            AtticAppearanceCheck.writePanelRenders(to: target, suffix: "-1")
            AtticAppearanceCheck.writePanelRenders(to: target, suffix: "-2", raised: AtticRaisedCandidates.craft)
            AtticAppearanceCheck.writePanelRenders(to: target, suffix: "-3", raised: AtticRaisedCandidates.craftStronger)
            let report = AtticRaisedCandidates.contrastReport()
            try? report.write(to: target.appendingPathComponent("raised-contrast.txt"), atomically: true, encoding: .utf8)
            print(report)
            print("Attic raised controls: \(target.path)")
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains(keyboardLabArgument) {
            openLab(AnyView(AtticGalleryKeyboardLab()), title: "Attic Keyboard Lab", height: 240)
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

/// Candidate raised-control looks translated from Craft's measured deltas
/// (owner references, sRGB): Light page 255, fill about 249–250 with a
/// white band inside the top edge, a 1 pt edge about 248 at the top, 240 on
/// the sides and 231 at the bottom, no shadow; Dark page about 91, fill
/// about +17, a bright 1 pt rim (+35 to +65 over the page, brightest at top
/// and bottom), no dark outer edge. Moved onto Attic's #FAFAFA and #2C2C2D
/// surfaces by the same deltas.
enum AtticRaisedCandidates {
    static func craft(_ mode: AtticDesignContext.Mode) -> AtticRaisedComparison {
        switch mode {
        case .light:
            AtticRaisedComparison(
                fill: .grey(245), sheenTop: .white(0.55), sheenBottom: .white(0.35),
                innerRimTop: .white(0.9), innerRimBottom: .white(0.6),
                edgeTop: .black(0.028), edgeMiddle: .black(0.04), edgeBottom: .black(0.09),
                shadow: .black(0.03), shadowRadius: 0.5, shadowY: 0.5
            )
        case .dark:
            AtticRaisedComparison(
                fill: .grey(44 + 17), sheenTop: .white(0.015), sheenBottom: .white(0.005),
                edgeTop: .white(0.24), edgeMiddle: .white(0.10), edgeBottom: .white(0.21)
            )
        }
    }

    static func craftStronger(_ mode: AtticDesignContext.Mode) -> AtticRaisedComparison {
        switch mode {
        case .light:
            AtticRaisedComparison(
                fill: .grey(243), sheenTop: .white(0.6), sheenBottom: .white(0.4),
                innerRimTop: .white(0.95), innerRimBottom: .white(0.7),
                edgeTop: .black(0.045), edgeMiddle: .black(0.065), edgeBottom: .black(0.12),
                shadow: .black(0.05), shadowRadius: 0.75, shadowY: 0.5
            )
        case .dark:
            AtticRaisedComparison(
                fill: .grey(44 + 21), sheenTop: .white(0.02), sheenBottom: .white(0.008),
                edgeTop: .white(0.30), edgeMiddle: .white(0.14), edgeBottom: .white(0.27)
            )
        }
    }

    /// Contrast of what sits on a raised control (the add bar's placeholder,
    /// the control glyphs and icons, the selected chip's label) on each
    /// candidate's face, at its middle and at its top and bottom sheen.
    static func contrastReport() -> String {
        var lines = ["Raised-control candidates: contrast on the control face (floor in brackets)"]
        let candidates: [(String, (AtticDesignContext.Mode) -> AtticRaisedComparison?)] = [
            ("1 current", { _ in nil }), ("2 Craft-matched", craft), ("3 Craft-matched stronger", craftStronger)
        ]
        for mode in AtticDesignContext.Mode.allCases {
            let tokens = AtticDesignContext(mode: mode).tokens
            for (name, candidate) in candidates {
                let faces: [AtticRGBA]
                if let recipe = candidate(mode) {
                    faces = [recipe.fill, recipe.sheenTop.over(recipe.fill), recipe.sheenBottom.over(recipe.fill)]
                } else {
                    let r = tokens.raised
                    faces = [r.face, r.sheenTop, r.sheenBottom].map { $0.over(tokens.controlBase) }
                }
                let checks: [(String, AtticInk, AtticRGBA?, Double)] = [
                    ("placeholder", .placeholder, nil, 3), ("glyph", .glyph, nil, 3), ("icon", .icon, nil, 3),
                    ("icon on chip hover", .icon, tokens.chipHover, 3), ("heading on selected chip", .heading, tokens.chipSelected, 4.5)
                ]
                let faceHex = faces.map { String(format: "%.0f", $0.red * 255) }.joined(separator: "/")
                var parts: [String] = []
                for (label, ink, overlay, floor) in checks {
                    let worst = faces.map { face in tokens.ink(ink).contrast(on: overlay.map { $0.over(face) } ?? face) }.min() ?? 0
                    parts.append(String(format: "%@ %.2f [%.1f]%@", label, worst, floor, worst < floor ? " FAIL" : ""))
                }
                lines.append("\(mode.title) \(name) (face mid/top/bottom \(faceHex)): " + parts.joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
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
#endif
