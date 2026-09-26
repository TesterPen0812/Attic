import Foundation

/// The agent tools for Settings (spec § Agent access: `get_settings`,
/// `update_settings`): every setting a person can change in Settings,
/// except Agent Access itself and Launch at login, which only the person
/// changes (Launch at login registers a macOS login item, an effect outside
/// Attic; the owner decided on 2026-09-26 that agents may not change it).
/// Changes go through `AppSettings`, so they are validated and clamped
/// exactly as the Settings window's controls are, and the window shows them
/// at once. An update is all or nothing and one undoable step.
@MainActor
final class AgentSettingsTools {
    private let settings: AppSettings
    /// Reported by `get_settings`, never changed.
    private let launchAtLogin: (() -> Bool)?
    private let undo: UndoRoute?
    private let history: UndoHistoryID

    init(
        settings: AppSettings,
        launchAtLogin: (() -> Bool)? = nil,
        undo: UndoRoute? = nil,
        history: UndoHistoryID = .library
    ) {
        self.settings = settings
        self.launchAtLogin = launchAtLogin
        self.undo = undo
        self.history = history
    }

    convenience init(settings: AppSettings, loginItemService: LoginItemService, undo: UndoRoute?) {
        self.init(settings: settings, launchAtLogin: { loginItemService.isEnabled }, undo: undo)
    }

    static let toolNames: Set<String> = ["get_settings", "update_settings"]

    /// The owner's decision (2026-09-26), said plainly to the agent.
    static let launchAtLoginRefusal = "Agents can't change Launch at login: the owner decided only they change it, "
        + "in Settings → General. Nothing was changed, including the other settings in this request."

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
            ]
        ]
    }

    static let definitions: [[String: Any]] = [
        [
            "name": "get_settings",
            "title": "Get Attic Settings",
            "description": "Read Attic's settings: appearance (mode, palette, surface, tint), panel (reveal corner, delays, corner size, width) and behaviour (haptics; launch at login, read only). Agent Access is not included.",
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
            "description": "Change one or more of Attic's settings, as the person would in Settings; give only the ones to change. Numbers are clamped to the ranges Settings allows. All or nothing: if any value is invalid nothing changes. The change is one undoable step. Agent Access and Launch at login can only be changed by the person. Returns every setting after the change.",
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
        var result = values()
        if let launchAtLogin { result["launch_at_login"] = launchAtLogin() }
        return result
    }

    /// The settings an agent can change, as the tools name them.
    private func values() -> [String: Any] {
        [
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
    }

    /// Validates everything first; then applies the whole change, checks
    /// that every setting took it, and restores every value it touched if
    /// any did not. Only a complete change is recorded, as one undo step.
    private func update(_ arguments: [String: Any]) throws {
        if arguments.keys.contains(where: { ["agent_access", "is_agent_access_enabled", "agentAccess"].contains($0) }) {
            throw AgentToolError.invalidArguments("Agent Access can only be changed by the person, in Settings → Agent Access.")
        }
        if arguments.keys.contains(where: { ["launch_at_login", "launchAtLogin", "launch_at_startup"].contains($0) }) {
            throw AgentToolError.invalidArguments(Self.launchAtLoginRefusal)
        }
        let known = Set(Self.settingProperties.keys)
        if let unknown = arguments.keys.sorted().first(where: { !known.contains($0) }) {
            throw AgentToolError.invalidArguments("Unknown setting: \(unknown). Settings: \(known.sorted().joined(separator: ", ")).")
        }
        guard !arguments.isEmpty else {
            throw AgentToolError.invalidArguments("Give at least one setting to change.")
        }
        var requested: [String: Any] = [:]
        for key in arguments.keys {
            requested[key] = try validated(key, arguments[key] as Any)
        }

        let before = values()
        let keys = Array(requested.keys)
        do {
            try apply(requested)
        } catch {
            // Put back every value this call touched, then report.
            try? apply(before.filter { keys.contains($0.key) })
            throw error
        }
        let after = values()
        let changed = keys.filter { !Self.same(before[$0], after[$0]) }
        guard !changed.isEmpty, let undo else { return }
        let from = before.filter { changed.contains($0.key) }
        let to = after.filter { changed.contains($0.key) }
        undo.record(UndoStep(
            name: "Change Settings",
            undoOutcome: { [weak self] in self?.move(from: to, to: from) ?? .obsolete },
            redoOutcome: { [weak self] in self?.move(from: from, to: to) ?? .obsolete }
        ), in: history)
    }

    /// Undo and redo: set each setting that still holds `from` back to
    /// `to`; a setting changed since (by the person, or another agent) is
    /// left alone. Nothing left to move makes the step obsolete.
    private func move(from: [String: Any], to: [String: Any]) -> UndoOutcome {
        let current = values()
        let movable = to.filter { Self.same(current[$0.key], from[$0.key]) }
        guard !movable.isEmpty else { return .obsolete }
        do {
            try apply(movable)
            return .applied
        } catch {
            return .failed
        }
    }

    /// The value for `key`, typed and checked; throws a clear error.
    private func validated(_ key: String, _ raw: Any) throws -> Any {
        let arguments = [key: raw]
        switch key {
        case "appearance": return try choice(arguments, key, AppearancePreference.self)!
        case "palette": return try choice(arguments, key, AtticPanelTheme.self)!
        case "surface": return try choice(arguments, key, PanelSurfaceStyle.self)!
        case "tint": return try choice(arguments, key, PanelTintLevel.self)!
        case "reveal_corner": return try choice(arguments, key, ScreenCorner.self)!
        case "haptics": return try flag(arguments, key)!
        default: return try number(arguments, key)!
        }
    }

    /// Writes the values and checks each one took (clamped as Settings
    /// clamps); throws if a setting refused its value.
    private func apply(_ values: [String: Any]) throws {
        for (key, value) in values {
            switch key {
            case "appearance": settings.appearance = try typed(value, AppearancePreference.self)
            case "palette": settings.panelTheme = try typed(value, AtticPanelTheme.self)
            case "surface": settings.panelSurfaceStyle = try typed(value, PanelSurfaceStyle.self)
            case "tint": settings.panelTint = try typed(value, PanelTintLevel.self)
            case "reveal_corner": settings.corner = try typed(value, ScreenCorner.self)
            case "tint_length": settings.panelTintLength = try double(value)
            case "reveal_delay": settings.revealDelay = try double(value)
            case "hide_delay": settings.hideDelay = try double(value)
            case "corner_size": settings.panelCornerSize = try double(value)
            case "panel_width": settings.panelContentSize = try double(value)
            case "haptics": settings.hapticsEnabled = try typed(value, Bool.self)
            default: throw AgentToolError.invalidArguments("Unknown setting: \(key).")
            }
        }
        let now = self.values()
        for (key, value) in values where !Self.accepts(now[key], requested: value) {
            throw AgentToolError.storeFailure("\(key) did not take the value \(value). Nothing was changed.")
        }
    }

    private func typed<T>(_ value: Any, _ type: T.Type) throws -> T {
        if let value = value as? T { return value }
        if let raw = value as? String, let rawType = T.self as? any (RawRepresentable<String>).Type,
           let converted = rawType.init(rawValue: raw) as? T {
            return converted
        }
        throw AgentToolError.invalidArguments("Invalid value \(value).")
    }

    private func double(_ value: Any) throws -> Double {
        if let number = value as? Double { return number }
        if let number = value as? NSNumber { return number.doubleValue }
        throw AgentToolError.invalidArguments("Invalid number \(value).")
    }

    /// Whether a stored value is what was asked for: equal, or a number
    /// the setting clamped (every number setting clamps to its range).
    private static func accepts(_ stored: Any?, requested: Any) -> Bool {
        if stored is Double { return true }
        if let raw = requested as? any RawRepresentable<String> { return (stored as? String) == raw.rawValue }
        return same(stored, requested)
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject).isEqual(rhs as AnyObject)
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
