import Combine
import QuartzCore
import SwiftUI

extension PanelBottomBarLook {
    /// "+" on the Draw page: a new, empty canvas straight away.
    static let drawPlus = Plus(label: String(localized: "New canvas"), help: String(localized: "New canvas"),
                               identifier: "draw-new-canvas")
}

/// The Draw page in the panel (Planning.md, Accepted "Draw: the canvas
/// page"): the board under everything, the top row (Pin, the title capsule,
/// ••• and Search), the tool capsule and the shared "+".
struct DrawPageHost: View {
    @ObservedObject var model: DrawPageModel
    /// Read for its hide and reveal counts only (not observed).
    let uiState: PanelUIState
    let layout: PanelPageLayout

    @Environment(\.atticDesign) private var design
    @Environment(\.atticPanelPageIsCurrent) private var isCurrent
    @Environment(\.panelTopRowState) private var topRowState
    @State private var panelHidden = false

    private var barInsets: EdgeInsets { PanelSharedBottomBar.plusInsets(layout: layout) }

    /// The board's clear area: inside the top row and the bottom bar.
    private var clearInsets: NSEdgeInsets {
        let m = DrawPageMetrics.self
        return NSEdgeInsets(top: layout.chromeInsets.top + m.capsule + m.clearGap, left: layout.chromeInsets.leading,
                            bottom: barInsets.bottom + m.capsule + m.clearGap, right: layout.chromeInsets.trailing)
    }

    var body: some View {
        let dim = model.isDrawingLive ? DrawPageMetrics.dimmed : 1
        let dimAnimation = design.reduceMotion ? AtticMotionScale.reducedChange : AtticMotionScale.easeOut(AtticMotionScale.fast)
        ZStack(alignment: .topLeading) {
            DrawBoardRepresentable(model: model, clearInsets: clearInsets)
            // The page's floating controls fold away under the chat, as the
            // top row does: blurred, their glass would still glow through.
            // Unlike the top row, they stay folded while the chat watches.
            DrawSelectionOverlay(model: model, viewportState: model.viewportState)
                .opacity(model.isDrawingLive ? 0 : 1)
                .modifier(PanelChatFold(state: topRowState, page: .canvas, topRow: false))
            DrawZoomPill(model: model, viewportState: model.viewportState)
                .modifier(PanelChatFold(state: topRowState, page: .canvas, topRow: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, barInsets.bottom + DrawPageMetrics.capsule + DrawPageMetrics.pillGap)
            DrawToolBar(model: model)
                .opacity(dim)
                .animation(dimAnimation, value: model.isDrawingLive)
                .modifier(PanelChatFold(state: topRowState, page: .canvas, topRow: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, barInsets.leading)
                .padding(.bottom, barInsets.bottom)
            topRow
                .opacity(dim)
                .animation(dimAnimation, value: model.isDrawingLive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelBottomBar(.canvas, look: PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.drawPlus),
                        actions: PanelBottomBarActions(plus: { [weak model] in
                            guard let model else { return }
                            AtticSounds.play(.created, if: model.newCanvas())
                        }))
        .onAppear { model.start() }
        .onChange(of: isCurrent, initial: true) { _, _ in updateShown() }
        .onReceive(uiState.$hideCount.dropFirst()) { _ in panelHidden = true; updateShown() }
        .onReceive(uiState.$revealCount.dropFirst()) { _ in panelHidden = false; updateShown() }
        // D6: the shell's Pin, ••• and Search dim with the bar.
        .onChange(of: model.isDrawingLive) { _, live in topRowState?.setDimmed(live, on: .canvas) }
        .onDisappear { model.setShown(false); topRowState?.setDimmed(false, on: .canvas) }
    }

    private func updateShown() { model.setShown(isCurrent && !panelHidden) }

    private var topRow: some View {
        PanelTopRow(page: .canvas, layout: layout, searchOpen: model.isSearching, moreCommands: { [model] in model.moreCommands() }) {
            if model.isSearching {
                DrawSearchField(model: model, search: model.search)
                    .accessibilityIdentifier("draw-search")
                    .transition(PanelTopRowLayout.fieldTransition)
            } else {
                PanelTopRowSearchButton(label: "Search", identifier: "draw-search-button", action: model.openSearch)
                    .transition(.opacity)
            }
        }
        .animation(PanelTopRowLayout.searchAnimation(shown: model.isSearching, reduceMotion: design.reduceMotion),
                   value: model.isSearching)
        .overlay(alignment: .top) {
            if !model.isSearching {
                DrawTitleCapsule(model: model, library: model.library)
                    .modifier(PanelChatFold(state: topRowState, page: .canvas))
                    .padding(.top, layout.chromeInsets.top)
                    .padding(.horizontal, DrawPageMetrics.titleSideInset)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // D4: the title capsule owns the filter. Its menu contains only
            // canvases and actions, below the unchanged top-row controls.
            AtticUnfoldPresence(value: !model.isSearching && model.isFiltering ? true : nil, fromTop: true) { _ in
                DrawLibraryMenu(model: model.library, maxListHeight: DrawPageMetrics.menuListRoom(
                    boardHeight: model.boardSize.height,
                    chromeTop: model.clearInsets.top - DrawPageMetrics.capsule - DrawPageMetrics.clearGap,
                    chromeBottom: model.clearInsets.left), isActive: model.isFiltering)
                    // A hidden AppKit-backed field can remain in the native
                    // accessibility tree despite SwiftUI's hidden modifier.
                    // Remove the closed menu's subtree entirely.
            }
            .padding(.top, layout.chromeInsets.top + DrawPageMetrics.capsule + DrawPageMetrics.menuGap)
        }
        .overlay(alignment: .top) {
            if model.isSearching {
                DrawSearchResults(model: model.search)
                    .padding(.top, layout.chromeInsets.top + DrawPageMetrics.capsule + AtticSpacing.s4)
                    .padding(.horizontal, layout.chromeInsets.leading)
                    .transition(AtticMotionPreset.popover.transition(reduceMotion: design.reduceMotion))
            }
        }
    }
}

/// The title: the canvas name with its ⌄ in a glass capsule, centred in the
/// top row. A click turns it into the filter above the canvas menu.
/// Its native input stays prepared between openings, disabled and hidden
/// from accessibility while closed. Rename edits the name in the capsule.
struct DrawTitleCapsule: View {
    @ObservedObject var model: DrawPageModel
    @ObservedObject var library: DrawLibraryMenuModel

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = DrawPageMetrics.self
        let flat = design.effectiveControls != .liquidGlass
        Group {
            if library.isRenaming {
                VStack(spacing: AtticSpacing.s4) {
                    DrawTitleField(text: $library.nameDraft, placeholder: String(localized: "Canvas name"),
                                   label: String(localized: "Canvas name"), onReturn: library.commitRename,
                                   onMove: { _ in }, onEscape: library.cancelRename, onEnd: library.commitRename)
                        .frame(height: m.capsule)
                        .padding(.horizontal, m.titlePadding.leading)
                        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false, edgeLight: true))
                        .accessibilityIdentifier("draw-title-rename")
                    if library.renameFailed {
                        AtticErrorLine(message: String(localized: "Not saved"), onRetry: library.commitRename)
                            .accessibilityIdentifier("draw-title-rename-failure")
                    }
                }
            } else {
                ZStack {
                    HStack(spacing: 5) {
                        AtticIcon(systemName: "magnifyingglass", size: 10, weight: .regular, ink: .helper)
                            .accessibilityHidden(true)
                        DrawTitleField(text: $library.filter, placeholder: model.canvasName,
                            label: String(localized: "Find a canvas"), onReturn: library.openFirstMatch,
                            onMove: library.moveHighlight(by:), onEscape: model.closeFilter, onEnd: nil,
                            alignment: .left, font: .systemFont(ofSize: m.titleFont), identifier: "draw-title-filter",
                            requestsFocus: model.isFiltering && library.mode == .list)
                            .accessibilityLabel(String(localized: "Find a canvas"))
                            .accessibilityHidden(!model.isFiltering || library.mode != .list)
                        Button(action: model.closeFilter) {
                            AtticIcon(systemName: "xmark", size: 8, weight: .medium, ink: .helper)
                                .frame(width: 16, height: m.capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.isFiltering)
                        .accessibilityLabel(String(localized: "Close canvas menu"))
                    }
                    .frame(height: m.capsule)
                    .padding(.leading, m.titlePadding.leading)
                    .padding(.trailing, 4)
                    .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false, edgeLight: true))
                    .frame(width: model.isFiltering ? nil : 0)
                    .opacity(model.isFiltering ? 1 : 0)
                    .allowsHitTesting(model.isFiltering)
                    .accessibilityHidden(!model.isFiltering)

                    Button(action: { model.isFiltering ? model.closeFilter() : model.openFilter() }) {
                        HStack(spacing: m.titleGap) {
                            Text(verbatim: model.canvasName)
                                .font(.system(size: m.titleFont, weight: .bold))
                                .tracking(-0.015 * m.titleFont)
                                .foregroundStyle(design.tokens.color(.heading))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            AtticIcon(systemName: "chevron.down", size: 6, weight: .semibold, ink: .chevron)
                        }
                        .padding(.leading, m.titlePadding.leading)
                        .padding(.trailing, m.titlePadding.trailing)
                        .frame(height: m.capsule)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(AtticRaisedButtonStyle(cornerRadius: AtticRadius.header, flat: flat))
                    .help(model.canvasName)
                    .accessibilityLabel(model.canvasName)
                    .accessibilityHint(String(localized: "Opens the canvas menu"))
                    .accessibilityAddTraits(model.isFiltering ? .isSelected : [])
                    .accessibilityIdentifier("draw-title")
                    .disabled(model.isFiltering)
                    .opacity(model.isFiltering ? 0 : 1)
                    .allowsHitTesting(!model.isFiltering)
                    .accessibilityHidden(model.isFiltering)
                }
            }
        }
        .atticDesignCorners()
    }
}

/// The top Search on the Draw page: the shared header field bound to the
/// library's search; ↑ ↓ and Return go to its results.
struct DrawSearchField: View {
    @ObservedObject var model: DrawPageModel
    @ObservedObject var search: DrawSearchModel
    @State private var searchFocused = true

    var body: some View {
        AtticTabsSearchField(placeholder: String(localized: "Search canvases"), text: $search.query,
                             isFocused: $searchFocused, nativeInputIdentifier: "draw-search-native-input",
                             nativeOnMove: { search.moveHighlight(by: $0) },
                             nativeOnSubmit: { if search.openHighlighted() { model.closeSearch() } },
                             floating: true, onEscape: model.closeSearch, header: true)
            .atticDesignCorners()
            .onKeyPress(.upArrow) { search.moveHighlight(by: -1); return .handled }
            .onKeyPress(.downArrow) { search.moveHighlight(by: 1); return .handled }
            .onKeyPress(.return) {
                guard !search.results.isEmpty else { return .ignored }
                if search.openHighlighted() { model.closeSearch() }
                return .handled
            }
    }
}

/// D5's pill: the zoom level for a moment after a zoom; "Fit" while nothing
/// is in view. A click fits.
struct DrawZoomPill: View {
    @ObservedObject var model: DrawPageModel
    @ObservedObject var viewportState: DrawViewportState

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = DrawPageMetrics.self
        let shown = viewportState.pillShown
        Button(action: model.fit) {
            Text(verbatim: viewportState.pillLabel)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(design.tokens.color(.body))
                .padding(.horizontal, m.pillPadding)
                .frame(height: m.pillHeight)
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: m.pillHeight / 2, flat: design.effectiveControls != .liquidGlass))
        .atticDesignCorners()
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : AtticMotionScale.overlayRise)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel(String(localized: "Zoom to Fit"))
        .accessibilityValue(viewportState.pillLabel)
        .accessibilityIdentifier("draw-zoom-pill")
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: shown), value: shown)
    }
}

/// The board in SwiftUI.
struct DrawBoardRepresentable: NSViewRepresentable {
    let model: DrawPageModel
    let clearInsets: NSEdgeInsets
    @Environment(\.atticDesign) private var design

    func makeNSView(context: Context) -> DrawBoardView {
        let view = DrawBoardView(model: model)
        model.setBoard(size: model.boardSize, clearInsets: clearInsets)
        return view
    }

    func updateNSView(_ view: DrawBoardView, context: Context) {
        model.setBoard(size: view.bounds.size == .zero ? model.boardSize : view.bounds.size, clearInsets: clearInsets)
        view.queueCursorRefresh()
        view.setDotsDesign(design)
    }
}

/// The title field (D4): centred bold text in the capsule; Return, ↑ ↓ and
/// Escape go to the canvas menu.
struct DrawTitleField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let onReturn: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void
    /// The field lost the keyboard (Rename commits then).
    let onEnd: (() -> Void)?
    var alignment: NSTextAlignment = .center
    var font: NSFont = .systemFont(ofSize: DrawPageMetrics.titleFont, weight: .bold)
    var identifier: String?
    var requestsFocus = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private final class PreparedField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.fieldEditor(false, for: self) == nil else { return }
            // Allocate the shared editor without claiming first responder.
            _ = window.fieldEditor(true, for: self)
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = PreparedField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = alignment
        field.font = font
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = placeholder
        if let identifier { field.setAccessibilityIdentifier(identifier) }
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.setAccessibilityElement(requestsFocus)
        field.isEnabled = requestsFocus
        if requestsFocus { context.coordinator.claimFocus(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let takesFocus = requestsFocus && !context.coordinator.parent.requestsFocus
        context.coordinator.parent = self
        field.isEnabled = requestsFocus
        field.setAccessibilityElement(requestsFocus)
        field.setAccessibilityLabel(label)
        if takesFocus { context.coordinator.claimFocus(field) }
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DrawTitleField
        init(_ parent: DrawTitleField) { self.parent = parent }

        func claimFocus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, self.parent.requestsFocus, let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onEnd?() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onReturn(); return true
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }
}
