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
    @State private var quickEntryTitle = ""
    @State private var quickEntryPriority: TaskPriority = .none
    /// Pending attachments for the task being written; same lifetime as the
    /// draft title above.
    @StateObject private var composerAttachments = TaskComposerAttachments()
    @State private var isComposerFileDropTargeted = false
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
        composerAttachments.canSubmit(title: quickEntryTitle)
    }
    private var canAddComposerAttachments: Bool {
        composerAttachments.canAdd && !TaskAttachmentPicker.isPresenting(uiState)
    }
    private var isTaskEntryExpanded: Bool {
        uiState.isComposerPresented
    }
    private var taskEntryHeight: CGFloat {
        AtticStyle.taskComposerRowHeight
            + (isTaskEntryExpanded ? AtticStyle.taskComposerOptionsHeight : 0)
            + (composerAttachments.isEmpty ? 0 : TaskComposerLayout.pendingStripHeight)
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
            glassStyle: effectiveGlassStyle,
            isTranslucent: settings.isTranslucent,
            reduceTransparency: reduceTransparency
        )
    }
    private var effectiveGlassStyle: PanelGlassStyle {
        settings.panelGlassStyle.resolved(for: settings.panelTheme, colorScheme: systemColorScheme)
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
        themedPanel
    }

    private var panelContent: some View {
        ZStack {
            sectionWorkspace
        }
        .coordinateSpace(name: AtticPanelCoordinateSpaceName.taskWorkspace)
        // Rows hidden or fading under the chrome bands are inert as well as
        // dimmed: these shields sit between the list and the controls, so a
        // press or hover landing beside the pin button, in the fade, or on
        // the composer can never reach a row the mask has faded out. Scroll
        // wheel events still reach the list, which AppKit hit-tests
        // independently of these shapes.
        .overlay(alignment: .top) {
            if uiState.selectedSection.isTaskBased {
                AtticPointerShield(height: taskTopObscuredHeight + TaskScrollMaskLayout.fadeLength)
            }
        }
        .overlay(alignment: .bottom) {
            if uiState.selectedSection.isTaskBased {
                AtticPointerShield(height: taskBottomObscuredHeight + TaskScrollMaskLayout.fadeLength)
            }
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
                    .padding(.bottom, contentInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var surfacedPanel: some View {
        panelContent
        .environment(\.colorScheme, systemColorScheme)
        .foregroundStyle(panelThemePalette.primaryForegroundColor, panelThemePalette.secondaryForegroundColor)
        .environment(\.atticPanelGlassStyle, effectiveGlassStyle)
        .environment(\.atticPanelTranslucencyEnabled, settings.isTranslucent)
        .environment(
            \.atticClearGlassForegroundReadabilityEnabled,
            AtticClearGlassReadabilityPolicy.isEnabled(
                isTranslucent: settings.isTranslucent,
                isClearStyle: effectiveGlassStyle == .clear,
                reduceTransparency: reduceTransparency
            )
        )
        .environment(\.controlActiveState, .key)
        .atticPanelSurface(
            treatment: panelSurfaceTreatment,
            cornerRadius: cornerRadius,
            gradientCoverage: settings.panelGradientCoverage,
            gradientColorHex: settings.panelGradientColorHex,
            showsElevation: true
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
            syncTaskEntryInteractionLocks()
            syncNoteDraftInteractionLocks()
        }
        .onChange(of: isModeDockExpanded) { _, _ in
            syncModeDockInteractionWidth()
        }
        .onChange(of: isTaskEntryExpanded) { _, _ in
            syncComposerInteractionHeight()
        }
        .onChange(of: composerAttachments.isEmpty) { _, _ in
            syncComposerInteractionHeight()
            syncTaskEntryInteractionLocks()
        }
        .onChange(of: isQuickEntryFocused) { _, _ in
            syncTaskEntryInteractionLocks()
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

    private func syncComposerInteractionHeight() {
        chromeInteractionState.bottomControlsHeight =
            uiState.selectedSection.isTaskBased ? taskEntryHeight : AtticStyle.composerControlHeight
    }

    private func syncTaskEntryInteractionLocks() {
        let isTaskSection = uiState.selectedSection.isTaskBased
        uiState.setInteractionLock(
            .quickEntryFocus,
            isActive: isTaskSection && (isQuickEntryFocused || isQuickSubmitFocused || focusedQuickPriority != nil)
        )
        uiState.setInteractionLock(
            .taskComposer,
            isActive: isTaskSection && (!quickEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || quickEntryPriority != .none || !composerAttachments.isEmpty)
        )
    }

    @ViewBuilder
    private var sectionWorkspace: some View {
        if uiState.selectedSection.isTaskBased {
            taskWorkspace
                .transition(.opacity)
        } else if uiState.selectedSection.isCanvas {
            CanvasPanelContent(
                session: canvasSession,
                horizontalInset: horizontalInset,
                isClearConfirmationPresented: $uiState.isCanvasConfirmationPresented,
                bottomOverlayInset: PanelGeometry.canvasErrorBannerOffset(
                    measuredHeight: errorBannerHeight
                ) + contentInsets.bottom,
                topOverlayInset: chromeInsets.top + AtticStyle.controlHitSize,
                mainControlRects: [
                    CGRect(x: chromeInset, y: chromeInsets.top, width: AtticStyle.controlHitSize, height: AtticStyle.controlHitSize),
                    CGRect(x: panelSize.width - chromeInset - PanelModeDockLayout.width(isExpanded: isModeDockExpanded),
                           y: chromeInsets.top, width: PanelModeDockLayout.width(isExpanded: isModeDockExpanded), height: AtticStyle.controlHitSize)
                ]
            )
            .transition(.opacity)
        } else {
            notesWorkspace
                .transition(.opacity)
        }
    }

    /// The band at the top of the workspace the pin button and mode dock
    /// occupy, plus a little breathing room below them.
    private var taskTopObscuredHeight: CGFloat {
        chromeInsets.top + AtticStyle.controlHitSize + 6
    }

    /// The band the composer shell occupies, plus its bottom inset.
    private var taskBottomObscuredHeight: CGFloat {
        chromeInsets.bottom + taskEntryHeight + 6
    }

    private var taskWorkspace: some View {
        let snapshot = store.snapshot(for: uiState.selectedSection.taskScope ?? .tasks)

        return Group {
            if snapshot.visibleCount == 0 {
                taskEmptyState
                    .padding(.top, contentInsets.top + taskWorkspaceTopPadding)
                    .padding(.bottom, contentInsets.bottom)
            } else {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(allSections(from: snapshot.sections)) { section in
                            TaskSectionView(
                                store: store,
                                uiState: uiState,
                                subtaskPanels: subtaskPanels,
                                status: section.status,
                                tasks: section.tasks
                            )
                        }
                    }
                    .padding(.horizontal, horizontalInset + 2)
                    .padding(.top, contentInsets.top + taskWorkspaceTopPadding + AtticStyle.taskScrollTopPadding)
                    .padding(.bottom, contentInsets.bottom + taskEntryHeight + 54)
                }
                .scrollIndicators(.never)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TaskListViewportPreferenceKey.self,
                            value: proxy.frame(
                                in: .named(AtticPanelCoordinateSpaceName.taskWorkspace)
                            )
                        )
                    }
                }
            }
        }
        .mask(taskScrollMask)
    }

    private var taskScrollMask: some View {
        let stops = TaskScrollMaskLayout.stops(
            height: panelSize.height,
            topObscuredHeight: taskTopObscuredHeight,
            bottomObscuredHeight: taskBottomObscuredHeight
        )
        return LinearGradient(
            stops: TaskScrollMaskLayout.gradientStops(stops, underChromeOpacity: TaskScrollMaskLayout.underChromeOpacity(
                reduceTransparency: reduceTransparency, increasedContrast: hasIncreasedContrast)),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var notesWorkspace: some View {
        Group {
            if !hasRestoredNoteSession {
                ProgressView("Restoring draft…")
            } else if uiState.isComposerPresented {
                NoteComposerView(noteDraft: noteDraft, uiState: uiState,
                                 topContentInset: contentInsets.top + 64,
                                 bottomContentInset: contentInsets.bottom)
                    .padding(.horizontal, horizontalInset)
            } else {
                NotesPanelContent(
                    noteStore: noteStore,
                    noteDraft: noteDraft,
                    uiState: uiState,
                    topContentInset: contentInsets.top + 64,
                    bottomContentInset: contentInsets.bottom
                )
            }
        }
    }

    private var taskEntryBar: some View {
        VStack(spacing: 0) {
            // Pending items sit above the text row, so the bottom-anchored
            // shell grows upward and the text row never moves.
            if !composerAttachments.isEmpty {
                TaskComposerAttachmentStrip(attachments: composerAttachments, store: store)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Menu {
                        Button("Attach images or files…", systemImage: "paperclip", action: chooseComposerAttachments)
                            .disabled(!canAddComposerAttachments)
                            .accessibilityIdentifier("quick-entry-attach")
                        Button(isTaskEntryExpanded
                                ? uiState.selectedScope.quickEntryCloseOptionsCommandTitle
                                : uiState.selectedScope.quickEntryOptionsCommandTitle,
                               systemImage: "flag") {
                            withAnimation(reduceMotion ? nil : AtticMotion.quick) {
                                if isTaskEntryExpanded { uiState.endAdding() }
                                else { uiState.beginAdding() }
                            }
                            isQuickEntryFocused = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(panelThemePalette.primaryForegroundColor)
                            .frame(width: AtticStyle.taskComposerControlSize, height: AtticStyle.taskComposerControlSize)
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: AtticStyle.taskComposerControlSize, height: AtticStyle.taskComposerControlSize)
                    .atticQuietMenuGlyph(panelThemePalette.primaryForegroundColor)
                    .help(quickEntryOptionsTitle)
                    .accessibilityLabel(quickEntryOptionsTitle)
                    .accessibilityIdentifier("add-task-button")

                    TextField(quickEntryPlaceholder, text: $quickEntryTitle,
                              prompt: Text(quickEntryPlaceholder)
                                .foregroundStyle(panelThemePalette.secondaryForegroundColor))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(panelThemePalette.primaryForegroundColor)
                        .atticClearGlassForegroundReadability()
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: AtticStyle.taskComposerControlSize)
                        .focused($isQuickEntryFocused)
                        .onSubmit(saveQuickTask)
                        .onExitCommand {
                            isQuickEntryFocused = false
                            uiState.endAdding()
                        }
                        .accessibilityIdentifier("quick-entry-title")
                }
                .atticGlassControl(in: Capsule(), interactive: false)

                Button(action: saveQuickTask) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            quickSubmitForegroundColor
                        )
                        .atticClearGlassForegroundReadability()
                        .frame(width: AtticStyle.taskComposerControlSize, height: AtticStyle.taskComposerControlSize)
                        .atticGlassControl(in: Circle())
                        .overlay {
                            quickSubmitEmphasis
                                .animation(reduceMotion ? nil : AtticMotion.quick,
                                           value: isQuickSubmitEmphasized)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSaveQuickTask)
                .focused($isQuickSubmitFocused)
                .onHover { isQuickSubmitHovered = $0 }
                .help(composerAttachments.isImporting ? quickEntryPendingSubmitTitle : quickEntrySubmitTitle)
                .accessibilityLabel(quickEntrySubmitTitle)
                .accessibilityIdentifier("quick-entry-submit")
            }
            .frame(height: AtticStyle.taskComposerRowHeight)
            if isTaskEntryExpanded {
                HStack(spacing: 4) {
                    Text("Priority")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                        .padding(.leading, 4)
                    ForEach(TaskPriority.allCases) { priority in
                        Button {
                            quickEntryPriority = priority
                            uiState.beginAdding()
                            isQuickEntryFocused = true
                        } label: {
                            Image(systemName: priority == .none ? "flag.slash" : "flag.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(priority == .none ? panelThemePalette.secondaryForegroundColor : priority.color)
                                .frame(width: 34, height: 24)
                                .background(
                                    priority.color.opacity(quickEntryPriority == priority ? 0.16 : 0),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().stroke(
                                        priority.color.opacity(quickEntryPriority == priority ? 0.55 : 0),
                                        lineWidth: 1)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedQuickPriority, equals: priority)
                        .help("\(priority.title) priority")
                        .accessibilityLabel("\(priority.title) priority")
                        .accessibilityAddTraits(quickEntryPriority == priority ? .isSelected : [])
                        .accessibilityIdentifier("task-priority-\(priority.rawValue)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .contentShape(
            RoundedRectangle(cornerRadius: AtticStyle.taskComposerRowHeight / 2, style: .continuous)
        )
        .overlay {
            if isComposerFileDropTargeted {
                TaskDropOverlay(
                    message: "Drop to attach to the new task",
                    shape: RoundedRectangle(cornerRadius: AtticStyle.taskComposerRowHeight / 2, style: .continuous),
                    compact: true
                )
            }
        }
        .onDrop(of: TaskDropContent.dropTypes, delegate: TaskFileDropDelegate(
            // The new task has no owner yet, so a card from any task copies in.
            canAccept: { content in
                canAddComposerAttachments && (content == .files || TaskAttachmentCardDrag.canCopy(toOwner: nil))
            },
            setTargeted: { targeted in
                withAnimation(reduceMotion ? nil : AtticMotion.quick) { isComposerFileDropTargeted = targeted }
            },
            perform: { content, providers in
                if content == .attachmentCard {
                    addComposerCopies(of: providers)
                } else {
                    addComposerAttachments(count: providers.count) { try await TaskDroppedFiles.stage(providers) }
                }
            }
        ))
        .animation(reduceMotion ? nil : AtticMotion.quick, value: isTaskEntryExpanded)
        .animation(reduceMotion ? nil : AtticMotion.quick, value: composerAttachments.isEmpty)
        .padding(.horizontal, chromeInset)
        .padding(.bottom, chromeInsets.bottom)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(quickEntryContainerLabel)
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
                .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalInset)
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
            .padding(.bottom, uiState.selectedSection.isTaskBased
                ? 118 + (composerAttachments.isEmpty ? 0 : TaskComposerLayout.pendingStripHeight) : 20)
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

    /// One save creates the task with its pending attachments. On failure
    /// the store reports it and the title, priority and pending items stay
    /// for a retry.
    private func saveQuickTask() {
        guard canSaveQuickTask else { return }
        guard store.create(
            title: quickEntryTitle,
            priority: quickEntryPriority,
            status: uiState.selectedScope.creationStatus,
            attachments: composerAttachments.pending
        ) != nil else { return }
        composerAttachments.didBind()
        quickEntryTitle = ""
        quickEntryPriority = .none
        DispatchQueue.main.async { isQuickEntryFocused = true }
    }

    private func chooseComposerAttachments() {
        guard canAddComposerAttachments else { return }
        TaskAttachmentPicker.chooseForComposer(uiState: uiState) { urls in
            addComposerAttachments(count: urls.count) { TaskAttachmentStaging(urls: urls) }
        }
    }

    private func addComposerAttachments(count: Int,
                                        stage: @escaping @MainActor () async throws -> TaskAttachmentStaging) {
        let store = store
        composerAttachments.add(count: count, files: store.taskImageFiles, stage: stage,
                                succeeded: { store.dismissError() }) { error in
            store.reportAttachmentImportFailure(error)
        }
    }

    /// A gallery card dropped on the composer: a private copy of the
    /// verified source becomes a pending item like any other.
    private func addComposerCopies(of providers: [NSItemProvider]) {
        let store = store
        let card = TaskAttachmentCardDrag.current
        composerAttachments.add(count: providers.count, files: store.taskImageFiles, importing: { existing in
            let sources = try await TaskAttachmentCardDrag.sources(from: providers, expected: card)
            let references = try store.verifiedCopySources(sources, excludingOwner: nil)
            return try await store.taskImageFiles.importCopies(of: references, existing: existing)
        }, succeeded: { store.dismissError() }) { error in
            store.reportAttachmentImportFailure(error)
        }
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

    /// Backlog and Tasks share the quick-entry composer, so its copy follows
    /// the selected scope; creation routing is unchanged.
    private var quickEntryPlaceholder: String { uiState.selectedScope.quickEntryPlaceholder }
    private var quickEntrySubmitTitle: String { uiState.selectedScope.quickEntrySubmitTitle }
    private var quickEntryPendingSubmitTitle: String { uiState.selectedScope.quickEntryPendingSubmitTitle }
    private var quickEntryOptionsTitle: String { uiState.selectedScope.quickEntryOptionsTitle }
    private var quickEntryContainerLabel: String { uiState.selectedScope.quickEntryContainerLabel }

    private var quickSubmitForegroundColor: Color {
        guard canSaveQuickTask else { return Color.primary.opacity(0.34) }
        return usesOriginalTheme
            ? Color.primary.opacity(0.94)
            : panelThemePalette.accentColor.opacity(0.98)
    }

    /// The panel's primary action had no hover or focus affordance on any
    /// treatment: `atticGlassControl` supplies no hover variant on material or
    /// opaque, and native glass interactivity answers the pointer only — never
    /// keyboard focus. This emphasis is drawn over whichever backing the system
    /// chose, so all three behave the same, and nothing is drawn at rest.
    @ViewBuilder
    private var quickSubmitEmphasis: some View {
        if isQuickSubmitEmphasized {
            Circle()
                .fill(quickSubmitEmphasisFill)
                .overlay {
                    Circle().stroke(
                        quickSubmitEmphasisStroke,
                        lineWidth: QuickSubmitEmphasis.strokeWidth(isFocused: isQuickSubmitFocused)
                    )
                }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var isQuickSubmitEmphasized: Bool {
        QuickSubmitEmphasis.isEmphasized(
            canSubmit: canSaveQuickTask,
            isHovered: isQuickSubmitHovered,
            isFocused: isQuickSubmitFocused
        )
    }

    private var quickSubmitEmphasisFill: Color {
        if usesOriginalTheme {
            return Color.primary.opacity(0.16)
        }
        return panelThemePalette.accentColor.opacity(
            min(panelThemePalette.selectedFillOpacity + 0.06, 0.24)
        )
    }

    /// Keyboard focus reads stronger than hover, as it does on the mode dock.
    private var quickSubmitEmphasisStroke: Color {
        if usesOriginalTheme {
            let opacity = isQuickSubmitFocused ? 0.30 : 0.16
            return Color.primary.opacity(hasIncreasedContrast ? min(opacity + 0.12, 1) : opacity)
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
