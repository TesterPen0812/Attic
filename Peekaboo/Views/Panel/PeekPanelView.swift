import SwiftUI

struct PeekPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header(activeCount: headerActiveCount)
            sectionPicker

            if uiState.isComposerPresented {
                composerView
                    .padding(.horizontal, PeekabooStyle.horizontalPadding)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if uiState.selectedSection.isNotes {
                NotesPanelContent(noteStore: noteStore, uiState: uiState)
                    .transition(.opacity)
            } else {
                taskSurface
                    .transition(.opacity)
            }

            if let error = currentErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, PeekabooStyle.horizontalPadding)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .peekPanelSurface(translucent: settings.isTranslucent)
        .animation(reduceMotion ? nil : PeekabooMotion.spring, value: uiState.isComposerPresented)
        .animation(reduceMotion ? nil : PeekabooMotion.spring, value: store.tasks.map(\.id))
        .animation(reduceMotion ? nil : PeekabooMotion.spring, value: noteStore.notes.map(\.id))
        .animation(reduceMotion ? nil : PeekabooMotion.quick, value: uiState.selectedSection)
        .animation(reduceMotion ? nil : PeekabooMotion.quick, value: uiState.isDraggingTask)
        .onChange(of: uiState.selectedSection) { _, _ in
            openMostRecentNoteIfNeeded()
        }
        .onChange(of: noteStore.notes.map(\.id)) { _, _ in
            openMostRecentNoteIfNeeded()
        }
    }

    private var taskSurface: some View {
        let snapshot = store.snapshot(for: uiState.selectedSection.taskScope ?? .tasks)
        return Group {
            if snapshot.visibleCount == 0 {
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                taskList(sections: snapshot.sections)
            }
        }
    }

    @ViewBuilder
    private var composerView: some View {
        if uiState.selectedSection.isNotes {
            NoteComposerView(noteStore: noteStore, uiState: uiState)
        } else {
            TaskComposerView(store: store, uiState: uiState)
        }
    }

    private var headerActiveCount: Int {
        uiState.selectedSection.isNotes
            ? noteStore.notes.count
            : store.snapshot(for: uiState.selectedSection.taskScope ?? .tasks).activeCount
    }

    private var currentErrorMessage: String? {
        uiState.selectedSection.isNotes ? noteStore.lastErrorMessage : store.lastErrorMessage
    }

    private func openMostRecentNoteIfNeeded() {
        guard uiState.selectedSection.isNotes,
              !uiState.isComposerPresented,
              uiState.editingNoteID == nil,
              let mostRecentNote = noteStore.orderedNotes().first else {
            return
        }

        withAnimation(reduceMotion ? nil : PeekabooMotion.spring) {
            uiState.beginEditingNote(mostRecentNote)
        }
    }

    private func header(activeCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Peekaboo")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("· \(activeSubtitle(count: activeCount))")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : PeekabooMotion.quick, value: activeCount)

            Spacer()

            Button {
                AppCoordinator.shared.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-button")

            Button {
                if uiState.isComposerPresented {
                    uiState.endAdding()
                } else {
                    uiState.beginAdding()
                }
            } label: {
                Image(systemName: uiState.isComposerPresented ? "xmark" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(uiState.isComposerPresented ? "Cancel" : newItemTitle)
            .accessibilityLabel(uiState.isComposerPresented ? "Cancel" : newItemTitle)
            .accessibilityIdentifier(uiState.selectedSection.isNotes ? "add-note-button" : "add-task-button")
        }
        .padding(.horizontal, PeekabooStyle.horizontalPadding)
        .frame(height: 44)
    }

    private var sectionPicker: some View {
        HStack(spacing: 6) {
            ForEach(PanelSection.allCases) { section in
                sectionCapsule(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PeekabooStyle.horizontalPadding)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-section-picker")
    }

    private func sectionCapsule(_ section: PanelSection) -> some View {
        let isSelected = uiState.selectedSection == section

        return Button {
            selectSection(section)
        } label: {
            Text(section.title)
                .font(.system(
                    size: 10,
                    weight: isSelected ? .semibold : .medium,
                    design: .rounded
                ))
                .foregroundStyle(
                    isSelected
                        ? Color(nsColor: .windowBackgroundColor)
                        : Color.secondary
                )
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(
                    Color.primary.opacity(isSelected ? 0.9 : 0.035),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("panel-section-\(section.rawValue)")
    }

    private func selectSection(_ section: PanelSection) {
        guard uiState.selectedSection != section else { return }

        let select = {
            uiState.selectSection(section)
            if section.isNotes {
                openMostRecentNoteIfNeeded()
            }
        }

        if reduceMotion {
            select()
        } else {
            withAnimation(PeekabooMotion.quick) {
                select()
            }
        }
    }

    private func taskList(sections: [TaskSectionSnapshot]) -> some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(displaySections(from: sections)) { section in
                    TaskSectionView(
                        store: store,
                        uiState: uiState,
                        status: section.status,
                        tasks: section.tasks
                    )
                }
            }
            .padding(.horizontal, PeekabooStyle.horizontalPadding - 4)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
    }

    /// While a task is being dragged, surface every section of the scope —
    /// including empty ones — so any status is reachable as a drop target.
    private func displaySections(from sections: [TaskSectionSnapshot]) -> [TaskSectionSnapshot] {
        guard uiState.isDraggingTask else { return sections }
        return uiState.selectedScope.statuses.map { status in
            sections.first { $0.status == status }
                ?? TaskSectionSnapshot(status: status, tasks: [])
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text(uiState.selectedScope.emptyStateTitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
            Text(uiState.selectedScope == .tasks
                ? "Add a task and it will stay close by."
                : "Capture an idea for later.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 18)
    }

    private func activeSubtitle(count: Int) -> String {
        uiState.selectedSection.activeSubtitle(count: count)
    }

    private var newItemTitle: String {
        uiState.selectedSection.newItemTitle
    }
}
