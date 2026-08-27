import AppKit

final class AtticPanel: NSPanel {
    var opticalInteractionHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .mouseMoved,
             .scrollWheel,
             .keyDown:
            opticalInteractionHandler?()
        default:
            break
        }
        super.sendEvent(event)
    }
}
