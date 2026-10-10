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

    var body: some View {
        ZStack(alignment: .top) {
            if let session = browser.preview {
                NoteEditorRepresentable(session: session, chrome: chrome,
                    columnInset: layout.chromeInsets.leading + AtticNoteMetrics.columnInset,
                    topInset: layout.headerBottom + 76,
                    bottomInset: 64 - AtticControlSize.panelButton.height,
                    headerBottom: layout.headerBottom, design: design,
                    tagEditor: { AnyView(EmptyView()) }, tagCounts: { [:] },
                    scrollOverride: browser.scrollOffset - layout.headerBottom - 76)
                    .id(session.id)
                    .atticScrollUnderFade(plainText: [(layout.headerBottom + 32)...(layout.headerBottom + 52)], topEdge: layout.scrollEdgeFadeTop,
                                         bottomEdge: 0)
                    .padding(.bottom, layout.chromeInsets.bottom + AtticControlSize.panelButton.height)
                    .accessibilityIdentifier("notes-history-preview")
            }
            VStack(spacing: 6) {
                Picker("Compare version", selection: Binding(get: { browser.showsCurrent }, set: {
                    browser.showsCurrent = $0
                    controller.refreshHistoryPreview()
                })) {
                    Text("Current").tag(true)
                    Text(browser.selected?.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "Version").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .font(.system(size: 11.5, weight: .medium))
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
                    AtticRaisedButton(systemName: "chevron.backward", label: "Back") { controller.closeHistory() }
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
            guard await controller.restoreHistoryVersionDurably() else { return }
            let ticket = controller.versionRestoreUndoID
            toasts?.show("Restored the version from \(timestamp)", answersUndoKey: false, performingAsync: {
                await controller.undoVersionRestoreDurably(expectedID: ticket)
                    ? .applied : .failed(CommandFailure("The restore could not be undone. The note may have changed; your current text is kept."))
            })
        }
    }
}
