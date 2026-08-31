# Canvas — verified macOS local implementation

## Product scope

Canvas is the fourth section of the compact macOS Attic panel, beside Tasks, Backlog, and Notes. Current development and verification are macOS-only and local-first. The iPhone target and CloudKit synchronization are deferred; their source may remain in the repository, but `ATTIC_LOCAL_ONLY` builds do not create Canvas remote-change observers, CloudKit event observers, sync activity assertions, or sync timeouts.

An isolated preview must use a unique `com.taha.Attic.*` bundle identity and its own local store. Canvas work must never copy, reset, migrate, or replace the official app's data.

## Current object and tool model

Canvas currently supports:

- multiple named pages;
- pen and whole-stroke eraser input;
- image import, selection, movement, resizing, deletion, and layer movement;
- rectangle, ellipse, line, and arrow placement;
- text placement;
- pan, pinch/magnification, zoom controls, reset, and fit;
- clear, Undo, and Redo.

The persistence model is not yet a fully semantic drawing-object model. Ink is stored as stroke geometry. Shapes are converted to strokes, and text is rendered into image bytes before storage. Therefore existing shape and text content remains renderable but is not structurally editable as a shape or as text. A semantic text/shape migration requires a separately approved, backward-compatible schema and storage plan; legacy content must not be reinterpreted or destroyed.

## Persistence and duplicate safety

The local SwiftData store contains `CanvasBoardItem`, `CanvasStrokeItem`, and `CanvasImageItem` rows. Logical UUIDs are app-level identifiers rather than SwiftData uniqueness constraints. Refresh selects one deterministic presentation winner for duplicate physical rows, while mutations apply to every physical replica with the same logical UUID.

Board clear uses a monotonic generation. Older-generation content stays retained but invisible, including stale rows that arrive later. Clear Undo restores the captured strokes and images into the current generation in one persistence transaction; it does not decrement the generation. A second-stage restore failure rolls the whole transaction back.

Canvas saves report typed outcomes: no change, persisted, persisted with a refresh warning, or total failure. A successful persistence followed by a failed fresh-context reload is not retried as a save; the store reconciles from the already-saved context and keeps the visible/durable result truthful.

In local-only builds, Canvas save and reveal paths remain Cloud/APNs dormant. Deferred synchronization code is not evidence that CloudKit or mobile delivery works.

## Stroke archive

Stroke geometry is encoded as sorted-key UTF-8 JSON with a version, semantic color token, width, and logical board points:

```json
{
  "version": 1,
  "color": "ink",
  "width": 3.0,
  "points": [{"x": 12.5, "y": -8.25}]
}
```

Unknown versions or malformed stroke payloads are retained and omitted from rendering with a non-destructive warning. Failed image decodes are memoized, render a stable non-destructive checker/X placeholder, and can be explicitly invalidated for retry by the renderer cache. The Canvas UI does not yet expose the required retry/remove/export recovery actions.

## Coordinates, pages, and history

Strokes and images use an unbounded world coordinate system. The viewport is `{center, scale}`:

- `view = (world - center) * scale + viewportCenter`
- `world = (view - viewportCenter) / scale + center`

Resize changes the view center and does not rewrite stored object geometry. Pan changes world center; zoom is clamped and anchored around the gesture location. Fit uses visible content bounds plus padding.

Viewport and Undo/Redo history are currently session-local. They are not persisted on relaunch and are not yet independently retained per page. This is an accepted limitation under C-06, not a documented guarantee. App-level Commands route Command-Z and Command-Shift-Z to the active Canvas independently of whether compact toolbar buttons are visible.

## Input and rendering

The macOS `CanvasNSView` owns pointer interaction and renders through Core Graphics. Completed ink and grouped erasure persist once per accepted gesture. Pan, magnification, image transforms, and placement have separate interaction paths.

Rendering culls strokes and images outside an expanded world viewport. Stroke paths and decoded images use caches; the decoded image cache has a 256 MiB cost limit and 48-image count limit. On macOS, the surface supplies only images intersecting the viewport plus a 192-point prefetch margin to the three-worker decode queue, with onscreen images ahead of margin-only images. Leaving that candidate set prunes queued work. Up to three active ImageIO operations finish into the bounded cache because their C decode cannot be interrupted once entered; page/lifecycle teardown still cancels publication. Failed-decode history retains all current candidates and at most 512 off-canvas failures.

These bounds do not yet make the full pipeline resource-complete:

- rapid ink currently does not consume AppKit coalesced mouse samples;
- history is count-bounded rather than byte-bounded;
- transform refresh still performs an exact encoded-`Data` comparison on the main actor.

Image/file import preparation is bounded to two concurrent items, cancellable, ordered by the original batch, and bound to an immutable page UUID plus board generation. The store validates that target immediately before one atomic batch save. UI progress and per-item recovery presentation are still being completed under C-16.

## Accessibility and compact-shell boundary

The Canvas surface exposes retained strokes and images as independently navigable accessibility objects with selected state, position, finite forward/reverse keyboard traversal, image transform/delete/layer actions, and truthful mutation outcomes. Installed VoiceOver speech order, rotor behavior, announcements, and Full Keyboard Access visual focus still require UAT under C-03.

The compact shell owns legal resize handles outside content. Hosted all-corner coverage is still required to prove that no drawn Canvas point is stolen by shell resizing and that attached-side resize remains disabled.

## Verification boundary

Unit tests establish local model, persistence, duplicate, command-routing, import-target, and geometry behavior. Signed UI tests establish only the scenarios they actually drive through the real `NSPanel` host. They do not establish physical trackpad behavior, installed visual quality, CloudKit, APNs, iPhone, TestFlight, or Production behavior.

Current accepted-finding status and exact evidence live in `Docs/AuditFixResolutionLedger-2026-08-31.md`.
