import AppKit
import SwiftUI

/// Uses the same TextKit host, typography, Mono and table renderer as the
/// live note. The preview has no save callbacks and is always read-only.
struct NoteHistoryPage: View {
    @ObservedObject var controller: NotesPageController
    @ObservedObject var browser: NoteHistoryBrowser
    let layout: PanelPageLayout
    @StateObject private var chrome = NotesPageChrome()
    @State private var menuAnchor = AtticMenuAnchor.Holder()
    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelToasts) private var toasts

    /// The version switch and its summary line, down from the panel's top.
    static func versionLine(_ layout: PanelPageLayout) -> ClosedRange<CGFloat> {
        (layout.headerBottom + 8)...versionLineBottom(layout)
    }

    static func versionLineBottom(_ layout: PanelPageLayout) -> CGFloat { layout.headerBottom + 52 }

    /// The page's floating edges.
    static func edges(_ layout: PanelPageLayout) -> AtticFloatingEdges {
        AtticFloatingEdges(top: versionLineBottom(layout), bottom: bottomControls(layout))
    }

    /// The bottom row's top, up from the panel's bottom edge.
    static func bottomControls(_ layout: PanelPageLayout) -> CGFloat {
        layout.chromeInsets.bottom + AtticControlSize.panelButton.height
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let session = browser.preview {
                NoteEditorRepresentable(session: session, chrome: chrome,
                    columnInset: layout.chromeInsets.leading + AtticNoteMetrics.columnInset,
                    topInset: layout.headerBottom + 76,
                    bottomInset: 64 + layout.chromeInsets.bottom,
                    headerBottom: layout.headerBottom, design: design,
                    tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] },
                    scrollOverride: browser.scrollOffset - layout.headerBottom - 76)
                    .id(session.id)
                    // Floating controls (owner, 2026-10-14): the preview runs on
                    // under the version line, visible through the variable
                    // blur (owner, 2026-10-17), and under the bottom row,
                    // sharp (owner, 2026-10-22).
                    .overlay { AtticFloatingControlsBand(height: Self.bottomControls(layout)) }
                    .accessibilityIdentifier("notes-history-preview")
            }
            // The variable blur, its own layer under the version line (the
            // bottom row has none; never an overlay of the text view).
            if browser.preview != nil { AtticEdgeBlurBackdrops(Self.edges(layout)) }
            // Top glass: the switch grew 4 pt (26 to 30), so the gap to the
            // summary shrank by as much and the summary keeps its place.
            VStack(spacing: NoteHistoryVersionSwitch.summaryGap) {
                // U-30: the app's own monochrome selected state (as the
                // tabs and menus), never the system's blue segment.
                NoteHistoryVersionSwitch(
                    choices: [(true, String(localized: "Current")),
                              (false, browser.selected?.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                                  ?? String(localized: "Version"))],
                    selection: Binding(get: { browser.showsCurrent }, set: {
                        browser.showsCurrent = $0
                        controller.refreshHistoryPreview()
                    }))
                .accessibilityIdentifier("notes-history-switch")
                Text("\(browser.comparison.differingCount) blocks differ \(browser.showsCurrent ? "from version" : "from now") · \(browser.comparison.missing.count) missing")
                    .font(.system(size: 10.5))
                    .foregroundStyle(design.tokens.color(.helper))
                    .accessibilityIdentifier("notes-history-summary")
            }
            .padding(.horizontal, layout.chromeInsets.leading)
            .padding(.top, layout.headerBottom + 8)

            VStack(spacing: 6) {
                Spacer()
                if let failure = browser.failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .foregroundStyle(design.tokens.color(.body))
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("notes-history-restore-error")
                }
                HStack(spacing: 6) {
                    // U-31: leaving history is an ✕, so the only chevrons
                    // on the row step between versions.
                    AtticRaisedButton(systemName: "xmark", label: "Close History", help: String(localized: "Close History (Esc)")) {
                        controller.closeHistory()
                    }
                        .accessibilityIdentifier("notes-history-back")
                    Spacer(minLength: 0)
                    Button { step(1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 32) }
                        .disabled(browser.selectedIndex + 1 >= browser.entries.count || browser.isRestoring)
                        .accessibilityLabel("Older version")
                        .accessibilityIdentifier("notes-history-older")
                    Button {
                        guard let view = menuAnchor.view else { return }
                        AtticNativeMenu.popUp(versionCommands, in: view)
                    } label: {
                        Text(browser.selected?.createdAt.formatted(.dateTime.hour().minute()) ?? "—")
                            .monospacedDigit()
                            .frame(width: 56, height: 32)
                    }
                    .background(AtticMenuAnchor(holder: menuAnchor).accessibilityHidden(true))
                    .onKeyPress(.leftArrow) { step(1); return .handled }
                    .onKeyPress(.rightArrow) { step(-1); return .handled }
                    .accessibilityLabel("Versions")
                    .accessibilityIdentifier("notes-history-versions")
                    Button { step(-1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 32) }
                        .disabled(browser.selectedIndex == 0 || browser.isRestoring)
                        .accessibilityLabel("Newer version")
                        .accessibilityIdentifier("notes-history-newer")
                    Spacer(minLength: 0)
                    Button { restore() } label: {
                        Text(browser.failure == nil ? "Restore" : "Retry").frame(width: 60, height: 32)
                    }
                        .disabled(browser.selected?.canRestore != true || browser.isRestoring || browser.showsCurrent)
                        .accessibilityIdentifier("notes-history-restore")
                }
                .font(.system(size: 11.5, weight: .medium))
                .buttonStyle(AtticRaisedButtonStyle(cornerRadius: AtticRadius.control(height: AtticControlSize.panelButton.height)))
                .frame(height: AtticControlSize.panelButton.height)
            }
            .padding(.horizontal, layout.chromeInsets.leading)
            .padding(.bottom, layout.chromeInsets.bottom)
        }
        .onChange(of: design) { _, design in browser.preview?.engine.update(design: design) }
        .onExitCommand { controller.closeHistory() }
        .onAppear { chrome.menuCommands = { versionCommands } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notes-history-browser")
    }

    private func step(_ delta: Int) { controller.selectHistoryVersion(browser.selectedIndex + delta) }

    private var versionCommands: [AtticMenuCommand] {
        var commands: [AtticMenuCommand] = []
        var lastDay: Date?
        for (index, entry) in browser.entries.enumerated() {
            let day = Calendar.current.startOfDay(for: entry.createdAt)
            if day != lastDay {
                commands.append(AtticMenuCommand("\(day.formatted(.dateTime.weekday().month().day()))", isDisabled: true,
                    startsSection: !commands.isEmpty) {})
                lastDay = day
            }
            let reason = entry.reason == .pause ? "" : " · \(entry.reason?.historyLabel ?? "Saved version")"
            commands.append(AtticMenuCommand("\(entry.createdAt.formatted(.dateTime.hour().minute()))\(reason)",
                isChecked: index == browser.selectedIndex, identifier: "notes-history-version-\(entry.id)") {
                controller.selectHistoryVersion(index)
            })
        }
        commands.append(AtticMenuCommand("Copy This Version", startsSection: true, identifier: "notes-history-copy") {
            controller.copyHistoryVersion()
        })
        return commands
    }

    private func restore() {
        let timestamp = browser.selected?.createdAt.formatted(.dateTime.hour().minute()) ?? ""
        Task { @MainActor in
            let undoBefore = controller.versionRestoreUndoID
            guard await controller.restoreHistoryVersionDurably() else { return }
            let ticket = controller.versionRestoreUndoID
            // A task's page restores without the Notes page's Undo ticket:
            // the replaced text stays a version in its history.
            guard ticket != nil, ticket != undoBefore else {
                toasts?.show("Restored the version from \(timestamp)", actionTitle: String(localized: "OK"), answersUndoKey: false) {}
                return
            }
            toasts?.show("Restored the version from \(timestamp)", answersUndoKey: false, performingAsync: {
                await controller.undoVersionRestoreDurably(expectedID: ticket)
                    ? .applied : .failed(CommandFailure("The restore could not be undone. The note may have changed; your current text is kept."))
            })
        }
    }
}

/// History's Current / version switch (U-30): the selected half in the
/// app's monochrome selected fill and the heading ink, the other half
/// quiet; hover is a lighter fill. One tab stop; ← → move.
///
/// Top glass (2026-10-22): the preview scrolls under it, so its track is
/// the floating glass, as the page switch's capsule: the raised material at
/// the Medium height (was a recessed 26 pt track), the halves 4 pt inside.
/// Under Reduce Transparency it is the opaque raised surface.
struct NoteHistoryVersionSwitch: View {
    let choices: [(value: Bool, title: String)]
    @Binding var selection: Bool

    @Environment(\.atticDesign) private var design
    @State private var hovered: Bool?

    static let height = AtticTopGlassMetrics.height
    static let inset = AtticControlSize.capsuleInset
    /// The summary under it: 6 below the old 26 pt track, so 2 below this one.
    static let summaryGap: CGFloat = 6 - (height - 26)

    var body: some View {
        let tokens = design.tokens
        let height = Self.height
        let inset = Self.inset
        let outer = AtticRadius.control(height: height)
        let inner = max(0, outer - inset)
        HStack(spacing: 0) {
            ForEach(choices, id: \.value) { choice in
                let isSelected = choice.value == selection
                Button { selection = choice.value } label: {
                    AtticText(verbatim: choice.title, style: .controlLabel, ink: isSelected ? .heading : .helper)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - inset * 2)
                        .background {
                            RoundedRectangle(cornerRadius: inner, style: .continuous)
                                .fill((isSelected ? tokens.selected : (hovered == choice.value ? tokens.chipHover : .clear)).color)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(AtticUndimmedButtonStyle())
                .focusable(false)
                .onHover { hovered = $0 ? choice.value : (hovered == choice.value ? nil : hovered) }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(inset)
        .frame(height: height)
        .atticRaisedMaterial(cornerRadius: outer, interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Compare version"))
    }
}
