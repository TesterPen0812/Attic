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
11/14/20 pt text; corners are Square/Rounded. A text box's optional `textWidth`
is its wrap width (set by its side handles); without one the box grows to its
longest line.

`library(deleted:)` lists metadata newest first. `search` combines `#tags` with
name/text terms and returns matching text box IDs for reveal. Tags use Attic's
shared normalizer (lowercase, hyphen separators, 64-character maximum) for both
commands and queries. `duplicate` gives
objects fresh IDs. New and empty duplicates stay drafts until first content.
`deleteCanvas`/`restoreCanvas` manage deleted canvases; `deletedImages(in:)` and
`restoreObjects` expose individually deleted images for Recently Deleted.
`deletedImages()` lists every image deleted from a live canvas, library-wide,
from metadata only (no originals, thumbnails or board state).
`purge(_:)` removes deleted canvases and images for good (Delete Permanently,
Empty) and `purge(deletedBefore:)` is the 30-day removal; each target names the
deletion time it was listed with, every physical replica of it goes, and a
target whose replicas disagree (or whose canvas has an unsettled edit) is kept
and counted in the report. There is no Clear command.

`.thumbnail(data)` is a quiet write: no Undo step, no new `updatedAt`, no new
place in the library, and it doesn't count as an edit. History steps carry the
latest thumbnail, so Undo never brings back an older one. The page renders it
off the main thread once edits settle and when a canvas closes or switches;
nil (nothing drawn) keeps the library's empty card.

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
as Image (PNG at 2×, plus the original data for one image) and Export… (PNG
at 2×, vector PDF with full-resolution images) render on the page side
(`DrawExport`, `DrawImageActions`), off the main thread.

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

This API never accesses old `Canvas*` rows. `AtticDraw.isEnabled` (on unless
`AtticDraw.enabled` is false in defaults, read at launch) makes Draw the Canvas
page; the app then marks its container with `AtticLegacyCanvas.markDormant`,
and every old-Canvas reader (the Canvas store, Search's library, Recently
Deleted, tags, the replica fetch funnel) leaves the old rows unread and
unchanged. The quit route calls `DrawPageModel.prepareToQuit()`, which settles
the stroke in progress, retries or reconciles unsettled edits and returns false
while one is held. Undo survives session switches, not app relaunch.
