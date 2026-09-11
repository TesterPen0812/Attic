import SwiftUI

/// The one checklist presentation shared by the transient hover panel and
/// the pinned mini-window. It reads the live family from `store`, keeps
/// drafts in `uiState.subtaskDrafts`, and leaves every mutation to the same
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
    let parentID: UUID
    let mode: Mode

    @FocusState private var isEntryFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var parent: TaskItem? {
        store.tasks.first { $0.id == parentID && $0.parentID == nil }
    }

    private var children: [TaskItem] {
        store.subtasks(of: parentID)
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

    /// v1 allows one pinned family: when a different family owns it, the pin
    /// control is an explicit "Replace" affordance, not a silent swap.
    private var replacingPinnedFamily: Bool {
        if let pinned = subtaskPanels.pinnedFamilyID {
            return pinned != parentID
        }
        return false
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
        VStack(alignment: .leading, spacing: 0) {
            header
            if !children.isEmpty {
                Rectangle()
                    .fill(panelThemePalette.secondaryForegroundColor.opacity(0.16))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .accessibilityHidden(true)
                childList
            }
            if canAddSubtask {
                Rectangle()
                    .fill(panelThemePalette.secondaryForegroundColor.opacity(0.16))
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .accessibilityHidden(true)
                if showsEntry {
                    entryRow
                } else {
                    addAffordance
                }
            }
            if let message = store.lastErrorMessage {
                errorRow(message)
            }
        }
        .frame(width: SubtaskPanelLayout.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
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
            cornerRadius: AtticStyle.panelCornerRadius,
            gradientCoverage: settings.panelGradientCoverage,
            gradientColorHex: settings.panelGradientColorHex
        )
        .onHover { hovering in
            if mode == .transient {
                subtaskPanels.noteTransientPointer(inside: hovering)
            }
        }
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
                uiState.focusedSubtaskParentID = parentID
            } else if uiState.focusedSubtaskParentID == parentID {
                uiState.focusedSubtaskParentID = nil
            }
        }
        .onAppear {
            if uiState.focusedSubtaskParentID == parentID, showsEntry {
                DispatchQueue.main.async { isEntryFocused = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtasks")
        .accessibilityIdentifier(accessibilityIdentifier)
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
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background {
            if mode == .pinned {
                // The header is also the pinned window's drag handle; the
                // window itself still honours movable-by-background.
                SubtaskWindowDragHandle()
            }
        }
    }

    @ViewBuilder
    private var headerControls: some View {
        switch mode {
        case .transient:
            Button {
                subtaskPanels.pinFamily(parentID)
            } label: {
                Image(systemName: replacingPinnedFamily ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(replacingPinnedFamily
                        ? panelAccentColor : Color.primary.opacity(0.9))
                    .atticClearGlassForegroundReadability()
                    .frame(width: 24, height: 24)
                    .atticGlassControl(in: Circle())
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(replacingPinnedFamily
                ? "Replace the currently pinned list"
                : "Keep this list visible")
            .accessibilityLabel(replacingPinnedFamily
                ? "Replace pinned subtask list"
                : "Pin subtask list")
            .accessibilityIdentifier("subtask-pin-\(parentID.uuidString)")
        case .pinned:
            HStack(spacing: 6) {
                Button {
                    subtaskPanels.unpinPinned()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .atticClearGlassForegroundReadability()
                        .frame(width: 24, height: 24)
                        .atticGlassControl(in: Circle())
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Unpin subtask list")
                .accessibilityLabel("Unpin subtask list")
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("subtask-unpin-\(parentID.uuidString)")

                Button {
                    subtaskPanels.closePinned()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .atticClearGlassForegroundReadability()
                        .frame(width: 24, height: 24)
                        .atticGlassControl(in: Circle())
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close subtask list")
                .accessibilityLabel("Close subtask list")
                .accessibilityIdentifier("subtask-close-\(parentID.uuidString)")
            }
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
                        task: child
                    )
                    .padding(.horizontal, 4)
                }
            }
            .padding(.vertical, 4)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SubtaskListHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
        }
        .frame(height: listHeight)
        .onPreferenceChange(SubtaskListHeightPreferenceKey.self) { measured in
            subtaskPanels.noteMeasuredListHeight(for: parentID, height: measured)
        }
    }

    /// Cached per family by the controller so reopening never reflows.
    private var listHeight: CGFloat {
        SubtaskPanelLayout.clampedListHeight(
            subtaskPanels.measuredListHeight(for: parentID)
                ?? estimatedListHeight
        )
    }

    private var estimatedListHeight: CGFloat {
        CGFloat(children.count) * AtticStyle.controlHitSize + 8
    }

    /// Resting affordance: deliberately opens the entry, not a permanent
    /// text field. Focus loss, pin/unpin, and hides keep the state alive.
    private var addAffordance: some View {
        Button {
            uiState.activateSubtaskEntry(for: parentID)
        } label: {
            Label("Add subtask", systemImage: "plus")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(panelThemePalette.secondaryForegroundColor)
                .atticClearGlassForegroundReadability()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add subtask")
        .accessibilityIdentifier("add-subtask-\(parentID.uuidString)")
        .id("subtask-entry-\(parentID.uuidString)")
    }

    private var entryRow: some View {
        HStack(spacing: 8) {
            Button(action: addSubtask) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save subtask")
            .accessibilityIdentifier("subtask-entry-submit-\(parentID.uuidString)")
            .disabled(!canSubmitDraft)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .id("subtask-entry-\(parentID.uuidString)")
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color(nsColor: .systemRed))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
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
    func makeNSView(context: Context) -> DragHandleNSView {
        DragHandleNSView()
    }

    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}

    final class DragHandleNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if let window { window.performDrag(with: event) }
            else { super.mouseDown(with: event) }
        }
    }
}
