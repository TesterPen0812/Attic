import SwiftUI

/// Today's task list and add bar, moved verbatim out of `AtticPanelView`.
/// The Tasks stream replaces it with the new Tasks page and then deletes it.
struct LegacyTasksPage: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var subtaskPanels: SubtaskPanelController
    @ObservedObject var state: TasksPageState
    @ObservedObject var composerAttachments: TaskComposerAttachments
    let layout: PanelPageLayout
    let chromeInteractionState: PanelChromeInteractionState
    let usesOriginalTheme: Bool
    let isQuickEntryFocused: FocusState<Bool>.Binding

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.atticPanelThemePalette) private var panelThemePalette
    @State private var isComposerFileDropTargeted = false
    @State private var isQuickSubmitHovered = false
    @FocusState private var isQuickSubmitFocused: Bool
    @FocusState private var focusedQuickPriority: TaskPriority?

    private var panelSize: CGSize { layout.panelSize }
    private var contentInsets: EdgeInsets { layout.contentInsets }
    private var chromeInsets: EdgeInsets { layout.chromeInsets }
    private var horizontalInset: CGFloat { contentInsets.leading }
    private var chromeInset: CGFloat { chromeInsets.leading }
    private var taskWorkspaceTopPadding: CGFloat {
        PanelGeometry.taskWorkspaceTopPadding(
            cornerSize: layout.cornerSize,
            panelSize: panelSize
        )
    }
    private var quickEntryFocused: Bool { isQuickEntryFocused.wrappedValue }
    private var canSaveQuickTask: Bool {
        composerAttachments.canSubmit(title: state.quickEntryTitle)
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
    private var hasIncreasedContrast: Bool {
        colorSchemeContrast == .increased
    }

    var body: some View {
        taskWorkspace
            // Rows hidden or fading under the chrome bands are inert as well as
            // dimmed: these shields sit between the list and the controls, so a
            // press or hover landing beside the pin button, in the fade, or on
            // the composer can never reach a row the mask has faded out. Scroll
            // wheel events still reach the list, which AppKit hit-tests
            // independently of these shapes.
            .overlay(alignment: .top) {
                AtticPointerShield(height: taskTopObscuredHeight + TaskScrollMaskLayout.fadeLength)
            }
            .overlay(alignment: .bottom) {
                AtticPointerShield(height: taskBottomObscuredHeight + TaskScrollMaskLayout.fadeLength)
            }
            .overlay(alignment: .bottom) {
                taskEntryBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preference(
                key: PanelPageNoticeClearancePreferenceKey.self,
                value: 118 + (composerAttachments.isEmpty ? 0 : TaskComposerLayout.pendingStripHeight)
            )
            .onAppear {
                syncComposerInteractionHeight()
                syncTaskEntryInteractionLocks()
            }
            .onChange(of: uiState.selectedSection) { _, _ in
                syncComposerInteractionHeight()
                syncTaskEntryInteractionLocks()
            }
            .onChange(of: isTaskEntryExpanded) { _, _ in
                syncComposerInteractionHeight()
            }
            .onChange(of: composerAttachments.isEmpty) { _, _ in
                syncComposerInteractionHeight()
                syncTaskEntryInteractionLocks()
            }
            .onChange(of: quickEntryFocused) { _, _ in
                syncTaskEntryInteractionLocks()
            }
            .onChange(of: isQuickSubmitFocused) { _, _ in syncTaskEntryInteractionLocks() }
            .onChange(of: focusedQuickPriority) { _, _ in syncTaskEntryInteractionLocks() }
            .onChange(of: state.quickEntryTitle) { _, _ in syncTaskEntryInteractionLocks() }
            .onChange(of: state.quickEntryPriority) { _, _ in syncTaskEntryInteractionLocks() }
    }

    private func syncComposerInteractionHeight() {
        guard uiState.selectedSection.isTaskBased else { return }
        chromeInteractionState.bottomControlsHeight = taskEntryHeight
    }

    private func syncTaskEntryInteractionLocks() {
        let isTaskSection = uiState.selectedSection.isTaskBased
        uiState.setInteractionLock(
            .quickEntryFocus,
            isActive: isTaskSection && (quickEntryFocused || isQuickSubmitFocused || focusedQuickPriority != nil)
        )
        uiState.setInteractionLock(
            .taskComposer,
            isActive: isTaskSection && (!state.quickEntryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || state.quickEntryPriority != .none || !composerAttachments.isEmpty)
        )
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
                            isQuickEntryFocused.wrappedValue = true
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

                    TextField(quickEntryPlaceholder, text: $state.quickEntryTitle,
                              prompt: Text(quickEntryPlaceholder)
                                .foregroundStyle(panelThemePalette.secondaryForegroundColor))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(panelThemePalette.primaryForegroundColor)
                        .atticClearGlassForegroundReadability()
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: AtticStyle.taskComposerControlSize)
                        .focused(isQuickEntryFocused)
                        .onSubmit(saveQuickTask)
                        .onExitCommand {
                            isQuickEntryFocused.wrappedValue = false
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
                            state.quickEntryPriority = priority
                            uiState.beginAdding()
                            isQuickEntryFocused.wrappedValue = true
                        } label: {
                            Image(systemName: priority == .none ? "flag.slash" : "flag.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(priority == .none ? panelThemePalette.secondaryForegroundColor : priority.color)
                                .frame(width: 34, height: 24)
                                .background(
                                    priority.color.opacity(state.quickEntryPriority == priority ? 0.16 : 0),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule().stroke(
                                        priority.color.opacity(state.quickEntryPriority == priority ? 0.55 : 0),
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
                        .accessibilityAddTraits(state.quickEntryPriority == priority ? .isSelected : [])
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

    /// One save creates the task with its pending attachments. On failure
    /// the store reports it and the title, priority and pending items stay
    /// for a retry.
    private func saveQuickTask() {
        guard canSaveQuickTask else { return }
        guard store.create(
            title: state.quickEntryTitle,
            priority: state.quickEntryPriority,
            status: uiState.selectedScope.creationStatus,
            attachments: composerAttachments.pending
        ) != nil else { return }
        composerAttachments.didBind()
        state.quickEntryTitle = ""
        state.quickEntryPriority = .none
        let focus = isQuickEntryFocused
        DispatchQueue.main.async { focus.wrappedValue = true }
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
}
