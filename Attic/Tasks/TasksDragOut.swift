import AppKit

/// A drag of tasks out of the panel into another app (owner-approved,
/// 2026-10-01): an AppKit dragging session carrying `TasksTextExport`'s
/// text, Markdown and RTF. Always a copy; the panel's data never changes.
@MainActor
enum TasksDragOut {
    static func begin(_ export: TasksTextExport, count: Int, from view: NSView, at location: CGPoint,
                      ended: @escaping () -> Void) {
        guard let window = view.window else { ended(); return }
        let item = NSDraggingItem(pasteboardWriter: export.dragItem())
        let image = Self.image(title: count == 1 ? export.items.first?.title ?? "" : String(localized: "\(count) tasks"))
        item.setDraggingFrame(CGRect(x: location.x - image.size.width / 2, y: location.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        // The event the drag starts from: the current mouse event, or one
        // made at the pointer for the same window.
        let event: NSEvent? = if let current = NSApp.currentEvent,
                                 [.leftMouseDown, .leftMouseDragged].contains(current.type) {
            current
        } else {
            NSEvent.mouseEvent(with: .leftMouseDragged, location: view.convert(location, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let event else { ended(); return }
        let source = Source(ended: ended)
        Source.current = source
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        source.session = session
        Probe.shared.began += 1
    }

    /// UI tests: how many sessions began and ended (shown, under
    /// `ATTIC_UI_TESTING`, by the page's `tasks-drag-out-state` element).
    final class Probe: ObservableObject {
        static let shared = Probe()
        @Published var began = 0
        @Published var ended = 0
    }

    /// What a drag of tasks offers: a copy to other apps, nothing within
    /// Attic (a drop back on the panel does nothing).
    nonisolated static func operations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    /// A quiet label of what is being dragged.
    static func image(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let width = min(280, ceil(text.size().width)) + 24
        let size = NSSize(width: width, height: 28)
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.stroke()
            text.draw(with: CGRect(x: 12, y: (rect.height - text.size().height) / 2, width: rect.width - 24, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    /// The session's source (internal for the tests, which end it as Esc
    /// does).
    final class Source: NSObject, NSDraggingSource {
        /// Held for the session's life.
        static var current: Source?
        let ended: () -> Void
        /// The live session.
        weak var session: NSDraggingSession?

        init(ended: @escaping () -> Void) {
            self.ended = ended
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // A copy, never a move: nothing leaves Attic.
            TasksDragOut.operations(for: context)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finish()
        }

        /// The session ended: dropped, or cancelled (Esc, or no
        /// destination: no operation). Once; nothing in Attic changes
        /// either way.
        func finish() {
            guard Source.current === self else { return }
            Source.current = nil
            Probe.shared.ended += 1
            ended()
        }
    }
}
