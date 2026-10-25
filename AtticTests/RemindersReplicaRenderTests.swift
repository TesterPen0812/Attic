import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Renders the replica's rows for the side-by-side check against a
/// Reminders capture (the study's IMG-INITIAL, 1x, rows 7–19 of
/// UI-GEO-01's list, with the study's own test-list content). Writes PNGs
/// only when `ATTIC_REPLICA_RENDER` is 1; otherwise it only checks
/// the rows' heights.
@MainActor
final class RemindersReplicaRenderTests: XCTestCase {
    private struct Sample {
        var title: String
        var priority: AtticPriority = .none
        var date: (String, RemindersReplicaText.DateTone)?
        var notes: String?
        var tags: [String] = []
        var parent = false
        var child = false
    }

    private let samples: [Sample] = [
        Sample(title: "Send the invoice to Mira", priority: .medium, date: ("Today, 09:30", .overdue)),
        Sample(title: "Renew the parking permit", priority: .high, date: ("22/10/2026", .overdue)),
        Sample(title: "Pay the electricity bill", priority: .high, date: ("Yesterday, 18:00", .overdue)),
        Sample(title: "Call the dentist", date: ("Today", .quiet)),
        Sample(title: "Book flights for the conference", priority: .medium, date: ("Tomorrow", .quiet)),
        Sample(title: "Draft the quarterly report", date: ("01/11/2026", .quiet),
               notes: "Sections: revenue, hiring, roadmap.\nAsk Sam for the churn numbers.", tags: ["Ghiuggtg"]),
        Sample(title: "Compare three venues for the launch party, checking capacity, catering, accessibility and transport links before Friday",
               date: ("27/10/2026", .quiet)),
        Sample(title: "🎂 Order the birthday cake", date: ("30/10/2026", .quiet)),
        Sample(title: "Tidy the Downloads folder", priority: .low, parent: true),
        Sample(title: "Plan the team offsite", child: true),
        Sample(title: "Review the pull request", priority: .medium),
        Sample(title: "Fix the leaking tap", priority: .high),
        Sample(title: "Flagged, nothing else"),
    ]

    private func rows(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                if sample.child {
                    RemindersReplicaChildRow(subtask: AtticSubtaskModel(title: sample.title)) {}
                } else {
                    var model = AtticTaskRowModel(title: sample.title)
                    let _ = {
                        model.priority = sample.priority
                        model.notes = sample.notes
                        model.tags = sample.tags
                        if sample.parent { model.subtasks = (0, 1) }
                    }()
                    RemindersReplicaRow(model: model, isExpanded: sample.parent,
                                        actions: AtticTaskActions(toggleDone: {}, openPage: {}),
                                        onToggleExpanded: {}, dateLine: sample.date)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.atticCapture, AtticCaptureContext(collector: nil, backdrop: .wallpaper(.matchingMode)))
    }

    private func render(width: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .aqua)
        defer { NSAppearance.current = previous }
        let renderer = ImageRenderer(content: rows(width: width))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    func testReplicaRowsRenderAtTheCaptureWidthAndThePanelWidth() throws {
        let wide = try XCTUnwrap(render(width: 662, scale: 1))
        // M: rows 7–19 of the capture span 133.5…740.5 (607 pt); the
        // child has no date in Attic (its sample row had one: 48 → 32).
        XCTAssertEqual(CGFloat(wide.pixelsHigh), 607 - 16, accuracy: 1)
        let narrow = try XCTUnwrap(render(width: 320, scale: 1))
        XCTAssertGreaterThan(narrow.pixelsHigh, wide.pixelsHigh, "at 320 pt titles reflow")
        guard ProcessInfo.processInfo.environment["ATTIC_REPLICA_RENDER"] == "1" else { return }
        // The sandboxed host writes into its own temporary folder.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-replica-render")
        print("ATTIC_REPLICA_RENDER_OUT=\(url.path)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, rep) in [("replica-662@1x", wide), ("replica-320@1x", narrow),
                            ("replica-320@2x", try XCTUnwrap(render(width: 320, scale: 2)))] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}
