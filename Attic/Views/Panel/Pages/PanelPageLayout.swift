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
