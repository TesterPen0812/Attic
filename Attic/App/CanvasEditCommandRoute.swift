import Combine
import Foundation
#if os(macOS)
import AppKit
#endif

@MainActor
enum CanvasEditCommandRoute {
    #if os(macOS)
    /// The responder that owns keyboard focus for canvas commands: a text view
    /// focused in the key window, otherwise a canvas text editor that still
    /// holds focus in its visible window. The canvas panel is non-activating,
    /// so it can stop being key while its editor stays open, and accessibility
    /// presses still reach its controls; with the key window alone, Undo and
    /// Redo then acted on canvas history and tool changes skipped the save
    /// veto. Tests inject a specific window's responder instead.
    static var focusedResponder: @MainActor () -> NSResponder? = {
        let keyResponder = NSApp.keyWindow?.firstResponder
        if keyResponder is NSTextView { return keyResponder }
        return CanvasSemanticTextEditor.focusedInVisibleWindow ?? keyResponder
    }
    #endif

    /// Toolbar/menu tool changes must honor the same failed-save veto as a
    /// native responder change, including an unsaved insertion point.
    static func finishTextEditing() -> Bool {
        #if os(macOS)
        if let editor = focusedResponder() as? CanvasSemanticTextEditor {
            let canvas = editor.superview
            let window = editor.window
            guard editor.onCommit?() != false else { return false }
            window?.makeFirstResponder(canvas)
        }
        #endif
        return true
    }

    /// Whether the answer `canUndo`/`canRedo` gives right now is owned by a
    /// text view whose undo stack this app cannot observe: a focused
    /// `NSTextView` that is not the canvas editor — a pinned family panel's
    /// title field, a New/Rename Canvas alert field, a Settings field. Its undo
    /// manager fills and empties while nothing SwiftUI observes here moves, so
    /// a *disabled* state derived from it could not be corrected while it holds
    /// focus. `CanvasEditCommandFocusMonitor` republishes when such a view
    /// takes or gives up focus, which is what keeps this answer itself fresh;
    /// what happens *inside* that session stays unobservable.
    /// The canvas editor is deliberately excluded: focus, typing and its own
    /// undo all republish through `CanvasSession.editingAvailabilityToken`.
    static var availabilityIsUnobserved: Bool {
        #if os(macOS)
        guard let responder = focusedResponder() as? NSTextView else { return false }
        return !(responder is CanvasSemanticTextEditor)
        #else
        return false
        #endif
    }

    static func canUndo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView { return editor.undoManager?.canUndo ?? false }
        #endif
        return session.canUndo
    }

    static func canRedo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView { return editor.undoManager?.canRedo ?? false }
        #endif
        return session.canRedo
    }

    @discardableResult
    static func undo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView {
            guard editor.undoManager?.canUndo == true else { return false }
            editor.undoManager?.undo()
            return true
        }
        #endif
        return session.undo()
    }

    @discardableResult
    static func redo(session: CanvasSession, section: PanelSection) -> Bool {
        guard section.isCanvas else { return false }
        #if os(macOS)
        if let editor = focusedResponder() as? NSTextView {
            guard editor.undoManager?.canRedo == true else { return false }
            editor.undoManager?.redo()
            return true
        }
        #endif
        return session.redo()
    }
}

/// Publishes the moments at which the responder that owns Undo/Redo can have
/// changed, so Edit-menu enablement — which SwiftUI samples only when it
/// renders — is never left describing a responder that no longer has focus.
///
/// Canvas history, the canvas editor's focus and typing, and the selected
/// section all publish themselves through `CanvasSession` and `PanelUIState`.
/// The gap this closes is a *foreign* text view — a pinned family panel's
/// rename field, a New/Rename Canvas alert field, a Settings field — taking or
/// giving up a field-editor session: nothing in the app's own model moves, so
/// the menu kept whatever enablement it last rendered. A stale *disabled* item
/// is the damaging direction: AppKit consumes ⌘Z at it and neither it nor the
/// field's own undo runs (`testADisabledShortcutItemSwallowsItsKeyEquivalent`),
/// and a menu that is never opened never self-heals through menu tracking.
///
/// It subscribes broadly and publishes narrowly. Every notification schedules
/// one re-read of the live first responder, coalesced to a single pass per run
/// loop turn, and the published answer changes only when ownership actually
/// changes — so duplicate notifications, caret movement and typing inside one
/// session cost no render at all.
///
/// The re-read is deferred by one run-loop pass on purpose. An end-of-session
/// notification is posted while the view that is leaving is still the first
/// responder, so reading it in that instant would see the old owner; reading
/// once the transition has settled makes begin/end ordering irrelevant and
/// makes a begin that arrives before the matching end harmless.
///
/// The published value exists to *trigger* a render, not to answer one.
/// `CanvasEditCommandAvailability` re-reads the live route on every render, so
/// a mirror that ever lagged costs an extra render, never a wrong item.
@MainActor
final class CanvasEditCommandFocusMonitor: ObservableObject {
    /// Whether the last settled sample saw a text view this app cannot
    /// republish owning `canUndo`/`canRedo`.
    @Published private(set) var foreignTextViewOwnsAvailability = false

    #if os(macOS)
    /// Field-editor session boundaries and window focus changes: every way
    /// undo/redo ownership moves between a foreign text view and the canvas
    /// without the app's own model moving.
    ///
    /// The two shapes announce themselves differently, and between them they
    /// cover what enablement needs. A text field's shared field editor — a
    /// pinned family panel's rename field, a New/Rename Canvas alert field —
    /// posts a selection change as it is installed, so it is published on
    /// arrival, before anything is typed. A plain `NSTextView` taking focus can
    /// post nothing at all, but it cannot acquire something to undo without
    /// beginning to edit, so the latest it can be published is the moment it
    /// first has an undo a stale disabled item would swallow. Giving focus up
    /// posts an end of editing and a selection change in both shapes.
    private static let observedNotifications: [Notification.Name] = [
        NSText.didBeginEditingNotification,
        NSText.didEndEditingNotification,
        NSTextView.didChangeSelectionNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification
    ]

    private var observations: [NSObjectProtocol] = []
    private var hasPendingSample = false
    #endif

    init() {
        #if os(macOS)
        foreignTextViewOwnsAvailability = CanvasEditCommandRoute.availabilityIsUnobserved
        let center = NotificationCenter.default
        observations = Self.observedNotifications.map { name in
            // `.main` guarantees the block runs on the main thread even if a
            // notification is ever posted off it, so no isolation is assumed
            // that AppKit has not already established.
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSample() }
            }
        }
        #endif
    }

    deinit {
        #if os(macOS)
        observations.forEach(NotificationCenter.default.removeObserver)
        #endif
    }

    /// Drops the observers ahead of deallocation, so a monitor cannot outlive
    /// the scope that set it up — tests rely on this to prove the observers are
    /// the mechanism rather than a coincidence of the run loop.
    func stopObserving() {
        #if os(macOS)
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        #endif
    }

    #if os(macOS)
    private func scheduleSample() {
        guard !hasPendingSample else { return }
        hasPendingSample = true
        RunLoop.main.perform(inModes: [.common, .modalPanel, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated { self?.sampleSettledOwnership() }
        }
    }

    /// The settled re-read, one run-loop pass after the notification that woke
    /// it. Publishing only on a real change is what keeps caret movement,
    /// typing and repeated begin/end pairs from re-rendering the menu.
    private func sampleSettledOwnership() {
        hasPendingSample = false
        let ownsAvailability = CanvasEditCommandRoute.availabilityIsUnobserved
        guard ownsAvailability != foreignTextViewOwnsAvailability else { return }
        foreignTextViewOwnsAvailability = ownsAvailability
    }
    #endif
}

/// Whether the app's Edit menu shadows the standard Undo/Redo, and when those
/// items are presented enabled.
///
/// Enablement reads `CanvasEditCommandRoute`, the same source the canvas
/// toolbar's Undo/Redo buttons read, so the menu never offers an operation the
/// toolbar shows as unavailable. Mutations, undo and redo republish it through
/// `CanvasSession.canUndo`/`canRedo`, a canvas text editor's focus, typing and
/// own undo republish it through `editingAvailabilityToken`, leaving the Canvas
/// section republishes it through `PanelUIState.selectedSection`, and a foreign
/// text view taking or giving up focus republishes it through
/// `CanvasEditCommandFocusMonitor`. A render therefore happens at every
/// boundary that can change which responder owns the answer.
///
/// One case is exempt, and it is the reason enablement is not the bare route
/// answer. The items claim ⌘Z and ⇧⌘Z, and AppKit stops at the first item
/// matching a shortcut: a *disabled* one consumes the event and neither it nor
/// the standard item behind it runs
/// (`testADisabledShortcutItemSwallowsItsKeyEquivalent`). When the route's
/// answer comes from a *foreign* text view — a pinned family panel's title
/// field, a New/Rename Canvas alert field, a Settings field — the focus
/// monitor republishes when that view gains or loses focus, but nothing
/// observes its undo manager filling and emptying *within* that session
/// (`CanvasEditCommandRoute.availabilityIsUnobserved`). A disabled item would
/// then survive the field filling up with undoable typing, and ⌘Z in it would
/// do nothing at all. While such a view holds focus the items therefore stay
/// enabled, and the route — which re-reads the first responder when it runs —
/// forwards ⌘Z to that view's own undo manager. The two mechanisms are
/// deliberately layered: the monitor makes the boundary observable so canvas
/// state can govern enablement again the moment focus leaves, and this exemption
/// keeps the in-session answer safe without depending on a render landing
/// between a keystroke and the ⌘Z that follows it.
///
/// Enablement is not what decides which undo runs. It only decides what the
/// menu claims, and an enabled item with nothing to undo is a no-op, the same
/// thing the standard disabled Undo does.
///
/// The canvas toolbar's own Undo/Redo buttons take the route answer directly:
/// they hold no key equivalent, so a stale one cannot swallow anything.
@MainActor
enum CanvasEditCommandAvailability {
    /// Whether the shadowing items exist at all. Outside the Canvas section
    /// the standard Edit ▸ Undo/Redo is left alone.
    static func offersShadowingItems(section: PanelSection) -> Bool {
        section.isCanvas
    }

    /// Whether the offered *Undo Canvas Change* item is presented enabled.
    static func undoIsEnabled(session: CanvasSession, section: PanelSection) -> Bool {
        isEnabled(CanvasEditCommandRoute.canUndo(session: session, section: section), section: section)
    }

    /// Whether the offered *Redo Canvas Change* item is presented enabled.
    static func redoIsEnabled(session: CanvasSession, section: PanelSection) -> Bool {
        isEnabled(CanvasEditCommandRoute.canRedo(session: session, section: section), section: section)
    }

    /// An offered item may only be presented disabled when the answer behind
    /// it is one this app republishes: see the type's documentation.
    private static func isEnabled(_ canPerform: Bool, section: PanelSection) -> Bool {
        guard offersShadowingItems(section: section) else { return false }
        return canPerform || CanvasEditCommandRoute.availabilityIsUnobserved
    }
}
