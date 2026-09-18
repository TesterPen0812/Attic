# Task panel V2 — user contract, September 13

Preserve the approved dark Attic visual language, current proportions, main-panel motion,
macOS local-only contract, durable local data and performance-conscious architecture.
Reference images: TaskPanelV2References/subtasks.png and gallery.png. Written behavior
below takes priority over incidental elements/text in the reference images.

## R1 Main rows
- Subtle continuous-corner/superellipse row hover; Liquid Glass top controls.
- Single-line titles, stable row height, soft trailing fade for overflow. Full title
  accessible through hover/focus and editing. Tight title-to-metadata spacing.
- Attachment previews/counts and subtask progress (e.g. 2/11) are passive metadata,
  without button appearance/behavior. The task row opens its task subpanel.
- Ellipsis hidden normally, shown on row hover or keyboard focus together with hover
  surface. Always reserve its space so nothing jumps. Tasks draggable/reorderable
  everywhere, including child rows. One-level subtasks only.
- Tiny muted pinned status near title: tooltip Panel pinned; activating it reveals
  existing pinned family. Pin/unpin control belongs to subpanel, not this metadata.

## R2 Unified family panel
- One movable subpanel per parent task, can pin, retaining task identity and moved
  position. Opening always begins on Subtasks. No duplicate panel for that family.
- Exactly two main views: Subtasks and Attachments/Gallery. Switch deliberately inside
  panel, beside bottom composer; switch icon depicts DESTINATION view.
- Subtasks composer Add subtask…; Attachments composer Add attachment….
- Short smooth slide/crossfade, panel stays anchored while content transitions;
  animate height to content. Both views share sizing: minimal required height,
  grows with content to EXISTING subtask max then content scrolls. Long list -> small
  gallery shrinks; converse expands. One image must not dominate panel.
- Neutral row hover never unexpectedly switches panel content. Explicit re-opening
  starts on Subtasks; movement/hover of an already-open panel must not reset its view.
- Preserve deliberately latched/dragged panel staying open until outside click;
  the user's older idle auto-hide complaint was MAIN panel only.

## R3 Attachments
- Parent owns images AND normal files together. One Add attachment picker accepts both.
- Compact image thumbnails and file cards, quiet actions. Hover may show small remove ×;
  clicking opens/previews, keyboard equivalents remain accessible.
- Images/files draggable everywhere they appear. Durable private storage, scoped
  security access, rollback on save failure, duplicate-safe UUID semantics. Existing
  image attachments remain compatible. No image data duplication on drag/resize.

## R4 Drop interactions
- Drop images/files onto any task row or anywhere on open parent subpanel, EVEN while
  Subtasks showing. Resolve child-row attachments to parent; no nested children.
- Restrained overlay Drop to attach to <task>, existing content visible underneath.
- Successful drop attaches to parent, smoothly switches to Attachments, animates new
  cards into gallery. Failure leaves clear calm recovery and no false success.
- Preserve task drag/reorder and scrolling; distinguish internal task drags, attachment
  file drags, trackpad scrolling and dismissal gestures.

## R5 Main composer
- Attach images/files while creating task by picker AND drop into composer.
- Pending items visible before submission; composer grows UPWARD within existing shell.
- Submit binds items to new parent atomically/durably. Failures preserve draft/items;
  cancellation cleans only owned temporary staging, never originals/user data.

## R6 Pointer travel / pinning
- Newly opened transient must not vanish before cursor reaches it when pinned family
  nearby. Safe corridor from source row to actual positioned transient, generous enough
  for normal travel. Crossing pinned Attic panels doesn't dismiss transient; entering
  transient cancels pending dismissal immediately. Dismiss only clearly away from
  both source and destination. Avoid transient/pinned overlap where screen allows.
- Pinned stays same task and moved position; reveal brings existing panel front.

## R7 Trackpad dismissal
- Unpinned subpanel: direct two-finger dismiss follows movement, subtle inward scale
  plus opacity, velocity-aware completion threshold; cancel smoothly restores.
- Pinned ignores dismissal. Vertical/normal content scrolling never dismisses.
- Reduce Motion uses fade/reduced transform. Main accepted animation unchanged.

## R8 Surface vs controls
- Panel translucency changes PANEL SURFACE only: off solid, on translucent.
- Interactive pin, complete, composer, view switch and equivalent controls remain
  Liquid Glass in both modes. Preserve heavier pinned glass appearance.
- Settings copy: Changes the panel surface. Controls always use Liquid Glass.

## Batches and ownership
Orchestrator manages scope/status and acceptance. Opus 5 is sole production implementer.
Two SWE-2 reviewers independently review each completed batch, covering requirements,
code quality, correctness, performance and regressions; fixes feed back to Opus.
Do not use Sol medium for interim reviews. Reserve Astra high for a final overall review
after all batches, followed by fixes and verification of any findings.
Use targeted live UI verification with one exclusive UI owner at a time.
Minimize Codex usage, redundant polling, duplicate audits and repeated broad test runs.
No feature is complete from agent self-report alone; cite source diff, test results,
preview identity and live evidence separately. Do not merge/push/release/reset user data.

1. R1 + R8 row/control foundation. Preserve existing attachment actions via menu until
   gallery replacement; do not silently remove existing capability.
2. R2 + R3 unified panel, general files and adaptive sizing.
3. R4 + R5 drag/drop and pending composer attachments.
4. R6 + R7 corridor, pin lifecycle, trackpad dismissal.
5. Integrated review, fixes, targeted tests, local-only preview, live UAT and resources.

For every batch record exact changed files/diff, checks, review findings/fixes, and
unverified behavior in TaskPanelV2Ledger.md. Keep all remaining batches on the ledger.
