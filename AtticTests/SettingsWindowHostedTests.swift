import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import Attic

/// Override only the preference getter for isolated Settings fixtures. An
/// existing scroll view must still be styled explicitly when the preference
/// changes: posting the notification alone does not restyle mounted views.
@MainActor
private enum SettingsScrollerPreference {
    private static let readings: (overlay: IMP, legacy: IMP) = {
        func getter(_ style: NSScroller.Style) -> IMP {
            let read: @convention(block) (AnyObject) -> Int = { _ in style.rawValue }
            return imp_implementationWithBlock(read)
        }
        return (getter(.overlay), getter(.legacy))
    }()

    static func install(_ style: NSScroller.Style) throws -> @MainActor () -> Void {
        let method = try XCTUnwrap(class_getClassMethod(NSScroller.self, #selector(getter: NSScroller.preferredScrollerStyle)))
        let previous = method_setImplementation(method, style == .legacy ? readings.legacy : readings.overlay)
        return { method_setImplementation(method, previous) }
    }
}

/// The external AX query is injectable so an unavailable tree cannot silently
/// become permission to exclude native scrollbar parts from the naming audit.
private struct SettingsScrollAXSnapshot {
    var found: Bool
    var allHidden: Bool
    var traversalSucceeded: Bool
    var hiddenErrors: [AXError]
}

private enum SettingsScrollAXGuard {
    static func permitsExclusion(visibleLegacyBar: Bool, read: () -> SettingsScrollAXSnapshot) -> Bool {
        let snapshot = read()
        let hidden = snapshot.found && snapshot.allHidden
        // Existing predicate, extracted unchanged for a red-first guard test.
        return visibleLegacyBar ? !hidden : hidden
    }
}

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

    private func withScrollerPreference(_ style: NSScroller.Style, check: () throws -> Void) throws {
        let previous = NSScroller.preferredScrollerStyle
        let restore = try SettingsScrollerPreference.install(style)
        defer {
            // Let outstanding TasksScrollKeeper restyles from a previously
            // mounted test host drain before replacing the global getter.
            spin(0.32)
            restore()
            XCTAssertEqual(NSScroller.preferredScrollerStyle, previous)
        }
        XCTAssertEqual(NSScroller.preferredScrollerStyle, style)
        try check()
    }

    private func nativeScrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(nativeScrollViews(in:))
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func ci8Elements(_ root: AnyObject) -> [AnyObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: AnyObject) -> [AnyObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            return [node] + ((node.accessibilityChildren?() ?? nil) ?? []).flatMap { walk($0 as AnyObject) }
        }
        return walk(root)
    }

    private func ci8Value(_ row: AnyObject?) -> String? {
        guard let row else { return nil }
        // SwiftUI's AccessibilityNode answers the selector without adopting
        // the full NSAccessibilityProtocol. Keep its actual spoken value.
        let value: String? = row.accessibilityValue?()
        return value
    }

    private func withCI8Host<V: View>(_ view: V, check: (NSHostingView<V>) throws -> Void) rethrows {
        print("CI8_HOST pid=\(getpid())")
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 650, height: 1400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        defer {
            AtticGlassMenu.testDriver = nil
            AtticGlassMenu.ordersCardsFront = true
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            NSApp.accessibilitySetValue(previous, forAttribute: enhanced)
        }
        AtticGlassMenu.ordersCardsFront = false
        host.layoutSubtreeIfNeeded()
        spin()
        try check(host)
    }

    /// CI8-AX: M-02 replaced the row's real button with a virtual menu
    /// button, losing its identifier and enabled state on macOS 26.
    func testCI8PopUpRowIsOneEnabledVoiceOverButton() throws {
        try withCI8Host(AtticPopUpRow(label: "Surface", choices: [("solid", "Solid"), ("glass", "Glass")],
                                    selection: .constant("solid"), identifier: "menu-lab-popup")) { host in
            let rows = ci8Elements(host).filter { $0.accessibilityLabel?() == "Surface" }
            XCTAssertEqual(rows.count, 1, "The entire pop-up row is one VoiceOver element")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.accessibilityRole?()?.rawValue, "AXButton")
            XCTAssertEqual(row.accessibilityIdentifier?(), "menu-lab-popup")
            XCTAssertEqual(row.isAccessibilityEnabled?(), true)
            XCTAssertEqual(ci8Value(row), "Solid")
        }
    }

    func testCI8GeneralAnimationsIsIdentifiableAndChooses() throws {
        let oldLevel = AtticMotionPreference.level
        let oldStyle = AtticReducedMotionStyle.current
        let oldTuning = AtticMotionTuning.current
        defer {
            AtticMotionPreference.level = oldLevel
            AtticReducedMotionStyle.current = oldStyle
            AtticMotionTuning.current = oldTuning
        }
        let suite = "CI8General.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        try withCI8Host(GeneralSettingsView(settings: settings,
            loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
            globalHotKey: GlobalHotKey(combination: .newTask))) { host in
            for level in AtticAnimationLevel.allCases {
                let row = try XCTUnwrap(ci8Elements(host).first { $0.accessibilityIdentifier?() == "setting-animations" },
                                       "Animations stays reachable on General")
                var opened = false
                AtticGlassMenu.testDriver = { menu in
                    opened = true
                    XCTAssertEqual(menu.commands.map(\.title), AtticAnimationLevel.allCases.map(\.title))
                    menu.choose(menu.commands.first { $0.title == level.title }!)
                }
                XCTAssertTrue(row.accessibilityPerformPress?() ?? false)
                spin()
                XCTAssertTrue(opened)
                XCTAssertEqual(settings.animations, level)
                let updated = ci8Elements(host).first { $0.accessibilityIdentifier?() == "setting-animations" }
                XCTAssertEqual(ci8Value(updated), level.title)
            }
        }
    }

    func testCI8AppearancePopUpsSurviveModeAndPaletteChanges() throws {
        let oldLevel = AtticMotionPreference.level
        let oldStyle = AtticReducedMotionStyle.current
        let oldTuning = AtticMotionTuning.current
        defer {
            AtticMotionPreference.level = oldLevel
            AtticReducedMotionStyle.current = oldStyle
            AtticMotionTuning.current = oldTuning
        }
        let suite = "CI8Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        try withCI8Host(AppearanceSettingsView(settings: settings)) { host in
            for mode in [AppearancePreference.dark, .light, .dark] {
                settings.appearance = mode
                for palette in AtticPanelTheme.allCases {
                    settings.panelTheme = palette
                    spin(0.02)
                    host.layoutSubtreeIfNeeded()
                    for style in PanelSurfaceStyle.allCases {
                        let row = try XCTUnwrap(ci8Elements(host).first { $0.accessibilityIdentifier?() == "setting-panel-surface" },
                                               "Surface remains reachable after \(mode)/\(palette)")
                        var opened = false
                        AtticGlassMenu.testDriver = { menu in
                            opened = true
                            XCTAssertEqual(menu.commands.map(\.title), PanelSurfaceStyle.allCases.map(\.title))
                            menu.choose(menu.commands.first { $0.title == style.title }!)
                        }
                        XCTAssertTrue(row.accessibilityPerformPress?() ?? false)
                        // The menu opens on the next turn of the run loop: wait for
                        // that, not a fixed 20 ms a loaded runner can miss.
                        waitForTestOperation("the glass menu opening after the press") { opened }
                        XCTAssertTrue(opened)
                        XCTAssertEqual(settings.panelSurfaceStyle, style)
                    }
                    XCTAssertEqual(ci8Elements(host).filter { $0.accessibilityIdentifier?() == "setting-panel-tint" }.count, 1)
                }
            }
        }
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
        // The full AX control-name audit is expensive; legacy specifically
        // exercises the native scroll-part guard that failed in CI.
        try withScrollerPreference(.legacy) { try checkA11yEverySettingsSectionNamesItsInteractiveControls() }
    }

    private func checkA11yEverySettingsSectionNamesItsInteractiveControls() throws {
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
        var axDiagnostic = ""
        func externalScrollbarsAreHidden() -> SettingsScrollAXSnapshot {
            var found = false
            var allHidden = true
            var traversalSucceeded = true
            var hiddenErrors: [AXError] = []
            func visit(_ element: AXUIElement, depth: Int) {
                guard depth < 25 else { return }
                var rawRole: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole) == .success,
                   rawRole as? String == kAXScrollBarRole as String {
                    found = true
                    var hidden: CFTypeRef?
                    let result = AXUIElementCopyAttributeValue(element, kAXHiddenAttribute as CFString, &hidden)
                    // With a native legacy NSScroller, AXHidden is often
                    // attributeUnsupported (-25205): that means *visible*,
                    // not hidden. Preserve the hidden assertion for overlays.
                    if result != .success || hidden as? Bool != true { allHidden = false }
                    if result != .success { hiddenErrors.append(result) }
                }
                var children: CFTypeRef?
                let childrenResult = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                if depth == 0 { axDiagnostic = "application children=\(childrenResult.rawValue) trusted=\(AXIsProcessTrusted())" }
                guard childrenResult == .success else {
                    if childrenResult != .attributeUnsupported { traversalSucceeded = false }
                    return
                }
                for child in (children as? [AXUIElement]) ?? [] { visit(child, depth: depth + 1) }
            }
            visit(AXUIElementCreateApplication(getpid()), depth: 0)
            return SettingsScrollAXSnapshot(found: found, allHidden: allHidden,
                                            traversalSucceeded: traversalSucceeded, hiddenErrors: hiddenErrors)
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
                // Native AppKit scrollbar parts have no app-owned labels.
                // Legacy bars are intended to stay visible and draggable;
                // they must never be forced through the overlay hidden guard.
                let visibleLegacyBar = nativeScrollViews(in: host).contains { scroll in
                    scroll.scrollerStyle == .legacy && (
                        (scroll.hasVerticalScroller && scroll.verticalScroller?.isHidden == false) ||
                        (scroll.hasHorizontalScroller && scroll.horizontalScroller?.isHidden == false)
                    )
                }
                // AppKit can publish its private scroller parts before the
                // external AX client sees the containing scrollbar's hidden
                // state. Require that actual state, not a fixed paint delay.
                var allowed = SettingsScrollAXGuard.permitsExclusion(visibleLegacyBar: visibleLegacyBar,
                                                                     read: externalScrollbarsAreHidden)
                if !visibleLegacyBar {
                    let deadline = Date().addingTimeInterval(2)
                    while !allowed && Date() < deadline {
                        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                        host.layoutSubtreeIfNeeded()
                        allowed = SettingsScrollAXGuard.permitsExclusion(visibleLegacyBar: false,
                                                                        read: externalScrollbarsAreHidden)
                    }
                }
                XCTAssertTrue(allowed, "Excluded native scrollbar parts require verified external AX state")
                print("CI6_SETTINGS_AX section=\(section.rawValue) \(axDiagnostic)")
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

    func testCIStandingAXGuardRejectsUnavailableTree() {
        XCTAssertFalse(SettingsScrollAXGuard.permitsExclusion(visibleLegacyBar: true) {
            SettingsScrollAXSnapshot(found: false, allHidden: true,
                                     traversalSucceeded: false, hiddenErrors: [])
        }, "A legacy scroller cannot turn a failed external traversal into a pass")
    }

    func testCIStandingAXGuardRejectsNonUnsupportedError() {
        XCTAssertFalse(SettingsScrollAXGuard.permitsExclusion(visibleLegacyBar: true) {
            SettingsScrollAXSnapshot(found: true, allHidden: false,
                                     traversalSucceeded: true, hiddenErrors: [.cannotComplete])
        }, "Only attributeUnsupported is allowed for a matched native legacy scrollbar")
    }

    func testR24ScrollContentFillsWideShortAndNarrowTallHost() throws {
        for style in [NSScroller.Style.overlay, .legacy] {
            try withScrollerPreference(style) { try checkR24ScrollContentFillsWideShortAndNarrowTallHost() }
        }
    }

    private func checkR24ScrollContentFillsWideShortAndNarrowTallHost() throws {
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
            print("CI6_SETTINGS_SIZE requested=\(size) window=\(window.contentLayoutRect.size) host=\(host.frame) scrolls=\(scrollViews(in: host).map(\.frame))")
            let scroll = try XCTUnwrap(candidate,
                                       "The undersized Settings host must offer scrolling")
            let content = try XCTUnwrap(scroll.documentView)
            XCTAssertEqual(scroll.frame.width, size.width, accuracy: 0.5)
            XCTAssertLessThanOrEqual(scroll.contentView.bounds.width, size.width + 0.5)
            XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle)
            if size.width >= SettingsWindowLayout.minimumContentSize.width {
                XCTAssertEqual(content.frame.width, scroll.contentView.bounds.width, accuracy: 1,
                               "At a wide host the page must follow the native clip, including its gutter")
            }
            XCTAssertGreaterThanOrEqual(content.frame.width,
                                        max(SettingsWindowLayout.minimumContentSize.width,
                                            scroll.contentView.bounds.width) - 2,
                                        "Sidebar background and page card must fill the available clip")
            XCTAssertEqual(content.frame.height,
                           max(SettingsWindowLayout.minimumContentSize.height, scroll.contentView.bounds.height),
                           accuracy: 0.5,
                           "Content must fill the native clip exactly, excluding the horizontal track")
        }
    }

    func testR24ScrollerPreferenceChangesKeepBothAxesAvailable() throws {
        let size = CGSize(width: 590, height: 390)
        let restoreOverlay = try SettingsScrollerPreference.install(.overlay)
        defer { spin(0.32); restoreOverlay() }
        let host = NSHostingView(rootView: GeometryReader { available in
            SettingsAdaptiveScroll(size: available.size) { Color.clear }
        })
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }

        func verify(_ size: CGSize, style: NSScroller.Style) throws {
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            spin(0.12)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let scroll = try XCTUnwrap(nativeScrollViews(in: host).first { $0.frame.height > 200 },
                                       "Settings retains the native outer scroll view")
            // Simulate AppKit's real preference restyle on the mounted scroll
            // view. A getter swizzle and notification by themselves do not.
            scroll.scrollerStyle = style
            scroll.layoutSubtreeIfNeeded()
            spin(0.05)
            let clip = scroll.contentView
            let document = try XCTUnwrap(scroll.documentView)
            let isHorizontallyClipped = document.frame.width > clip.bounds.width + 0.5
            XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle)
            XCTAssertEqual(scroll.frame.width, size.width, accuracy: 0.5,
                           "Native scroller gutters must not grow the SwiftUI host")
            XCTAssertLessThanOrEqual(clip.bounds.width, window.contentView!.bounds.width + 0.5)
            XCTAssertEqual(scroll.hasHorizontalScroller, isHorizontallyClipped,
                           "Horizontal scrolling must match clipping at \(size), \(style): document \(document.frame), clip \(clip.bounds)")
            XCTAssertTrue(scroll.hasVerticalScroller)
            if isHorizontallyClipped {
                clip.scroll(to: CGPoint(x: 0, y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
                let x = clip.bounds.origin.x
                clip.scroll(to: CGPoint(x: min(15, document.frame.width - clip.bounds.width),
                                        y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
                XCTAssertGreaterThan(clip.bounds.origin.x, x,
                                     "A wheel-less mouse must be able to reach the right edge")
            }
        }

        for currentStyle in [NSScroller.Style.overlay, .legacy, .overlay] {
            let restore = try SettingsScrollerPreference.install(currentStyle)
            defer { spin(0.32); restore() }
            for size in [CGSize(width: 590, height: 390), CGSize(width: 650, height: 400),
                         CGSize(width: 640, height: 400), CGSize(width: 630, height: 400)] {
                try verify(size, style: currentStyle)
            }
        }
    }

    /// CI-standing R-1: inspect the actual Appearance card against the inner
    /// native clip, rather than the outer window (which includes both gutters).
    func testCIStandingAppearanceCardsFitLegacyInnerClip() throws {
        try withScrollerPreference(.legacy) {
            let suite = "SettingsLegacyCards.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(SettingsSection.appearance.rawValue, forKey: SettingsSection.selectionStorageKey)
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            let store = TaskStore(container: container)
            let host = NSHostingView(rootView: SettingsView(
                settings: AppSettings(defaults: defaults),
                loginItemService: LoginItemService(readStatus: { .notRegistered }, changeRegistration: { _ in }),
                agentServer: AgentServer(port: 0, bearerToken: "test", handler: MCPRequestHandler(tools: AgentTaskTools(store: store))),
                globalHotKey: GlobalHotKey(combination: .newTask), library: nil))
            let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 640, height: 460),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

            for size in [CGSize(width: 640, height: 460), CGSize(width: 640, height: 400)] {
                window.setContentSize(size)
                host.frame = CGRect(origin: .zero, size: size)
                let deadline = Date().addingTimeInterval(2)
                repeat {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    spin(0.05)
                } while Date() < deadline
                // This is a layout fixture, not the live preference test.
                // Apply the style to mounted scroll views just as AppKit does.
                for scroll in nativeScrollViews(in: host) {
                    scroll.scrollerStyle = .legacy
                    scroll.tile()
                }
                host.layoutSubtreeIfNeeded()
                spin(0.32)
                host.layoutSubtreeIfNeeded()
                let elements = ci8Elements(host)
                func frame(_ id: String) throws -> CGRect {
                    let item = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id })
                    return try XCTUnwrap((item as? NSAccessibilityElementProtocol)?.accessibilityFrame())
                }
                let mode = try frame("setting-appearance")
                let palette = try frame("setting-panel-theme")
                let preview = try frame("setting-appearance-preview")
                let dark = try frame("setting-appearance-dark")
                let inner = try XCTUnwrap(nativeScrollViews(in: host).filter { $0.frame.height > 100 }
                    .min { $0.frame.width < $1.frame.width })
                let clip = window.convertToScreen(inner.contentView.convert(inner.contentView.bounds, to: nil))
                let outer = try XCTUnwrap(nativeScrollViews(in: host).first)
                XCTAssertLessThanOrEqual(inner.frame.width,
                                         outer.contentView.bounds.width - AtticLayout.settingsSidebarWidth
                                         - AtticSpacing.settingsCardInset + 0.5,
                                         "The inner scroll view, including its gutter, must stay inside the card viewport")
                XCTAssertEqual(inner.scrollerStyle, .legacy)
                print("CI_R1 size=\(size) mode=\(mode) palette=\(palette) preview=\(preview) dark=\(dark) clip=\(clip) inner=\(inner.frame) hasV=\(inner.hasVerticalScroller) hidden=\(String(describing: inner.verticalScroller?.isHidden)) all=\(nativeScrollViews(in: host).map { ($0.frame, $0.contentView.bounds) })")
                XCTAssertGreaterThan(mode.width, 0)
                XCTAssertLessThanOrEqual(dark.maxX, clip.maxX - AtticSpacing.settingsGroupInset + 0.5,
                                         "The final mode tile must remain inside the group inset")
                XCTAssertLessThanOrEqual(mode.maxX, clip.maxX - AtticSpacing.settingsGroupInset + 0.5,
                                         "Mode card keeps its trailing inset at \(size)")
                XCTAssertLessThanOrEqual(palette.maxX, clip.maxX - AtticSpacing.settingsGroupInset + 0.5)
                XCTAssertEqual(mode.width, preview.width, accuracy: 0.5,
                               "Mode card must match the full-width preview, not overflow the column")
            }
        }
    }

    /// CI-standing R-4 (pre-existing): the horizontal legacy track must
    /// consume viewport height, not create an otherwise unnecessary vertical range.
    func testR24LegacyHorizontalTrackDoesNotCreateVerticalOverflow() throws {
        try withScrollerPreference(.legacy) {
            let size = CGSize(width: 580, height: 650)
            let host = NSHostingView(rootView: GeometryReader { available in
                SettingsAdaptiveScroll(size: available.size) { Color.clear }
            })
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }

            let deadline = Date().addingTimeInterval(2)
            var scroll: NSScrollView?
            repeat {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                scroll = nativeScrollViews(in: host).first { $0.frame.height > 200 }
                spin(0.05)
            } while Date() < deadline
            let mounted = try XCTUnwrap(scroll)
            let document = try XCTUnwrap(mounted.documentView)
            XCTAssertEqual(mounted.scrollerStyle, .legacy)
            XCTAssertTrue(mounted.hasHorizontalScroller)
            XCTAssertGreaterThan(document.frame.width, mounted.contentView.bounds.width)
            XCTAssertLessThanOrEqual(document.frame.height, mounted.contentView.bounds.height + 0.5,
                                     "A horizontal legacy track must not create a spurious vertical scroll range")
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
        for style in [NSScroller.Style.overlay, .legacy] {
            try withScrollerPreference(style) { try checkUX2DefaultWindowKeepsSettingsContentWithinViewport() }
        }
    }

    private func checkUX2DefaultWindowKeepsSettingsContentWithinViewport() throws {
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
            // Appearance changes animate the page for 0.16 s. The first AX
            // frame during that transition can still describe the prior
            // scroll presentation. Wait for the actual sidebar to return to
            // its fixed offset; a lasting horizontal shift still fails.
            let deadline = Date().addingTimeInterval(2)
            var sidebarAfter = try frame("settings-nav-general").minX - window.frame.minX
            while abs(sidebarAfter - sidebarBefore) > 0.5 && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.008))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                sidebarAfter = try frame("settings-nav-general").minX - window.frame.minX
            }
            XCTAssertEqual(sidebarAfter, sidebarBefore, accuracy: 0.5,
                           "Choosing Dark must not scroll the sidebar horizontally")
            print("CI6_SETTINGS_DARK size=\(size) sidebar=\(sidebarBefore)->\(sidebarAfter) scroll=\(scroll.frame) clip=\(scroll.contentView.bounds) document=\(document.frame)")
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
