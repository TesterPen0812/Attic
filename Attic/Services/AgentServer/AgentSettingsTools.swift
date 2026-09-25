import Foundation

/// The agent tools for Settings (spec § Agent access: `get_settings`,
/// `update_settings`): every setting a person can change in Settings,
/// except Agent Access itself, which only the person changes. Changes go
/// through `AppSettings`, so they are validated and clamped exactly as the
/// Settings window's controls are, and the window shows them at once.
@MainActor
final class AgentSettingsTools {
    /// Launch at login is a macOS login item; tests supply their own.
    struct LoginItem {
        let isEnabled: () -> Bool
        let setEnabled: (Bool) -> Void
    }

    private let settings: AppSettings
    private let loginItem: LoginItem?

    init(settings: AppSettings, loginItem: LoginItem? = nil) {
        self.settings = settings
        self.loginItem = loginItem
    }

    convenience init(settings: AppSettings, loginItemService: LoginItemService) {
        self.init(settings: settings, loginItem: LoginItem(
            isEnabled: { loginItemService.isEnabled },
            setEnabled: { loginItemService.setEnabled($0) }
        ))
    }

    static let toolNames: Set<String> = ["get_settings", "update_settings"]

    /// The settings an agent can change, with their JSON schema.
    private static var settingProperties: [String: Any] {
        [
            "appearance": [
                "type": "string", "enum": AppearancePreference.allCases.map(\.rawValue),
                "description": "Light, Dark, or follow the Mac (system)."
            ],
            "palette": [
                "type": "string", "enum": AtticPanelTheme.allCases.map(\.rawValue),
                "description": "The panel's palette (a gentle hue and the accent)."
            ],
            "surface": [
                "type": "string", "enum": PanelSurfaceStyle.allCases.map(\.rawValue),
                "description": "Solid, Glass or Frosted. Reduce Transparency draws Solid without changing this."
            ],
            "tint": [
                "type": "string", "enum": PanelTintLevel.allCases.map(\.rawValue),
                "description": "The wash across the top of the panel."
            ],
            "tint_length": [
                "type": "number", "minimum": PanelTintLength.range.lowerBound, "maximum": PanelTintLength.range.upperBound,
                "description": "How far down the panel the tint reaches, as a fraction of its height (1 is full height)."
            ],
            "reveal_corner": [
                "type": "string", "enum": ScreenCorner.allCases.map(\.rawValue),
                "description": "The screen corner that reveals the panel."
            ],
            "reveal_delay": [
                "type": "number", "minimum": PanelSettingsRanges.revealDelay.lowerBound, "maximum": PanelSettingsRanges.revealDelay.upperBound,
                "description": "Seconds the pointer rests in the corner before the panel opens."
            ],
            "hide_delay": [
                "type": "number", "minimum": PanelSettingsRanges.hideDelay.lowerBound, "maximum": PanelSettingsRanges.hideDelay.upperBound,
                "description": "Seconds the panel waits after the pointer leaves."
            ],
            "corner_size": [
                "type": "number", "minimum": PanelCornerSize.min, "maximum": PanelCornerSize.max,
                "description": "The panel's corner size, in points."
            ],
            "panel_width": [
                "type": "number", "minimum": PanelContentSize.min,
                "description": "The panel's width, in points."
            ],
            "haptics": [
                "type": "boolean",
                "description": "A light haptic tick when a task is completed or a dragged item snaps into place."
            ],
            "launch_at_login": [
                "type": "boolean",
                "description": "Open Attic when the person logs in (a macOS login item; macOS may ask them to approve it)."
            ]
        ]
    }

    static let definitions: [[String: Any]] = [
        [
            "name": "get_settings",
            "title": "Get Attic Settings",
            "description": "Read Attic's settings: appearance (mode, palette, surface, tint), panel (reveal corner, delays, corner size, width) and behaviour (haptics, launch at login). Agent Access is not included.",
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ]
        ],
        [
            "name": "update_settings",
            "title": "Update Attic Settings",
            "description": "Change one or more of Attic's settings, as the person would in Settings; give only the ones to change. Numbers are clamped to the ranges Settings allows. Agent Access can't be changed by an agent. Returns every setting after the change.",
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false
            ],
            "inputSchema": [
                "type": "object",
                "properties": settingProperties,
                "additionalProperties": false
            ]
        ]
    ]

    func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "get_settings":
            guard arguments.isEmpty else {
                throw AgentToolError.invalidArguments("get_settings takes no arguments.")
            }
            return try encode(snapshot())
        case "update_settings":
            try update(arguments)
            return try encode(snapshot())
        default:
            throw AgentToolError.unknownTool(name)
        }
    }

    /// Every setting as the tools name it.
    func snapshot() -> [String: Any] {
        var result: [String: Any] = [
            "appearance": settings.appearance.rawValue,
            "palette": settings.panelTheme.rawValue,
            "surface": settings.panelSurfaceStyle.rawValue,
            "tint": settings.panelTint.rawValue,
            "tint_length": settings.panelTintLength,
            "reveal_corner": settings.corner.rawValue,
            "reveal_delay": settings.revealDelay,
            "hide_delay": settings.hideDelay,
            "corner_size": settings.panelCornerSize,
            "panel_width": settings.panelContentSize,
            "haptics": settings.hapticsEnabled
        ]
        if let loginItem { result["launch_at_login"] = loginItem.isEnabled() }
        return result
    }

    /// Validates everything first and changes nothing unless every value is
    /// valid, so a bad argument never leaves half a change behind.
    private func update(_ arguments: [String: Any]) throws {
        if arguments.keys.contains(where: { ["agent_access", "is_agent_access_enabled", "agentAccess"].contains($0) }) {
            throw AgentToolError.invalidArguments("Agent Access can only be changed by the person, in Settings → Agent Access.")
        }
        let known = Set(Self.settingProperties.keys)
        if let unknown = arguments.keys.sorted().first(where: { !known.contains($0) }) {
            throw AgentToolError.invalidArguments("Unknown setting: \(unknown). Settings: \(known.sorted().joined(separator: ", ")).")
        }
        guard !arguments.isEmpty else {
            throw AgentToolError.invalidArguments("Give at least one setting to change.")
        }
        if arguments["launch_at_login"] != nil, loginItem == nil {
            throw AgentToolError.invalidArguments("Launch at login can't be changed here.")
        }

        let appearance = try choice(arguments, "appearance", AppearancePreference.self)
        let palette = try choice(arguments, "palette", AtticPanelTheme.self)
        let surface = try choice(arguments, "surface", PanelSurfaceStyle.self)
        let tint = try choice(arguments, "tint", PanelTintLevel.self)
        let corner = try choice(arguments, "reveal_corner", ScreenCorner.self)
        let tintLength = try number(arguments, "tint_length")
        let revealDelay = try number(arguments, "reveal_delay")
        let hideDelay = try number(arguments, "hide_delay")
        let cornerSize = try number(arguments, "corner_size")
        let width = try number(arguments, "panel_width")
        let haptics = try flag(arguments, "haptics")
        let launchAtLogin = try flag(arguments, "launch_at_login")

        if let appearance { settings.appearance = appearance }
        if let palette { settings.panelTheme = palette }
        if let surface { settings.panelSurfaceStyle = surface }
        if let tint { settings.panelTint = tint }
        if let tintLength { settings.panelTintLength = tintLength }
        if let corner { settings.corner = corner }
        if let revealDelay { settings.revealDelay = revealDelay }
        if let hideDelay { settings.hideDelay = hideDelay }
        if let cornerSize { settings.panelCornerSize = cornerSize }
        if let width { settings.panelContentSize = width }
        if let haptics { settings.hapticsEnabled = haptics }
        if let launchAtLogin, let loginItem { loginItem.setEnabled(launchAtLogin) }
    }

    private func choice<T: RawRepresentable & CaseIterable>(
        _ arguments: [String: Any], _ key: String, _ type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let raw = arguments[key] else { return nil }
        guard let string = raw as? String, let value = T(rawValue: string) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw AgentToolError.invalidArguments("\(key) must be one of: \(allowed).")
        }
        return value
    }

    private func number(_ arguments: [String: Any], _ key: String) throws -> Double? {
        guard let raw = arguments[key] else { return nil }
        // JSON booleans arrive as NSNumber too: refuse them as numbers.
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw AgentToolError.invalidArguments("\(key) must be a number.")
        }
        return number.doubleValue
    }

    private func flag(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AgentToolError.invalidArguments("\(key) must be true or false.")
        }
        return number.boolValue
    }

    private func encode(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
