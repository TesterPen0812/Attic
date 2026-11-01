import Combine
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
        let dimAnimation = design.reduceMotion ? nil : AtticMotionScale.easeOut(AtticMotionScale.fast)
        ZStack(alignment: .topLeading) {
            DrawBoardRepresentable(model: model, clearInsets: clearInsets)
            DrawSelectionOverlay(model: model, viewportState: model.viewportState)
                .opacity(model.isDrawingLive ? 0 : 1)
            DrawZoomPill(model: model, viewportState: model.viewportState)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, barInsets.bottom + DrawPageMetrics.capsule + DrawPageMetrics.pillGap)
            DrawToolBar(model: model)
                .opacity(dim)
                .animation(dimAnimation, value: model.isDrawingLive)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, barInsets.leading)
                .padding(.bottom, barInsets.bottom)
            topRow
                .opacity(dim)
                .animation(dimAnimation, value: model.isDrawingLive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelBottomBar(.canvas, look: PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.drawPlus),
                        actions: PanelBottomBarActions(plus: { [weak model] in model?.newCanvas() }))
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
        PanelTopRow(page: .canvas, layout: layout, searchOpen: model.isSearching) {
            if model.isSearching {
                AtticTabsSearchField(placeholder: String(localized: "Search canvases"), text: $model.searchQuery,
                                     floating: true, onEscape: model.closeSearch, header: true)
                    .atticDesignCorners()
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
                DrawTitleCapsule(model: model)
                    .padding(.top, layout.chromeInsets.top)
                    .padding(.horizontal, DrawPageMetrics.titleSideInset)
                    .transition(.opacity)
            }
        }
    }
}

/// The title: the canvas name with its ⌄ in a glass capsule, centred in the
/// top row. D4: a click makes the capsule itself the canvas filter, typing in
/// place, with the library's menu hanging under it.
struct DrawTitleCapsule: View {
    @ObservedObject var model: DrawPageModel

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = DrawPageMetrics.self
        let flat = design.effectiveControls != .liquidGlass
        VStack(spacing: AtticSpacing.s4) {
            Group {
                if model.isFiltering {
                    DrawTitleField(text: $model.filterText, onReturn: { DrawLibraryHosting.openFirstMatch(model) },
                                   onMove: { DrawLibraryHosting.moveHighlight(model, by: $0) }, onEscape: model.closeFilter)
                        .frame(height: m.capsule)
                        .padding(.horizontal, m.titlePadding.leading)
                        .background(Color.clear.atticRaisedMaterial(cornerRadius: AtticRadius.header, interactive: false))
                        .accessibilityIdentifier("draw-title-filter")
                } else {
                    Button(action: model.openFilter) {
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
                    .accessibilityIdentifier("draw-title")
                }
            }
            .atticDesignCorners()
            if model.isFiltering {
                DrawLibraryHosting.menu(model)
            }
        }
        .animation(DrawPageMetrics.fold(design.reduceMotion), value: model.isFiltering)
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

    func makeNSView(context: Context) -> DrawBoardView {
        let view = DrawBoardView(model: model)
        model.setBoard(size: model.boardSize, clearInsets: clearInsets)
        return view
    }

    func updateNSView(_ view: DrawBoardView, context: Context) {
        model.setBoard(size: view.bounds.size == .zero ? model.boardSize : view.bounds.size, clearInsets: clearInsets)
        view.window?.invalidateCursorRects(for: view)
    }
}

/// The title field (D4): centred bold text in the capsule; Return, ↑ ↓ and
/// Escape go to the canvas menu.
struct DrawTitleField: NSViewRepresentable {
    @Binding var text: String
    let onReturn: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: DrawPageMetrics.titleFont, weight: .bold)
        field.placeholderString = String(localized: "Canvases")
        field.delegate = context.coordinator
        field.setAccessibilityLabel(String(localized: "Find a canvas"))
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DrawTitleField
        init(_ parent: DrawTitleField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

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

/// The seam to the library builder's canvas menu (`Attic/Draw/Library/`).
/// Until their `DrawLibraryMenu` lands, the filter shows no menu.
@MainActor
enum DrawLibraryHosting {
    @ViewBuilder
    static func menu(_ model: DrawPageModel) -> some View {
        EmptyView()
    }

    static func openFirstMatch(_ model: DrawPageModel) {}
    static func moveHighlight(_ model: DrawPageModel, by step: Int) {}
}
