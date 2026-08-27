# Canvas Ink Essentials — Repository Design

## Scope and placement

Canvas becomes the fourth macOS `PanelSection` beside Tasks, Backlog, and Notes, and a Canvas destination in the iPhone shell. It is one persistent board. V1 contains only pen, whole-stroke eraser, an accessible fixed palette, continuous width, undo/redo, zoom/pan, fit/reset view, confirmed clear, and automatic persistence of completed operations.

No shapes, arrows, text, files/images, layers, multiple boards, collaboration, templates, or AI drawing are introduced.

## Boundaries

- **Domain/format:** platform-neutral stroke archive, viewport math, hit testing, and gesture state transitions.
- **Persistence:** a shared `CanvasStore` over the existing SwiftData/CloudKit container.
- **Session history:** a `CanvasSession` owns tools, viewport, visible immutable stroke snapshots, and session-local undo/redo.
- **Rendering/input:** one native `NSView`/`UIView` surface renders cached Core Graphics paths and owns the in-progress gesture. SwiftUI supplies controls and accessibility, not one view per point or stroke.
- **Platform shells:** `CanvasPanelContent` integrates the compact macOS panel; `MobileCanvasScreen` integrates the iPhone root.

## Persistent model and stroke format

Two CloudKit-compatible SwiftData models are added without unique constraints or relationships:

- `CanvasBoardItem`: deterministic app-level board UUID, `formatVersion` defaulting to `1`, monotonic `clearGeneration` defaulting to `0`, and `updatedAt`.
- `CanvasStrokeItem`: logical stroke UUID, `payloadVersion` defaulting to `1`, JSON `payload` defaulting to empty `Data`, `boardGeneration` defaulting to `0`, monotonic `mutationVersion` defaulting to `1`, `tombstoned` defaulting to `false`, and created/updated/deleted timestamps. The field avoids the `NSManagedObject.isDeleted` name reserved by SwiftData's Core Data backing.

The board row is lazily materialized; no row means generation zero. A completed stroke is encoded once as sorted-key UTF-8 JSON:

```json
{
  "version": 1,
  "color": "ink",
  "width": 3.0,
  "points": [{"x": 12.5, "y": -8.25}]
}
```

Coordinates and widths are logical board-point `Double` values. Color is a stable semantic token, not a platform color object. Unknown versions or malformed payloads are ignored for rendering, retained in storage, and surfaced as a non-destructive store error.

## Coordinate system and viewport

Strokes are stored in an unbounded world coordinate system. The viewport is `{center, scale}`:

- `view = (world - center) * scale + viewportCenter`
- `world = (view - viewportCenter) / scale + center`

Resize changes only `viewportCenter`; it never rewrites points. Pan changes `center`; zoom is clamped and anchored around the gesture location. Reset uses center `(0, 0)` and scale `1`. Fit computes visible-stroke bounds plus padding, centers them, and clamps scale. An empty board resets.

Viewport state is local session state and is not written to SwiftData or CloudKit.

## Input and rendering semantics

The native surface has explicit `idle`, `drawing`, `erasing`, and `panning` states.

- Primary mouse/pencil/finger input starts pen or eraser work.
- Trackpad scrolling, magnification, Space-drag, middle/secondary drag, two-finger pan, and pinch are viewport gestures and never begin ink.
- If a viewport gesture or second touch takes ownership while ink is in progress, the unfinished ink/erase probe is discarded before panning.
- Pointer/touch up completes the operation. Cancellation, tool change, section removal, window loss, app deactivation, or view dismantling discards it.
- Coalesced pointer/touch samples are consumed when available. Points remain in memory during the gesture; one callback and at most one SwiftData save occurs when the completed stroke or grouped erase is accepted.
- Eraser hit IDs are accumulated during the gesture and committed together, so dragging the eraser does not save per sample.
- Rendering uses one native view and cached `CGPath` values per immutable stroke snapshot. The active stroke is drawn directly by that view.

## Replica, sync, and failure semantics

The existing event-driven `NSPersistentStoreRemoteChange` and `NSPersistentCloudKitContainer.eventChangedNotification` protections are reused. A completed import replaces the long-lived `ModelContext` before fetching.

CloudKit may contain physical duplicates with the same logical UUID:

- Presentation groups replicas; it never deletes duplicates during refresh.
- Board generation is the maximum generation across board replicas.
- A stroke winner is chosen deterministically by `mutationVersion`, then `boardGeneration`, then tombstone-over-visible, then `updatedAt`, then a stable payload/persistent-ID tie break.
- Mutation, restore, erasure, and deletion state are applied to every physical replica of the logical stroke UUID.
- Board clear mutation is applied to every physical board replica.

A clear increments the monotonic board generation. Strokes from older generations become invisible, including stale replicas imported later. This avoids destructive mass deletion and prevents pre-clear ink from reappearing.

On save failure, the context rolls back, a fresh context reloads the persisted state, the attempted session operation is not added to history, and the UI exposes the error. Completed ink already saved before section changes, hiding, Settings focus, termination, relaunch, or imports remains durable.

## Undo, redo, erase, and clear

History is deliberately session-local and is not synchronized or restored after relaunch.

- Add undo/redo toggles the logical stroke tombstone using a higher mutation version.
- Erase undo restores all strokes erased by that gesture; redo erases the same logical IDs.
- Clear increments generation. Undo replays the captured pre-clear visible strokes into the current generation without decrementing generation; redo performs another generation increment.
- A successful new user operation clears redo.
- A failed operation changes neither stack.
- A remote/import refresh that changes the semantic board snapshot clears both stacks so stale local commands cannot overwrite imported state.

## Accessibility and compact layout

The four-section macOS picker uses a one-row layout when it fits and a two-row fallback at constrained content widths. Every tool, color, width, history, view, and clear control has a label and stable accessibility identifier. Selection uses shape/border/checkmark state in addition to color. The canvas reports stroke count and active tool. Keyboard focus and shortcuts cover section selection, pen/eraser, undo/redo, fit/reset, and clear. Animations respect Reduce Motion; palette rendering uses semantic system colors in Light and Dark appearances.

UI tests use accessibility hooks for the surface, stroke count, tools, undo/redo, fit/reset, clear confirmation, section switching, Settings focus, and a dedicated local UI-test store that can be retained across a controlled relaunch without touching production data.

## Affected files

New shared files:

- `Attic/Models/CanvasBoardItem.swift`
- `Attic/Models/CanvasStrokeItem.swift`
- `Attic/Canvas/CanvasTypes.swift`
- `Attic/Canvas/CanvasStrokeCodec.swift`
- `Attic/Canvas/CanvasViewport.swift`
- `Attic/Canvas/CanvasInputStateMachine.swift`
- `Attic/Canvas/CanvasSession.swift`
- `Attic/Canvas/CanvasSurface.swift`
- `Attic/Services/CanvasStore.swift`

New platform UI files:

- `Attic/Views/Panel/CanvasPanelContent.swift`
- `AtticMobile/Views/MobileCanvasScreen.swift`

Existing integration files:

- `Attic/Services/PersistenceController.swift`
- `Attic/App/AppCoordinator.swift`
- `Attic/Window/PanelSection.swift`
- `Attic/Window/PanelUIState.swift`
- `Attic/Window/AtticPanelController.swift`
- `Attic/Views/Panel/AtticPanelView.swift`
- `AtticMobile/App/MobileAppModel.swift`
- `AtticMobile/Views/MobileAppRoot.swift`
- `Scripts/generate_project.rb`
- generated `Attic.xcodeproj` files
- macOS/iPhone unit and UI-test targets

Identifiers, entitlements, APNs/CloudKit environments, observers, store environment separation, and production data paths remain unchanged.
