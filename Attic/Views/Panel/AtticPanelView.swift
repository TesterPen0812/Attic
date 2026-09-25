import SwiftUI

/// The panel's shell: the surface, the header (Pin and the page switch), the
/// page host for the current page, and the notices above it (the Undo toast
/// and the error notice). Pages lay themselves out inside
/// `PanelPageLayout`; the shell owns everything around them.
struct AtticPanelView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var canvasSession: CanvasSession
    @ObservedObject var noteDraft: NoteDraftController
    let chromeInteractionState: PanelChromeInteractionState
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings
    @ObservedObject var subtaskPanels: SubtaskPanelController
    @ObservedObject var toasts: PanelToastCenter

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemColorScheme
    /// What the Tasks page keeps while another page shows (the add bar's
    /// draft and pending attachments).
    @StateObject private var tasksPageState = TasksPageState()
    @State private var noticeHeight: CGFloat = 0
    @State private var noticeClearance = PanelPageNoticeClearancePreferenceKey.defaultValue
    @State var hasRestoredNoteSession = false
    /// The current page's primary input (the Tasks add bar). The shell owns
    /// it so a page switch can take focus out of the page.
    @FocusState private var isQuickEntryFocused: Bool

    @MainActor
    init(
        store: TaskStore,
        noteStore: NoteStore,
        canvasSession: CanvasSession,
        noteDraft: NoteDraftController,
        chromeInteractionState: PanelChromeInteractionState,
        uiState: PanelUIState,
        settings: AppSettings,
        subtaskPanels: SubtaskPanelController,
        toasts: PanelToastCenter? = nil
    ) {
        self.store = store
        self.noteStore = noteStore
        self.canvasSession = canvasSession
        self.noteDraft = noteDraft
        self.chromeInteractionState = chromeInteractionState
        self.uiState = uiState
        self.settings = settings
        self.subtaskPanels = subtaskPanels
        self.toasts = toasts ?? PanelToastCenter()
    }

    private var cornerRadius: CGFloat { settings.panelCornerSize }
    private var panelSize: CGSize { uiState.panelSize }
    private var pageLayout: PanelPageLayout {
        PanelPageLayout(cornerSize: cornerRadius, panelSize: panelSize)
    }
    private var chromeInsets: EdgeInsets { pageLayout.chromeInsets }
    private var currentPage: PanelPage { PanelPage(uiState.selectedSection) }

    /// The legacy pages still read the PR #5 palette for their own text.
    private var panelThemePalette: AtticPanelThemePalette {
        settings.panelTheme.palette(for: systemColorScheme, contrast: colorSchemeContrast)
    }
    private var panelSurfaceTreatment: AtticPanelSurfaceTreatment {
        settings.panelSurfaceTreatment(
            colorScheme: systemColorScheme,
            contrast: colorSchemeContrast,
            reduceTransparency: reduceTransparency
        )
    }
    private var panelAccentColor: Color {
        settings.panelTheme.usesSystemAccent ? Color.accentColor : panelThemePalette.accentColor
    }

    /// The native window leaves `AtticStyle.panelElevationMargin` around the
    /// surface, so the exterior elevation is drawn here.
    static let showsSurfaceElevation = true

    private static let exposesKeyStateForUITesting =
        ProcessInfo.processInfo.environment["ATTIC_UI_TESTING"] == "1"

    var body: some View {
        themedPanel
    }

    // MARK: Composition

    private var panelContent: some View {
        ZStack {
            if uiState.isPageContentLoaded {
                // The current page, over any page kept built behind it (a
                // switch back only shows it). Only the current page takes
                // clicks, keys, VoiceOver and the notices' clearance.
                ForEach(PanelPage.allCases) { page in
                    if page == currentPage || uiState.builtPages.contains(page) {
                        pageHost(page)
                            .modifier(PanelPageVisibility(
                                isCurrent: page == currentPage,
                                // Canvas has single-key tool shortcuts (V, P, E);
                                // hidden, they must not fire. Tasks has none
                                // outside its menus, and disabling it would
                                // redraw the whole list on every switch.
                                disablesWhenHidden: page == .canvas
                            ))
                    }
                }
            }
        }
        .coordinateSpace(name: AtticPanelCoordinateSpaceName.taskWorkspace)
        .coordinateSpace(PanelPageLayout.coordinateSpace)
        .overlay(alignment: .top) {
            header
        }
        .overlay(alignment: .topLeading) {
            if Self.exposesKeyStateForUITesting {
                // UI tests read whether the panel is key (the drawn or the
                // glass look) instead of waiting a fixed time.
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("panel-key-state")
                    .accessibilityValue(uiState.isPanelKey ? "key" : "not key")
            }
        }
        .overlay(alignment: .bottom) {
            notices
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(PanelPageNoticeClearancePreferenceKey.self) { clearance in
            if noticeClearance != clearance { noticeClearance = clearance }
        }
    }

    private var header: some View {
        PanelHeader(
            isPinned: uiState.isPanelPinned,
            page: currentPage,
            onTogglePin: { uiState.isPanelPinned.toggle() },
            onSelectPage: selectPage,
            onApproachPageSwitch: prepareOtherPages
        )
        .padding(.horizontal, chromeInsets.leading)
        .padding(.top, chromeInsets.top)
        .frame(maxWidth: .infinity)
    }

    private var notices: some View {
        PanelNoticeStack(
            toasts: toasts,
            notice: currentNotice,
            onRetry: retryCurrentNotice,
            onDismissNotice: dismissCurrentNotice
        )
        .padding(.horizontal, chromeInsets.leading)
        .padding(.bottom, pageLayout.contentInsets.bottom + noticeClearance)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PanelNoticeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func pageHost(_ page: PanelPage) -> some View {
        switch page {
        case .tasks:
            TasksPageHost(
                store: store,
                uiState: uiState,
                settings: settings,
                subtaskPanels: subtaskPanels,
                state: tasksPageState,
                layout: pageLayout,
                chromeInteractionState: chromeInteractionState,
                primaryInputFocus: $isQuickEntryFocused,
                isCurrent: page == currentPage
            )
            .transition(.opacity)
        case .canvas:
            CanvasPageHost(
                canvasSession: canvasSession,
                uiState: uiState,
                layout: pageLayout,
                errorBannerHeight: currentNotice == nil && toasts.current == nil ? 0 : noticeHeight,
                headerControlRects: headerControlRects,
                headerBottom: PanelHeaderLayout.bottom(chromeInsets: chromeInsets)
            )
            .transition(.opacity)
        case .notes:
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

    /// The header controls' frames in panel coordinates (top-left origin).
    private var headerControlRects: [CGRect] {
        [
            CGRect(x: chromeInsets.leading, y: chromeInsets.top,
                   width: PanelHeaderLayout.pinSize.width, height: PanelHeaderLayout.height),
            CGRect(x: panelSize.width - chromeInsets.trailing - PanelHeaderLayout.pageSwitchWidth,
                   y: chromeInsets.top, width: PanelHeaderLayout.pageSwitchWidth, height: PanelHeaderLayout.height)
        ]
    }

    // MARK: Surface, observation and theme

    private var surfacedPanel: some View {
        panelContent
            .environment(\.colorScheme, systemColorScheme)
            .foregroundStyle(panelThemePalette.primaryForegroundColor, panelThemePalette.secondaryForegroundColor)
            .environment(\.controlActiveState, .key)
            .modifier(PanelShellSurface(
                cornerSize: cornerRadius,
                elevation: Self.showsSurfaceElevation ? panelSurfaceTreatment.surfaceElevation : nil
            ))
            .contextMenu {
                AtticMenuItems(commands: panelMenuCommands)
            }
    }

    private var storeObservedPanel: some View {
        surfacedPanel
            .onChange(of: uiState.selectedSection) { _, _ in
                syncBottomControlsHeight()
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
            // Task-list plumbing the legacy Tasks page relies on; it runs on
            // every page, as it always has, and leaves with that page.
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
                chromeInteractionState.modeDockWidth = PanelHeaderLayout.pageSwitchWidth
                syncBottomControlsHeight()
                syncNoteDraftInteractionLocks()
            }
            .onChange(of: uiState.primaryInputFocusRequest) { _, _ in
                // An explicit open on Tasks: the keyboard lands in the add
                // bar. A plain text field draws no focus ring.
                guard uiState.selectedSection.isTaskBased else { return }
                isQuickEntryFocused = true
            }
            .onChange(of: noteDraft.isDirty) { _, _ in syncNoteDraftInteractionLocks() }
            .onChange(of: noteDraft.hasConflict) { _, _ in syncNoteDraftInteractionLocks() }
            .onChange(of: noteStore.attachmentImportState) { _, _ in syncNoteDraftInteractionLocks() }
            .onPreferenceChange(PanelNoticeHeightPreferenceKey.self) { measured in
                let resolved = max(0, measured.isFinite ? measured : 0)
                if abs(noticeHeight - resolved) >= 0.5 { noticeHeight = resolved }
            }
    }

    private var themedPanel: some View {
        interactionObservedPanel
            .environment(\.atticPanelThemePalette, panelThemePalette)
            .environment(\.atticPanelUsesSystemAccent, settings.panelTheme.usesSystemAccent)
            .environment(\.atticPanelUsesSystemOpaqueSurface, panelSurfaceTreatment.usesSystemOpaqueSurface)
            .environment(\.atticPanelToasts, toasts)
            .tint(panelAccentColor)
            .accentColor(panelAccentColor)
            .atticDesignFromSystem(
                palette: settings.panelTheme,
                surface: settings.panelSurfaceStyle,
                tint: settings.panelTint,
                tintLength: settings.panelTintLength,
                hapticsEnabled: settings.panelHapticsEnabled,
                controls: PanelKeyTreatment.controls(isPanelKey: uiState.isPanelKey)
            )
            // Native menus (context menus, pop-ups) follow Attic's chosen
            // appearance, not only the Mac's.
            .atticWindowAppearance(settings.appearance.designMode)
    }

    // MARK: Menus

    /// The panel's own right-click menu, with every shortcut shown.
    private var panelMenuCommands: [AtticMenuCommand] {
        var commands = PanelPage.allCases.map { page in
            AtticMenuCommand(
                String.LocalizationValue(page.title),
                systemImage: page.systemName,
                shortcut: KeyboardShortcut(page.keyEquivalent, modifiers: .command),
                isDisabled: page == currentPage
            ) { selectPage(page) }
        }
        commands.append(AtticMenuCommand(
            uiState.isPanelPinned ? "Unpin panel" : "Pin panel",
            systemImage: uiState.isPanelPinned ? "pin.slash" : "pin",
            shortcut: KeyboardShortcut("p", modifiers: [.command, .shift]),
            startsSection: true
        ) { uiState.isPanelPinned.toggle() })
        commands.append(AtticMenuCommand(
            "Settings…",
            systemImage: "gearshape",
            shortcut: KeyboardShortcut(",", modifiers: .command)
        ) { AppCoordinator.shared.openSettings() })
        return commands
    }

    // MARK: Pages

    /// Builds the pages the switch leads to (those the shell keeps), one per
    /// main-thread turn so the pointer never waits on all of them at once.
    private func prepareOtherPages() {
        let pending = PanelPage.allCases.filter {
            $0 != currentPage && PanelUIState.keepsBuilt($0) && !uiState.builtPages.contains($0)
        }
        for (index, page) in pending.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(index)) {
                uiState.prepareBuiltPage(page)
            }
        }
    }

    private func selectPage(_ page: PanelPage) {
        guard page != currentPage else { return }
        selectSection(page.section)
    }

    private func selectSection(_ section: PanelSection) {
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
        withAnimation(AtticMotionPreset.pageSwitch.animation(reduceMotion: reduceMotion)) { selection() }
    }

    /// Pages with their own bottom controls (the Tasks add bar) report their
    /// height themselves; every other page has one compact bottom bar.
    private func syncBottomControlsHeight() {
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

    // MARK: Notices

    /// The problem the current page's store reports. Task errors that
    /// concern one family's panel show inside that panel only.
    private var currentNotice: PanelNoticeContent? {
        switch currentPage {
        case .canvas:
            return canvasSession.lastErrorMessage.map {
                PanelNoticeContent(message: $0, canRetry: !canvasSession.failedImageIDs.isEmpty)
            }
        case .notes:
            return noteStore.lastErrorMessage.map { PanelNoticeContent(message: $0, canRetry: false) }
        case .tasks:
            guard store.lastErrorOwnerID == nil else { return nil }
            return store.lastErrorMessage.map { PanelNoticeContent(message: $0, canRetry: false) }
        }
    }

    private func retryCurrentNotice() {
        guard currentPage == .canvas else { return }
        if canvasSession.retryFailedImageDecodes() { canvasSession.dismissErrorMessage() }
    }

    private func dismissCurrentNotice() {
        switch currentPage {
        case .canvas: canvasSession.dismissErrorMessage()
        case .notes: noteStore.dismissError()
        case .tasks: store.dismissError()
        }
    }
}

/// A page in the shell's stack: shown when current, otherwise kept built
/// but invisible and inert (no clicks, no keyboard shortcuts, hidden from
/// VoiceOver), and adding nothing to what the shell measures.
private struct PanelPageVisibility: ViewModifier {
    let isCurrent: Bool
    let disablesWhenHidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isCurrent ? 1 : 0)
            .allowsHitTesting(isCurrent)
            .disabled(disablesWhenHidden && !isCurrent)
            .accessibilityHidden(!isCurrent)
            .zIndex(isCurrent ? 1 : 0)
            .transformPreference(PanelPageNoticeClearancePreferenceKey.self) { value in
                if !isCurrent { value = 0 }
            }
    }
}

/// Native Liquid Glass renders flat (a grey slab with a dark outline) in a
/// window that is not key, and a panel revealed from the corner must not
/// take the keyboard from the app the person is typing in. So the panel's
/// controls are real glass while it is key (an explicit open, or once the
/// person clicks in it) and the Craft-style recipe, the design system's
/// drawn material, while it is not.
enum PanelKeyTreatment {
    static func controls(isPanelKey: Bool) -> AtticControlMaterial {
        isPanelKey ? .liquidGlass : .craft
    }
}

private struct PanelNoticeHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension AppSettings {
    /// The Haptics setting (spec § Touch and sound: a light tick when a task
    /// is completed or a dragged item snaps into place, "can be turned
    /// off"), as the panel feeds it into the design context: every
    /// design-system component in the panel (the status circle's tick
    /// included) follows it.
    var panelHapticsEnabled: Bool { hapticsEnabled }
}

extension AppearancePreference {
    /// The design system's mode for this choice; nil follows the Mac.
    var designMode: AtticDesignContext.Mode? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
