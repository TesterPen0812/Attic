import XCTest
@testable import Attic

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testNonFiniteStoredDelaysUseSafeFallbacks() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        defaults.set(Double.nan, forKey: "revealDelay")
        defaults.set(Double.infinity, forKey: "hideDelay")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertTrue(settings.revealDelay.isFinite)
        XCTAssertTrue(settings.hideDelay.isFinite)
    }

    @MainActor
    func testNonFiniteAssignedDelaysAreSanitizedAndPersisted() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        markDelayMigrationsComplete(in: defaults)
        let settings = AppSettings(defaults: defaults)

        settings.revealDelay = .infinity
        settings.hideDelay = .nan

        XCTAssertEqual(settings.revealDelay, 0.2)
        XCTAssertEqual(settings.hideDelay, 0.3)
        XCTAssertEqual(defaults.double(forKey: "revealDelay"), 0.2)
        XCTAssertEqual(defaults.double(forKey: "hideDelay"), 0.3)
    }

    func testNativeGlassProfileResolvesIndependentCapabilities() {
        let preferences = PanelGlassPreferences(
            material: .clear,
            tint: .accent,
            response: .interactive
        )

        let profile = PanelGlassProfile.resolve(
            PanelGlassResolutionInputs(
                preferences: preferences,
                supportsNativeGlass: true,
                reduceTransparency: false
            )
        )

        XCTAssertEqual(profile.surface, .native(.clear))
        XCTAssertEqual(profile.tint, .accent)
        XCTAssertEqual(profile.response, .interactive)
    }

    func testUnavailableNativeGlassUsesOneHonestMaterialFallback() {
        let preferences = PanelGlassPreferences(
            material: .clear,
            tint: .accent,
            response: .interactive
        )

        let profile = PanelGlassProfile.resolve(
            PanelGlassResolutionInputs(
                preferences: preferences,
                supportsNativeGlass: false,
                reduceTransparency: false
            )
        )

        XCTAssertEqual(profile.surface, .legacyMaterial)
        XCTAssertEqual(profile.tint, .none)
        XCTAssertEqual(profile.response, .static)
    }

    func testReduceTransparencyUsesOpaqueStaticUntintedFallback() {
        let preferences = PanelGlassPreferences(
            material: .clear,
            tint: .accent,
            response: .interactive
        )

        let profile = PanelGlassProfile.resolve(
            PanelGlassResolutionInputs(
                preferences: preferences,
                supportsNativeGlass: true,
                reduceTransparency: true
            )
        )

        XCTAssertEqual(profile.surface, .opaque)
        XCTAssertEqual(profile.tint, .none)
        XCTAssertEqual(profile.response, .static)
    }

    @MainActor
    func testLegacyAppearanceKeysMigrateToNativeGlassDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "isTranslucent")
        defaults.set(true, forKey: "consistentAppearance")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.panelGlassMaterial, .regular)
        XCTAssertEqual(settings.panelGlassTint, .none)
        XCTAssertEqual(settings.panelGlassResponse, .interactive)
        XCTAssertEqual(defaults.string(forKey: "panelGlassMaterial"), "regular")
        XCTAssertEqual(defaults.string(forKey: "panelGlassTint"), "none")
        XCTAssertEqual(defaults.string(forKey: "panelGlassResponse"), "interactive")
        XCTAssertTrue(defaults.bool(forKey: "hasMigratedToNativeGlassProfileV1"))
        XCTAssertNil(defaults.object(forKey: "isTranslucent"))
        XCTAssertNil(defaults.object(forKey: "consistentAppearance"))
    }

    func testWindowFocusStateIsNotAnApplicationInput() {
        let inputs = PanelGlassResolutionInputs(
            preferences: PanelGlassPreferences(
                material: .regular,
                tint: .none,
                response: .static
            ),
            supportsNativeGlass: true,
            reduceTransparency: false
        )

        let inputNames = Set(Mirror(reflecting: inputs).children.compactMap(\.label))
        let preferenceNames = Set(Mirror(reflecting: inputs.preferences).children.compactMap(\.label))

        XCTAssertEqual(
            inputNames,
            Set(["preferences", "supportsNativeGlass", "reduceTransparency"])
        )
        XCTAssertEqual(preferenceNames, Set(["material", "tint", "response"]))
        XCTAssertFalse((inputNames.union(preferenceNames)).contains { name in
            let normalized = name.lowercased()
            return normalized.contains("focus")
                || normalized.contains("active")
                || normalized.contains("keywindow")
        })
    }

    func testPanelAppearanceImplementationDoesNotReadWindowFocusState() throws {
        let sourcePaths = [
            "Attic/Design/AtticStyle.swift",
            "Attic/Services/AppSettings.swift",
            "Attic/Views/Panel/AtticPanelView.swift",
            "Attic/Window/AtticPanelController.swift"
        ]
        let forbiddenInputs = [
            "appearsActive",
            "controlActiveState",
            "isKeyWindow",
            "keyWindow",
            "didBecomeKeyNotification",
            "didResignKeyNotification",
            "NSApp.isActive"
        ]

        for sourcePath in sourcePaths {
            let source = try repositorySource(at: sourcePath)
            for forbiddenInput in forbiddenInputs {
                XCTAssertFalse(
                    source.contains(forbiddenInput),
                    "\(sourcePath) must not read focus input \(forbiddenInput)"
                )
            }
        }
    }

    func testPanelSurfaceContainsNoSyntheticOpticalEffects() throws {
        let source = try repositorySource(at: "Attic/Design/AtticStyle.swift")
        let forbiddenEffects = [
            "distortionEffect",
            "layerEffect",
            "visualEffect",
            "Shader(",
            "CoreImage",
            "CIFilter",
            "NSVisualEffectView",
            "value(forKey:",
            ".opacity(",
            ".blur(",
            ".overlay(",
            ".stroke("
        ]

        XCTAssertTrue(source.contains(".glassEffect("))
        XCTAssertTrue(source.contains(".tint("))
        XCTAssertTrue(source.contains(".interactive("))
        for forbiddenEffect in forbiddenEffects {
            XCTAssertFalse(
                source.contains(forbiddenEffect),
                "Panel surface must not contain synthetic effect \(forbiddenEffect)"
            )
        }
    }

    private func repositorySource(at relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func markDelayMigrationsComplete(in defaults: UserDefaults) {
        defaults.set(true, forKey: "hasAdoptedFasterReveal")
        defaults.set(true, forKey: "hasAdoptedQuickerRevealV2")
        defaults.set(true, forKey: "hasAdoptedInstantRevealV3")
    }
}
