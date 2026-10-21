import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Attic

/// Round O1's headless renders for the report (`ATTIC_O1_RENDER=1`, set
/// through `TEST_RUNNER_ATTIC_O1_RENDER`): each visual item in Light
/// and Dark, drawn off screen. Glass does not draw off screen, so pages use
/// the flat drawing (Reduce Transparency); layout and metrics are the same.
/// "Before" images replicate the exact drawing the item replaced.
@MainActor
final class RoundO1RenderTests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["ATTIC_O1_RENDER"] == "1" else {
            throw XCTSkip("renders only on request")
        }
        // The test host is sandboxed: its own temporary folder, printed.
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("attic-o1-renders", isDirectory: true)
        print("O1_RENDER_DIR \(directory?.path ?? "")")
        try FileManager.default.createDirectory(at: try XCTUnwrap(directory), withIntermediateDirectories: true)
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func context(_ mode: AtticDesignContext.Mode) -> AtticDesignContext {
        AtticDesignContext(mode: mode, reduceTransparency: true)
    }

    private func save(_ view: NSView, _ name: String, scale: CGFloat = 2) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                                 pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: try XCTUnwrap(directory).appendingPathComponent(name + ".png"))
    }

    private func component(_ view: some View, _ name: String, mode: AtticDesignContext.Mode, scale: CGFloat = 4) throws {
        let ctx = context(mode)
        let host = NSHostingView(rootView: AnyView(view.padding(12).atticDesign(ctx).background(ctx.tokens.panel.base.color)))
        host.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        try save(host, name, scale: scale)
    }

    /// The Tasks page (demo tasks) with the shell's notice stack over it,
    /// at `clearance` (nil: the page's own report).
    @MainActor private final class Page {
        let store: TaskStore
        let model: TasksPageModel
        let window: NSWindow
        let focus = Focus()
        final class Focus { var addBar = false }

        init(mode: AtticDesignContext.Mode, context: AtticDesignContext, focused: Bool, clearance: CGFloat?) throws {
            let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
            try TasksPagePreview.seedDemo(in: container, long: false)
            store = TaskStore(container: container)
            model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
            model.services.chooseComposerFiles = {}
            focus.addBar = focused
            let size = AtticLayout.panelSize
            let layout = PanelPageLayout(cornerSize: 52, panelSize: size)
            let root = Root(model: model, store: store, layout: layout, focus: focus, fixedClearance: clearance)
                .atticDesign(context)
                .frame(width: size.width, height: size.height)
            window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: root)
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }

        private struct Root: View {
            @ObservedObject var model: TasksPageModel
            let store: TaskStore
            let layout: PanelPageLayout
            let focus: Focus
            let fixedClearance: CGFloat?
            @State private var clearance = PanelPageNoticeClearancePreferenceKey.defaultValue

            var body: some View {
                TasksPage(model: model, store: store, layout: layout,
                          addBarFocused: Binding(get: { focus.addBar }, set: { focus.addBar = $0 }))
                    .background(AtticPanelStageSurface(cornerSize: 0))
                    .overlay(alignment: .bottom) {
                        PanelNoticeStack(toasts: model.toasts, notice: nil, onRetry: {}, onDismissNotice: {})
                            .padding(.horizontal, layout.chromeInsets.leading)
                            .padding(.bottom, layout.contentInsets.bottom + (fixedClearance ?? clearance))
                    }
                    .onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { clearance = $0 }
            }
        }
    }

    func testRenderTheToastOverTheComposer() throws {
        for mode in AtticDesignContext.Mode.allCases {
            let ctx = context(mode)
            let layout = PanelPageLayout(cornerSize: 52, panelSize: AtticLayout.panelSize)
            let bottomInset = max(AtticSpacing.panelMargin, layout.chromeInsets.bottom)
            let old = TasksPage.footerZone
            _ = bottomInset
            for (label, clearance) in [("before", Optional(old)), ("after", nil)] {
                let page = try Page(mode: mode, context: ctx, focused: false, clearance: clearance)
                defer { page.window.close() }
                page.model.showToast("Tagged #work")
                spin(1)
                try save(try XCTUnwrap(page.window.contentView), "o17-02-toast-\(label)-\(mode.rawValue)")
            }
            // After, with the date and tags row showing (a draft).
            let page = try Page(mode: mode, context: ctx, focused: true, clearance: nil)
            defer { page.window.close() }
            page.model.addBarState.text.text = "Pay rent"
            page.model.showToast("Tagged #work")
            spin(1)
            try save(try XCTUnwrap(page.window.contentView), "o17-02-toast-after-strip-\(mode.rawValue)")
        }
    }

    func testRenderTheGrowingComposerWithFiles() throws {
        for mode in AtticDesignContext.Mode.allCases {
            let page = try Page(mode: mode, context: context(mode), focused: true, clearance: nil)
            defer { page.window.close() }
            page.model.addBarState.text.text = "Call the plumber about the kitchen sink, then ask about the bathroom tap and the boiler service"
            spin(1)
            try save(try XCTUnwrap(page.window.contentView), "o17-05-composer-grown-\(mode.rawValue)")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attic-o1-render-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let lease = folder.appendingPathComponent("Lease.pdf")
            try Data(repeating: 1, count: 8).write(to: lease)
            page.model.addBarState.text.text = "Sign the lease"
            page.model.addComposerFiles(urls: [lease])
            spin(1)
            try save(try XCTUnwrap(page.window.contentView), "o17-06-composer-file-\(mode.rawValue)")
            page.model.addComposerFiles(urls: [lease])
            spin(0.6)
            try save(try XCTUnwrap(page.window.contentView), "o17-06-composer-files-\(mode.rawValue)")
            page.model.clearComposerFiles()
        }
    }

    func testRenderTheSubtaskEntry() throws {
        for mode in AtticDesignContext.Mode.allCases {
            let page = try Page(mode: mode, context: context(mode), focused: false, clearance: nil)
            defer { page.window.close() }
            let parent = try XCTUnwrap(page.model.rows(for: .now).first { $0.model.subtasks != nil })
            page.model.beginAddingSubtask(to: parent.id)
            page.model.newSubtaskTitle = "Ask the landlord about the boiler service and the gas safety certificate before Friday"
            spin(1)
            try save(try XCTUnwrap(page.window.contentView), "o17-04-05-subtask-entry-\(mode.rawValue)")
        }
    }

    func testRenderTheSmallVisuals() throws {
        for mode in AtticDesignContext.Mode.allCases {
            // O17-10: the actions button, before (semibold) and after.
            let m = AtticRowActionsMetrics.self
            let before = AtticIcon(systemName: "ellipsis", size: m.iconSize, weight: .semibold, ink: .icon)
                .frame(width: m.width, height: AtticTaskRowMetrics.metaPillHeight)
                .background(AtticMetaPill(visible: true).padding(.horizontal, AtticTaskRowMetrics.metaPillOutset))
            try component(before, "o17-10-actions-before-\(mode.rawValue)", mode: mode, scale: 6)
            try component(AtticRowActionsButton(action: { _ in }).atticForcedState(.hover),
                          "o17-10-actions-after-\(mode.rawValue)", mode: mode, scale: 6)

            // O17-11: a file line under the pointer (Remove alone).
            let store = TaskStore(container: try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false))
            let file = TaskImageReference(id: UUID(), filename: "Lease.pdf", digest: "d", contentTypeIdentifier: UTType.pdf.identifier, byteCount: 2048)
            try component(TasksFileRow(file: file, store: store, owner: UUID(), remove: {}).frame(width: 260).atticForcedState(.hover),
                          "o17-11-file-line-after-\(mode.rawValue)", mode: mode)

            // O17-14: "Add subtask" under the pointer, before and after.
            let q = AtticQuietActionMetrics.self
            let hover = context(mode).tokens.chipHover.color
            let replaced = HStack(spacing: q.gap) {
                AtticIcon(systemName: "plus", size: q.iconSize, weight: .medium, ink: .icon).frame(width: q.iconSlot)
                AtticText(verbatim: "Add subtask", style: .body, ink: .helper)
            }
            .padding(.horizontal, q.horizontalPadding)
            .frame(height: q.height)
            .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: q.height), style: .continuous).fill(hover))
            try component(replaced, "o17-14-add-subtask-before-\(mode.rawValue)", mode: mode)
            try component(AtticQuietAction(systemName: "plus", title: "Add subtask", action: {}).atticForcedState(.hover),
                          "o17-14-add-subtask-after-\(mode.rawValue)", mode: mode)
        }
    }
}
