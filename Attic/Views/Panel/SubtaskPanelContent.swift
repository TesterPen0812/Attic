import SwiftUI

/// The one family presentation shared by the transient hover panel and the
/// pinned mini-window, with two views: Subtasks and Attachments. It reads the
/// live family from `store`, keeps drafts in `uiState.subtaskDrafts`, reads
/// its view from `panelViews`, and leaves every mutation to the same
/// `TaskStore` APIs the main list uses — the surface is presentation only.
struct SubtaskPanelContent: View {
    enum Mode {
        case transient
        case pinned
    }

    @ObservedObject var store: TaskStore
    @ObservedObject var uiState: PanelUIState
    @ObservedObject var settings: AppSettings
    @ObservedObject var subtaskPanels: SubtaskPanelController
    @ObservedObject var panelViews: FamilyPanelViewState
    let parentID: UUID
    let mode: Mode

    /// File drops anywhere on the surface, including over child rows.
    @StateObject private var fileDrop: TaskFileDropTarget
    @State private var measuredHeaderHeight: CGFloat = 0
    @State private var measuredFooterHeight: CGFloat = 0
    @FocusState private var isEntryFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(store: TaskStore, uiState: PanelUIState, settings: AppSettings,
         subtaskPanels: SubtaskPanelController, panelViews: FamilyPanelViewState,
         parentID: UUID, mode: Mode) {
        self.store = store
        self.uiState = uiState
        self.settings = settings
        self.subtaskPanels = subtaskPanels
        self.panelViews = panelViews
        self.parentID = parentID
        self.mode = mode
        _fileDrop = StateObject(wrappedValue: TaskFileDropTarget())
    }

    private var parent: TaskItem? {
        guard let task = store.task(withID: parentID), task.parentID == nil else { return nil }
        return task
    }

    private var children: [TaskItem] {
        store.subtasks(of: parentID)
    }

    private var activeView: FamilyPanelView {
        panelViews.view(for: parentID)
    }

    private var attachments: [TaskImageReference] {
        parent?.attachments ?? []
    }

    private var completedCount: Int {
        children.filter { $0.status == .done }.count
    }

    private var draft: Binding<String> {
        Binding(
            get: { uiState.subtaskDrafts[parentID] ?? "" },
            set: { uiState.subtaskDrafts[parentID] = $0 }
        )
    }

    private var canAddSubtask: Bool {
        parent != nil && parent?.status != .done
    }

    private var canSubmitDraft: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The user's panel corner setting — the auxiliary surfaces share the
    /// main panel's squircle language, so their radius follows the same
    /// value and the Squircle itself clamps it to these smaller bounds. The
    /// AppKit hit test reads the same setting, so the clickable shape and the
    /// painted one can never diverge.
    private var surfaceCornerRadius: CGFloat {
        CGFloat(settings.panelCornerSize)
    }

    /// Corner-aware spacing (see `SubtaskPanelLayout.surfaceInsets`).
    private var insets: SurfaceInsets {
        SubtaskPanelLayout.surfaceInsets(cornerSize: surfaceCornerRadius)
    }

    private var contentHorizontalPadding: CGFloat { insets.horizontal }
    private var contentTopPadding: CGFloat { insets.top }
    private var contentBottomPadding: CGFloat { insets.bottom }
    private var rowOuterPadding: CGFloat { insets.row }

    /// The entry is a deliberate state — opened by the '+ Add subtask'
    /// affordance (or an Add subtask… menu command), kept alive by an
    /// un-submitted draft, and closed only by an explicit Escape cancel.
    /// Focus loss, pinning, and surface hides preserve both it and the draft.
    private var entryActive: Bool {
        uiState.subtaskEntryActiveIDs.contains(parentID)
    }

    private var hasDraft: Bool {
        !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsEntry: Bool {
        canAddSubtask && (entryActive || hasDraft)
    }

    private var panelThemePalette: AtticPanelThemePalette {
        settings.panelTheme.palette(for: systemColorScheme, contrast: colorSchemeContrast)
    }

    private var effectiveGlassStyle: PanelGlassStyle {
        settings.panelGlassStyle.resolved(
            for: settings.panelTheme,
            colorScheme: systemColorScheme
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

    private var panelAccentColor: Color {
        settings.panelTheme.usesSystemAccent
            ? Color.accentColor
            : panelThemePalette.accentColor
    }

    var body: some View {
        ZStack(alignment: .top) {
            viewContent
                // A different task is a new list, not an animated insertion
                // of every row into the previous task's scrolling state.
                .id(parentID)
                .mask(chromeMask)
            // Rows faded out under the header and footer are inert too: the
            // shields sit between the list and the chrome, so nothing hidden
            // can take a press or a hover through the gaps between controls.
            Color.clear
                .frame(height: headerHeight + Self.chromeFadeLength)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
            Color.clear
                .frame(height: footerHeight + contentBottomPadding + Self.chromeFadeLength)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .frame(maxHeight: .infinity, alignment: .bottom)
            header
                .background(chromeHeightReader("header"))
            footer
                .padding(.horizontal, rowOuterPadding)
                .background(chromeHeightReader("footer"))
                .padding(.bottom, contentBottomPadding)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // The ideal height is what the window fits to; the surface itself
        // fills whatever frame the window has, so an animated window resize
        // carries the painted shape, the hit shape and the footer together.
        .frame(width: SubtaskPanelLayout.panelWidth)
        .frame(minHeight: 0, idealHeight: panelHeight, maxHeight: .infinity, alignment: .top)
        // Layout-neutral: the overlay never changes what the window fits to.
        .overlay {
            if fileDrop.isTargeted {
                TaskDropOverlay(
                    message: TaskFileDrop.message(for: parent?.title ?? "task"),
                    shape: Squircle(cornerRadius: surfaceCornerRadius, exponent: AtticStyle.panelSquircleExponent)
                )
            }
        }
        .animation(reduceMotion ? nil : AtticMotion.quick, value: fileDrop.isTargeted)
        .environment(\.taskFileDropTarget, fileDrop)
        .onDrop(of: TaskDropContent.dropTypes, delegate: TaskFileDropDelegate(
            canAccept: { fileDrop.canAccept($0) },
            setTargeted: { fileDrop.setTargeted($0, source: "surface") },
            perform: { fileDrop.perform($0, $1) }
        ))
        .onAppear(perform: configureFileDrop)
        .onPreferenceChange(SubtaskChromeHeightKey.self) { values in
            var changed = false
            if let height = values["header"], abs(height - measuredHeaderHeight) > 0.5 { measuredHeaderHeight = height; changed = true }
            if let height = values["footer"], abs(height - measuredFooterHeight) > 0.5 { measuredFooterHeight = height; changed = true }
            // The first fit used estimated chrome; re-fit once it is measured.
            if changed { subtaskPanels.noteChromeMeasured(for: parentID, mode: mode) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsEntry)
        .foregroundStyle(
            panelThemePalette.primaryForegroundColor,
            panelThemePalette.secondaryForegroundColor
        )
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
        .environment(\.atticPanelThemePalette, panelThemePalette)
        .environment(\.atticPanelUsesSystemAccent, settings.panelTheme.usesSystemAccent)
        .environment(
            \.atticPanelUsesSystemOpaqueSurface,
            panelSurfaceTreatment.usesSystemOpaqueSurface
        )
        .environment(\.controlActiveState, .key)
        .tint(panelAccentColor)
        .atticPanelSurface(
            treatment: panelSurfaceTreatment,
            cornerRadius: surfaceCornerRadius,
            gradientCoverage: settings.panelGradientCoverage,
            gradientColorHex: settings.panelGradientColorHex
        )
        .coordinateSpace(name: Self.surfaceSpace)
        .onPreferenceChange(PanelSurfaceDragGeometryPreferenceKey.self) { geometry in
            subtaskPanels.noteSurfaceDragGeometry(geometry, for: parentID, mode: mode)
        }
        // The transient host is reused across families: its drop target must
        // follow the family it now shows and forget a stale highlight.
        .onChange(of: parentID) { _, _ in
            fileDrop.end()
            configureFileDrop()
        }
        .onChange(of: mode) { _, _ in configureFileDrop() }
        .onChange(of: uiState.subtaskEntryRequest) { _, _ in
            guard uiState.focusedSubtaskParentID == parentID, showsEntry else { return }
            DispatchQueue.main.async { isEntryFocused = true }
        }
        .onChange(of: uiState.focusedSubtaskParentID) { _, focusedID in
            if focusedID == parentID, showsEntry {
                isEntryFocused = true
            } else if isEntryFocused {
                isEntryFocused = false
            }
        }
        .onChange(of: isEntryFocused) { _, focused in
            if focused {
                // Only a key surface can host a live field editor. The shared
                // transient host keeps this @FocusState alive across rootView
                // swaps, so a dismissed surface's claim can resurrect on a
                // plain hover reopen while the window isn't even key — that
                // phantom must not re-arm the focus pointer, or the composer
                // lock pins an unlatched surface open forever.
                if uiState.focusedSubtaskParentID == parentID
                    || subtaskPanels.isLiveSurfaceKey(for: parentID, mode: mode) {
                    uiState.focusedSubtaskParentID = parentID
                }
            } else if subtaskPanels.isLiveSurface(for: parentID, mode: mode) {
                // A live host's resign reports through the controller, which
                // records it so a same-click pin/unpin still restores focus.
                // A dying host is gated off — its late resign must not clear
                // the pointer the replacement surface already asserted.
                subtaskPanels.noteSubtaskEntryResigned(for: parentID)
            }
        }
        .onAppear {
            if uiState.focusedSubtaskParentID == parentID, showsEntry {
                DispatchQueue.main.async { isEntryFocused = true }
            } else if isEntryFocused {
                isEntryFocused = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(activeView == .subtasks ? "Subtasks" : "Attachments")
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// Named space shared by every measurement inside one surface; its
    /// origin is the content's top-left, which is also the flipped hosting
    /// view's origin.
    fileprivate static let surfaceSpace = "attic.subtaskSurface"

    /// Every file drop on this surface goes to the parent, and so does a
    /// card from another family (never one of its own). The drop re-asserts
    /// the open so the panel stays up while the files import.
    private func configureFileDrop() {
        Self.configureFileDrop(fileDrop, parentID: parentID, mode: mode, store: store, subtaskPanels: subtaskPanels)
    }

    /// The target stores these callbacks, so they hold it weakly: a strong
    /// capture would keep the target, store and controller alive after the
    /// surface releases it.
    static func configureFileDrop(_ fileDrop: TaskFileDropTarget, parentID: UUID, mode: Mode,
                                  store: TaskStore, subtaskPanels: SubtaskPanelController) {
        fileDrop.canAccept = { TaskFileDrop.canAccept($0, onto: parentID, store: store) }
        fileDrop.perform = { [weak fileDrop] content, providers in
            fileDrop?.end()
            if mode == .transient { subtaskPanels.openFamilyPanel(for: parentID, focusEntry: false) }
            TaskFileDrop.attach(content, providers, to: parentID, store: store, subtaskPanels: subtaskPanels)
        }
    }

    private func dragRegionReader(
        _ make: @escaping (CGRect) -> PanelSurfaceDragGeometry
    ) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PanelSurfaceDragGeometryPreferenceKey.self,
                value: make(proxy.frame(in: .named(Self.surfaceSpace)))
            )
        }
    }

    private var accessibilityIdentifier: String {
        switch mode {
        case .transient: "subtask-panel-\(parentID.uuidString)"
        case .pinned: "subtask-pinned-\(parentID.uuidString)"
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(parent?.title ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(panelThemePalette.primaryForegroundColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(parent?.title ?? "")
                if !children.isEmpty {
                    Text("\(completedCount) of \(children.count) complete")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                        .atticClearGlassForegroundReadability()
                        .contentTransition(.numericText())
                } else {
                    Text("No subtasks yet")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                        .atticClearGlassForegroundReadability()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            headerControls
        }
        .padding(.horizontal, contentHorizontalPadding)
        .padding(.top, contentTopPadding)
        .padding(.bottom, 9)
        .background {
            SubtaskWindowDragHandle(familyID: parentID)
            dragRegionReader { PanelSurfaceDragGeometry(headerFrame: $0) }
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        switch mode {
        case .transient:
            Button {
                subtaskPanels.pinFamily(parentID)
            } label: {
                Image(systemName: "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .atticClearGlassForegroundReadability()
                    .frame(width: SubtaskPanelLayout.footerControlSize, height: SubtaskPanelLayout.footerControlSize)
                    .atticGlassControl(in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background { dragRegionReader { PanelSurfaceDragGeometry(controlFrames: [$0]) } }
            .help("Keep this list visible")
            .accessibilityLabel("Pin subtask list")
            .accessibilityIdentifier("subtask-pin-\(parentID.uuidString)")
        case .pinned:
            HStack(spacing: 6) {
                Button {
                    subtaskPanels.unpinPinned(parentID)
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .atticClearGlassForegroundReadability()
                        .frame(width: SubtaskPanelLayout.footerControlSize, height: SubtaskPanelLayout.footerControlSize)
                        .atticGlassControl(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background { dragRegionReader { PanelSurfaceDragGeometry(controlFrames: [$0]) } }
                .help("Unpin subtask list")
                .accessibilityLabel("Unpin subtask list")
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("subtask-unpin-\(parentID.uuidString)")

                Button {
                    subtaskPanels.closePinned(parentID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .atticClearGlassForegroundReadability()
                        .frame(width: SubtaskPanelLayout.footerControlSize, height: SubtaskPanelLayout.footerControlSize)
                        .atticGlassControl(in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background { dragRegionReader { PanelSurfaceDragGeometry(controlFrames: [$0]) } }
                .help("Close subtask list")
                .accessibilityLabel("Close subtask list")
                .accessibilityIdentifier("subtask-close-\(parentID.uuidString)")
            }
        }
    }

    private var headerHeight: CGFloat { measuredHeaderHeight > 0 ? measuredHeaderHeight : contentTopPadding + 48 }
    private var footerHeight: CGFloat { measuredFooterHeight > 0 ? measuredFooterHeight : SubtaskPanelLayout.footerControlSize }

    private static let chromeFadeLength: CGFloat = 18

    /// Scrolling content remains faintly visible behind chrome and becomes
    /// fully readable in the workspace, matching the main task list.
    private var chromeMask: some View {
        let stops = TaskScrollMaskLayout.stops(
            height: panelHeight,
            topObscuredHeight: headerHeight,
            bottomObscuredHeight: footerHeight + contentBottomPadding,
            fadeLength: Self.chromeFadeLength
        )
        let underlay = TaskScrollMaskLayout.underChromeOpacity(
            reduceTransparency: reduceTransparency, increasedContrast: colorSchemeContrast == .increased)
        return LinearGradient(
            stops: TaskScrollMaskLayout.gradientStops(
                stops, underChromeOpacity: underlay,
                // The header contains text as well as controls; keep its
                // scrolling impression quieter than the composer underlay.
                headerUnderChromeOpacity: underlay * 0.4),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var panelHeight: CGFloat {
        headerHeight + contentHeight + footerHeight + contentBottomPadding
    }

    /// Both views share one rule: natural height up to the list maximum.
    private var contentHeight: CGFloat {
        SubtaskPanelLayout.contentHeight(
            for: activeView,
            childCount: children.count,
            measuredListHeight: subtaskPanels.measuredListHeight(for: parentID),
            attachmentCount: attachments.count
        )
    }

    /// Only the active view is in the hierarchy. A short directional slide
    /// plus crossfade; Reduce Motion keeps just the fade.
    @ViewBuilder
    private var viewContent: some View {
        ZStack(alignment: .top) {
            switch activeView {
            case .subtasks:
                childList.transition(viewTransition(entering: .subtasks))
            case .attachments:
                gallery.transition(viewTransition(entering: .attachments))
            }
        }
    }

    private func viewTransition(entering view: FamilyPanelView) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        // Attachments sit to the right of Subtasks. Each view enters from and
        // leaves toward its own side, so both layers page the same way.
        let slide = SubtaskPanelLayout.viewSwitchOffset(for: view)
        return .offset(x: slide).combined(with: .opacity)
    }

    private var gallery: some View {
        ScrollView {
            TaskAttachmentGallery(attachments: attachments, store: store, owner: parentID,
                                  freshIDs: panelViews.freshAttachments(for: parentID)) { reference in
                store.removeAttachment(reference.id, from: parentID)
            }
            .padding(.horizontal, rowOuterPadding + 4)
            .padding(.top, headerHeight)
            .padding(.bottom, footerHeight + contentBottomPadding)
        }
        .scrollIndicators(.never)
        .accessibilityIdentifier("subtask-attachments-\(parentID.uuidString)")
    }

    /// The composer for the active view beside the switch to the other view.
    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                HStack(spacing: 0) {
                    if activeView == .attachments || canAddSubtask {
                        Button {
                            if activeView == .attachments { chooseAttachment() }
                            else if showsEntry && canSubmitDraft { addSubtask() }
                            else { uiState.activateSubtaskEntry(for: parentID) }
                        } label: {
                            Image(systemName: showsEntry && canSubmitDraft && activeView == .subtasks ? "arrow.up" : "plus")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: SubtaskPanelLayout.footerControlSize, height: SubtaskPanelLayout.footerControlSize)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(activeView == .attachments && !TaskAttachmentPicker.isAvailable(for: parentID, store: store, uiState: uiState))
                        .accessibilityLabel(activeView == .attachments ? "Add attachment" : (showsEntry && canSubmitDraft ? "Save subtask" : "Add subtask"))
                        .accessibilityIdentifier("subtask-composer-action-\(parentID.uuidString)")
                    }
                    composer
                }
                .atticGlassControl(in: Capsule(), interactive: false)
                viewSwitch
            }
            if let message = panelErrorMessage { errorRow(message) }
        }
    }

    @ViewBuilder
    private var composer: some View {
        Group {
            switch activeView {
            case .subtasks:
                if canAddSubtask {
                    if showsEntry { entryRow }
                    else { addAffordance }
                } else {
                    Text("Task completed")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
            case .attachments:
                addAttachmentButton
            }
        }
        .frame(height: SubtaskPanelLayout.footerControlSize)
    }

    private func chooseAttachment() {
        let atStart = subtaskPanels.revealContext
        TaskAttachmentPicker.choose(for: parentID, store: store, uiState: uiState) { ids, ownerID in
            subtaskPanels.revealImportedAttachments(ids, for: ownerID, since: atStart)
        }
    }

    /// Only this family's own notice: general and composer errors belong to
    /// the main panel, so one failure never shows in two places.
    private var panelErrorMessage: String? {
        guard store.lastErrorOwnerID == parentID else { return nil }
        return store.lastErrorMessage
    }

    private var isImportingAttachments: Bool {
        store.importingAttachmentTaskIDs.contains(parentID)
    }

    private var addAttachmentButton: some View {
        Button(action: chooseAttachment) {
            HStack(spacing: 8) {
                if isImportingAttachments {
                    ProgressView().controlSize(.mini)
                }
                Text(isImportingAttachments ? "Attaching…" : "Add attachment…")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(panelThemePalette.secondaryForegroundColor)
            .atticClearGlassForegroundReadability()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!TaskAttachmentPicker.isAvailable(for: parentID, store: store, uiState: uiState))
        .help("Add images or files")
        .accessibilityLabel(isImportingAttachments ? "Attaching files" : "Add attachment")
        .accessibilityIdentifier("add-attachment-\(parentID.uuidString)")
    }

    /// Shows the destination view's icon: attachments from Subtasks, the
    /// checklist from Attachments.
    private var viewSwitch: some View {
        let destination = activeView.destination
        // Files dropped while Subtasks shows are copying in: the switch to
        // Attachments carries the progress until the gallery takes over.
        let showsImport = isImportingAttachments && activeView == .subtasks
        return Button {
            subtaskPanels.showPanelView(destination, for: parentID)
        } label: {
            ZStack {
                if showsImport {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: activeView.switchSymbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .atticClearGlassForegroundReadability()
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: SubtaskPanelLayout.footerControlSize, height: SubtaskPanelLayout.footerControlSize)
            .atticGlassControl(in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(showsImport ? "Attaching files. \(activeView.switchLabel)" : activeView.switchLabel)
        .accessibilityLabel(activeView.switchLabel)
        .accessibilityValue(showsImport ? "Attaching files" : "")
        .accessibilityIdentifier("subtask-view-switch-\(parentID.uuidString)")
    }

    private func chromeHeightReader(_ part: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SubtaskChromeHeightKey.self, value: [part: proxy.size.height])
        }
    }

    private var childList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(children) { child in
                    TaskRowView(
                        store: store,
                        uiState: uiState,
                        subtaskPanels: subtaskPanels,
                        task: child,
                        isEditing: uiState.editingTaskID == child.id,
                        isConfirmingDeletion: uiState.confirmingTaskDeletionID == child.id,
                        isImportingAttachments: store.importingAttachmentTaskIDs.contains(child.id)
                    )
                    .equatable()
                    .padding(.horizontal, rowOuterPadding)
                    .transition(.opacity.combined(with: .offset(y: -5)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: children.map(\.id))
            .padding(.vertical, 4)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SubtaskListHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .padding(.top, headerHeight)
            .padding(.bottom, footerHeight + contentBottomPadding)
        }
        .scrollIndicators(.never)
        .onPreferenceChange(SubtaskListHeightPreferenceKey.self) { measured in
            subtaskPanels.noteMeasuredListHeight(for: parentID, height: measured)
        }
    }

    /// Resting affordance: deliberately opens the entry, not a permanent
    /// text field. Focus loss, pin/unpin, and hides keep the state alive.
    private var addAffordance: some View {
        Button {
            uiState.activateSubtaskEntry(for: parentID)
        } label: {
            Text("Add subtask…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add subtask")
        .accessibilityIdentifier("add-subtask-\(parentID.uuidString)")
        .id("subtask-add-\(parentID.uuidString)")
    }

    private var entryRow: some View {
        HStack(spacing: 0) {
            TextField("Add subtask…", text: draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .focused($isEntryFocused)
                .onSubmit(addSubtask)
                // Escape cancels the entry deliberately (drops the draft).
                // Window-level Escape dismissal stays a separate path that
                // only fires when no field editor is active.
                .onExitCommand {
                    uiState.cancelSubtaskEntry(for: parentID)
                    isEntryFocused = false
                }
                .accessibilityIdentifier("subtask-title-\(parentID.uuidString)")
        }
        .foregroundStyle(panelThemePalette.secondaryForegroundColor)
        .atticClearGlassForegroundReadability()
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .id("subtask-entry-\(parentID.uuidString)")
    }

    /// A compact notice under the composer: two lines at most, quiet
    /// colour, and a dismiss control. It also clears on the next successful
    /// save, so it never lingers past the retry it invites.
    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
            Button(action: store.dismissError) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 16, height: 16)
                    .atticGlassControl(in: Circle())
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
            .accessibilityIdentifier("subtask-panel-error-dismiss-\(parentID.uuidString)")
        }
        .padding(.leading, contentHorizontalPadding)
        .padding(.trailing, 6)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .accessibilityIdentifier("subtask-panel-error-\(parentID.uuidString)")
    }

    private func addSubtask() {
        guard let parent else { return }
        guard store.create(title: draft.wrappedValue, parentID: parent.id) != nil else {
            // The store keeps the failure on lastErrorMessage and the draft
            // survives so the user can retry instead of retyping.
            return
        }
        uiState.subtaskDrafts[parentID] = nil
        // Enter saves and keeps the entry active for chain-adding.
        uiState.focusSubtaskEntry(for: parentID)
        isEntryFocused = true
    }
}

/// Drags on unclaimed header space move the pinned window. Controls above it
/// still take their own events, so this only owns empty surface.
struct SubtaskWindowDragHandle: NSViewRepresentable {
    let familyID: UUID

    func makeNSView(context: Context) -> DragHandleNSView {
        let view = DragHandleNSView()
        view.setAccessibilityIdentifier("subtask-drag-\(familyID.uuidString)")
        return view
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {
        nsView.setAccessibilityIdentifier("subtask-drag-\(familyID.uuidString)")
    }

    final class DragHandleNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // The pinned panel is nonactivating: without this, the first
        // press-drag is spent making the window key and never reaches
        // performDrag — the window looked undraggable on first touch.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityLabel() -> String? { "Drag window" }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct SubtaskChromeHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
