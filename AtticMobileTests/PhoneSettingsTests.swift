import Foundation
import SwiftUI
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneSettingsTests: XCTestCase {
    func testFreshPreferencesFollowSystemAndUseLivelyMotionWithoutWritingDefaults() throws {
        let defaults = try isolatedDefaults()
        let preferences = PhoneLocalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertNil(preferences.appearance.colorScheme)
        XCTAssertEqual(preferences.animations, .lively)
        XCTAssertNil(defaults.object(forKey: PhoneLocalPreferences.Key.appearance))
        XCTAssertNil(defaults.object(forKey: PhoneLocalPreferences.Key.animations))
    }

    func testPhoneChoicesPersistWithoutReadingOrChangingMacPreferences() throws {
        let defaults = try isolatedDefaults()
        // These stand in for unrelated preferences in this synthetic suite.
        defaults.set("dark", forKey: "appearance")
        defaults.set("reduced", forKey: "animations")
        defaults.set("keep", forKey: "unrelated")
        var preferences = PhoneLocalPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.animations, .lively)

        preferences.appearance = .light
        preferences.animations = .subtle
        let reopened = PhoneLocalPreferences(defaults: defaults)
        XCTAssertEqual(reopened.appearance, .light)
        XCTAssertEqual(reopened.appearance.colorScheme, .light)
        XCTAssertEqual(reopened.animations, .subtle)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "dark")
        XCTAssertEqual(defaults.string(forKey: "animations"), "reduced")
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")

        preferences.appearance = .dark
        XCTAssertEqual(PhoneLocalPreferences(defaults: defaults).appearance.colorScheme, .dark)
        preferences.appearance = .system
        XCTAssertNil(PhoneLocalPreferences(defaults: defaults).appearance.colorScheme)
    }

    func testUnknownStoredChoicesFallBackWithoutRewritingThem() throws {
        let defaults = try isolatedDefaults()
        defaults.set("future-appearance", forKey: PhoneLocalPreferences.Key.appearance)
        defaults.set("future-motion", forKey: PhoneLocalPreferences.Key.animations)
        let preferences = PhoneLocalPreferences(defaults: defaults)

        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.animations, .lively)
        XCTAssertEqual(defaults.string(forKey: PhoneLocalPreferences.Key.appearance), "future-appearance")
        XCTAssertEqual(defaults.string(forKey: PhoneLocalPreferences.Key.animations), "future-motion")
    }

    func testSystemReduceMotionOverridesEveryChoiceWithoutChangingStoredChoice() throws {
        let defaults = try isolatedDefaults()
        var preferences = PhoneLocalPreferences(defaults: defaults)
        for choice in PhoneAnimationLevel.allCases {
            preferences.animations = choice
            XCTAssertEqual(choice.effective(systemReduceMotion: true), .reduced)
            XCTAssertEqual(choice.effective(systemReduceMotion: false), choice)
            XCTAssertEqual(PhoneLocalPreferences(defaults: defaults).animations, choice)
        }
    }

    func testReducedMotionSuppressesExplicitTravelAndDoesNotAffectNonanimatedChanges() {
        for level in PhoneAnimationLevel.allCases {
            var idle = Transaction()
            level.apply(to: &idle)
            XCTAssertNil(idle.animation)
        }

        var moving = Transaction(animation: .linear(duration: 2))
        PhoneAnimationLevel.reduced.apply(to: &moving)
        XCTAssertNil(moving.animation)
        XCTAssertTrue(moving.disablesAnimations)

        for level in [PhoneAnimationLevel.lively, .subtle] {
            var animated = Transaction(animation: .linear(duration: 2))
            level.apply(to: &animated)
            XCTAssertEqual(animated.animation, level.animation)
            XCTAssertFalse(animated.disablesAnimations)

            var suppressed = Transaction(animation: .linear(duration: 2))
            suppressed.disablesAnimations = true
            level.apply(to: &suppressed)
            XCTAssertTrue(suppressed.disablesAnimations)
        }
    }

    func testHomeMenuIncludesOnlyAvailableActionsAndDispatchesToTheirOwners() {
        var settingsOpened = 0
        var tagsEdited = 0
        let menu = PhonePageMenu.home(
            openSettings: { settingsOpened += 1 },
            editTags: { tagsEdited += 1 }
        )
        XCTAssertEqual(menu.actions.map(\.id), ["settings", "edit-tags"])
        XCTAssertEqual(menu.accessibilityLabel, "Home options")
        menu.actions[0].perform()
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(tagsEdited, 0)
        menu.actions[1].perform()
        XCTAssertEqual(tagsEdited, 1)

        let settingsOnly = PhonePageMenu.home(openSettings: { settingsOpened += 1 })
        XCTAssertEqual(settingsOnly.actions.map(\.id), ["settings"])
    }

    func testPageMenuKeepsSuppliedSelectionAndDestructiveRoleWithoutGlobalNavigation() {
        var chosen: String?
        let notes = PhonePageMenu(pageTitle: "All notes", actions: [
            .init(id: "list", title: "List", systemImage: "list.bullet", isSelected: true) {
                chosen = "list"
            },
            .init(id: "board", title: "Board", systemImage: "square.grid.2x2") {
                chosen = "board"
            }
        ])
        XCTAssertEqual(notes.accessibilityLabel, "All notes options")
        XCTAssertEqual(notes.actions.map(\.id), ["list", "board"])
        XCTAssertTrue(notes.actions[0].isSelected)
        XCTAssertFalse(notes.actions[1].isSelected)
        notes.actions[1].perform()
        XCTAssertEqual(chosen, "board")

        let deletion = PhonePageMenuAction(id: "delete", title: "Delete", systemImage: "trash",
                                          role: .destructive) { chosen = "delete" }
        XCTAssertEqual(deletion.role, .destructive)
        deletion.perform()
        XCTAssertEqual(chosen, "delete")
        XCTAssertTrue(PhonePageMenu(pageTitle: "Settings", actions: []).actions.isEmpty)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "AtticMobile.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
