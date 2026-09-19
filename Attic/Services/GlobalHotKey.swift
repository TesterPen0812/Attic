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

    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_Space): "Space"
    ]
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

    private static let keyEquivalents: [UInt32: KeyEquivalent] = [
        UInt32(kVK_Space): .space
    ]
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
                + "Free that combination in the other app, then restart Attic. "
                + "Attic's menu bar icon still opens the panel."
        }
        let subject = shortcut.map { "macOS refused Attic's \($0) shortcut" }
            ?? "macOS refused Attic's shortcut"
        return "\(subject), so it is off. "
            + "Restart Attic to try again. Attic's menu bar icon still opens the panel."
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

    let combination: GlobalHotKeyCombination
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
