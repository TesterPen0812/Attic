# Hover + pinned subtasks: local continuation checkpoint

Durable handoff between the interrupted cloud sessions and the local
implementer/reviewer pair. Update this file whenever the checkpoint moves.

## Coordination handshake (authoritative)

- **Phase:** `READY_FOR_REVIEW`
- **Candidate SHA:** `READY_FOR_REVIEW: 209a0eb20967c98770c2b7326b63e226f950cbe9`
  ("Address local adversarial-review findings F1-F5", on top of `7535d00`).
- **Report consumed:** `.build/LocalAdversarialReview.md` baseline verdict
  on `7535d00` = NOT CLEAN, findings F1–F4 — all addressed by the candidate
  (plus F5, a willSet-lag defect the first native test run exposed and the
  baseline could not see: `.subtaskComposer` previously engaged/released one
  change late). Reviewer refinement requests on F2 (same-click resign +
  stale focus pointer) are implemented.
- **Unresolved finding IDs:** none known pending re-review; reviewer's
  remarks were no-action. F2's residual decisions taken: real teardowns
  clear `focusedSubtaskParentID` (entry row + draft still survive);
  same-click resign reuse window = 0.5 s.
- **Verification at candidate SHA:** `verify_project_generation.rb` PASS;
  `xcodebuild build -scheme Attic` PASS (Local config,
  `CODE_SIGNING_ALLOWED=NO`); `xcodebuild test -only-testing:AtticTests`
  PASS — 637 tests, 0 failures, 1 skipped. AtticUITests + manual UAT remain.
- **Waking the reviewer:** this session CANNOT message the reviewer
  directly; READY_FOR_REVIEW here is necessary but NOT sufficient — a
  coordinating message to the reviewer session is required to trigger its
  follow-up pass. Do not claim completion until the reviewer's report
  names `209a0eb`.

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
