import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Renders List Style: New's rows at the panel's 320 pt for the side-by-side
/// check against the council's `final/states-d1.png` (its sample list, Mon
/// 26 Oct 2026). Writes PNGs only when `ATTIC_NEW_RENDER` is 1; otherwise it
/// checks the rows' heights (32 or 48, FINAL § 2.1).
@MainActor
final class NewStyleRenderTests: XCTestCase {
    private struct Sample {
        var title: String
        var priority: AtticPriority = .none
        var date: (String, TasksNewText.Tone)?
        var tags: [String] = []
        var subtasks: (Int, Int)?
        var photos = 0
        var page = false
    }

    private let samples: [Sample] = [
        Sample(title: "Finalize launch checklist", priority: .high, date: ("Yesterday", .overdue), tags: ["launch"], subtasks: (1, 3)),
        Sample(title: "Pay the electricity bill", priority: .medium, date: ("Late 23 Oct", .overdue), tags: ["home"], photos: 1),
        Sample(title: "Email beta testers", priority: .medium, date: ("Wed", .quiet), tags: ["launch"]),
        Sample(title: "Book dentist", priority: .low, date: ("Today", .today)),
        Sample(title: "Call the plumber"),
        Sample(title: "Plan the team offsite", date: ("3 Nov", .quiet), tags: ["planning", "work"], subtasks: (0, 2), page: true),
        Sample(title: "Renew passport", priority: .low, date: ("6 Nov", .quiet), tags: ["errands"]),
    ]

    /// 0: at rest; 1: "Email beta testers" selected by keyboard; 2: it just
    /// ticked (kept, Undo).
    private func rows(state: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                var model = AtticTaskRowModel(title: sample.title)
                let _ = {
                    model.priority = sample.priority
                    model.tags = sample.tags
                    model.photos = sample.photos
                    model.hasPage = sample.page
                    if let subtasks = sample.subtasks { model.subtasks = subtasks }
                    if state == 2, index == 2 { model.state = .done }
                }()
                TasksNewRow(model: model, isSelected: state == 1 && index == 2, listHasKeyboard: true,
                            actions: AtticTaskActions(toggleDone: {}, openPage: {}), onToggleExpanded: {},
                            date: sample.date.map { (text: $0.0, tone: $0.1) }, isKept: state == 2 && index == 2,
                            onDate: {}, onMove: {}, onInfo: {}, onUndo: {})
            }
        }
        // The page's 8 pt edge on each side, as in the panel.
        .padding(.horizontal, AtticLayout.tasksPageEdge(chromeInset: 16))
        .frame(width: 320, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .wallpaper(.matchingMode)))
    }

    private func render(state: Int, scale: CGFloat) -> NSBitmapImageRep? {
        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .aqua)
        defer { NSAppearance.current = previous }
        let renderer = ImageRenderer(content: rows(state: state))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    func testNewRowsRenderAtThePanelWidth() throws {
        let rest = try XCTUnwrap(render(state: 0, scale: 1))
        // 48 · 48 · 48 · 32 · 32 · 48 · 48: line 2 only where there is
        // something for it.
        XCTAssertEqual(CGFloat(rest.pixelsHigh), 48 * 5 + 32 * 2, accuracy: 1)
        XCTAssertEqual(rest.pixelsWide, 320)
        let selected = try XCTUnwrap(render(state: 1, scale: 1))
        let ticked = try XCTUnwrap(render(state: 2, scale: 1))
        XCTAssertEqual(selected.pixelsHigh, rest.pixelsHigh, "the column takes turns without changing the layout")
        XCTAssertEqual(ticked.pixelsHigh, rest.pixelsHigh, "a ticked row stays as it was, struck through (4A)")
        guard ProcessInfo.processInfo.environment["ATTIC_NEW_RENDER"] == "1" else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-new-render")
        print("ATTIC_NEW_RENDER_OUT=\(url.path)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, state) in [("new-rest", 0), ("new-selected", 1), ("new-ticked", 2)] {
            let rep = try XCTUnwrap(render(state: state, scale: 2))
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + "@2x.png"))
        }
    }
}
