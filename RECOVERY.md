# Draw round 6 recovery log

## Scope

Repository: TesterPen0812/Attic. Write only phase-3/proimpl-draw-r6.
Base: 4ba1f012460c59f3e5cc23406ab52b2cf7a066d6.
This turn is Draw only. Composer remains at its initial log checkpoint.
No other branch writes, force pushes, pull requests, merges, builds, tests, CI dispatches, or user-store access.

## Verified prior checkpoints

- Draw initial log: b5aa93fff7288e31cf4d698d9fc27bd61f53ee57.
- Composer initial log: ed3cd1c53a73e948c7f36762860a1f2805c0d045.
- DS-6 file-backed store regression candidate: fac856c8adbd633f60447914f5acce87180180c3.
- DS-6 store correction and source extraction: 94cd1a1e1bc2963e85ed74caaeed2e0ed87b7336. Verified as the exact branch head at the beginning of this resumed turn; RECOVERY.md and AGENTS.md read at that SHA.
- This checkpoint adds DS-6 page-level regression candidates before the page fix. Resolve its SHA from this commit; the next checkpoint records it. No commit can embed its own final SHA.

## Current finding status

DS-6 remains PARTIAL. The store correction is implemented in source at 94cd1a1e, not compiled or tested: recovery requires a complete saved canvas load; an error retains the original record and blocks admission rather than installing objectsBefore as a complete body. Only an originally absent, empty, never-saved canvas may reconstruct from an absent base. Explicit store Retry reloads the complete base, then reconciles the original operation. Query metadata can expose recovery without inventing an object body.

The page still renders recoveryIssue with canRetry=false. Its retrySave() visits only pendingEdits, while complete-load failures deliberately have no pendingEdits projection. open() also forgets a failed open request. The source fix for these page boundaries has NOT been applied in this checkpoint.

DS-1 through DS-5 and DS-7 through DS-16: not implemented in this restart. Existing round-5 fixes remain to be verified. Composer CP-1 through CP-17 and carry findings: untouched.

## Files changed in this checkpoint

- AtticTests/DrawR6RecoveryRetryTests.swift (new).
- RECOVERY.md.

No production code changed and no existing test was deleted in this checkpoint.
The prior DrawStore extraction remains unchanged: DrawStore.swift, DrawStore+Recovery.swift, DrawStore+Commands.swift, DrawStore+History.swift, DrawStore+HistoryBudget.swift, DrawStore+Rename.swift, DrawStore+AgentUndo.swift and DrawStepPins.swift. Its cross-file implementation members are module-internal; no schema/storage-format change was made.

## Regression candidates

- Existing: DrawR6RecoveryLoadTests.testDS6FailedCompleteLoadNeverSubstitutesARenamesEmptyObjectPatch.
- New: DrawR6RecoveryRetryTests.testDS6PageNoticeRetriesCompleteLoadAndRestoresOriginalCanvas. Uses a real file-backed store, an unretired committed rename, store deallocation without close, a fresh container and injected full-load failures. Asserts the existing notice offers Retry, each repeated failed Retry attempts one full load without changing journal bytes, eventual Retry opens the requested complete canvas with exact image bytes, and a settled Retry does not replay/read again.
- New: DrawR6RecoveryRetryTests.testDS6RecoveryRetryKeepsAnotherCanvasOpen. Recover the failed canvas while browsing a different one; Retry must not steal the user's later navigation.

These tests were authored before the page source change. No executed red/green result exists. Nothing has been compiled, tested, launched, or measured. The owner's Mac runner must regenerate the project for the new Swift files and execute all checks.

## Exact next step

Verify this commit and phase-3/proimpl-draw-r6 head on GitHub. In DrawPageModel.swift, expose Retry for known complete-recovery-load failures; have retrySave() attempt those original records once before ordinary pending saves (exclude them from a second attempt in that press); remember a failed open target and reopen it after successful Retry only if no other canvas has since opened. Keep the existing notice mechanism and exact existing load-error message. Commit the source fix with this log and verify its SHA before starting DS-7.

Then DS-7: retryable journal reads and conservative admission. DS-8 still must fix swallowed retirement failures. This checkpoint does not claim either.

Stop immediately on any GitHub write or SHA-verification failure. GitHub, not the temporary local files or conversation, is authoritative.
