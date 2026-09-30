import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The first keystroke's cost, headless (round 4: no screen): the Tasks
/// page hosted in an unordered window over a 500-task list, the add bar's
/// real text view, each keystroke followed by the page's layout and a draw
/// pass. Prints what it measures (`ATTIC_KEYSTROKE`) and holds the budget
/// loosely, so a regression back to the strip-building cost shows here.
@MainActor
final class TasksKeystrokeCostTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
        try await super.tearDown()
    }

    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private func page(tasks count: Int) throws -> (model: TasksPageModel, field: AtticTokenTextView, hosting: NSView) {
        let store = try makeTestStore()
        for index in 0..<count { _ = store.create(title: "Task number \(index)") }
        let library = AtticLibrary(tasks: store)
        let model = TasksPageModel(library: library)
        let size = CGSize(width: 344, height: 520)
        let root = TasksPage(model: model, store: store, layout: PanelPageLayout(cornerSize: 52, panelSize: size),
                             addBarFocused: .constant(true))
            .frame(width: size.width, height: size.height)
            .atticDesign(.default)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let field = try XCTUnwrap(Self.tokenField(in: hosting))
        window.makeFirstResponder(field)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return (model, field, hosting)
    }

    private static func tokenField(in view: NSView) -> AtticTokenTextView? {
        if let field = view as? AtticTokenTextView { return field }
        for subview in view.subviews { if let found = tokenField(in: subview) { return found } }
        return nil
    }

    /// One keystroke as the probe times it: the edit, then everything it
    /// makes SwiftUI do before the next frame (the run loop turn included).
    private func keystroke(_ character: String, into field: AtticTokenTextView, hosting: NSView) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        field.insertText(character, replacementRange: field.selectedRange())
        RunLoop.current.run(until: Date())
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        CATransaction.flush()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testTheFirstKeystrokeCostsAboutWhatTheOthersDo() throws {
        let (_, field, hosting) = try page(tasks: 500)
        var times: [Double] = []
        for character in "quiet probe" { times.append(keystroke(String(character), into: field, hosting: hosting)) }
        let rest = times.dropFirst().sorted()
        let median = rest[rest.count / 2]
        print(String(format: "ATTIC_KEYSTROKE first %.1f ms, then median %.1f ms (500 tasks)", times[0], median))
        // Loose: the first keystroke (the strip appearing, the list making
        // room) may cost a few frames, never the 70+ ms it did.
        XCTAssertLessThan(times[0], 60, "first keystroke \(times[0]) ms")
    }

    /// Where the first keystroke's time goes (printed, not asserted).
    func testWhereTheFirstKeystrokeGoes() throws {
        let (_, emptyField, emptyHosting) = try page(tasks: 0)
        let emptyFirst = keystroke("q", into: emptyField, hosting: emptyHosting)
        window?.close()
        let (model, field, hosting) = try page(tasks: 500)
        // The strip already shown: a draft typed before the measurement.
        _ = keystroke("x", into: field, hosting: hosting)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let withDraft = keystroke("q", into: field, hosting: hosting)
        // Back to empty (the strip hides), then the first keystroke again.
        field.selectAll(nil)
        field.insertText("", replacementRange: field.selectedRange())
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let again = keystroke("q", into: field, hosting: hosting)
        print(String(format: "ATTIC_KEYSTROKE empty list first %.1f; 500 with draft %.1f; 500 first again %.1f; draft %@",
                     emptyFirst, withDraft, again, model.addBar.text))
    }
}
