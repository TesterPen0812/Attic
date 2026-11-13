import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Signals when SwiftUI has evaluated the next Appearance state. The test
/// then forces the hosted layout/display candidate; no onscreen frame is used.
@MainActor
private struct SettingsHuntFrameProbe: View {
    @ObservedObject var settings: AppSettings
    let content: SettingsView
    let onCandidate: (TimeInterval) -> Void

    private var appearanceSignature: String {
        [settings.appearance.rawValue, settings.panelTheme.rawValue,
         settings.panelSurfaceStyle.rawValue, settings.panelTint.rawValue,
         String(settings.brightenGlass), String(settings.panelTintLength)]
            .joined(separator: "/")
    }

    var body: some View {
        content.onChange(of: appearanceSignature) { _, _ in
            onCandidate(ProcessInfo.processInfo.systemUptime)
        }
    }
}

/// The Settings window as AppKit really lays it out: its traffic lights
/// sit on the page title's line, keep the system's spacing, still take
/// clicks there, and stay put through resizes.
@MainActor
final class SettingsWindowHostedTests: XCTestCase {
    private var window: SettingsWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testSettingsHuntHostedNavigationReadsTheScratchSuite() throws {
        let suite = "SettingsHuntNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let outsideBefore = UserDefaults.standard.object(forKey: SettingsSection.selectionStorageKey) as? String
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)

        for selected in [SettingsSection.appearance, .panel] {
            defaults.set(selected.rawValue, forKey: SettingsSection.selectionStorageKey)
            XCTAssertEqual(SettingsNavigation(defaults: defaults).selection, selected)
            let host = NSHostingView(rootView: SettingsView(
                settings: AppSettings(defaults: defaults, motionLabAvailable: false),
                loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
                agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
                globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
            let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 860, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            spin(0.3)
            host.layoutSubtreeIfNeeded()

            func find(_ element: AnyObject, id: String, visited: inout Set<ObjectIdentifier>) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
                if element.accessibilityIdentifier?() == id { return element }
                for child in (element.accessibilityChildren?() ?? nil) ?? [] {
                    if let match = find(child as AnyObject, id: id, visited: &visited) { return match }
                }
                return nil
            }
            var visited = Set<ObjectIdentifier>()
            // The page identifier is on a mask-wrapped ScrollView, which
            // AppKit omits from the AX tree. Read controls unique to the
            // actual page instead of mistaking a missing scroll AX node for
            // the wrong navigation selection.
            let expectedID = selected == .appearance ? "setting-appearance-system" : "setting-reveal-on-hover"
            let otherID = selected == .appearance ? "setting-reveal-on-hover" : "setting-appearance-system"
            let found = find(host, id: expectedID, visited: &visited) != nil
            visited.removeAll()
            let wrongPageVisible = find(host, id: otherID, visited: &visited) != nil
            if !found {
                var seen = Set<ObjectIdentifier>()
                func snapshot(_ element: AnyObject, depth: Int) {
                    guard depth < 24, seen.insert(ObjectIdentifier(element)).inserted else { return }
                    if let id = element.accessibilityIdentifier?() {
                        print("SETTINGS_NAV_AX selected=\(selected.rawValue) depth=\(depth) id=\(id) label=\(element.accessibilityLabel?() ?? "")")
                    }
                    for child in (element.accessibilityChildren?() ?? nil) ?? [] {
                        snapshot(child as AnyObject, depth: depth + 1)
                    }
                }
                snapshot(host, depth: 0)
            }
            // A click must write the same scratch suite used for the initial
            // selection, and the resulting page must update immediately.
            let next = selected == .appearance ? SettingsSection.panel : .appearance
            visited.removeAll()
            let nextSidebarRow = find(host, id: next.accessibilityIdentifier, visited: &visited)
            XCTAssertTrue(nextSidebarRow?.accessibilityPerformPress?() ?? false)
            spin(0.2)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(SettingsNavigation(defaults: defaults).selection, next)
            visited.removeAll()
            XCTAssertNotNil(find(host, id: otherID, visited: &visited),
                            "The newly selected Settings page must appear in the hosted control tree")
            XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsSection.selectionStorageKey) as? String,
                           outsideBefore, "Switching a scratch Settings page must not change standard defaults")
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            XCTAssertTrue(found, "A hosted SettingsView must show \(expectedID) for \(selected.rawValue)")
            XCTAssertFalse(wrongPageVisible, "The old Settings page must not remain in the hosted control tree")
        }
        XCTAssertEqual(UserDefaults.standard.object(forKey: SettingsSection.selectionStorageKey) as? String,
                       outsideBefore, "A scratch Settings window must not write its navigation to standard defaults")
    }

    /// Elapsed time from a setting change to SwiftUI's next observed
    /// Appearance update plus an offscreen layout/display candidate. This
    /// cannot establish actual display or compositor presentation latency.
    func testSettingsHuntAppearanceToNextHostedFrameCandidate() throws {
        let suite = "SettingsHuntFrame.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SettingsSection.appearance.rawValue, forKey: SettingsSection.selectionStorageKey)
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        // Prime the last value of each group before hosting. The first
        // measured choice must be a real change, including on a fresh suite.
        settings.appearance = try XCTUnwrap(AppearancePreference.allCases.last)
        settings.panelTheme = try XCTUnwrap(AtticPanelTheme.allCases.last)
        settings.panelSurfaceStyle = try XCTUnwrap(PanelSurfaceStyle.allCases.last)
        settings.panelTint = try XCTUnwrap(PanelTintLevel.allCases.last)
        var candidateTimes: [TimeInterval] = []
        let content = SettingsView(
            settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil)
        let host = NSHostingView(rootView: SettingsHuntFrameProbe(
            settings: settings, content: content, onCandidate: { candidateTimes.append($0) }))
        let window = NSWindow(contentRect: CGRect(x: -6_000, y: -6_000, width: 860, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        spin(0.1)

        var samples: [String: [Double]] = [:]
        func measure(_ choice: String, _ action: () -> Void) {
            let previousCandidates = candidateTimes.count
            let start = ProcessInfo.processInfo.systemUptime
            action()
            let deadline = Date().addingTimeInterval(1)
            while candidateTimes.count == previousCandidates && Date() < deadline {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            XCTAssertGreaterThan(candidateTimes.count, previousCandidates,
                                 "SwiftUI must observe Appearance mutation \(choice) in the hosted frame")
            guard candidateTimes.count > previousCandidates else { return }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let durationMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            XCTAssertTrue(durationMS.isFinite && durationMS >= 0)
            samples[choice, default: []].append(durationMS)
        }

        for _ in 0..<5 {
            for mode in AppearancePreference.allCases {
                measure("mode.\(mode.rawValue)") { settings.appearance = mode }
            }
            for theme in AtticPanelTheme.allCases {
                measure("palette.\(theme.rawValue)") { settings.panelTheme = theme }
            }
            for surface in PanelSurfaceStyle.allCases {
                measure("surface.\(surface.rawValue)") { settings.panelSurfaceStyle = surface }
            }
            for tint in PanelTintLevel.allCases {
                measure("tint.\(tint.rawValue)") { settings.panelTint = tint }
            }
            for enabled in [true, false] {
                measure("brighten.\(enabled)") { settings.brightenGlass = enabled }
            }
            for length in [0.3, 0.65, 1.0] {
                measure("tintLength.\(length)") { settings.panelTintLength = length }
            }
        }
        for key in samples.keys.sorted() {
            let ordered = try XCTUnwrap(samples[key]).sorted()
            guard ordered.count == 5 else {
                XCTFail("Expected five genuine Appearance transitions for \(key), got \(ordered.count)")
                continue
            }
            let median = ordered[2]
            let p95 = ordered[4]
            print(String(format: "SETTINGS_FRAME_CANDIDATE kind=%@ n=5 median_ms=%.3f p95_ms=%.3f",
                         key, median, p95))
        }
    }

    /// Accessibility of each Settings page's hosted controls; the earlier
    /// appearance/defaults audit did not exercise VoiceOver's control tree.
    func testA11yEverySettingsSectionNamesItsInteractiveControls() throws {
        // Navigation follows the isolated AppSettings suite, so visiting
        // About cannot change another test's starting page.
        let suite = "SettingsAX.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let host = NSHostingView(rootView: SettingsView(
            settings: AppSettings(defaults: defaults),
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 860, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let roles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton",
                                  "AXComboBox", "AXTextField", "AXTextArea", "AXSlider", "AXLink", "AXSwitch"]
        func descendants(_ node: AnyObject, visited: inout Set<ObjectIdentifier>) -> [AnyObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            var result: [AnyObject] = [node]
            for child in (node.accessibilityChildren?() ?? nil) ?? [] {
                result.append(contentsOf: descendants(child as AnyObject, visited: &visited))
            }
            return result
        }
        func externalScrollbarsAreHidden() -> Bool {
            var found = false
            var allHidden = true
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 25 else { return }
                var rawRole: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
                   rawRole as? String == kAXScrollBarRole as String {
                    found = true
                    var hidden: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXHiddenAttribute as CFString, &hidden) != .success ||
                       hidden as? Bool != true { allHidden = false }
                }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else {
                    return
                }
                for child in (children as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
            }
            visit(AXUIElementCreateApplication(getpid()), depth: 0)
            return found && allHidden
        }
        for section in SettingsSection.allCases {
            host.layoutSubtreeIfNeeded()
            spin(0.12)
            var visited = Set<ObjectIdentifier>()
            let before = descendants(host, visited: &visited)
            let row = try XCTUnwrap(before.first { $0.accessibilityIdentifier?() == section.accessibilityIdentifier },
                                    "Settings sidebar exposes \(section.rawValue)")
            XCTAssertTrue(row.accessibilityPerformPress?() ?? false, "Settings can switch to \(section.rawValue) through AX")
            spin(0.15)
            visited.removeAll()
            let after = descendants(host, visited: &visited)
            // AppKit reports four NSAccessibilityScrollerPart pseudo-buttons
            // even while their parent scrollbar has AXHidden=true. They are
            // not reachable controls; require that state from an external AX
            // client before excluding only those system-created parts.
            let hiddenParts = after.filter { String(describing: type(of: $0)) == "NSAccessibilityScrollerPart" }
            if !hiddenParts.isEmpty {
                // AppKit can publish its private scroller parts before the
                // external AX client sees the containing scrollbar's hidden
                // state. Require that actual state, not a fixed paint delay.
                let deadline = Date().addingTimeInterval(2)
                var scrollbarsHidden = externalScrollbarsAreHidden()
                while !scrollbarsHidden && Date() < deadline {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                    host.layoutSubtreeIfNeeded()
                    scrollbarsHidden = externalScrollbarsAreHidden()
                }
                XCTAssertTrue(scrollbarsHidden,
                              "native scrollbar buttons may be excluded only while the AX scrollbar is hidden")
            }
            let interactive = after.filter {
                roles.contains($0.accessibilityRole?()?.rawValue ?? "") &&
                String(describing: type(of: $0)) != "NSAccessibilityScrollerPart"
            }
            let missing = interactive.filter {
                ($0.accessibilityLabel?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map { "\($0.accessibilityRole?()?.rawValue ?? "?") \($0.accessibilityIdentifier?() ?? "")" }
            print("A11Y_SETTINGS section=\(section.rawValue) interactive=\(interactive.count) hiddenNativeScrollParts=\(hiddenParts.count) missing=\(missing)")
            XCTAssertFalse(interactive.isEmpty, "Settings has accessible controls on \(section.rawValue)")
            XCTAssertTrue(missing.isEmpty, "\(section.rawValue) has unnamed controls: \(missing)")
        }
    }

    func testR24ScrollContentFillsWideShortAndNarrowTallHost() throws {
        let suite = "SettingsR24.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let settings = AppSettings(defaults: defaults)
        let host = NSHostingView(rootView: SettingsView(
            settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 860, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI creates the native scroll hierarchy when the hosting
        // window is presented. Keep the test window off-screen, as in UX2,
        // but make it visible to AppKit before looking for NSScrollView.
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        for size in [CGSize(width: 860, height: 420), CGSize(width: 580, height: 650)] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            spin(0.2)
            host.layoutSubtreeIfNeeded()
            // The native hierarchy is created by the hosted draw as well as
            // layout; on CI the initial layout can complete before SwiftUI
            // has handed its ScrollView to AppKit.
            window.displayIfNeeded()
            // On a slower hosted runner the NSHostingView can publish its
            // first native ScrollView after the initial layout pass.
            let deadline = Date().addingTimeInterval(2)
            var candidate = scrollViews(in: host).first { abs($0.frame.width - size.width) < 2 }
            while candidate == nil && Date() < deadline {
                spin(0.05)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                candidate = scrollViews(in: host).first { abs($0.frame.width - size.width) < 2 }
            }
            let scroll = try XCTUnwrap(candidate,
                                       "The undersized Settings host must offer scrolling")
            let content = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThanOrEqual(content.frame.width, max(640, size.width) - 2,
                                        "Sidebar background and page card must fill the wide host")
            XCTAssertGreaterThanOrEqual(content.frame.height, max(460, size.height) - 2,
                                        "Content must fill the tall host without leaving a bare strip")
        }
    }

    func testR24ScrollThresholdDoesNotRemountPageLocalState() {
        var appearances = 0
        let host = NSHostingView(rootView: GeometryReader { available in
            SettingsAdaptiveScroll(size: available.size) {
                Text("Settings page state")
                    .onAppear { appearances += 1 }
            }
        })
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 860, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for size in [CGSize(width: 860, height: 650), CGSize(width: 860, height: 420),
                     CGSize(width: 580, height: 650), CGSize(width: 860, height: 650)] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            spin(0.05)
            XCTAssertEqual(appearances, 1, "Changing the scroll threshold must keep the current Settings page mounted")
        }
    }

    func testUX2DefaultWindowKeepsSettingsContentWithinViewport() throws {
        // The viewport assertion targets General's controls; an earlier AX
        // navigation test cannot affect this fresh scratch suite.
        let suite = "SettingsUX2.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let settings = AppSettings(defaults: defaults)
        let host = NSHostingView(rootView: SettingsView(
            settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
            globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6_000, y: -6_000),
                                                  size: SettingsWindowLayout.preferredContentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        spin(0.3)

        func elements(_ root: AnyObject) -> [AnyObject] {
            [root] + ((root.accessibilityChildren?() ?? nil) ?? []).flatMap { elements($0 as AnyObject) }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        func element(_ id: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            return elements(host).first { $0.accessibilityIdentifier?() == id }
        }
        func frame(_ id: String) throws -> CGRect {
            let item = try XCTUnwrap(element(id), "\(id) should appear in the page")
            return try XCTUnwrap((item as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        }
        func assertContentFits(_ identifiers: [String], at size: CGSize) throws {
            host.layoutSubtreeIfNeeded()
            spin(0.1)
            host.layoutSubtreeIfNeeded()
            for id in identifiers {
                let bounds = try frame(id)
                XCTAssertGreaterThan(bounds.width, 0, "\(id) is laid out")
                XCTAssertGreaterThanOrEqual(bounds.minX, window.frame.minX + AtticLayout.settingsSidebarWidth - 2,
                                            "\(id) stays clear of the sidebar at \(size): \(bounds)")
                XCTAssertLessThanOrEqual(bounds.maxX, window.frame.maxX - AtticSpacing.settingsCardInset + 2,
                                         "\(id) fits inside the page at \(size): \(bounds)")
            }
        }

        for size in [SettingsWindowLayout.preferredContentSize, SettingsWindowLayout.minimumContentSize] {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(in: host).first { abs($0.frame.width - size.width) < 2 })
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 2,
                                     "No horizontal Settings content beyond \(size)")
            try assertContentFits(["setting-launch-at-login", "setting-animations", "setting-hide-animation",
                                   "setting-quick-capture-shortcut"], at: size)
            // The offscreen NSWindow can be repositioned by AppKit during an
            // appearance change. Compare sidebar position inside the window,
            // so real horizontal content movement still fails this test.
            let sidebarBefore = try frame("settings-nav-general").minX - window.frame.minX
            let appearance = try XCTUnwrap(element("settings-nav-appearance"))
            XCTAssertTrue(appearance.accessibilityPerformPress?() ?? false)
            try assertContentFits(["setting-appearance-preview", "setting-appearance-system",
                                   "setting-appearance-light", "setting-appearance-dark",
                                   "setting-panel-surface", "setting-panel-theme"], at: size)
            let dark = try XCTUnwrap(element("setting-appearance-dark"))
            XCTAssertTrue(dark.accessibilityPerformPress?() ?? false)
            try assertContentFits(["setting-appearance-system", "setting-appearance-light",
                                   "setting-appearance-dark", "setting-panel-theme"], at: size)
            XCTAssertEqual(try frame("settings-nav-general").minX - window.frame.minX, sidebarBefore, accuracy: 0.5,
                           "Choosing Dark must not scroll the sidebar horizontally")
            let general = try XCTUnwrap(element("settings-nav-general"))
            XCTAssertTrue(general.accessibilityPerformPress?() ?? false)
        }
    }

    private func makeWindow() -> SettingsWindow {
        let window = SettingsWindow(contentViewController: NSHostingController(rootView: Color.clear))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsWindowLayout.preferredContentSize)
        window.orderFront(nil)
        self.window = window
        spin()
        return window
    }

    /// Each button's centre, measured from the window's top-left, in points.
    private func centres(_ window: NSWindow) throws -> [CGPoint] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { type in
            let button = try XCTUnwrap(window.standardWindowButton(type))
            let rect = button.convert(button.bounds, to: nil)
            return CGPoint(x: rect.midX, y: window.frame.height - rect.midY)
        }
    }

    private func assertOnTitleLine(_ window: NSWindow, spacing expected: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
        let points = try centres(window)
        for point in points {
            XCTAssertEqual(point.y, SettingsChromeLayout.titleLineCenterY, accuracy: 0.5, "on the title line", file: file, line: line)
        }
        let spacing = points[1].x - points[0].x
        XCTAssertEqual(points[2].x - points[1].x, spacing, accuracy: 0.5, "even spacing", file: file, line: line)
        if let expected { XCTAssertEqual(spacing, expected, accuracy: 0.5, "the system's spacing is kept", file: file, line: line) }
        // The buttons still take clicks where they are drawn.
        let frameView = try XCTUnwrap(window.contentView?.superview)
        for (index, point) in points.enumerated() {
            let location = NSPoint(x: point.x, y: window.frame.height - point.y)
            let hit = frameView.hitTest(frameView.convert(location, from: nil))
            let button = window.standardWindowButton([.closeButton, .miniaturizeButton, .zoomButton][index])
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button!) == true, "button \(index) takes clicks", file: file, line: line)
        }
        return spacing
    }

    func testTrafficLightsSitOnTheTitleLineAndStayThroughResizes() throws {
        // AppKit's own spacing, from a plain window with the same style.
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.orderFront(nil)
        spin()
        let plainCentres = try centres(plain)
        let systemSpacing = plainCentres[1].x - plainCentres[0].x
        plain.orderOut(nil)
        plain.close()

        let window = makeWindow()
        XCTAssertNotEqual(plainCentres[0].y, SettingsChromeLayout.titleLineCenterY, "AppKit alone would put them elsewhere")
        _ = try assertOnTitleLine(window, spacing: systemSpacing)

        for size in [NSSize(width: 1_000, height: 780), SettingsWindowLayout.minimumContentSize, NSSize(width: 900, height: 700)] {
            window.setContentSize(size)
            window.contentView?.needsLayout = true
            window.layoutIfNeeded()
            spin(0.05)
            _ = try assertOnTitleLine(window, spacing: systemSpacing)
        }

        // Key and not key re-lay the title bar out too.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.placeTrafficLights()
        _ = try assertOnTitleLine(window, spacing: systemSpacing)
    }
}
