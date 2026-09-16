# Task panel V2 — batch 2 independent review (SWE-B)

**Verdict: approved with one contract decision pending (F1) and minor fixes recommended.** The
R2 unified family panel and R3 general attachments are implemented coherently: one panel
identity per family, deliberate-only view switching with correct view retention, shared sizing
rules, correct owner resolution, atomic import with rollback, duplicate-safe replica writes, and
unchanged stored-data keys. No P1 and no batch-2 regression found in source. Build, focused, and
full-suite claims verified against logs. Live UI behavior remains unverified by design.

**Evidence base:** `.build/batch2.diff` (15 files, prefix tree `11866767`), full source read of
`SubtaskPanelController.swift`, `SubtaskPanelContent.swift`, `TaskImageAttachments.swift`,
`SubtaskPanelLayout.swift`, `TaskStore.swift` (attachment paths), `TaskItem.swift`,
`TaskImageReference.swift`, `TaskDragPayload.swift`, `TaskRowView.swift`, `TaskFamilyView.swift`,
`PanelSurfaceHostingView.swift`, `PanelUIState.swift`, `AttachmentFileStore.swift`,
`NoteAttachmentPlatformSupport.swift`, plus callers and the new tests. Logs:
`build-local-3.log` BUILD SUCCEEDED; `unit-tests-1.log` 711 tests / 3 skipped / 0 failures;
`unit-focused-2.log` 108 tests / 0 failures; `uitest-compile-1.log` TEST BUILD SUCCEEDED.
These match the Opus/ledger numbers.

## Findings

### F1 — Decision required: hover replaces a latched (not-yet-dragged) transient and downgrades it to hover origin

**Severity:** P2 contract question; inherited batch-1 semantics, not a batch-2 regression.
**Location:** `Attic/Services/SubtaskPanelLayout.swift:426-451` (`noteRowHover`),
`SubtaskPanelLayout.swift:478-488` (`maturePendingOpen`), fast dwell at
`SubtaskPanelLayout.swift:26`; replacement presentation at
`Attic/Window/SubtaskPanelController.swift:294-306`, `:871-892`.

**Causal path:** click family A's row → `openTransient(A, latched: true)` sets
`transientOrigin = .explicit` → outside-click monitoring arms (`updateOutsideClickMonitoring`,
controller:1030-1047). Now rest the pointer on family B's row for 75 ms:
`noteRowHover` guards only `!isTransientDetached` (line 428) — `isTransientLatched` is not
checked — so `pendingOpen(B)` arms at `familySwitchDwell`. `maturePendingOpen` then sets
`transientFamilyID = B`, **`transientOrigin = .hover`**, `isTransientDetached = false`. The same
window is reconfigured for B in `presentTransient`, `syncState` → `panelViews.retain` drops A's
view state, and B's surface is hover-origin: leaving B's row auto-hides it. Net effect: a
deliberately latched panel for A is destroyed by pure pointer movement with no click, and the
replacement surface is weaker (auto-hide) than the one it replaced.

Related anchor-bound behavior: a latched-but-anchored transient also closes when its row scrolls
out of the list viewport (`updateTaskRowFrames`/`updateTaskListViewport`,
controller:204-222 → `closeTransientSurface`). Only *detached* transients are fully protected —
the `!isTransientDetached` guard, the detached `transientCoverage` (controller:639-641 drops the
corridor), and `resizeDetachedSurface` make a dragged panel hover-immune, anchor-independent, and
outside-click-dismissed. So "moved/latched stays until outside click" holds only after a drag.

**Contract:** R2's "Preserve deliberately latched/dragged panel staying open until outside
click" reads ambiguous between latched-anywhere and latched-after-detach. The ledger records the
browsing interpretation; the batch-2 tests pin down hover-origin switching
(`testFamilySwitchUsesFastDwellWhileASurfaceIsOpen`, `testBrowsingToAnotherFamilyOpensItOnSubtasks`)
but nothing exercises the latched-transient replacement path — it is uncontracted.
**Narrow fix (if the contract forbids it):** gate the pending-open arm in `noteRowHover` on
`transientOrigin == .hover` (or `!isTransientLatched`), so a latched anchored panel ignores
hovered family switches; add a controller test. Lifecycle work belongs to the deferred batches
per the ledger — flagging for the orchestrator's ruling, not as a batch-2 blocker.

### F2 — Stale `frameAnimationTargets` entry can misplace a recreated surface

**Severity:** P3 (low probability, bounded blast radius).
**Location:** `Attic/Window/SubtaskPanelController.swift:953-962`, `:966-1008`; close paths
`:716` (`closePinned` → `window.close()`), `:780-782` (`orderOut`).

**Causal path:** entries keyed by `ObjectIdentifier` are cleared only by the animation
completion handler or `stopFrameAnimation`. If a pinned window is closed mid-animation, its
`weak surface` in the completion handler is nil → the entry persists under a dead identifier.
AppKit can hand the freed address to a new `PanelSurfaceWindow`; then `resizeDetachedSurface`
computes `current` from the stale target rect, `pinnedResizedFrame` returns a frame at the dead
window's position, and `applyFrame` (top/width changed) snaps the *new* surface to the old
window's location. Transient surfaces reuse one window so only pinned recreation is exposed.
**Narrow fix:** clear `frameAnimationTargets[ObjectIdentifier(window)]` in `windowWillClose` /
`closePinned` / the `orderOut` path, or hold the animation target on the window itself.

### F3 — "Add attachment…" silently no-ops while another attachment UI is presented

**Severity:** P3.
**Location:** `Attic/Views/Panel/TaskImageAttachments.swift:56-59` (`TaskAttachmentPicker.choose`
guard), callers `SubtaskPanelContent.swift:447-473` and `TaskRowView.swift:382-387`.

**Causal path:** `choose` requires `uiState.presentedTaskAttachmentsID == nil`. With a child's
legacy popover open (`showsChildAttachments`, `TaskRowView.swift:425-428`) or any picker up, the
panel footer's Add attachment button and the row-menu item do nothing — and neither affordance
is disabled for that state (footer disables on `parent == nil || isImportingAttachments`;
row menu disables on import-in-flight/unresolvable owner).
**Narrow fix:** disable the affordances while `presentedTaskAttachmentsID != nil`, or let the
second `choose` take over the mark.

### F4 — "Open" exposes the mutable private copy to external editors

**Severity:** P3 fix priority, real user-facing footgun; matches the established Notes model.
**Location:** `Attic/Views/Panel/TaskImageAttachments.swift:94-99` (`TaskAttachmentActions.open`),
`Attic/Services/AttachmentFileStore.swift:260-271` (`verifiedMaterializedURL` returns the private
URL), same semantics at `Attic/Services/NoteAttachmentPlatformSupport.swift:17-28`.

**Causal path:** context-menu "Open" → `NSWorkspace.shared.open(url)` hands the verified private
file to the default app, writable. If the user edits and saves (a .txt in TextEdit, an image in
Preview markup), bytes change → digest mismatch → every subsequent access fails verification →
"… is missing or changed in Attic's private storage," with no in-app recovery. The doc comment
says "Callers never write to it," but the OS does not enforce that. Note attachments inherited
this exposure; general file attachments make editing far more likely.
**Narrow fix (contract choice):** open an exported temp copy (the `exportCopy` pattern already
exists at `NoteAttachmentPlatformSupport.swift:88-105`), or if in-place editing is intended,
re-derive the digest on read instead of refusing. Escalate as a product decision either way.

### F5 — First-fit uses estimated chrome heights; attachments-only opens may never re-fit

**Severity:** P3 cosmetic.
**Location:** `Attic/Views/Panel/SubtaskPanelContent.swift:354-359` (estimates), preference
measurement `:148-151`, `:498-502`; fitting at `SubtaskPanelController.swift:885-890`,
`:1010-1017`.

**Causal path:** `fittingSize` for a first presentation reads `headerHeight`/`footerHeight`
estimates (`contentTopPadding + 48` / 32) because `SubtaskChromeHeightKey` preferences publish
after the initial layout. For subtasks-with-children, `noteMeasuredListHeight`
(controller:760-769) triggers the correcting re-fit. For attachments-first opens
(`openFamilyPanel(view: .attachments)`, Add-attachment completion) or childless families there
is no equivalent trigger, so the window can sit ~6 pt taller than ideal until an unrelated
re-fit (store revision, corner change, entry toggle). Footer stays bottom-anchored, so the
artifact is only extra space in the scroll region.
**Narrow fix:** re-fit once when measured header/footer first land (e.g., `onChange` of the
measured values → controller refresh), or take a second `fittingSize` after the first real
layout pass.

## Lower-risk observations (not defects)

- `TaskRowView.swift:183`, `:486` — VoiceOver row action and help say "Show subtasks" for
  attachment-only families too; the panel then opens on "No subtasks yet". Consider
  family-neutral wording.
- `SubtaskPanelContent.swift:265-276` — header subtitle always describes subtask progress
  ("No subtasks yet" / "N of M complete") regardless of the active view; slightly confusing on
  the Attachments view of a childless family.
- `TaskImageAttachments.swift:175` — the VoiceOver "Open" action is unconditional and silently
  no-ops for non-openable types, while the context menu correctly disables it
  (`:282-283`). Gate the action on `canOpen`.
- `AttachmentFileStore.swift:415` — `importOne` re-reads the whole file into `payload` after the
  streaming digest pass; task attachments only use the payload for image validation, so each
  non-image file pays a discarded full read (≤15 MiB). Bounded, minor.
- `SubtaskPanelController.swift:1059-1066` — the shared Quick Look panel is neither
  popUpMenu/statusBar level nor a sheet of the surface, so clicking an open preview dismisses a
  latched family panel (preview itself survives). Consistent with outside-click semantics;
  noting for live UAT.
- Attachment-only families are not hover-openable (`TaskFamilyView.swift:26-30`,
  controller `hoverWorthy` :365-369) — deliberate, ledgered interpretation; explicit opens work.
- No reconciler exists for the `Attic/TaskImages` tree (notes have `reconcileFileStorage`);
  orphan files from failed async removes accumulate. Pre-existing gap, unchanged here.
- AtticMobile compiles `TaskStore.swift` without `TaskImageReference.swift` /
  `AttachmentFileStore.swift` / `TaskDragPayload.swift`; the dependency predates batch 2 and
  iPhone is deferred — flagging as an existing integration gap, not a batch-2 regression.

## Verified against requirements

- **Unified identity/lifecycle:** one transient + one pinned window per family; `openFamilyPanel`
  raises a pinned window instead of duplicating (controller:499-503); `FamilyPanelViewState`
  stores non-default views only and `retain` drops them when the family is no longer presented
  (controller:783-787, :1135-1151) — fresh opens start on Subtasks, explicit `view:` is honored,
  `focusEntry` forces Subtasks (controller:496-536).
- **Deliberate-only switching:** the switch sits beside the composer, shows the destination
  icon/label (`SubtaskPanelContent.swift:478-496`, `SubtaskPanelLayout.swift:358-367`); hover,
  row movement, main-panel movement, re-click, and detach never call `showPanelView` — covered
  by `testFreshOpenStartsOnSubtasksAndMovementKeepsTheChosenView`,
  `testPinUnpinAndPinnedRevealKeepTheSamePanelView`,
  `testExplicitViewRequestsAndSubtaskEntryChooseTheirView`,
  `testBrowsingToAnotherFamilyOpensItOnSubtasks`.
- **Sizing/animation:** one `contentHeight` rule for both views (`SubtaskPanelLayout.swift:
  167-177`) — natural height up to 240, then scroll; gallery height is deterministic arithmetic
  matching the fixed 100-pt cards (`:159-163`, `TaskImageAttachments.swift:198-214`); two columns
  keep one image from dominating; height-only re-fit animates holding top+width while moves and
  clamps snap (`applyFrame` :971-999); Reduce Motion snaps frames and fades the view
  transition (`:550-552`, `SubtaskPanelContent.swift:385-393`).
- **Hit testing/geometry:** one squircle predicate shared by `PanelSurfaceHostingView.hitTest`,
  `surfaceContains`, and `pointerCoverage`; header drags exclude measured controls
  (`PanelSurfaceDragGeometry.allowsWindowDrag`); transient placement flips/clamps/avoids pinned
  surfaces; detached transients resize via `pinnedResizedFrame`.
- **R3 attachments:** `attachmentOwnerID` resolves children to parents; one multi-select picker
  accepting any regular file; `importOne` starts the security scope before touching attributes,
  streams+hashes into staging, and rolls the whole batch back on failure; `attachFiles` writes
  every replica and removes imported copies on save failure; `removeAttachment`/`delete`/
  `purgeCompleted` clean files after successful saves; digest is verified on every materialized
  access; Codable keys unchanged (verified in the batch-2 diff — earlier stored data still
  decodes); legacy child attachments stay in `TaskAttachmentsPopover`; drag-out copies only on
  accepted drop; thumbnails are bounded (64-entry cache, ≤512 px, images only).
- **Keyboard/accessibility:** cards are FKA-focusable with Space/Return preview and Delete
  removal, labeled with filename/type/size plus VO actions; the × is pointer-only by design;
  the switch, pin/unpin/close, and composer are labeled; progress stays passive (not a button).
- **Stale confirmation test:** `AtticUITests.swift:539-571` now asserts the alert and exercises
  both branches — Cancel leaves the parent in To do with child state unchanged; "Complete
  anyway" moves the parent to Done while the unfinished child stays unfinished. Both paths have
  real assertions, not just traversal.

## Caveats / unverified

- No live evidence exists. View-switch feel, height-animation smoothness, gallery scrolling,
  hover-remove, drag-out to real destinations, FKA/VoiceOver traversal inside the panel,
  Quick Look interplay, and corner-size live changes are compile+unit verified only.
- F1 is the only item that changes user-visible semantics if the orchestrator rules against
  inherited browsing behavior; everything else is P3 or below.
