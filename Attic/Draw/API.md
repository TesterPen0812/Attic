# Draw data API

All calls are on the main actor. Keep one `DrawStoreProtocol` instance alive above
page, canvas and panel switches; it owns per-canvas session Undo/Redo. The store
has no selection, tool or viewport state. Geometry is in points.
Call `activate(_:)` when the page opens a canvas. The active canvas, unsaved
drafts and unsettled edits remain cached; inactive persisted canvases may be
reloaded after the eight-state cache limit. Body eviction discards the canvas's
entire session Undo/Redo history and expires dependent offers; reopening starts
fresh history. Each resident canvas keeps at most 100 combined Undo and Redo
steps, expiring offers before removing the oldest whole prefix. Pending edits
are never evicted.

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
longest line. Its optional `textScale` (set when a group is resized) draws the
style's size that much larger or smaller: the lines are laid out at the
style's size and wrap width ÷ scale, then scaled, so they never reflow.

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
target whose replicas disagree (canvas, object or payload rows: parent,
digest and bytes) or whose canvas has an unsettled edit is kept and counted
in the report. There is no Clear command.

`.thumbnail(data, dark:)` is a quiet write: no Undo step, no new `updatedAt`, no new
place in the library, and it doesn't count as an edit. It records the
appearance it was rendered for in the optional `DrawCanvas.thumbnailDark`
(nil without a thumbnail, or for one written before it was kept); the same
bytes for the other appearance still write. History steps carry the latest
thumbnail and its appearance, so Undo never brings back an older one. The page
renders it off the main thread once edits settle and when a canvas closes or
switches; nil (nothing drawn) keeps the library's empty card. When the
appearance no longer matches, the page renders it again: the open canvas
through the same settle path after an appearance change, and any other canvas
only when its thumbnail is about to show (`DrawLibraryActions.thumbnailsShown`,
which the menu's and Search's rows call once they appear). Requests are
queued for the next turn of the main loop and coalesced per canvas; the old
thumbnail shows until the new one lands.

Observe `revision`, `lastDelta`, `pendingEdits` and `hasUnsettledEdits` on the
concrete observable store. Live ink and typing remain provisional until their
bounded input buffer reaches a complete recovery checkpoint or a proven database
commit. Successful saves publish a delta and advance history once. One failed
write freezes mutation admission across Draw; new attempts are refused without
writing, accumulating history, or retrying implicitly. View, switch, select,
pan, zoom, copy and export remain available. Already admitted input and imports
retain their finite buffers and original canvas identity. Retry reconciles the
same operation: proven after-state settles once, proven before-state may retry
with the same identities, and mixed/unreadable evidence stays held. Quit refuses
every unresolved operation and memory-only buffer. `reload` reads fresh durable
values after an external import, withdraws its old session offers, and refuses
to replace an unsettled draft.

Use `copy` to encode `DrawStore.clipboardType` (`com.taha.attic.draw-objects.v1`)
into the pasteboard. After successfully writing the pasteboard, call `cut` to
remove the same IDs. `paste` validates the version, assigns fresh IDs, offsets
geometry, and places the objects above existing objects as one Undo step. Copy
as Image (PNG at 2× on the board colour; for one image, a single pasteboard
item with the original bytes in their own type, plus a PNG of the image when
the original isn't one) and Export… (PNG
at 2×, vector PDF with full-resolution images) render on the page side
(`DrawExport`, `DrawImageActions`), off the main thread. Export… and Save
Image write the whole file to a staging folder, swap it in atomically, and only
then move the old file to the Trash; a failure leaves the old file as it was and
shows in `saveNotice` (without Retry). An image drop or paste lands on the
canvas it was made on, even after a switch (`DrawPageModel.perform(_:on:)`).
An import keeps successfully saved peers and names failed inputs in the existing
notice; its success sound requires a confirmed save. An asynchronous image copy
writes only while its original pasteboard change count and copy generation still
match, so a later Copy, Cut or external clipboard change wins.

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
For disk-backed stores, a recovery file beside the SwiftData store holds one
pending operation and its complete physical before/after proof. A healthy save
performs one combined checkpoint replacement, one database save, and one
checkpoint retirement. A committed write with failed retirement remains fenced
for cleanup-only Retry; the operation is never re-applied. If the checkpoint
cannot be written, its unsaved head stays owned in memory and Quit refuses.
On relaunch a full canvas load must succeed before a pending sparse change is
projected; load failure stays visible and retryable, never a fabricated empty
or incomplete canvas. An unreadable checkpoint is preserved and blocks edits,
purge, and Quit until it can be re-read. Existing v1 recovery tails remain
readable and drain their individual actions in order, advancing durably after
each head; normal operation no longer appends tails. Session Undo is not
persisted across launches. In-memory stores have no recovery sidecar.

This API never accesses old `Canvas*` rows. `AtticDraw.isEnabled` (on unless
`AtticDraw.enabled` is false in defaults, read at launch) makes Draw the Canvas
page; the app then marks its container with `AtticLegacyCanvas.markDormant`,
and every old-Canvas reader (the Canvas store, Search's library, Recently
Deleted, tags, workspace tokens and inventory, links and titles, all through
the counted `fetchCanvasReplicas` funnel) leaves the old rows unread and
unchanged. The quit route closes Draw admission before waiting on other page
providers, drains already admitted strokes, typing and image imports, and
performs a final owner check. It refuses while any operation, memory-only input,
unknown recovery ownership, import or thumbnail render remains, and reopens
admission when refused. Undo survives canvas switches while its body remains
resident, but not body eviction or relaunch.

Agent Draw snapshots, token checks and Draw Undo guards first settle queued input
on pages using that exact store (acknowledged commands and typing). An active
pointer gesture continues until its normal end; the editor stays open with its
latest text. A failed flush remains an unsettled
store edit and prevents an agent mutation, including creation of a new canvas.
Agent `draw_list_canvases` returns `draw_mutations_paused`; `draw_read_canvas`
returns that status and `canvas_save_unsettled` so provisional snapshots cannot
be mistaken for durably committed ones. Agent resize accepts a zero extent only
on an already flat line/arrow axis while resizing its nonzero dimension; pointer
resize retains its existing 4 pt minimum. Raster image decoding bounds its
requested pixel size before integer arithmetic, without rewriting stored frames.


The page can receive identity-scoped `resumeDefaults`; without them it is fully
session-only. With them it resumes the last canvas, each canvas's validated
viewport, and pending thumbnail IDs. A render unfinished at quit is regenerated
when its canvas is opened or its thumbnail is shown on a later launch; the marker
clears only after a successful quiet thumbnail write. Gesture changes update
memory immediately and coalesce preference writes; canvas switches and quitting
flush the latest viewport. New unnamed
canvases use the next free `Untitled` suffix across saved canvases and drafts.

The title capsule becomes the canvas filter; the menu has no duplicate search
row. Tab/Shift-Tab and arrows visit individual objects in top-to-bottom rows
(centres within 30 pt), left-to-right within each row. Tab past either end leaves
the board through the native key-view loop. VoiceOver receives stable, named
object elements whose frames follow the viewport; selecting one reveals it at
the current zoom. Navigation changes no drawing data or undo history.
