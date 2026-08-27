import SwiftUI

struct MobileAppRoot: View {
    @ObservedObject var appModel: MobileAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: MobileSection = .tasks

    var body: some View {
        Group {
            if let store = appModel.store,
               let noteStore = appModel.noteStore,
               let canvasSession = appModel.canvasSession {
                VStack(spacing: 0) {
                    sectionPicker

                    switch section {
                    case .tasks:
                        MobileTaskListScreen(
                            store: store,
                            iCloudAvailability: appModel.iCloudAvailability,
                            refresh: appModel.refresh
                        )
                    case .notes:
                        MobileNotesScreen(
                            noteStore: noteStore,
                            iCloudAvailability: appModel.iCloudAvailability,
                            refresh: appModel.refresh
                        )
                    case .canvas:
                        MobileCanvasScreen(
                            session: canvasSession,
                            iCloudAvailability: appModel.iCloudAvailability
                        )
                    }
                }
            } else {
                startupFailure
            }
        }
        .fontDesign(.rounded)
        .task(id: scenePhase) {
            guard scenePhase == .active, appModel.store != nil else { return }
            // Re-read the local store once when returning to the foreground.
            // CloudKit delivery itself remains push-driven; polling this fetch
            // cannot force an import and only adds misleading churn.
            await appModel.refresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                appModel.canvasSession?.cancelActiveInteraction()
            }
        }
        .onChange(of: section) { oldSection, _ in
            if oldSection == .canvas {
                appModel.canvasSession?.cancelActiveInteraction()
            }
        }
    }

    private var startupFailure: some View {
        ContentUnavailableView {
            Label("Attic unavailable", systemImage: "exclamationmark.icloud")
        } description: {
            Text(appModel.startupError ?? "Attic couldn't open its data store.")
        } actions: {
            Button("Try Again", action: appModel.loadStore)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(MobileSection.allCases) { candidate in
                sectionButton(candidate)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mobile-section-picker")
    }

    private func sectionButton(_ candidate: MobileSection) -> some View {
        let isSelected = section == candidate

        return Button {
            guard section != candidate else { return }
            if reduceMotion {
                section = candidate
            } else {
                withAnimation(AtticMotion.quick) {
                    section = candidate
                }
            }
        } label: {
            Text(candidate.title)
                .font(.system(
                    size: 13,
                    weight: isSelected ? .semibold : .medium,
                    design: .rounded
                ))
                .foregroundStyle(
                    isSelected
                        ? Color(uiColor: .systemBackground)
                        : Color.secondary
                )
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(
                    Color.primary.opacity(isSelected ? 0.9 : 0.05),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color.primary.opacity(0.9)
                                : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 0.75
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("mobile-section-\(candidate.rawValue)")
    }
}

private enum MobileSection: String, CaseIterable, Identifiable {
    case tasks
    case notes
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .notes: "Notes"
        case .canvas: "Canvas"
        }
    }
}
