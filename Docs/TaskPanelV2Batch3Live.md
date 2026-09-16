# Task Panel V2 — Batch 3 live validation

## Frozen preview provenance

- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Frozen dirty-status SHA-256: `9a14c52800d4a4f238e84e73942fe48adffd84172f6bfe70ba6335f6cd1e27ca`
- `.build/batch3.diff` SHA-256: `dfc2d67772e155640a3f966094c076c5274a5ec8dceb75acb5ae236cdfafd51a`
- `.build/batch3-fixes.diff` SHA-256: `f1d03cece3ebe2b1db0989ff13125ecde48f2e8524121d9ba07a76c5ad2ba8b2`
- Preview executable SHA-256: `01c2fa67de91373cb5416d9b73fd22d749341df2c3596e4c476951132d0f32e6`
- Display name: `Attic Task Panels V2`
- Bundle identifier: `com.taha.Attic.taskpanels.v2`
- Executable: `AtticTaskPanelsV2`
- Preview root: `.build/TaskPanelsV2Preview`

The preview was rebuilt from the frozen Batch 3 tree with
`Scripts/launch_local_preview.zsh`. The emitted entitlements contain the sandbox,
user-selected file access, get-task-allow and local network entries only; they contain no
CloudKit, ubiquity or APNs entitlement. Build and identity evidence is in
`.build/batch3-live/launch.log`; the frozen status is in
`.build/batch3-live/source-status.txt`.

## Actionable defect

### P1 — Composer attachment picker is absent from the rendered entry bar

The paperclip required by R5 is not rendered in the 332 pt main panel and is absent from the
accessibility hierarchy. This was checked both with an empty title and with
`Batch 3 composer attachment fixture` entered. In each state the rendered bar contained the
leading Task options control, the title field and the trailing submit control only. Moving the
pointer away from the trailing controls confirmed that a cursor glyph had initially resembled a
paperclip in one capture; no attachment control remained beneath it.

The hierarchy likewise exposed `add-task-button`, `quick-entry-title` and
`quick-entry-submit`, but no `quick-entry-attach`. Consequently the picker, pending cards,
upward composer expansion, pending removal/cancel and submit-with-attachments flow are not
reachable through the specified main-composer control in this preview.

## Verified live behavior

A dedicated preview-only task, `Batch 3 attachment drop target`, was created. Its empty family
surface switched between Subtasks and Attachments without losing the family.

The subpanel `Add attachment` picker selected the isolated 1.6 MB
`.build/batch3-live/fixtures/batch3-image.png`. On successful import:

- the open family remained on Attachments;
- the empty state was replaced by one compact image card named `batch3-image.png`;
- accessibility reported `batch3-image.png, image, 1.6 MB` with `Remove` and `Open` actions;
- dismissing the family returned to the main list with passive `1 attachment` metadata on the
  dedicated task row.

This confirms the common picker/import persistence and gallery reveal path on the frozen build.
The original fixture remained untouched. The dedicated task and imported private copy remain in
the isolated preview store.

## Drag/drop attempts and limits

An isolated Finder window contained a normal 42-byte text file and a PNG. Native CUA drag
attempts were aimed at the measured on-screen task row and at the whole open family surface while
Subtasks was visible. Neither attempt delivered a Finder drag session to the destination; no
overlay appeared and no attachment count changed. The same CUA drag primitive also did not start
an observable gallery-card drag across Attic windows. These are recorded as automation/input
limitations rather than product failures: no successful drag session reached an Attic target.

Therefore the following remain unverified live:

- restrained row/panel drop overlay and animated drop-success reveal;
- child-row forwarding to its parent;
- own-card refusal and card copy to another task or composer;
- task reorder and attachment drag-out preservation;
- Finder promised files, Mail promises, failure recovery, size/count limits and busy-owner
  refusal;
- physical mouse/trackpad drag disambiguation and scrolling during drag.

No XCTest retry was made because the host runner had repeatedly stalled before test execution in
the preceding focused passes. No production or test source was edited and no store was reset.
The family surface was closed, the main panel restored to unpinned state, the temporary Finder
window closed, fixtures retained, and the exclusive UI lock released after validation.

