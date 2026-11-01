# Draw data API

All calls are on the main actor. Keep one `DrawStoreProtocol` instance alive above
page, canvas and panel switches; it owns per-canvas session Undo/Redo. The store
has no selection, tool or viewport state. Geometry is in points.

```swift
let store: any DrawStoreProtocol = DrawInMemoryStore()
let canvas = store.create(name: "Ideas") // local draft, not in library yet
let box = DrawObject(content: .text("Hello"))
let result = store.perform(.put([box]), on: canvas.id)
let snapshot = try store.open(canvas.id)
let matches = try store.search("#work hello")
```

`put` adds/replaces objects (including frame, z-order and style); `remove` deletes
whole objects. Supply finished smoothed samples for strokes; storage preserves
them exactly. Each command is one Undo step, including each text typing edit:
submit `put` while typing, not only on blur. Multiple-object transforms/style
changes are one `put`. Image originals, dimensions and type round-trip exactly.
Colours are Ink/Blue/Red/Green/Orange; sizes map to 1.5/2.25/4 pt strokes and
11/14/20 pt text; corners are Square/Rounded.

`library(deleted:)` lists metadata newest first. `search` combines `#tags` with
name/text terms and returns matching text box IDs for reveal. `duplicate` gives
objects fresh IDs. New and empty duplicates stay drafts until first content.
`deleteCanvas`/`restoreCanvas` manage deleted canvases; `deletedImages(in:)` and
`restoreObjects` expose individually deleted images for Recently Deleted.
There is no Clear command and no automatic permanent deletion in this API.

Observe `revision`, `lastDelta`, `pendingEdits` and `hasUnsettledEdits` on the
concrete observable store. Successful saves publish one delta and advance history
once. `.retry` keeps the visible after-draft and permits `retry(on:)`; `.held`
requires `reconcile(on:)`. History stays unchanged until a save is confirmed.
Do not release the session or allow quit with unsettled edits. The store blocks
further commands on that canvas until reconciliation/Retry settles it. Other
canvases remain available. `reload` reads fresh durable values after external
imports and clears only that canvas's old history; it refuses unsettled drafts.

Use `copy` to encode `DrawStore.clipboardType` (`com.taha.attic.draw-objects.v1`)
into the pasteboard. After successfully writing the pasteboard, call `cut` to
remove the same IDs. `paste` validates the version, assigns fresh IDs, offsets
geometry, and places the objects above existing objects as one Undo step. Copy
as Image and all pasteboard/UI rendering are the next builder's responsibility.

For durable storage, use `DrawPersistentStore(container: appContainer)` behind
the same protocol. It accepts an existing container; it never opens a default
path. `PersistenceController.appModelTypes` registers the three new entities.
The writer serializes on the main actor, uses one fresh autosave-disabled
context and one save per command. Binary payloads are separate from object
headers and library metadata. Library reads load only metadata and optional
thumbnails. SQL indexes bound changed-family lookups; unchanged originals are
not read or rewritten. History holds sparse object patches, not board copies.

Thrown saves use a fresh read of all affected physical replicas: exact before
means Retry, exact after publishes once, mixed/unreadable remains held. There
is no automatic overwrite/discard of a held draft. A normal failed edit stays
visible through `open`/`pendingEdits`, while `library` describes durable data.

This API never accesses old `Canvas*` rows and is not yet wired into the old
Canvas page, shared search, Recently Deleted UI, quit route, or pasteboard.
Those callers must adopt the API, including the unsettled-edit guard, during
the later UI/switch-over work. Undo survives session switches, not app relaunch.
