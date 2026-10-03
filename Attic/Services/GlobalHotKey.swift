import AppKit
import Carbon.HIToolbox
import Combine
import os
#if canImport(SwiftUI)
import SwiftUI
#endif

/// A key combination Attic can claim application-wide. Carried by everything
/// that talks about the shortcut — the Carbon registration, the refusal copy
/// and the menu equivalent — so no surface can name a combination other than
/// the one that was actually claimed.
struct GlobalHotKeyCombination: Equatable {
    /// Carbon virtual key code (`kVK_…`).
    let keyCode: UInt32
    /// Carbon modifier mask (`controlKey`, `optionKey`, `shiftKey`, `cmdKey`).
    let modifiers: UInt32

    /// Attic's one global shortcut: show the panel with a new task ready.
    static let newTask = GlobalHotKeyCombination(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey)
    )

    /// The combination written the way menus write it, in Apple's modifier
    /// order, or nil for a key or mask Attic has no name for. Copy that would
    /// otherwise have to guess omits the combination instead.
    var displayName: String? {
        guard let key = Self.keyNames[keyCode] else { return nil }
        let glyphs = Self.modifierGlyphs(modifiers)
        // A shortcut with no modifiers could never be claimed globally, so a
        // mask this type cannot read is a value it must not describe.
        guard !glyphs.isEmpty else { return nil }
        return glyphs + key
    }

    private static func modifierGlyphs(_ modifiers: UInt32) -> String {
        var glyphs = ""
        if modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { glyphs += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { glyphs += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { glyphs += "⌘" }
        return glyphs
    }

    /// What VoiceOver says for it: "Control Option Space".
    var spokenName: String? {
        guard let key = Self.keyNames[keyCode] else { return nil }
        var words: [String] = []
        if modifiers & UInt32(controlKey) != 0 { words.append(String(localized: "Control")) }
        if modifiers & UInt32(optionKey) != 0 { words.append(String(localized: "Option")) }
        if modifiers & UInt32(shiftKey) != 0 { words.append(String(localized: "Shift")) }
        if modifiers & UInt32(cmdKey) != 0 { words.append(String(localized: "Command")) }
        guard !words.isEmpty else { return nil }
        return (words + [Self.spokenKeys[keyCode] ?? key]).joined(separator: " ")
    }

    /// The keys a quick capture shortcut may use (round 10's recorder),
    /// named as menus name them. Letters and digits by the ANSI layout's
    /// key position (what Carbon registers).
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=", UInt32(kVK_ANSI_LeftBracket): "[",
            UInt32(kVK_ANSI_RightBracket): "]", UInt32(kVK_ANSI_Semicolon): ";", UInt32(kVK_ANSI_Quote): "'",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".", UInt32(kVK_ANSI_Slash): "/",
            UInt32(kVK_ANSI_Backslash): "\\", UInt32(kVK_ANSI_Grave): "`"
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"),
            (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"), (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
            (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12")
        ]
        for (code, name) in letters { names[UInt32(code)] = name }
        return names
    }()

    private static let spokenKeys: [UInt32: String] = [
        UInt32(kVK_Return): String(localized: "Return"), UInt32(kVK_Tab): String(localized: "Tab"),
        UInt32(kVK_LeftArrow): String(localized: "Left Arrow"), UInt32(kVK_RightArrow): String(localized: "Right Arrow"),
        UInt32(kVK_UpArrow): String(localized: "Up Arrow"), UInt32(kVK_DownArrow): String(localized: "Down Arrow")
    ]

    /// The Carbon mask for AppKit modifier flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Why a recorded combination can't be Attic's global shortcut, or nil
    /// when it can (round 10's recorder). A global shortcut is claimed in
    /// every app, so it must not take a key people type or a command every
    /// app has: it needs Control or Option, or Command with another
    /// modifier, on a key Attic can name; and not one macOS keeps for
    /// itself (Spotlight, input sources, app switching).
    var recordingProblem: String? {
        guard Self.keyNames[keyCode] != nil else { return String(localized: "Attic can’t use that key. Try a letter, a number or Space.") }
        let control = modifiers & UInt32(controlKey) != 0
        let option = modifiers & UInt32(optionKey) != 0
        let shift = modifiers & UInt32(shiftKey) != 0
        let command = modifiers & UInt32(cmdKey) != 0
        guard control || option || (command && shift) else {
            return String(localized: "Use Control or Option, or Command with Shift, so the shortcut doesn’t take a key other apps use.")
        }
        let reserved: [GlobalHotKeyCombination] = [
            .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)),
            .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey | cmdKey)),
            .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)),
            .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey | shiftKey))
        ]
        if reserved.contains(self) { return String(localized: "macOS uses that shortcut. Try another.") }
        return nil
    }
}

#if canImport(SwiftUI)
extension GlobalHotKeyCombination {
    /// The same combination as a SwiftUI shortcut, so a menu item cannot
    /// advertise one binding while Carbon claims another. nil for a key this
    /// app never binds: the menu then shows no equivalent at all rather than
    /// the wrong one.
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = Self.keyEquivalents[keyCode] else { return nil }
        var flags = SwiftUI.EventModifiers()
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        guard !flags.isEmpty else { return nil }
        return KeyboardShortcut(key, modifiers: flags)
    }

    private static let keyEquivalents: [UInt32: KeyEquivalent] = {
        var keys: [UInt32: KeyEquivalent] = [
            UInt32(kVK_Space): .space, UInt32(kVK_Return): .return, UInt32(kVK_Tab): .tab,
            UInt32(kVK_LeftArrow): .leftArrow, UInt32(kVK_RightArrow): .rightArrow,
            UInt32(kVK_UpArrow): .upArrow, UInt32(kVK_DownArrow): .downArrow
        ]
        for (code, name) in GlobalHotKeyCombination.keyNames where name.count == 1 && keys[code] == nil {
            if let character = name.lowercased().first { keys[code] = KeyEquivalent(character) }
        }
        return keys
    }()
}
#endif

/// Why the system refused Attic's global shortcut, and the calm sentence
/// Settings shows for it. Kept separate from the Carbon calls so the wording
/// and the conflict/failure distinction are testable without asking the system
/// for a real shortcut.
struct GlobalHotKeyFailure: Equatable {
    /// Which Carbon step refused.
    enum Stage: Equatable {
        /// Installing the application-wide keyboard event handler.
        case eventHandler
        /// Claiming the key combination itself.
        case hotKey
    }

    let stage: Stage
    let status: OSStatus
    /// The combination that was refused. Required, not defaulted: the copy
    /// below names it, and it previously named ⌃⌥Space whatever was claimed.
    let combination: GlobalHotKeyCombination

    /// Another application already owns the same combination. Carbon reports
    /// this separately from an outright failure, and it is the only case the
    /// user can resolve themselves.
    var isConflict: Bool {
        stage == .hotKey && status == OSStatus(eventHotKeyExistsErr)
    }

    /// One sentence, no error codes: the shortcut is the only thing that
    /// stopped working, and the menu bar item still opens Attic. The
    /// combination is named only when it can be named correctly.
    var settingsMessage: String {
        let shortcut = combination.displayName
        if isConflict {
            let subject = shortcut.map { "Another app already uses \($0)" }
                ?? "Another app already uses Attic's shortcut combination"
            return "\(subject), so Attic's shortcut is off. "
                + "Record another shortcut, or free it in the other app and try again. "
                + "Attic's menu bar icon still opens the panel."
        }
        let subject = shortcut.map { "macOS refused Attic's \($0) shortcut" }
            ?? "macOS refused Attic's shortcut"
        return "\(subject), so it is off. "
            + "Try again, or record another shortcut. Attic's menu bar icon still opens the panel."
    }

    /// Full detail for the log, where the status code belongs.
    var logDescription: String {
        let stageName = stage == .eventHandler ? "InstallEventHandler" : "RegisterEventHotKey"
        let combinationName = combination.displayName
            ?? "key \(combination.keyCode) with modifier mask \(combination.modifiers)"
        return "\(stageName) returned \(status) for \(combinationName)"
            + (isConflict ? " (the combination is already taken)" : "")
    }
}

/// The state of Attic's global shortcut. `notRegistered` before the first
/// attempt and after `unregister()`; `register()` always leaves a terminal
/// value, so a refusal can never pass unnoticed.
enum GlobalHotKeyRegistration: Equatable {
    case notRegistered
    case registered
    case failed(GlobalHotKeyFailure)

    var failure: GlobalHotKeyFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }

    /// Whether the combination is actually claimed right now. UI must not
    /// advertise a global binding while this is false.
    var isActive: Bool { self == .registered }
}

@MainActor
final class GlobalHotKey: ObservableObject {
    private static let signature: OSType = 0x504B424F // "PKBO"

    /// The combination claimed (or to claim). Settings can change it
    /// (round 10: the quick capture shortcut recorder).
    @Published private(set) var combination: GlobalHotKeyCombination
    /// Distinguishes this instance's presses from another GlobalHotKey's on the
    /// shared application event target.
    private let identifier: UInt32
    /// Assigned by the owner after construction so the hot key can be handed
    /// to Settings before the coordinator finishes initializing.
    var action: (@MainActor () -> Void)?
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private let logger = Logger(subsystem: "com.taha.Attic", category: "GlobalHotKey")

    /// Published so Settings can explain a refused shortcut instead of
    /// advertising one that never fires.
    @Published private(set) var registration: GlobalHotKeyRegistration = .notRegistered

    convenience init(action: (@MainActor () -> Void)? = nil) {
        self.init(combination: .newTask, action: action)
    }

    init(combination: GlobalHotKeyCombination, action: (@MainActor () -> Void)? = nil) {
        self.combination = combination
        self.action = action
        Self.nextIdentifier += 1
        identifier = Self.nextIdentifier
    }

    /// Hot key ids start at 1; `EventHotKeyID()` zero-fills, so a malformed
    /// event can never match a live instance.
    private static var nextIdentifier: UInt32 = 0

    @discardableResult
    func register() -> GlobalHotKeyRegistration {
        guard hotKeyReference == nil else { return registration }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }

                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                // Every GlobalHotKey installs its own handler on the same
                // process-wide target, so each one sees the others' presses.
                // Match the signature *and* this instance's own id, otherwise a
                // second hot key would fire every registered action at once.
                guard status == noErr,
                      identifier.signature == GlobalHotKey.signature,
                      identifier.id == hotKey.identifier else {
                    return noErr
                }
                Task { @MainActor in hotKey.action?() }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandlerReference
        )
        guard installStatus == noErr else {
            eventHandlerReference = nil
            return record(.init(stage: .eventHandler, status: installStatus, combination: combination))
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registerStatus = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        if registerStatus != noErr {
            if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
            eventHandlerReference = nil
            hotKeyReference = nil
            return record(.init(stage: .hotKey, status: registerStatus, combination: combination))
        }
        registration = .registered
        return registration
    }

    /// Settings chose another combination, or turned the shortcut on or
    /// off (round 10): the old one is released, the new one claimed only
    /// while on. A refusal is recorded as for the first claim, so Settings
    /// shows it with Try Again.
    @discardableResult
    func apply(_ combination: GlobalHotKeyCombination, enabled: Bool) -> GlobalHotKeyRegistration {
        guard combination != self.combination || enabled != (hotKeyReference != nil) || registration.failure != nil else {
            return registration
        }
        unregister()
        self.combination = combination
        return enabled ? register() : registration
    }

    /// Try Again after a refusal: claim the same combination afresh.
    @discardableResult
    func retry() -> GlobalHotKeyRegistration {
        unregister()
        return register()
    }

    func unregister() {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
        hotKeyReference = nil
        eventHandlerReference = nil
        registration = .notRegistered
    }

    /// The Carbon handler holds this object unretained, so the registration
    /// must not outlive it: an event arriving after deallocation would resolve
    /// a dangling pointer. The application event target is process-wide, so
    /// there is no owner left to call `unregister()` for us.
    deinit {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
    }

    @discardableResult
    private func record(_ failure: GlobalHotKeyFailure) -> GlobalHotKeyRegistration {
        logger.error("Global shortcut unavailable: \(failure.logDescription, privacy: .public)")
        registration = .failed(failure)
        return registration
    }
}
