import AppKit
import SwiftData
import XCTest
@testable import Attic

/// Phase 1 follow-up, control audit item 10: Settings › Panel › Corner gets
/// Reveal on hover, a key to hold, and All or Selected Displays. The rule,
/// its persistence, the page's words, the agent settings, and the real
/// hover monitor honouring it (explicit opens are never affected).
@MainActor
final class CornerRevealSettingsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites.removeAll()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "CornerRevealSettingsTests.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    // MARK: - The rule

    func testTheRule() {
        var policy = CornerRevealPolicy()
        XCTAssertTrue(policy.reveals(displayID: "A", flags: []), "by default every corner answers, no key")
        XCTAssertTrue(policy.reveals(displayID: nil, flags: [.command]), "extra keys don't stop it")

        policy.modifier = .option
        XCTAssertFalse(policy.reveals(displayID: "A", flags: []), "the key must be held")
        XCTAssertFalse(policy.reveals(displayID: "A", flags: [.command]))
        XCTAssertTrue(policy.reveals(displayID: "A", flags: [.option]))
        XCTAssertTrue(policy.reveals(displayID: "A", flags: [.option, .shift]))
        XCTAssertTrue(policy.answers(displayID: "A"), "near the corner the monitor still samples: the key may come")

        policy.displays = .selected
        policy.selectedDisplayIDs = ["B"]
        XCTAssertFalse(policy.reveals(displayID: "A", flags: [.option]), "a display not chosen")
        XCTAssertFalse(policy.answers(displayID: "A"))
        XCTAssertTrue(policy.reveals(displayID: "B", flags: [.option]))
        XCTAssertFalse(policy.answers(displayID: nil), "a display with no identifier can't be chosen")

        policy.revealsOnHover = false
        XCTAssertFalse(policy.reveals(displayID: "B", flags: [.option]), "off: nothing answers hover")
        XCTAssertFalse(policy.answers(displayID: "B"))
    }

    func testModifierFlagsAndTitles() {
        XCTAssertEqual(RevealModifier.none.flags, [])
        XCTAssertEqual(RevealModifier.option.flags, .option)
        XCTAssertEqual(RevealModifier.control.flags, .control)
        XCTAssertEqual(RevealModifier.command.flags, .command)
        XCTAssertEqual(RevealModifier.shift.flags, .shift)
        XCTAssertEqual(RevealModifier.allCases.map(\.title), ["No key", "⌥ Option", "⌃ Control", "⌘ Command", "⇧ Shift"])
        XCTAssertEqual(RevealDisplays.allCases.map(\.title), ["All displays", "Selected displays"])
    }

    // MARK: - Persistence

    func testSettingsPersistAndDefault() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.revealOnHover, "on by default")
        XCTAssertEqual(settings.revealModifier, .none)
        XCTAssertEqual(settings.revealDisplays, .all)
        XCTAssertEqual(settings.revealDisplayIDs, [])
        XCTAssertEqual(settings.cornerRevealPolicy, CornerRevealPolicy())

        settings.revealOnHover = false
        settings.revealModifier = .control
        settings.revealDisplays = .selected
        settings.revealDisplayIDs = ["B", "A", "B", ""]
        XCTAssertEqual(settings.revealDisplayIDs, ["A", "B"], "unique, sorted, no empty ids")

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.revealOnHover)
        XCTAssertEqual(relaunched.revealModifier, .control)
        XCTAssertEqual(relaunched.revealDisplays, .selected)
        XCTAssertEqual(relaunched.revealDisplayIDs, ["A", "B"])
        XCTAssertEqual(relaunched.cornerRevealPolicy,
                       CornerRevealPolicy(revealsOnHover: false, modifier: .control, displays: .selected, selectedDisplayIDs: ["A", "B"]))

        defaults.set("sideways", forKey: "revealModifier")
        defaults.set("some", forKey: "revealDisplays")
        let corrupt = AppSettings(defaults: defaults)
        XCTAssertEqual(corrupt.revealModifier, .none, "an unknown value falls back")
        XCTAssertEqual(corrupt.revealDisplays, .all)
    }

    func testPanelDismissModeDefaultsPersistsAndRejectsUnknownStoredValues() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        // Owner, 5 Nov (Planning.md Accepted): an unpinned panel goes away on a click off it.
        XCTAssertEqual(settings.panelDismissMode, .clickAway)
        XCTAssertEqual(PanelDismissMode.allCases.map(\.title), ["Move cursor away", "Click away"])
        settings.panelDismissMode = .moveCursorAway
        XCTAssertEqual(AppSettings(defaults: defaults).panelDismissMode, .moveCursorAway)
        defaults.set("unknown", forKey: "panelDismissMode")
        XCTAssertEqual(AppSettings(defaults: defaults).panelDismissMode, .clickAway)
    }

    // MARK: - Agent settings

    func testAgentsReadAndChangeTheRuleAsOneStep() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let undo = UndoRoute()
        let tools = AgentSettingsTools(settings: settings, undo: undo)
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(tools.call(name: "get_settings", arguments: [:]).utf8)) as? [String: Any])
        XCTAssertEqual(before["reveal_on_hover"] as? Bool, true)
        XCTAssertEqual(before["reveal_modifier"] as? String, "none")
        XCTAssertEqual(before["reveal_displays"] as? String, "all")
        XCTAssertNotNil(before["displays"] as? [[String: Any]], "the connected displays, read only")

        _ = try tools.call(name: "update_settings", arguments: [
            "reveal_on_hover": false, "reveal_modifier": "command", "reveal_displays": "selected", "reveal_display_ids": ["X", "X"]
        ])
        XCTAssertFalse(settings.revealOnHover)
        XCTAssertEqual(settings.revealModifier, .command)
        XCTAssertEqual(settings.revealDisplays, .selected)
        XCTAssertEqual(settings.revealDisplayIDs, ["X"])
        XCTAssertTrue(undo.undo(in: .library), "one step")
        XCTAssertTrue(settings.revealOnHover)
        XCTAssertEqual(settings.revealModifier, .none)
        XCTAssertEqual(settings.revealDisplays, .all)
        XCTAssertEqual(settings.revealDisplayIDs, [])

        XCTAssertThrowsError(try tools.call(name: "update_settings", arguments: ["reveal_modifier": "hyper"]))
        XCTAssertThrowsError(try tools.call(name: "update_settings", arguments: ["reveal_display_ids": "X"]))
        XCTAssertThrowsError(try tools.call(name: "update_settings", arguments: ["reveal_on_hover": 1]))
    }

    // MARK: - The hover monitor

    private struct Panel {
        let settings: AppSettings
        let uiState: PanelUIState
        let controller: AtticPanelController
        let monitor: CornerHoverMonitor
    }

    private func makePanel() throws -> Panel {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore())
        let canvasStore = CanvasStore(container: container)
        let canvasSession = CanvasSession(store: canvasStore)
        let noteDraft = NoteDraftController(noteStore: notes)
        let settings = AppSettings(defaults: try makeDefaults())
        let uiState = PanelUIState()
        let controller = AtticPanelController(store: store, noteStore: notes, canvasSession: canvasSession,
                                              noteDraft: noteDraft, settings: settings, uiState: uiState)
        let monitor = CornerHoverMonitor(settings: settings, panelController: controller, uiState: uiState,
                                         store: store, noteStore: notes, canvasStore: canvasStore, noteDraft: noteDraft)
        return Panel(settings: settings, uiState: uiState, controller: controller, monitor: monitor)
    }

    func testClickAwayPressMonitorOnlyLivesWhileVisibleUnpinnedAndSelected() throws {
        let rig = try makePanel()
        rig.settings.revealOnHover = false
        // Start in cursor-away mode so the test sees monitoring switch on.
        rig.settings.panelDismissMode = .moveCursorAway
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertFalse(rig.controller.isOutsidePressMonitoringForTesting)
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)
        XCTAssertFalse(rig.controller.isOutsidePressMonitoringForTesting)

        rig.settings.panelDismissMode = .clickAway
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting)

        // The island's live windows hand their drawing to the panel during
        // reveal. Its space must still count as an inside press right now.
        let revealIsland = rig.controller.islandWindowsForTesting.islandFrame
        rig.controller.handlePressForTesting(at: CGPoint(x: revealIsland.midX, y: revealIsland.midY))
        XCTAssertTrue(rig.controller.isPanelVisible)
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting, "an island press must not begin hiding during reveal")
        rig.uiState.isPanelPinned = true
        XCTAssertFalse(rig.controller.isOutsidePressMonitoringForTesting)
        rig.uiState.isPanelPinned = false
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting)
        rig.settings.panelDismissMode = .moveCursorAway
        XCTAssertFalse(rig.controller.isOutsidePressMonitoringForTesting)
        rig.settings.panelDismissMode = .clickAway
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting)

        let frame = rig.controller.visibleContentFrameForTesting
        rig.controller.handlePressForTesting(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(rig.controller.isPanelVisible, "a press in the panel keeps it open")
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting)
        spin(0.5) // the animated island hands its real windows back
        let island = rig.controller.islandWindowsForTesting.islandFrame
        rig.controller.handlePressForTesting(at: CGPoint(x: island.midX, y: island.midY))
        XCTAssertTrue(rig.controller.isPanelVisible, "the island belongs to the panel")
        XCTAssertTrue(rig.controller.isOutsidePressMonitoringForTesting, "an island press must not begin hiding at rest")

        let outside = CGPoint(x: frame.midX - 700, y: frame.midY - 700)
        rig.controller.handlePressForTesting(at: outside)
        let deadline = Date().addingTimeInterval(3)
        while rig.controller.isPanelVisible, Date() < deadline { spin(0.03) }
        XCTAssertFalse(rig.controller.isPanelVisible, "an outside press hides the panel")
        XCTAssertFalse(rig.controller.isOutsidePressMonitoringForTesting, "hide removes both press monitors")
    }

    func testPinnedAndInteractionHoldsPreventClickAwayDismissal() throws {
        let rig = try makePanel()
        rig.settings.revealOnHover = false
        rig.settings.panelDismissMode = .clickAway
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)
        let frame = rig.controller.visibleContentFrameForTesting
        let outside = CGPoint(x: frame.midX - 700, y: frame.midY - 700)

        rig.uiState.isPanelPinned = true
        rig.controller.handlePressForTesting(at: outside)
        XCTAssertTrue(rig.controller.isPanelVisible)
        rig.uiState.isPanelPinned = false

        for reason in [PanelInteractionLockReason.menuTracking, .taskComposer, .notesDirty,
                       .notesFilePicker, .windowMove, .blockingSave] {
            rig.uiState.setInteractionLock(reason, isActive: true)
            rig.controller.handlePressForTesting(at: outside)
            XCTAssertTrue(rig.controller.isPanelVisible, "\(reason) must hold the panel")
            rig.uiState.setInteractionLock(reason, isActive: false)
        }
        rig.controller.handlePressForTesting(at: outside)
        let deadline = Date().addingTimeInterval(3)
        while rig.controller.isPanelVisible, Date() < deadline { spin(0.03) }
        XCTAssertFalse(rig.controller.isPanelVisible)
    }

    /// A local click in Settings (including an attached sheet) belongs to
    /// Attic even when the pointer is well outside the panel's geometry.
    func testClickAwayKeepsPanelForOwnedSettingsAndChildWindowPresses() throws {
        let rig = try makePanel()
        rig.settings.revealOnHover = false
        rig.settings.panelDismissMode = .clickAway
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)

        let frame = rig.controller.visibleContentFrameForTesting
        let outside = CGPoint(x: frame.midX - 700, y: frame.midY - 700)
        let settingsWindow = SettingsWindow(contentRect: CGRect(x: -4000, y: -4000, width: 640, height: 480),
                                            styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        defer { settingsWindow.close() }
        XCTAssertTrue(NSApp.windows.contains { $0 === settingsWindow })

        rig.controller.handlePressForTesting(at: outside, in: settingsWindow)
        spin(0.4)
        XCTAssertTrue(rig.controller.isPanelVisible, "Settings is owned by Attic")

        let sheet = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 220, height: 160),
                            styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.addChildWindow(sheet, ordered: .above)
        defer { settingsWindow.removeChildWindow(sheet); sheet.close() }
        rig.controller.handlePressForTesting(at: outside, in: sheet)
        spin(0.4)
        XCTAssertTrue(rig.controller.isPanelVisible, "a child sheet or popover belongs to Attic")

        let menuCard = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 210, height: 180),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { menuCard.close() }
        rig.controller.handlePressForTesting(at: outside, in: menuCard)
        spin(0.4)
        XCTAssertTrue(rig.controller.isPanelVisible, "a separate Attic menu card is an owned window")
    }

    func testPointerLeavingCornerCancelsHiddenWarmerRetries() throws {
        let rig = try makePanel()
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        rig.uiState.setInteractionLock(.blockingSave, isActive: true)
        let frame = try XCTUnwrap(rig.monitor.hoverScreenFramesForTesting.first)
        let corner = CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
        rig.monitor.pointerActivityForTesting(at: corner)
        spin(0.08) // let the hidden guarded retry chain start while the save blocks it
        XCTAssertFalse(rig.uiState.isPageContentLoaded)
        rig.monitor.pointerActivityForTesting(at: CGPoint(x: frame.midX, y: frame.midY))
        rig.uiState.setInteractionLock(.blockingSave, isActive: false)
        spin(0.25)
        XCTAssertFalse(rig.uiState.isPageContentLoaded,
            "leaving the hotspot must cancel hidden retries before they can mount pages")
    }

    func testFirstTouchWarmsOnceDuringCornerDwellAndCancelsOnExit() throws {
        let rig = try makePanel()
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        let frame = try XCTUnwrap(rig.monitor.hoverScreenFramesForTesting.first)
        let away = CGPoint(x: frame.midX, y: frame.midY)
        let corner = CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)
        rig.monitor.pointerActivityForTesting(at: away)
        let initial = rig.controller.firstTouchWarmupRunsForTesting.corner

        rig.monitor.pointerActivityForTesting(at: corner)
        rig.monitor.pointerActivityForTesting(at: away) // Cancel before its next run-loop turn.
        spin(0.06)
        XCTAssertEqual(rig.controller.firstTouchWarmupRunsForTesting.corner, initial)
        XCTAssertFalse(rig.controller.isPanelVisible)

        rig.monitor.pointerActivityForTesting(at: corner)
        spin(0.06) // Less than the prescribed 200 ms dwell.
        XCTAssertEqual(rig.controller.firstTouchWarmupRunsForTesting.corner, initial + 1)
        XCTAssertFalse(rig.controller.isPanelVisible, "approach must not reveal the panel")
        rig.monitor.pointerActivityForTesting(at: corner)
        spin(0.06)
        XCTAssertEqual(rig.controller.firstTouchWarmupRunsForTesting.corner, initial + 1,
                       "repeated samples in the same approach cannot warm twice")
        rig.monitor.pointerActivityForTesting(at: away)
        rig.monitor.pointerActivityForTesting(at: corner)
        spin(0.06)
        XCTAssertEqual(rig.controller.firstTouchWarmupRunsForTesting.corner, initial + 2,
                       "leaving the corner makes a later approach independent")
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// WindowServer can remove a revealed panel from the current Space
    /// without changing the hover machine's logical visibility. Replaying
    /// that lost native presentation needs no new mouse event or activation.
    func testASpaceChangeRepairsLostNativePresentationWithoutTakingTheKeyboard() throws {
        let rig = try makePanel()
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)
        let panel = rig.controller.panelForTesting
        let active = NSRunningApplication.current.isActive
        let responder = panel.firstResponder
        XCTAssertFalse(rig.monitor.isHiddenForPerformanceProbe)
        panel.orderOut(nil)
        XCTAssertFalse(panel.isVisible)
        let samples = rig.monitor.sampleCount
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        spin()
        XCTAssertGreaterThan(rig.monitor.sampleCount, samples, "a Space change is an input even with a stationary pointer")
        XCTAssertTrue(panel.isVisible, "the logical reveal must have native presentation in the new Space")
        XCTAssertTrue(rig.controller.islandWindowsForTesting.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === responder)
        XCTAssertEqual(NSRunningApplication.current.isActive, active)
    }

    func testSpaceChangesNeverReviveAHiddenOrStoppedPanel() throws {
        let rig = try makePanel()
        rig.settings.revealOnHover = false
        rig.monitor.start()
        let panel = rig.controller.panelForTesting
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        spin()
        XCTAssertFalse(panel.isVisible)
        rig.monitor.stop()
        spin(0.4)
        let samples = rig.monitor.sampleCount
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        spin()
        XCTAssertEqual(rig.monitor.sampleCount, samples, "stop removes the workspace observer")
        XCTAssertFalse(panel.isVisible)
    }

    func testASpaceChangeDoesNotCancelAnAcceptedHide() throws {
        // Match CI: the zero-duration hide can complete before the deferred
        // Space observer runs. A lost-native-window repair is a different case.
        let previous = AtticMotionPreference.systemReduceMotionOverride
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = previous }
        let rig = try makePanel()
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)
        var hidden = false
        _ = rig.controller.requestHide { hidden = $0 == .hidden }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let deadline = Date().addingTimeInterval(3)
        while !hidden, Date() < deadline { spin(0.02) }
        XCTAssertTrue(hidden, "Space repair must not supersede the accepted hide")
        spin(0.1)
        XCTAssertTrue(rig.monitor.isHiddenForPerformanceProbe, "native hide completion must update logical visibility")
        XCTAssertFalse(rig.controller.isPanelVisible)
    }

    func testBugs3AnAutomaticHideDoesNotConsumeTheNextCornerEntry() throws {
        let previous = AtticMotionPreference.systemReduceMotionOverride
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = previous }
        let rig = try makePanel()
        // The automatic hide under test is the cursor-away one.
        rig.settings.panelDismissMode = .moveCursorAway
        rig.monitor.start()
        defer { rig.monitor.stop(); spin(0.4) }
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown)
        let screen = try XCTUnwrap(rig.monitor.hoverScreenFramesForTesting.first)
        let outside = CGPoint(x: screen.midX, y: screen.midY)
        let corner = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        XCTAssertTrue(rig.monitor.isInHotspotForTesting(corner, flags: []))
        let time = ProcessInfo.processInfo.systemUptime + 10
        // Let the normal hover machine request the hide after its grace.
        // No mouse movement occurs after completion until the next entry.
        rig.monitor.sampleForTesting(at: outside, uptime: time)
        rig.monitor.sampleForTesting(at: outside, uptime: time + rig.settings.hideDelay + 1)
        let deadline = Date().addingTimeInterval(2)
        while rig.controller.isPanelVisible, Date() < deadline { spin(0.01) }
        XCTAssertTrue(rig.monitor.isHiddenForPerformanceProbe)
        XCTAssertFalse(rig.controller.isPanelVisible)
        rig.monitor.sampleForTesting(at: corner, uptime: time + 5)
        rig.monitor.sampleForTesting(at: corner, uptime: time + 5 + rig.settings.revealDelay + 0.1)
        XCTAssertFalse(rig.monitor.isHiddenForPerformanceProbe, "a completed auto-hide must not require an extra exit and re-entry")
        XCTAssertTrue(rig.controller.isPanelVisible, "the first corner entry reveals the real native panel")
    }

    func testAVisibleWindowOutsideTheActiveSpaceGetsFreshNativeAdmissionWithItsVisibleChildren() {
        final class SpacePanel: NSPanel {
            var activeSpace = false
            var ordered: ((String) -> Void)?
            override var isOnActiveSpace: Bool { activeSpace }
            override func orderOut(_ sender: Any?) { ordered?("out"); super.orderOut(sender) }
            override func orderFrontRegardless() { ordered?("in"); super.orderFrontRegardless() }
        }
        func window() -> SpacePanel {
            let window = SpacePanel(contentRect: TestPresentationPolicy.offscreenFrame(CGRect(x: -6000, y: -6000, width: 80, height: 80)),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.becomesKeyOnlyIfNeeded = true
            return window
        }
        let parent = window(), child = window(), hiddenChild = window()
        defer {
            parent.removeChildWindow(child); parent.removeChildWindow(hiddenChild)
            child.close(); hiddenChild.close(); parent.close()
        }
        parent.orderFrontRegardless()
        parent.addChildWindow(child, ordered: .above)
        parent.addChildWindow(hiddenChild, ordered: .above)
        child.orderFrontRegardless(); hiddenChild.orderOut(nil)
        XCTAssertTrue(parent.isVisible)
        XCTAssertFalse(parent.isOnActiveSpace, "the real Air failure: AppKit visible, absent from the active Space")
        var orders: [String] = []
        parent.ordered = { orders.append("parent." + $0) }
        child.ordered = { orders.append("child." + $0) }
        hiddenChild.ordered = { orders.append("hidden." + $0) }
        let active = NSRunningApplication.current.isActive
        XCTAssertTrue(PanelSpacePresentation.reassert(parent, onActiveSpace: parent.isOnActiveSpace))
        XCTAssertEqual(orders, ["child.out", "parent.out", "parent.in", "child.in"],
                       "order-front alone leaves an already ordered window in its old Space; explicit child ordering also resets first-click policy")
        XCTAssertTrue(parent.isVisible)
        XCTAssertTrue(child.isVisible)
        XCTAssertFalse(hiddenChild.isVisible)
        XCTAssertFalse(parent.isKeyWindow)
        XCTAssertEqual(NSRunningApplication.current.isActive, active)
        orders.removeAll()
        parent.activeSpace = true
        XCTAssertFalse(PanelSpacePresentation.reassert(parent, onActiveSpace: parent.isOnActiveSpace))
        XCTAssertEqual(orders, [], "a window already on this Space is undisturbed")
    }

    /// The monitor reads the rule as it changes: hover off, a key, chosen
    /// displays. Corners that don't answer are not even sampled closely.
    /// Explicit opens show the panel whatever the rule says.
    func testTheMonitorHonoursTheRule() throws {
        let panel = try makePanel()
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = AtticDisplay.identifier(for: screen)
        panel.settings.corner = .topRight
        panel.monitor.start()
        defer {
            panel.monitor.stop()
            _ = panel.controller.requestHide { _ in }
            spin(0.3)
        }
        let corner = CGPoint(x: screen.frame.maxX - 1, y: screen.frame.maxY - 1)
        let away = CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        XCTAssertTrue(panel.monitor.isInHotspotForTesting(corner, flags: []))
        XCTAssertFalse(panel.monitor.isInHotspotForTesting(away, flags: []))
        XCTAssertEqual(panel.monitor.hoverScreenFramesForTesting.count, NSScreen.screens.count)

        panel.settings.revealModifier = .option
        spin()
        XCTAssertEqual(panel.monitor.revealPolicyForTesting.modifier, .option, "read as it changes")
        XCTAssertFalse(panel.monitor.isInHotspotForTesting(corner, flags: []), "no key, no reveal")
        XCTAssertTrue(panel.monitor.isInHotspotForTesting(corner, flags: [.option]))

        panel.settings.revealModifier = .none
        panel.settings.revealDisplays = .selected
        panel.settings.revealDisplayIDs = ["not-this-display"]
        spin()
        XCTAssertFalse(panel.monitor.isInHotspotForTesting(corner, flags: []), "a display not chosen")
        XCTAssertFalse(panel.monitor.hoverScreenFramesForTesting.contains(screen.frame), "and not sampled closely")
        if let displayID {
            panel.settings.revealDisplayIDs = [displayID]
            spin()
            XCTAssertTrue(panel.monitor.isInHotspotForTesting(corner, flags: []), "the chosen display answers")
            XCTAssertTrue(panel.monitor.hoverScreenFramesForTesting.contains(screen.frame))
        }

        panel.settings.revealOnHover = false
        spin()
        XCTAssertFalse(panel.monitor.isInHotspotForTesting(corner, flags: []), "hover off")
        XCTAssertTrue(panel.monitor.hoverScreenFramesForTesting.isEmpty, "no corner is watched closely")
        XCTAssertEqual(panel.monitor.revealProgrammatically(section: .tasks, takesKeyboard: false), .shown,
                       "the menu bar icon, quick capture and agents still open it")
    }

    // MARK: - CORNER-REVEAL-MISS: the exit latch means "resting since the hide began"

    /// Every hide that is not a cursor exit: click away, a controller hide
    /// (Esc, menu; the `hideCount` path), the interactive swipe and the probe.
    private enum LatchingHide: CaseIterable { case clickAway, controller, swipe, probe }

    private struct Corner {
        let rig: Panel
        let frame: CGRect
        var corner: CGPoint { CGPoint(x: frame.maxX - 1, y: frame.maxY - 1) }
        var far: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
        var band: CGPoint { CGPoint(x: frame.maxX - 50, y: frame.maxY - 50) }
        /// Whether the monitor has announced a reveal deadline since the last reset.
        let announced: Box
        final class Box { var revealPending = false }
    }

    /// Reveals, then hides by `path`. The pointer is at `begin(…)` as the
    /// hide begins and at `end(…)` as it ends, where it then rests (the
    /// monitor's timed follow-up reads it there too).
    private func reveal(_ rig: Panel, thenHideBy path: LatchingHide,
                        pointerAtBegin begin: (Corner) -> CGPoint, atEnd end: (Corner) -> CGPoint,
                        file: StaticString = #filePath, line: UInt = #line) throws -> Corner {
        let frame = try XCTUnwrap(rig.monitor.hoverScreenFramesForTesting.first, file: file, line: line)
        let box = Corner.Box()
        let corner = Corner(rig: rig, frame: frame, announced: box)
        let beginLocation = begin(corner)
        rig.controller.pointerLocation = { beginLocation }
        rig.monitor.pointerLocationForTesting = end(corner)
        XCTAssertEqual(rig.monitor.revealProgrammatically(takesKeyboard: false, focusesAddBar: false), .shown,
                       file: file, line: line)
        rig.monitor.onVisibilityChangeExpected = { expected in
            if let expected, !expected.hiding { box.revealPending = true }
        }
        switch path {
        case .clickAway:
            let panel = rig.controller.visibleContentFrameForTesting
            rig.controller.handlePressForTesting(at: CGPoint(x: panel.midX - 700, y: panel.midY - 700))
        case .controller:
            _ = rig.controller.requestHide { _ in }
        case .swipe:
            // The real swipe entry point; its own completion tells the monitor.
            rig.controller.panelForTesting.onTrackpadDismissRequest?()
        case .probe:
            rig.monitor.hideForPerformanceProbe { _ in }
        }
        let deadline = Date().addingTimeInterval(2)
        while rig.controller.isPanelVisible || !rig.monitor.isHiddenForPerformanceProbe, Date() < deadline { spin(0.01) }
        XCTAssertFalse(rig.controller.isPanelVisible, "\(path) hid the panel", file: file, line: line)
        XCTAssertTrue(rig.monitor.isHiddenForPerformanceProbe, file: file, line: line)
        return corner
    }

    /// Runs the run loop until the panel is visible or `timeout` passes.
    private func revealsWithin(_ rig: Panel, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !rig.controller.isPanelVisible, Date() < deadline { spin(0.01) }
        return rig.controller.isPanelVisible
    }

    /// The pointer arrives in the corner: the first sample after the hide
    /// is already in the hotspot, then the pointer rests there.
    private func arrive(at corner: Corner) {
        corner.announced.revealPending = false
        corner.rig.monitor.pointerLocationForTesting = corner.corner
        corner.rig.monitor.sampleForTesting(at: corner.corner)
    }

    private func withLatchRig(_ body: (Panel) throws -> Void) throws {
        let previous = AtticMotionPreference.systemReduceMotionOverride
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = previous }
        let rig = try makePanel()
        rig.settings.corner = .topRight
        rig.monitor.start()
        defer { rig.monitor.onVisibilityChangeExpected = nil; rig.monitor.stop(); spin(0.3) }
        try body(rig)
    }

    /// The owner's miss (20 Nov): the pointer is far from the corner when
    /// the hide begins and ends, no samples run there, and the first sample
    /// near the corner is already in the hotspot. That is a new approach,
    /// not a resting pointer, so the reveal is pending at once.
    func testCornerRevealMissFastApproachAfterAHideRevealsOnTheFirstHotspotSample() throws {
        for path in LatchingHide.allCases {
            try withLatchRig { rig in
                let corner = try reveal(rig, thenHideBy: path, pointerAtBegin: \.far, atEnd: \.far)
                arrive(at: corner)
                XCTAssertTrue(corner.announced.revealPending, "\(path): the first hotspot sample sets the reveal deadline")
                XCTAssertTrue(revealsWithin(rig, 1), "\(path): the panel reveals without a second entry")
            }
        }
    }

    /// The guarantee the latch exists for: the pointer rests in the corner
    /// from the hide's start to its end, so the hide must not re-reveal
    /// under it. Leaving and coming back then reveals.
    func testCornerRevealMissPointerStillInTheCornerAtAHideMustLeaveFirst() throws {
        for path in LatchingHide.allCases {
            try withLatchRig { rig in
                let corner = try reveal(rig, thenHideBy: path, pointerAtBegin: \.corner, atEnd: \.corner)
                XCTAssertFalse(revealsWithin(rig, 0.5), "\(path): a hide never re-reveals under a resting pointer")
                XCTAssertFalse(corner.announced.revealPending, "\(path): a resting pointer gets no reveal deadline")
                rig.monitor.pointerLocationForTesting = corner.far
                rig.monitor.sampleForTesting(at: corner.far)
                arrive(at: corner)
                XCTAssertTrue(corner.announced.revealPending, "\(path): after leaving, the next entry is a fresh approach")
                XCTAssertTrue(revealsWithin(rig, 1), "\(path)")
            }
        }
    }

    /// The sibling: a pointer still near the corner but outside the hotspot
    /// at the hide (inside the 96 pt band) is not resting in the corner; a
    /// flick into the hotspot is a new approach.
    func testCornerRevealMissPointerNearButOutsideTheHotspotAtAHideDoesNotLatch() throws {
        for path in LatchingHide.allCases {
            try withLatchRig { rig in
                let corner = try reveal(rig, thenHideBy: path, pointerAtBegin: \.band, atEnd: \.band)
                arrive(at: corner)
                XCTAssertTrue(corner.announced.revealPending, "\(path)")
                XCTAssertTrue(revealsWithin(rig, 1), "\(path)")
            }
        }
    }

    /// Round 2 (lead, 21 Nov): the pointer is away when the hide begins
    /// and reaches the corner before it ends (0.22 s on Slide, 0.80 s on
    /// Genie). That is an approach, not a resting pointer: it is not
    /// latched, and since a resting pointer sends no more events, a sample
    /// at the hide's end starts its dwell and the panel reveals with no
    /// further pointer event.
    func testCornerRevealMissPointerArrivingDuringTheHideRevealsWithoutAnotherEvent() throws {
        for path in LatchingHide.allCases {
            try withLatchRig { rig in
                let corner = try reveal(rig, thenHideBy: path, pointerAtBegin: \.far, atEnd: \.corner)
                XCTAssertTrue(revealsWithin(rig, 1), "\(path): the arrival reveals by itself")
                XCTAssertTrue(corner.announced.revealPending, "\(path): a reveal deadline was set at the hide's end")
            }
        }
    }
}
