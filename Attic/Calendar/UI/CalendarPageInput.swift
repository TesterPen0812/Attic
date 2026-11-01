import AppKit
import SwiftUI

/// Native boundaries do not publish geometry into the lazy agenda.
struct CalendarEventRowBoundary: NSViewRepresentable {
    final class Boundary: NSView {
        static let live = NSHashTable<Boundary>.weakObjects()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.live.add(self) }
        }
    }
    func makeNSView(context: Context) -> Boundary { Boundary() }
    func updateNSView(_ view: Boundary, context: Context) {}
}

/// Page-scoped keys work from the editor as well as the agenda. This view
/// never takes focus; hidden pages and other windows cannot answer them.
struct CalendarPageInput: NSViewRepresentable {
    let enabled: () -> Bool
    let today: () -> Void
    let escape: () -> Bool
    let emptyPress: () -> Void

    final class Input: NSView {
        var route: CalendarPageInput?
        private var token: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token); self.token = nil }
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func stop() {
            if let token { NSEvent.removeMonitor(token) }
            token = nil
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let route, route.enabled(), AtticGlassMenu.current == nil,
                  let window, event.window === window else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.type == .keyDown {
                if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "t" {
                    route.today()
                    return nil
                }
                if flags.isEmpty, event.keyCode == 53, route.escape() { return nil }
            } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                let onRow = CalendarEventRowBoundary.Boundary.live.allObjects.contains {
                    $0.window === window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                }
                let point = window.convertPoint(toScreen: event.locationInWindow)
                let hit = window.contentView?.accessibilityHitTest(point) as AnyObject?
                let role = hit?.accessibilityRole?()
                let control = [NSAccessibility.Role.button, .textField, .checkBox, .popUpButton, .comboBox].contains { $0 == role }
                if !onRow && !control { route.emptyPress() }
            }
            return event
        }
    }
    func makeNSView(context: Context) -> Input { Input() }
    func updateNSView(_ view: Input, context: Context) { view.route = self }
    static func dismantleNSView(_ view: Input, coordinator: ()) { view.stop() }
}
