import SwiftUI

/// The geometry the shell hands every page it hosts. Pages lay themselves
/// out from these values only, so the shell stays the one owner of the
/// panel's corner-aware padding and of the header band above the content.
struct PanelPageLayout: Equatable {
    /// The panel's corner size (its continuous corner radius).
    var cornerSize: CGFloat
    /// The visible panel surface, without the elevation margin.
    var panelSize: CGSize
    /// Corner-aware insets for page content.
    var contentInsets: EdgeInsets
    /// Corner-aware insets for floating controls (header, bottom bars).
    var chromeInsets: EdgeInsets

    /// The panel's own coordinate space: its bounds are the whole visible
    /// panel, header and bottom bars included, so `atticScrollEdgeFade`
    /// measures its edge zones in it.
    static let coordinateSpace = NamedCoordinateSpace.named("AtticPanel")

    /// The bottom of the header, measured from the panel's top edge. Content
    /// that scrolls starts below it and fades as it passes under it.
    var headerBottom: CGFloat { PanelHeaderLayout.bottom(chromeInsets: chromeInsets) }
    /// The scroll-under fade's bands at the panel's top and bottom edges
    /// (owner, 2026-10-06): from the edge to the middle of the header's
    /// controls, and of the bottom row.
    var scrollEdgeFadeTop: CGFloat { chromeInsets.top + AtticControlSize.panelButton.height / 2 }
    var scrollEdgeFadeBottom: CGFloat { chromeInsets.bottom + AtticControlSize.panelButton.height / 2 }

    /// The widest a page's column of rows and controls grows (U-42): a
    /// panel widened past it keeps its column this wide, centred, so a
    /// date never floats far from its title. The panel itself stays freely
    /// resizable.
    static let readingWidth: CGFloat = 600

    /// This layout with its content and floating controls held to a
    /// centred column at most `maxWidth` wide (the panel's own insets
    /// included).
    func readingColumn(maxWidth: CGFloat = PanelPageLayout.readingWidth) -> PanelPageLayout {
        let extra = max(0, (panelSize.width - maxWidth) / 2).rounded(.down)
        guard extra > 0 else { return self }
        var column = self
        column.contentInsets.leading += extra
        column.contentInsets.trailing += extra
        column.chromeInsets.leading += extra
        column.chromeInsets.trailing += extra
        return column
    }

    init(cornerSize: CGFloat, panelSize: CGSize) {
        self.cornerSize = cornerSize
        self.panelSize = panelSize
        contentInsets = PanelGeometry.contentInsets(cornerSize: cornerSize, panelSize: panelSize)
        chromeInsets = PanelGeometry.chromeInsets(cornerSize: cornerSize, panelSize: panelSize)
    }
}

/// How far above the panel's bottom content inset shell-level notices (the
/// error banner, toasts) must sit so they clear the page's own bottom
/// controls. A page that has bottom controls reports it; the default suits a
/// page with a single compact bottom bar.
struct PanelPageNoticeClearancePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 20

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
