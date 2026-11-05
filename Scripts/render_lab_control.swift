import AppKit
import SwiftUI

/// A deliberately trivial control window on the same Air: one state change
/// and a solid rectangle, with no Attic data, materials or moving masks.
@main
struct RenderLabControlApp: App {
    var body: some Scene {
        WindowGroup("Render Control") { RenderLabControlView() }
    }
}

private struct RenderLabControlView: View {
    @State private var turned = false

    var body: some View {
        VStack(spacing: 12) {
            Button("Toggle") { turned.toggle() }
                .accessibilityIdentifier("render-control-toggle")
            Rectangle()
                .fill(turned ? Color.blue : Color.orange)
                .frame(width: 260, height: 190)
            Text(turned ? "B" : "A")
        }
        .frame(width: 340, height: 275)
        .onAppear {
            // Position only this control window in an unobstructed region of
            // the Air, clear of the bottom-right Attic panel and its island.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                guard let window = NSApp.windows.first(where: { $0.title == "Render Control" }),
                      let screen = window.screen ?? NSScreen.main else { return }
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 60,
                                              y: screen.visibleFrame.maxY - window.frame.height - 60))
                window.level = .floating
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
