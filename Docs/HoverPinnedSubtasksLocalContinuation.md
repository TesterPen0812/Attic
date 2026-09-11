# Hover + pinned subtasks: local continuation checkpoint

Durable handoff between the interrupted cloud sessions and the local
implementer/reviewer pair. Update this file whenever the checkpoint moves.

## Coordination handshake (authoritative)

- **Phase:** `LOCAL_FIXES_IN_PROGRESS` — implementer holds all
  source/test/project write ownership; reviewer is read-only and owns ONLY
  `.build/LocalAdversarialReview.md` (never edit that file from here).
- **Reviewer input:** baseline review of immutable
  `7535d0028b50c03fcd4532122ec078d5c8c35cb2` (not the working tree).
- **Candidate SHA ready for review:** none yet — the F1–F4 fixes below are
  uncommitted. After local build/test checks they will be committed and the
  full SHA recorded here as `READY_FOR_REVIEW: <sha>`.
- **Report SHA consumed:** none yet — `.build/LocalAdversarialReview.md`
  baseline not yet published at this checkpoint's writing.
- **Unresolved finding IDs:** F1, F2, F3, F4 (implementer pass-2 findings,
  fixes in tree, tests added, build/test verification pending). Reviewer
  baseline IDs TBD — must be read and addressed even where they overlap.
- **Waking the reviewer:** this session CANNOT message the reviewer
  directly; marking READY_FOR_REVIEW here is necessary but NOT sufficient —
  a coordinating message to the reviewer session is required to trigger its
  follow-up pass. Do not claim completion until the reviewer's report
  names the same candidate SHA.

## Provenance

- Writable checkout: `/Users/taha/Developer/attic-hover-pinned-subtasks`
  (linked worktree of `/Users/taha/Developer/attic-recovery-20260907`;
  do not confuse with the read-only user checkout
  `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic`).
- Branch: `codex/attic-hover-pinned-subtasks`, remote
  `https://github.com/TesterPen0812/Attic.git` (fetch refspec is narrow —
  `git fetch origin codex/attic-hover-pinned-subtasks` lands in FETCH_HEAD,
  there is no `origin/codex/attic-hover-pinned-subtasks` tracking ref).
- Recovered 2026-09-11: local HEAD was `c59e4e5` (clean tree), fetched and
  fast-forwarded to the cloud implementer's push:
  `7535d0028b50c03fcd4532122ec078d5c8c35cb2` "Address adversarial-review
  findings 1-14" (+377/-59, 6 files). No uncommitted work was found or lost.
- Cloud implementer session 54864f9d: wrote 23ede87 → c59e4e5 → 7535d00.
- Cloud reviewer session dbe59721 (read-only): round-1 report found 14
  findings (all addressed by 7535d00); round-2 pass over 7535d00 was cut off
  by quota with NO final verdict. Its unfinished candidate list is carried
  forward below.

## Review round 2 (local pass over 7535d00) — findings

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| F1 | P2 | `releaseFamilyInteractionState` matches `id == familyID` — the parent's own rename (`editingTaskID`) and delete confirmation (`confirmingTaskDeletionID`) are hosted by the MAIN-list row (main list filters `parent(of:) == nil`; the surface renders only child `TaskRowView`s and a display-only title). Surface teardown (`closePinned`, `windowWillClose`, `unpinPinned` without re-anchor, `closeTransientSurface` via Escape/scroll-out/`mainPanelDidHide`) discards a live parent rename or silently dismisses its alert. Release must be child-keyed (`parentID == familyID`) only. | Fix implemented locally |
| F2 | P3 | Dying-host focus race: on pin/unpin the old host's `isEntryFocused → false` `.onChange` can nil `focusedSubtaskParentID` AFTER the controller's `focusSubtaskEntry` re-bump (AppKit field-editor resignation is not synchronous with `orderOut`), leaving the new surface's entry unfocused. Fix: the resign path only clears when the view still hosts the family's live surface (`isLiveSurface(for:mode:)`). | Fix implemented locally |
| F3 | P3 | Replace-pinned refusal while the displaced family is edit-busy (`pinFamily` early return) is a silent no-op — the affordance shows no disabled state or reason. Fix: disabled + dimmed + explanatory help/accessibility hint while `pinReplacementBlocked`. | Fix implemented locally |
| F4 | P3 | `commitPendingOpen`'s anchor-nil/unworthy branch is the only transient teardown that skips `releaseFamilyInteractionState`. Reachable lock-orphan interleavings are unlikely (busy surfaces re-arm), but the asymmetry leaves a residual path. Fix: route through `closeTransientSurface()`. | Fix implemented locally |

Reviewer-remark carried without action: the panel↔surface pointer corridor
counts as "inside" for both dismissal and auto-hide (accepted trade-off,
reviewer downgraded). Discarded suspicion: stale same-family suppression on
unpin — reviewed, likely impossible.

## Verification status

- Project regeneration + `verify_project_generation.rb`: PASS on 7535d00
  (PATH=/opt/homebrew/opt/ruby/bin:… + `bundle exec ruby`).
- `xcodebuild` build + AtticTests: see ledger/checks below once run.
- Manual UX acceptance (hover dwell, corridor, pin drag, VoiceOver, …):
  NATIVE-UAT, left for the user — do NOT take over the desktop.
- Existing preview `com.taha.Attic.devin.subtasks.preview`
  (`.build/DevinPreview`) contains user data — preserve; use separate
  verification artifacts.
