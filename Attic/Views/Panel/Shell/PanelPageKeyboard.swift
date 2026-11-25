import AppKit
import ObjectiveC
import SwiftUI

// MARK: - A page that is not shown never holds the keyboard
// (ops/design/hidden-page-keyboard.lead.md, the lead's verdict of 25 Nov)

extension EnvironmentValues {
    /// The panel page this content is part of; nil in the panel's chrome.
    /// Set once per page by the shell and never changed for that subtree,
    /// so reading it re-renders nothing.
    @Entry var atticPanelPage: PanelPage? = nil
}

/// Which part of a panel an AppKit view the keyboard can land on belongs
/// to: a page, or the panel's chrome (the top row, the Composer, overlays).
enum PanelKeyboardMembership: Equatable {
    case page(PanelPage)
    case chrome
}

/// The panel's one keyboard rule. The shell keeps hidden pages built and in
/// the window, hidden only in SwiftUI, so AppKit's own key-view loop and
/// focus hand-backs can land a responder under a page that is not shown.
/// AtticPanel asks this rule before a view takes the keyboard; the views
/// themselves answer `canBecomeKeyView` from it, so AppKit's Tab loop skips
/// them. Page membership is a tag each of our AppKit views gets when it is
/// made; whether that page is shown is asked of the panel, which answers
/// from the same state the shell switches on.
@MainActor
enum PanelPageKeyboard {
    nonisolated(unsafe) private static var membershipKey: UInt8 = 0

    /// Tags `view` with the page its representable sits on (chrome outside
    /// every page). Called once, when the view is made.
    static func tag(_ view: NSView, _ environment: EnvironmentValues) {
        tag(view, environment.atticPanelPage.map(PanelKeyboardMembership.page) ?? .chrome)
    }

    static func tag(_ view: NSView, _ membership: PanelKeyboardMembership) {
        let raw: String = switch membership {
        case .page(let page): page.rawValue
        case .chrome: ""
        }
        objc_setAssociatedObject(view, &membershipKey, raw as NSString, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The tag on `view` itself (not its ancestors); nil when untagged.
    static func membership(of view: NSView) -> PanelKeyboardMembership? {
        guard let raw = objc_getAssociatedObject(view, &membershipKey) as? String else { return nil }
        if raw.isEmpty { return .chrome }
        return PanelPage(rawValue: raw).map(PanelKeyboardMembership.page)
    }

    /// Whether `view` may take the keyboard now: no page it is part of is
    /// hidden in its panel, and no kept host above it is out of use. Views
    /// outside an AtticPanel are not the panel's to refuse.
    static func mayTakeKeyboard(_ view: NSView) -> Bool {
        guard let panel = view.window as? AtticPanel else { return true }
        var current: NSView? = view
        while let candidate = current {
            if let host = candidate as? KeptContentHostingView, !host.isInteractive { return false }
            if case .page(let page)? = membership(of: candidate), !panel.showsPage(page) { return false }
            current = candidate.superview
        }
        return true
    }

    #if DEBUG
    /// Where the guard rail reports; a test swaps it to record instead of
    /// stopping the process.
    static var reportUnknownResponder: (String) -> Void = { assertionFailure($0) }

    /// Guard rail (debug and test builds): in a real shell (a panel whose
    /// owner answers which page is shown), one of our own views under the
    /// shell's hosting view took the keyboard with no page tag and no kept
    /// or overlay host between them, so the rule above cannot know its
    /// page. Tag its representable. A panel with no shell (a test's bare
    /// panel) has no pages, so nothing there is reported.
    static func assertKnown(_ view: NSView, in panel: AtticPanel) {
        guard panel.showsPageQuery != nil, !(view is AtticPanelHostingView),
              Bundle(for: type(of: view)) == Bundle(for: AtticPanel.self) else { return }
        var current: NSView? = view
        while let candidate = current {
            if membership(of: candidate) != nil || candidate is KeptContentHostingView
                || candidate is AtticOverlayHostingView { return }
            if candidate is AtticPanelHostingView {
                reportUnknownResponder("\(type(of: view)) took the panel's keyboard with no page tag and no host above it")
                return
            }
            current = candidate.superview
        }
        // Not under the shell's hosting view: the panel's own chrome layers.
    }
    #endif
}
