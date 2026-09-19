import Carbon.HIToolbox
import Combine
import os

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

    /// Another application already owns the same combination. Carbon reports
    /// this separately from an outright failure, and it is the only case the
    /// user can resolve themselves.
    var isConflict: Bool {
        stage == .hotKey && status == OSStatus(eventHotKeyExistsErr)
    }

    /// One sentence, no error codes: the shortcut is the only thing that
    /// stopped working, and the menu bar item still opens Attic.
    var settingsMessage: String {
        if isConflict {
            return "Another app already uses ⌃⌥Space, so Attic's shortcut is off. "
                + "Free that combination in the other app, then restart Attic. "
                + "Attic's menu bar icon still opens the panel."
        }
        return "macOS refused Attic's ⌃⌥Space shortcut, so it is off. "
            + "Restart Attic to try again. Attic's menu bar icon still opens the panel."
    }

    /// Full detail for the log, where the status code belongs.
    var logDescription: String {
        let stageName = stage == .eventHandler ? "InstallEventHandler" : "RegisterEventHotKey"
        return "\(stageName) returned \(status)\(isConflict ? " (the combination is already taken)" : "")"
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
}

@MainActor
final class GlobalHotKey: ObservableObject {
    private static let signature: OSType = 0x504B424F // "PKBO"

    private let keyCode: UInt32
    private let modifiers: UInt32
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
        self.init(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            action: action
        )
    }

    init(keyCode: UInt32, modifiers: UInt32, action: (@MainActor () -> Void)? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

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
                guard status == noErr, identifier.signature == GlobalHotKey.signature else {
                    return noErr
                }

                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
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
            return record(.init(stage: .eventHandler, status: installStatus))
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        if registerStatus != noErr {
            if let eventHandlerReference { RemoveEventHandler(eventHandlerReference) }
            eventHandlerReference = nil
            hotKeyReference = nil
            return record(.init(stage: .hotKey, status: registerStatus))
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

    @discardableResult
    private func record(_ failure: GlobalHotKeyFailure) -> GlobalHotKeyRegistration {
        logger.error("Global shortcut unavailable: \(failure.logDescription, privacy: .public)")
        registration = .failed(failure)
        return registration
    }
}
