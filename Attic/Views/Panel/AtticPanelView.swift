import SwiftUI

struct AtticPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var canvasSession: CanvasSession
    @ObservedObject var noteDraft: NoteDraftController
    let chromeInteractionState: PanelChromeInteractionState
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings
    @ObservedObject var subtaskPanels: SubtaskPanelController

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemColorScheme
    /// What the Tasks page keeps while another page shows (the add bar's
    /// draft and pending attachments).
    @StateObject private var tasksPageState = TasksPageState()
    @State private var isModeDockHovered = false
    @State private var hoveredModeSection: PanelSection?
    @State private var errorBannerHeight: CGFloat = 0
    @State private var noticeClearance = PanelPageNoticeClearancePreferenceKey.defaultValue
    @State private var hasRestoredNoteSession = false
    /// The current page's primary input (the Tasks add bar). The shell owns
    /// it so a page switch can take focus out of the page.
    @FocusState private var isQuickEntryFocused: Bool
    @FocusState private var focusedModeSection: PanelSection?

    private var cornerRadius: CGFloat { settings.panelCornerSize }

    private var panelSize: CGSize {
        uiState.panelSize
    }

    private var pageLayout: PanelPageLayout {
        PanelPageLayout(cornerSize: cornerRadius, panelSize: panelSize)
    }

    private var contentInsets: EdgeInsets { pageLayout.contentInsets }

    private var chromeInsets: EdgeInsets { pageLayout.chromeInsets }

    private var chromeInset: CGFloat { chromeInsets.leading }
    private var isModeDockExpanded: Bool {
        isModeDockHovered || focusedModeSection != nil
    }
    private var panelThemePalette: AtticPanelThemePalette {
        settings.panelTheme.palette(
            for: systemColorScheme,
            contrast: colorSchemeContrast
        )
    }
    private var panelSurfaceTreatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: systemColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }

    /// The native window leaves `AtticStyle.panelElevationMargin` around the
    /// surface, so the exterior elevation is drawn here.
    static let showsSurfaceElevation = true
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
        themedPanel
    }

    private var panelContent: some View {
        ZStack {
            sectionWorkspace
        }
        .coordinateSpace(name: AtticPanelCoordinateSpaceName.taskWorkspace)
        .overlay(alignment: .top) {
            topChrome
        }
        .overlay(alignment: .bottom) {
            if let error = currentErrorMessage {
                errorBanner(error)
                    .padding(.bottom, contentInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { clearance in
            if noticeClearance != clearance { noticeClearance = clearance }
        }
    }

    private var surfacedPanel: some View {
        panelContent
        .environment(\.colorScheme, systemColorScheme)
        .foregroundStyle(panelThemePalette.primaryForegroundColor, panelThemePalette.secondaryForegroundColor)
        .environment(\.controlActiveState, .key)
        .atticPanelSurface(
            treatment: panelSurfaceTreatment,
            cornerRadius: cornerRadius,
            showsElevation: Self.showsSurfaceElevation
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
    }

    private var storeObservedPanel: some View {
        surfacedPanel
        .onChange(of: uiState.selectedSection) { _, _ in
            syncComposerInteractionHeight()
            releaseTaskEntryInteractionLocks()
            openMostRecentNoteIfNeeded()
            if PerformanceSignposts.hasPendingPageSwitch {
                DispatchQueue.main.async { PerformanceSignposts.pageLaidOut() }
            }
        }
        .task {
            _ = await noteDraft.restoreRecoveryIfNeeded()
            hasRestoredNoteSession = true
            openMostRecentNoteIfNeeded()
        }
        .onChange(of: store.revision) { _, _ in
            uiState.reconcileTaskIDs(Set(store.tasks.map(\.id)))
        }
        .onPreferenceChange(TaskRowAnchorPreferenceKey.self) { frames in
            subtaskPanels.updateTaskRowFrames(frames)
        }
        .onPreferenceChange(TaskSubtaskControlFramePreferenceKey.self) { frames in
            subtaskPanels.updateSubtaskControlFrames(frames)
        }
        .onPreferenceChange(TaskListViewportPreferenceKey.self) { viewport in
            subtaskPanels.updateTaskListViewport(viewport)
        }
        .onChange(of: noteStore.revision) { _, _ in
            reconcileNoteDraft()
            openMostRecentNoteIfNeeded()
        }
    }

    private var interactionObservedPanel: some View {
        storeObservedPanel
        .onAppear {
            syncModeDockInteractionWidth()
            syncComposerInteractionHeight()
            syncNoteDraftInteractionLocks()
        }
        .onChange(of: isModeDockExpanded) { _, _ in
            syncModeDockInteractionWidth()
        }
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
    }

    private var themedPanel: some View {
        interactionObservedPanel
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

    private var topChrome: some View {
        HStack(alignment: .top) {
            pinButton
            Spacer(minLength: 12)
            modeDock
        }
        .atticGlassEffectContainer(spacing: 12)
        .padding(.horizontal, chromeInset)
        .padding(.top, chromeInsets.top)
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

    /// Pages with their own bottom controls (the Tasks add bar) report their
    /// height themselves; every other page has one compact bottom bar.
    private func syncComposerInteractionHeight() {
        guard !uiState.selectedSection.isTaskBased else { return }
        chromeInteractionState.bottomControlsHeight = AtticStyle.composerControlHeight
    }

    /// The Tasks page keeps its add-bar locks while it shows; once another
    /// page shows, nothing typed there can hold the panel open.
    private func releaseTaskEntryInteractionLocks() {
        guard !uiState.selectedSection.isTaskBased else { return }
        uiState.setInteractionLock(.quickEntryFocus, isActive: false)
        uiState.setInteractionLock(.taskComposer, isActive: false)
    }

    private var headerControlRects: [CGRect] {
        let dockWidth = PanelModeDockLayout.width(isExpanded: isModeDockExpanded)
        return [
            CGRect(x: chromeInset, y: chromeInsets.top, width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize),
            CGRect(x: panelSize.width - chromeInset - dockWidth,
                   y: chromeInsets.top, width: dockWidth, height: AtticStyle.controlHitSize)
        ]
    }

    @ViewBuilder
    private var sectionWorkspace: some View {
        if uiState.selectedSection.isTaskBased {
            TasksPageHost(
                store: store,
                uiState: uiState,
                settings: settings,
                subtaskPanels: subtaskPanels,
                state: tasksPageState,
                layout: pageLayout,
                chromeInteractionState: chromeInteractionState,
                primaryInputFocus: $isQuickEntryFocused
            )
            .transition(.opacity)
        } else if uiState.selectedSection.isCanvas {
            CanvasPageHost(
                canvasSession: canvasSession,
                uiState: uiState,
                layout: pageLayout,
                errorBannerHeight: errorBannerHeight,
                headerControlRects: headerControlRects,
                headerBottom: chromeInsets.top + AtticStyle.controlHitSize
            )
            .transition(.opacity)
        } else {
            NotesPageHost(
                noteStore: noteStore,
                noteDraft: noteDraft,
                uiState: uiState,
                layout: pageLayout,
                hasRestoredSession: hasRestoredNoteSession
            )
            .transition(.opacity)
        }
    }

    /// A compact, dismissible notice above the composer. It clears itself on
    /// the next successful save and never grows past two lines.
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.primary)
                .atticClearGlassForegroundReadability()
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismissCurrentError) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .atticGlassControl(in: Circle())
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
            .accessibilityIdentifier("panel-error-dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .atticGlassControl(in: Capsule(), interactive: false)
        .padding(.horizontal, chromeInset)
            .padding(.bottom, noticeClearance)
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

    /// Task errors that concern one family's panel show inside that panel
    /// only; the main banner carries general and composer errors.
    private var currentErrorMessage: String? {
        if uiState.selectedSection.isCanvas { return canvasSession.lastErrorMessage }
        if uiState.selectedSection.isNotes { return noteStore.lastErrorMessage }
        guard store.lastErrorOwnerID == nil else { return nil }
        return store.lastErrorMessage
    }

    private func dismissCurrentError() {
        if uiState.selectedSection.isCanvas { canvasSession.dismissErrorMessage(); return }
        if uiState.selectedSection.isNotes { noteStore.dismissError(); return }
        store.dismissError()
    }

    private func selectSection(_ section: PanelSection) {
        // Pointer activation should not leave keyboard focus holding the dock
        // open after the pointer exits. Keyboard navigation still keeps it
        // expanded while focus remains within the four section controls.
        if isModeDockHovered {
            focusedModeSection = nil
        }
        guard uiState.selectedSection != section else { return }
        // A refused Notes close must leave every other state untouched, so
        // the refusal is decided before any focus or lock changes.
        if uiState.selectedSection.isNotes, noteDraft.isActive {
            guard noteDraft.close() else { return }
        }
        PerformanceSignposts.beginPageSwitch()
        isQuickEntryFocused = false
        uiState.setInteractionLock(.quickEntryFocus, isActive: false)
        if uiState.selectedSection.isCanvas {
            canvasSession.interruptActiveInteraction()
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

private struct PanelErrorBannerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
