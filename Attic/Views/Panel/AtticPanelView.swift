import SwiftUI

struct AtticPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var canvasSession: CanvasSession
    @ObservedObject var noteDraft: NoteDraftController
    let chromeInteractionState: PanelChromeInteractionState
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var quickEntryTitle = ""
    @State private var quickEntryPriority: TaskPriority = .none
    @State private var isModeDockHovered = false
    @State private var hoveredModeSection: PanelSection?
    @State private var isQuickSubmitHovered = false
    @State private var errorBannerHeight: CGFloat = 0
    @State private var hasRestoredNoteSession = false
    @FocusState private var isQuickEntryFocused: Bool
    @FocusState private var focusedModeSection: PanelSection?
    @FocusState private var isQuickSubmitFocused: Bool
    @FocusState private var focusedQuickPriority: TaskPriority?

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
    private var isTaskEntryExpanded: Bool {
        isQuickEntryFocused || uiState.isComposerPresented
    }
    private var panelThemePalette: AtticPanelThemePalette {
        settings.panelTheme.palette(
            for: systemColorScheme,
            contrast: colorSchemeContrast
        )
    }
    private var panelSurfaceTreatment: AtticPanelSurfaceTreatment {
        settings.panelTheme.surfaceTreatment(
            colorScheme: systemColorScheme,
            contrast: colorSchemeContrast,
            glassStyle: settings.panelGlassStyle,
            isTranslucent: settings.isTranslucent,
            reduceTransparency: reduceTransparency
        )
    }
    private var panelAccentColor: Color {
        settings.panelTheme.usesSystemAccent
            ? Color.accentColor
            : panelThemePalette.accentColor
    }
    private var usesOriginalTheme: Bool {
        settings.panelTheme == .original
    }
    private var hasIncreasedContrast: Bool {
        colorSchemeContrast == .increased
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
            if let error = currentErrorMessage {
                errorBanner(error)
            }
        }
        .padding(.top, contentInsets.top)
        .padding(.bottom, contentInsets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, systemColorScheme)
        .environment(\.atticPanelGlassStyle, settings.panelGlassStyle)
        .environment(\.atticPanelTranslucencyEnabled, settings.isTranslucent)
        .environment(
            \.atticClearGlassForegroundReadabilityEnabled,
            AtticClearGlassReadabilityPolicy.isEnabled(
                isTranslucent: settings.isTranslucent,
                isClearStyle: settings.panelGlassStyle == .clear,
                reduceTransparency: reduceTransparency
            )
        )
        .environment(\.controlActiveState, .key)
        .atticPanelSurface(
            treatment: panelSurfaceTreatment,
            glassStyle: settings.panelGlassStyle,
            opaqueColor: Color(nsColor: .windowBackgroundColor),
            cornerRadius: cornerRadius,
            prefersDarkSurface: systemColorScheme == .dark
        )
        .overlay {
            dockingPreview
        }
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
            syncComposerInteractionHeight()
            syncTaskEntryInteractionLocks()
            openMostRecentNoteIfNeeded()
        }
        .task {
            _ = await noteDraft.restoreRecoveryIfNeeded()
            hasRestoredNoteSession = true
            openMostRecentNoteIfNeeded()
        }
        .onChange(of: store.revision) { _, _ in
            uiState.reconcileTaskIDs(Set(store.tasks.map(\.id)))
        }
        .onChange(of: noteStore.revision) { _, _ in
            reconcileNoteDraft()
            openMostRecentNoteIfNeeded()
        }
        .onAppear {
            syncModeDockInteractionWidth()
            syncComposerInteractionHeight()
            syncTaskEntryInteractionLocks()
            syncNoteDraftInteractionLocks()
        }
        .onChange(of: isModeDockExpanded) { _, _ in
            syncModeDockInteractionWidth()
        }
        .onChange(of: isTaskEntryExpanded) { _, _ in
            syncComposerInteractionHeight()
        }
        .onChange(of: isQuickEntryFocused) { _, isFocused in
            syncTaskEntryInteractionLocks()
            if isFocused, uiState.selectedSection.isTaskBased {
                // Keep priority controls mounted when Tab or a pointer click
                // transfers focus out of the title field into the composer.
                uiState.beginAdding()
            }
        }
        .onChange(of: isQuickSubmitFocused) { _, _ in syncTaskEntryInteractionLocks() }
        .onChange(of: focusedQuickPriority) { _, _ in syncTaskEntryInteractionLocks() }
        .onChange(of: quickEntryTitle) { _, _ in syncTaskEntryInteractionLocks() }
        .onChange(of: quickEntryPriority) { _, _ in syncTaskEntryInteractionLocks() }
        .onChange(of: noteDraft.isDirty) { _, _ in
            syncNoteDraftInteractionLocks()
        }
        .onChange(of: noteDraft.hasConflict) { _, _ in
            syncNoteDraftInteractionLocks()
        }
        .onChange(of: noteStore.attachmentImportState) { _, _ in
            syncNoteDraftInteractionLocks()
        }
        .onPreferenceChange(PanelErrorBannerHeightPreferenceKey.self) { measuredHeight in
            let resolvedHeight = currentErrorMessage == nil
                ? 0
                : max(0, measuredHeight.isFinite ? measuredHeight : 0)
            if abs(errorBannerHeight - resolvedHeight) >= 0.5 {
                errorBannerHeight = resolvedHeight
            }
        }
        .environment(\.atticPanelThemePalette, panelThemePalette)
        .environment(
            \.atticPanelUsesSystemAccent,
            settings.panelTheme.usesSystemAccent
        )
        .environment(
            \.atticPanelUsesSystemOpaqueSurface,
            panelSurfaceTreatment.usesSystemOpaqueSurface
        )
        .tint(panelAccentColor)
        .accentColor(panelAccentColor)
    }

    @ViewBuilder
    private var dockingPreview: some View {
        if let corner = uiState.dockingPreviewCorner {
            ZStack(alignment: dockingAlignment(for: corner)) {
                Color.clear
                Image(systemName: dockingSymbol(for: corner))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 28, height: 28)
                    .atticGlassControl(in: Circle(), interactive: false)
                    .padding(14)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(reduceMotion ? nil : AtticMotion.quick, value: corner)
            .accessibilityHidden(true)
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
                .atticClearGlassForegroundReadability()
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
        .accessibilityRemoveTraits(uiState.isPanelPinned ? [] : .isSelected)
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
                let isFocused = focusedModeSection == section

                Button {
                    selectSection(section)
                } label: {
                    Image(systemName: symbol(for: section))
                        .font(.system(size: AtticStyle.controlSymbolSize, weight: isSelected ? .semibold : .regular))
                        .frame(width: AtticStyle.modeControlSize, height: AtticStyle.modeControlSize)
                        .foregroundStyle(
                            modeForegroundColor(
                                isSelected: isSelected,
                                isEmphasized: isEmphasized,
                                isFocused: isFocused
                            )
                        )
                        .atticClearGlassForegroundReadability()
                        .background(
                            modeBackgroundColor(
                                isSelected: isSelected,
                                isEmphasized: isEmphasized,
                                isFocused: isFocused
                            ),
                            in: Circle()
                        )
                        .overlay {
                            if isSelected || isFocused {
                                Circle().stroke(
                                    modeStrokeColor(isSelected: isSelected),
                                    lineWidth: hasIncreasedContrast ? 1 : 0.75
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
                .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
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

    private func syncModeDockInteractionWidth() {
        chromeInteractionState.modeDockWidth = PanelModeDockLayout.width(
            isExpanded: isModeDockExpanded
        )
    }

    private func syncComposerInteractionHeight() {
        chromeInteractionState.bottomControlsHeight =
            uiState.selectedSection.isTaskBased && isTaskEntryExpanded ? 88 : 42
    }

    private func syncTaskEntryInteractionLocks() {
        let isTaskSection = uiState.selectedSection.isTaskBased
        uiState.setInteractionLock(
            .quickEntryFocus,
            isActive: isTaskSection && (isQuickEntryFocused || isQuickSubmitFocused || focusedQuickPriority != nil)
        )
        uiState.setInteractionLock(
            .taskComposer,
            isActive: isTaskSection && (!quickEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quickEntryPriority != .none)
        )
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
                isClearConfirmationPresented: $uiState.isCanvasConfirmationPresented,
                bottomOverlayInset: PanelGeometry.canvasErrorBannerOffset(
                    measuredHeight: errorBannerHeight
                )
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
                    .padding(.bottom, isTaskEntryExpanded ? 142 : 96)
                }
                .scrollIndicators(.never)
            }
        }
        .mask(taskScrollMask)
    }

    private var taskScrollMask: some View {
        let stops = TaskScrollMaskLayout.stops(
            panelHeight: panelSize.height,
            bottomObscuredHeight: isTaskEntryExpanded ? 122 : 76
        )
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
            if !hasRestoredNoteSession {
                ProgressView("Restoring draft…")
            } else if uiState.isComposerPresented {
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(reduceMotion ? nil : AtticMotion.spring) {
                        if uiState.isComposerPresented {
                            isQuickEntryFocused = false
                            uiState.endAdding()
                        } else {
                            uiState.beginAdding()
                            isQuickEntryFocused = true
                        }
                    }
                } label: {
                    Image(systemName: uiState.isComposerPresented ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.92))
                        .atticClearGlassForegroundReadability()
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
                    .atticClearGlassForegroundReadability()
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity)
                    .frame(height: AtticStyle.entryControlHeight)
                    .focused($isQuickEntryFocused)
                    .onSubmit(saveQuickTask)
                    .onExitCommand {
                        isQuickEntryFocused = false
                        uiState.endAdding()
                    }
                    .accessibilityIdentifier("quick-entry-title")

                Button(action: saveQuickTask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            quickSubmitForegroundColor
                        )
                        .atticClearGlassForegroundReadability()
                        .frame(width: AtticStyle.composerActionSize, height: AtticStyle.composerActionSize)
                        .background(
                            quickSubmitBackgroundColor,
                            in: Circle()
                        )
                        .overlay {
                            Circle().stroke(
                                quickSubmitStrokeColor,
                                lineWidth: (isQuickSubmitFocused || hasIncreasedContrast) ? 1 : 0.75
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
            if isTaskEntryExpanded {
                HStack(spacing: 4) {
                    ForEach(TaskPriority.allCases) { priority in
                        Button {
                            quickEntryPriority = priority
                            uiState.beginAdding()
                            isQuickEntryFocused = true
                        } label: {
                            Image(systemName: priority == .none ? "flag.slash" : "flag.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(priority == .none ? Color.secondary : priority.color)
                                .frame(width: 30, height: 30)
                                .background(
                                    priority.color.opacity(quickEntryPriority == priority ? 0.16 : 0),
                                    in: Circle()
                                )
                                .overlay {
                                    Circle().stroke(
                                        priority.color.opacity(quickEntryPriority == priority ? 0.55 : 0),
                                        lineWidth: 1)
                                }
                                .frame(width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedQuickPriority, equals: priority)
                        .help("\(priority.title) priority")
                        .accessibilityLabel("\(priority.title) priority")
                        .accessibilityAddTraits(quickEntryPriority == priority ? .isSelected : [])
                        .accessibilityIdentifier("task-priority-\(priority.rawValue)")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .atticGlassControl(
            in: RoundedRectangle(cornerRadius: AtticStyle.composerControlHeight / 2, style: .continuous),
            interactive: false
        )
        .contentShape(
            RoundedRectangle(cornerRadius: AtticStyle.composerControlHeight / 2, style: .continuous)
        )
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isTaskEntryExpanded)
        .padding(.horizontal, chromeInset)
        .padding(.bottom, chromeBottomAdjustment)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick task entry")
        .accessibilityIdentifier("task-entry-bar")
    }

    private var taskEmptyState: some View {
        VStack(spacing: 6) {
            Text(uiState.selectedScope.emptyStateTitle)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .atticClearGlassForegroundReadability()
            Text(uiState.selectedScope == .tasks
                ? "Add a task and it will stay close by."
                : "Capture an idea for later.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .atticClearGlassForegroundReadability()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalInset)
    }

    private func errorBanner(_ error: String) -> some View {
        Text(error)
            .font(.caption2)
            .foregroundStyle(.red)
            .atticClearGlassForegroundReadability()
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .atticGlassControl(in: Capsule(), interactive: false)
            .padding(.horizontal, chromeInset)
            .padding(.bottom, uiState.selectedSection.isTaskBased ? 118 : 20)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PanelErrorBannerHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .accessibilityIdentifier("panel-error-message")
    }

    private var currentErrorMessage: String? {
        if uiState.selectedSection.isCanvas { return canvasSession.lastErrorMessage }
        return uiState.selectedSection.isNotes ? noteStore.lastErrorMessage : store.lastErrorMessage
    }

    private func saveQuickTask() {
        guard store.create(
            title: quickEntryTitle,
            priority: quickEntryPriority,
            status: uiState.selectedScope.creationStatus
        ) != nil else { return }
        quickEntryTitle = ""
        quickEntryPriority = .none
        uiState.beginAdding()
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
        isQuickEntryFocused = false
        uiState.setInteractionLock(.quickEntryFocus, isActive: false)
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
        guard hasRestoredNoteSession,
              uiState.selectedSection.isNotes,
              !uiState.isComposerPresented,
              uiState.editingNoteID == nil else { return }

        if noteDraft.isActive {
            if let restored = noteStore.orderedNotes().first(where: { $0.id == noteDraft.activeNoteID }) {
                uiState.beginEditingNote(restored)
            } else {
                uiState.beginAdding()
            }
            return
        }

        let note: NoteItem
        if noteDraft.resumeLastSession(),
           let restored = noteStore.orderedNotes().first(where: { $0.id == noteDraft.activeNoteID }) {
            note = restored
        } else if let recent = noteStore.orderedNotes().first,
                  noteDraft.beginEditing(recent) {
            note = recent
        } else {
            return
        }

        withAnimation(reduceMotion ? nil : AtticMotion.spring) {
            uiState.beginEditingNote(note)
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

    private func syncNoteDraftInteractionLocks() {
        uiState.setInteractionLock(.notesDirty, isActive: noteDraft.isDirty)
        uiState.setInteractionLock(.notesConflict, isActive: noteDraft.hasConflict)
        let isImporting: Bool
        if case .importing = noteStore.attachmentImportState {
            isImporting = true
        } else {
            isImporting = false
        }
        uiState.setInteractionLock(.notesImport, isActive: isImporting)
    }

    private func modeForegroundColor(
        isSelected: Bool,
        isEmphasized: Bool,
        isFocused: Bool
    ) -> Color {
        if usesOriginalTheme {
            return Color.primary.opacity(isSelected ? 0.96 : (isEmphasized ? 0.86 : 0.68))
        }
        if isSelected || isFocused {
            return panelThemePalette.accentColor.opacity(isSelected ? 0.98 : 0.92)
        }
        return Color.primary.opacity(isEmphasized ? 0.86 : 0.68)
    }

    private func modeBackgroundColor(
        isSelected: Bool,
        isEmphasized: Bool,
        isFocused: Bool
    ) -> Color {
        if usesOriginalTheme {
            return Color.primary.opacity(isSelected ? 0.15 : (isEmphasized ? 0.08 : 0))
        }
        if isSelected {
            return panelThemePalette.accentColor.opacity(panelThemePalette.selectedFillOpacity)
        }
        if isFocused {
            return panelThemePalette.accentColor.opacity(
                min(panelThemePalette.selectedFillOpacity * 0.72, 0.13)
            )
        }
        return Color.primary.opacity(isEmphasized ? 0.08 : 0)
    }

    private func modeStrokeColor(isSelected: Bool) -> Color {
        if usesOriginalTheme {
            let opacity = isSelected ? 0.16 : 0.12
            return Color.primary.opacity(hasIncreasedContrast ? opacity + 0.12 : opacity)
        }
        let opacity = panelThemePalette.selectedStrokeOpacity
            + (hasIncreasedContrast ? 0.14 : 0)
        return panelThemePalette.accentColor.opacity(min(opacity, 1))
    }

    private var quickSubmitForegroundColor: Color {
        guard canSaveQuickTask else { return Color.primary.opacity(0.34) }
        return usesOriginalTheme
            ? Color.primary.opacity(0.94)
            : panelThemePalette.accentColor.opacity(0.98)
    }

    private var quickSubmitBackgroundColor: Color {
        guard canSaveQuickTask else { return Color.primary.opacity(0.045) }
        let isEmphasized = isQuickSubmitHovered || isQuickSubmitFocused
        if usesOriginalTheme {
            return Color.primary.opacity(isEmphasized ? 0.16 : 0.10)
        }
        let opacity = isEmphasized
            ? min(panelThemePalette.selectedFillOpacity + 0.06, 0.24)
            : max(panelThemePalette.selectedFillOpacity * 0.72, 0.08)
        return panelThemePalette.accentColor.opacity(opacity)
    }

    private var quickSubmitStrokeColor: Color {
        if usesOriginalTheme {
            let opacity = isQuickSubmitFocused ? 0.30 : (canSaveQuickTask ? 0.12 : 0.06)
            return Color.primary.opacity(hasIncreasedContrast ? min(opacity + 0.12, 1) : opacity)
        }
        guard canSaveQuickTask else {
            return Color.primary.opacity(hasIncreasedContrast ? 0.16 : 0.06)
        }
        let baseOpacity = isQuickSubmitFocused
            ? panelThemePalette.selectedStrokeOpacity
            : panelThemePalette.selectedStrokeOpacity * 0.55
        return panelThemePalette.accentColor.opacity(
            min(baseOpacity + (hasIncreasedContrast ? 0.14 : 0), 1)
        )
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

    private func dockingAlignment(for corner: ScreenCorner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private func dockingSymbol(for corner: ScreenCorner) -> String {
        switch corner {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }
}

private struct PanelErrorBannerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension PanelSection {
    var isTaskBased: Bool { taskScope != nil }
}
