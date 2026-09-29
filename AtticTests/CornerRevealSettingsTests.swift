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
        XCTAssertEqual(RevealModifier.allCases.map(\.title), ["No Key", "⌥ Option", "⌃ Control", "⌘ Command", "⇧ Shift"])
        XCTAssertEqual(RevealDisplays.allCases.map(\.title), ["All Displays", "Selected Displays"])
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

    // MARK: - The page's words

    func testTheCornerFootnoteSaysWhatHoverDoes() {
        let displays = [AtticDisplay(id: "A", name: "Built-in"), AtticDisplay(id: "B", name: "Studio")]
        XCTAssertTrue(PanelSettingsText.cornerFootnote(CornerRevealPolicy(), connected: displays).hasPrefix("Works on every display."))
        let off = PanelSettingsText.cornerFootnote(CornerRevealPolicy(revealsOnHover: false), connected: displays)
        XCTAssertTrue(off.hasPrefix("Hover opens nothing. Open Attic from the menu bar icon or with the quick capture shortcut."), off)
        let keyed = PanelSettingsText.cornerFootnote(CornerRevealPolicy(modifier: .option), connected: displays)
        XCTAssertTrue(keyed.contains("Hold ⌥ as you move into the corner."), keyed)
        let chosen = PanelSettingsText.cornerFootnote(CornerRevealPolicy(displays: .selected, selectedDisplayIDs: ["B"]), connected: displays)
        XCTAssertTrue(chosen.hasPrefix("Works on the displays chosen above."), chosen)
        let none = PanelSettingsText.cornerFootnote(CornerRevealPolicy(displays: .selected, selectedDisplayIDs: ["Z"]), connected: displays)
        XCTAssertTrue(none.hasPrefix("No display is chosen, so hover opens nothing."), none)
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
        return Panel(settings: settings, controller: controller, monitor: monitor)
    }

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
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
}
