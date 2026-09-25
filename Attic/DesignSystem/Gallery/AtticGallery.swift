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

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// `--attic-gallery --control-shapes <dir>`: renders the panel with
    /// each candidate control shape (1 continuous 32 %, 2 continuous 42 %,
    /// 3–5 superellipse with exponent 3, 4, 5) for the owner's
    /// comparison, then quits.
    static let controlShapesArgument = "--control-shapes"

    static var controlShapesDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: controlShapesArgument), index + 1 < arguments.count else { return nil }
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
        if let directory = controlShapesDirectory {
            let target = (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
                ? directory
                : FileManager.default.temporaryDirectory.appendingPathComponent("AtticControlShapes", isDirectory: true)
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let variants: [(String, AtticControlCorner)] = [
                ("1", .continuous), ("2", .continuousFraction(0.42)), ("3", .superellipse(exponent: 3)),
                ("4", .superellipse(exponent: 4)), ("5", .superellipse(exponent: 5))
            ]
            for (name, corner) in variants {
                AtticAppearanceCheck.writePanelRenders(to: target, corner: corner, suffix: "-\(name)")
            }
            print("Attic control shapes: \(target.path)")
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains(keyboardLabArgument) {
            openKeyboardLab()
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

    static func openKeyboardLab() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Attic Keyboard Lab"
        window.identifier = NSUserInterfaceItemIdentifier("AtticKeyboardLab")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AtticGalleryKeyboardLab())
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
        let report = AtticAppearanceCheck.run()
        try? report.summary.write(to: target.appendingPathComponent("appearance-check.txt"), atomically: true, encoding: .utf8)
        print("Attic appearance check: \(report.failures.isEmpty ? "PASS" : "FAIL") — \(report.headline)")
        print("Contact sheets:\n" + sheets.map(\.path).joined(separator: "\n"))
        exit(report.failures.isEmpty ? 0 : 1)
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
