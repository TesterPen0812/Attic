import SwiftUI

struct AtticPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var canvasSession: CanvasSession
    let noteDraft: NoteDraftController
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var quickEntryTitle = ""
    @State private var isModeDockHovered = false
    @State private var hoveredModeSection: PanelSection?
    @State private var isQuickSubmitHovered = false
    @FocusState private var isQuickEntryFocused: Bool
    @FocusState private var focusedModeSection: PanelSection?
    @FocusState private var isQuickSubmitFocused: Bool

    private var cornerRadius: CGFloat { settings.panelCornerSize }

    private var panelSize: CGSize {
        uiState.panelSize
    }

    private var contentInsets: EdgeInsets {
        PanelGeometry.contentInsets(cornerSize: cornerRadius, panelSize: panelSize)
    }

    private var chromeInsets: EdgeInsets {
        PanelGeometry.chromeInsets(cornerSize: cornerRadius, panelSize: panelSize)
    }

    private var horizontalInset: CGFloat { contentInsets.leading }
    private var chromeInset: CGFloat { chromeInsets.leading }
    private var chromeTopAdjustment: CGFloat {
        max(0, chromeInsets.top - contentInsets.top)
    }
    private var chromeBottomAdjustment: CGFloat {
        max(0, chromeInsets.bottom - contentInsets.bottom)
    }
    private var taskWorkspaceTopPadding: CGFloat {
        PanelGeometry.taskWorkspaceTopPadding(
            cornerSize: cornerRadius,
            panelSize: panelSize
        )
    }
    private var isModeDockExpanded: Bool {
        isModeDockHovered || focusedModeSection != nil
    }
    private var canSaveQuickTask: Bool {
        !quickEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            sectionWorkspace
        }
        .overlay(alignment: .top) {
            topChrome
        }
        .overlay(alignment: .bottom) {
            if uiState.selectedSection.isTaskBased {
                taskEntryBar
            }
        }
        .overlay(alignment: .bottom) {
            if uiState.isComposerPresented, uiState.selectedSection.isTaskBased {
                advancedTaskComposer
            }
        }
        .overlay(alignment: .bottom) {
            if let error = currentErrorMessage {
                errorBanner(error)
            }
        }
        .padding(.top, contentInsets.top)
        .padding(.bottom, contentInsets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, systemColorScheme)
        .environment(\.atticPanelGlassStyle, settings.panelGlassStyle)
        .environment(\.controlActiveState, .key)
        .atticPanelSurface(
            translucent: settings.isTranslucent,
            glassStyle: settings.panelGlassStyle,
            opaqueColor: Color(nsColor: .windowBackgroundColor),
            cornerRadius: cornerRadius,
            prefersDarkSurface: systemColorScheme == .dark
        )
        .contextMenu {
            Button("Settings…", systemImage: "gearshape") {
                AppCoordinator.shared.openSettings()
            }
            Divider()
            Button(uiState.isPanelPinned ? "Unpin Panel" : "Pin Panel", systemImage: "pin") {
                uiState.isPanelPinned.toggle()
            }
        }
        .onChange(of: uiState.selectedSection) { _, _ in
            openMostRecentNoteIfNeeded()
        }
        .onChange(of: store.revision) { _, _ in
            uiState.reconcileTaskIDs(Set(store.tasks.map(\.id)))
        }
        .onChange(of: noteStore.revision) { _, _ in
            reconcileNoteDraft()
            openMostRecentNoteIfNeeded()
        }
    }

    private var topChrome: some View {
        HStack(alignment: .top) {
            pinButton
            Spacer(minLength: 12)
            modeDock
        }
        .atticGlassEffectContainer(spacing: 12)
        .padding(.horizontal, chromeInset)
        .padding(.top, chromeTopAdjustment)
        .frame(maxWidth: .infinity)
    }

    private var pinButton: some View {
        Button {
            uiState.isPanelPinned.toggle()
        } label: {
            Image(systemName: uiState.isPanelPinned ? "pin.fill" : "pin")
                .font(.system(size: AtticStyle.controlSymbolSize, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.9))
                .frame(width: AtticStyle.actionControlSize, height: AtticStyle.actionControlSize)
                .atticGlassControl(in: Circle())
                .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(uiState.isPanelPinned ? "Unpin panel" : "Keep panel visible")
        .accessibilityLabel(uiState.isPanelPinned ? "Unpin Attic panel" : "Pin Attic panel")
        .accessibilityAddTraits(uiState.isPanelPinned ? .isSelected : [])
        .accessibilityIdentifier("panel-pin-button")
    }

    private var modeDock: some View {
        HStack(spacing: 0) {
            ForEach(PanelSection.allCases) { section in
                let isSelected = uiState.selectedSection == section
                let isVisible = PanelModeDockLayout.isVisible(
                    section,
                    selectedSection: uiState.selectedSection,
                    isExpanded: isModeDockExpanded
                )
                let isEmphasized = isSelected
                    || hoveredModeSection == section
                    || focusedModeSection == section

                Button {
                    selectSection(section)
                } label: {
                    Image(systemName: symbol(for: section))
                        .font(.system(size: AtticStyle.controlSymbolSize, weight: isSelected ? .semibold : .regular))
                        .frame(width: AtticStyle.modeControlSize, height: AtticStyle.modeControlSize)
                        .foregroundStyle(
                            Color.primary.opacity(isSelected ? 0.96 : (isEmphasized ? 0.86 : 0.68))
                        )
                        .background(
                            Color.primary.opacity(isSelected ? 0.15 : (isEmphasized ? 0.08 : 0)),
                            in: Circle()
                        )
                        .overlay {
                            if isSelected || focusedModeSection == section {
                                Circle().stroke(
                                    Color.primary.opacity(isSelected ? 0.16 : 0.12),
                                    lineWidth: 0.75
                                )
                            }
                        }
                        .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focused($focusedModeSection, equals: section)
                .keyboardShortcut(shortcut(for: section), modifiers: .command)
                .help(section.title)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("panel-section-\(section.rawValue)")
                .frame(
                    width: isVisible ? AtticStyle.controlHitSize : 0,
                    height: AtticStyle.controlHitSize
                )
                .opacity(isVisible ? 1 : 0)
                .clipped()
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .onHover { hovering in
                    if hovering {
                        hoveredModeSection = section
                    } else if hoveredModeSection == section {
                        hoveredModeSection = nil
                    }
                }
            }
        }
        .frame(
            width: PanelModeDockLayout.width(isExpanded: isModeDockExpanded),
            height: AtticStyle.controlHitSize,
            alignment: .trailing
        )
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            isModeDockHovered = hovering
            if !hovering {
                hoveredModeSection = nil
            }
        }
        .animation(reduceMotion ? nil : AtticMotion.modeDock, value: isModeDockExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Panel sections")
        .accessibilityIdentifier("panel-section-picker")
    }

    @ViewBuilder
    private var sectionWorkspace: some View {
        if uiState.selectedSection.isTaskBased {
            taskWorkspace
                .padding(.top, taskWorkspaceTopPadding)
                .transition(.opacity)
        } else if uiState.selectedSection.isCanvas {
            CanvasPanelContent(
                session: canvasSession,
                horizontalInset: horizontalInset,
                isClearConfirmationPresented: $uiState.isCanvasConfirmationPresented
            )
            .padding(.top, 62)
            .transition(.opacity)
        } else {
            notesWorkspace
                .padding(.top, 64)
                .transition(.opacity)
        }
    }

    private var taskWorkspace: some View {
        let snapshot = store.snapshot(for: uiState.selectedSection.taskScope ?? .tasks)

        return Group {
            if snapshot.visibleCount == 0 {
                taskEmptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(allSections(from: snapshot.sections)) { section in
                            TaskSectionView(
                                store: store,
                                uiState: uiState,
                                status: section.status,
                                tasks: section.tasks
                            )
                        }
                    }
                    .padding(.horizontal, horizontalInset + 2)
                    .padding(.top, AtticStyle.taskScrollTopPadding)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.never)
            }
        }
        .mask(taskScrollMask)
    }

    private var taskScrollMask: some View {
        let stops = TaskScrollMaskLayout.stops(panelHeight: panelSize.height)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: stops.topFadeEnd),
                .init(color: .black, location: stops.bottomFadeStart),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var notesWorkspace: some View {
        Group {
            if uiState.isComposerPresented {
                NoteComposerView(noteDraft: noteDraft, uiState: uiState)
                    .padding(.horizontal, horizontalInset)
            } else {
                NotesPanelContent(
                    noteStore: noteStore,
                    noteDraft: noteDraft,
                    uiState: uiState
                )
            }
        }
    }

    private var taskEntryBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : AtticMotion.spring) {
                    if uiState.isComposerPresented {
                        uiState.endAdding()
                    } else {
                        uiState.beginAdding()
                    }
                }
            } label: {
                Image(systemName: uiState.isComposerPresented ? "xmark" : "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.92))
                    .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                    .background(
                        Color.primary.opacity(uiState.isComposerPresented ? 0.10 : 0),
                        in: Circle()
                    )
                    .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(uiState.isComposerPresented ? "Close task options" : "Task options")
            .accessibilityLabel(uiState.isComposerPresented ? "Close task options" : "Task options")
            .accessibilityIdentifier("add-task-button")

            TextField("Add a task, note, or idea", text: $quickEntryTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.92))
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity)
                .frame(height: AtticStyle.entryControlHeight)
                .focused($isQuickEntryFocused)
                .onSubmit(saveQuickTask)
                .accessibilityIdentifier("quick-entry-title")

            Button(action: saveQuickTask) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        canSaveQuickTask
                            ? Color.primary.opacity(0.94)
                            : Color.primary.opacity(0.34)
                    )
                    .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                    .background(
                        Color.primary.opacity(
                            canSaveQuickTask
                                ? ((isQuickSubmitHovered || isQuickSubmitFocused) ? 0.16 : 0.10)
                                : 0.045
                        ),
                        in: Circle()
                    )
                    .overlay {
                        Circle().stroke(
                            Color.primary.opacity(
                                isQuickSubmitFocused ? 0.30 : (canSaveQuickTask ? 0.12 : 0.06)
                            ),
                            lineWidth: isQuickSubmitFocused ? 1 : 0.75
                        )
                    }
                    .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSaveQuickTask)
            .focused($isQuickSubmitFocused)
            .onHover { isQuickSubmitHovered = $0 }
            .help("Add task")
            .accessibilityLabel("Add task")
            .accessibilityIdentifier("quick-entry-submit")
        }
        .padding(.horizontal, 2)
        .frame(height: AtticStyle.composerControlHeight)
        .atticGlassControl(in: Capsule(style: .continuous), interactive: false)
        .contentShape(Capsule(style: .continuous))
        .padding(.horizontal, chromeInset)
        .padding(.bottom, chromeBottomAdjustment)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick task entry")
        .accessibilityIdentifier("task-entry-bar")
    }

    private var advancedTaskComposer: some View {
        TaskComposerView(store: store, uiState: uiState)
            .padding(10)
            .atticGlassControl(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                interactive: false
            )
            .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
            .padding(.horizontal, chromeInset)
            .padding(.bottom, 62)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var taskEmptyState: some View {
        VStack(spacing: 6) {
            Text(uiState.selectedScope.emptyStateTitle)
                .font(.system(size: 14, weight: .medium, design: .rounded))
            Text(uiState.selectedScope == .tasks
                ? "Add a task and it will stay close by."
                : "Capture an idea for later.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalInset)
    }

    private func errorBanner(_ error: String) -> some View {
        Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .atticGlassControl(in: Capsule(), interactive: false)
            .padding(.horizontal, chromeInset)
            .padding(.bottom, uiState.selectedSection.isTaskBased ? 118 : 20)
            .accessibilityIdentifier("panel-error-message")
    }

    private var currentErrorMessage: String? {
        if uiState.selectedSection.isCanvas { return canvasSession.lastErrorMessage }
        return uiState.selectedSection.isNotes ? noteStore.lastErrorMessage : store.lastErrorMessage
    }

    private func saveQuickTask() {
        guard store.create(
            title: quickEntryTitle,
            status: uiState.selectedScope.creationStatus
        ) != nil else { return }
        quickEntryTitle = ""
        DispatchQueue.main.async { isQuickEntryFocused = true }
    }

    private func selectSection(_ section: PanelSection) {
        // Pointer activation should not leave keyboard focus holding the dock
        // open after the pointer exits. Keyboard navigation still keeps it
        // expanded while focus remains within the four section controls.
        if isModeDockHovered {
            focusedModeSection = nil
        }
        guard uiState.selectedSection != section else { return }
        if uiState.selectedSection.isNotes, noteDraft.isActive {
            guard noteDraft.close() else { return }
        }
        if uiState.selectedSection.isCanvas {
            canvasSession.cancelActiveInteraction()
        }

        let selection = {
            uiState.selectSection(section)
            if section.isNotes { openMostRecentNoteIfNeeded() }
        }
        if reduceMotion {
            selection()
        } else {
            withAnimation(AtticMotion.quick) { selection() }
        }
    }

    private func openMostRecentNoteIfNeeded() {
        guard uiState.selectedSection.isNotes,
              !uiState.isComposerPresented,
              uiState.editingNoteID == nil,
              !noteDraft.isActive,
              let mostRecentNote = noteStore.orderedNotes().first,
              noteDraft.beginEditing(mostRecentNote) else { return }

        withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            uiState.beginEditingNote(mostRecentNote)
        }
    }

    private func reconcileNoteDraft() {
        guard uiState.selectedSection.isNotes,
              uiState.isComposerPresented,
              noteDraft.isActive else { return }

        guard noteDraft.reconcileWithStore() else {
            uiState.endAdding()
            openMostRecentNoteIfNeeded()
            return
        }

        if uiState.editingNoteID != noteDraft.activeNoteID {
            uiState.editingNoteID = noteDraft.activeNoteID
        }
    }

    private func allSections(from sections: [TaskSectionSnapshot]) -> [TaskSectionSnapshot] {
        uiState.selectedScope.statuses.map { status in
            sections.first { $0.status == status }
                ?? TaskSectionSnapshot(status: status, tasks: [])
        }
    }

    private func symbol(for section: PanelSection) -> String {
        switch section {
        case .tasks: "checkmark.circle"
        case .backlog: "line.3.horizontal.circle"
        case .notes: "doc"
        case .canvas: "square.grid.3x3"
        }
    }

    private func shortcut(for section: PanelSection) -> KeyEquivalent {
        switch section {
        case .tasks: "1"
        case .backlog: "2"
        case .notes: "3"
        case .canvas: "4"
        }
    }
}

private extension PanelSection {
    var isTaskBased: Bool { taskScope != nil }
}
