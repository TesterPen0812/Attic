# Draw round 6 recovery log

## Scope

Repository: TesterPen0812/Attic. Write only phase-3/proimpl-draw-r6.
Base: 4ba1f012460c59f3e5cc23406ab52b2cf7a066d6.
This resumed turn is Draw only; stop at the DS-6 checkpoint rather than starting another long unsaved batch. Composer remains untouched.
No other branch writes, force pushes, pull requests, merges, builds, tests, CI dispatches, or user-store access.

## Verified prior checkpoints

- Draw initial log: b5aa93fff7288e31cf4d698d9fc27bd61f53ee57.
- Composer initial log: ed3cd1c53a73e948c7f36762860a1f2805c0d045.
- DS-6 file-backed store regression candidate: fac856c8adbd633f60447914f5acce87180180c3.
- DS-6 store correction and source extraction: 94cd1a1e1bc2963e85ed74caaeed2e0ed87b7336. Verified as the exact branch head at the beginning of this resumed turn; RECOVERY.md and AGENTS.md read at that SHA.
- DS-6 page-level regression candidates: 3fbd588e9b14217654689316072cd580fe82f3be. Pushed and verified by reading the GitHub branch ref before the page source change.
- This checkpoint completes the DS-6 page source route. Resolve its own SHA from the commit containing this log; a commit cannot embed its own final SHA. The next checkpoint must record that verified SHA.

## Current finding status

DS-6: implemented in source, with store and page regression candidates. NOT compiled or tested. The store correction at 94cd1a1e requires a complete saved canvas load; a read error retains the original record and blocks admission rather than installing objectsBefore as a complete body. Only an originally absent, empty, never-saved canvas may reconstruct from an absent base. Explicit store Retry reloads the complete base, then reconciles the original operation. Query metadata can expose recovery without inventing an object body.

This checkpoint finishes the missing page boundary: the existing save notice offers Retry for known complete-load failures. retrySave() explicitly retries their original records even though they have no pendingEdits object projection. A record attempted through that route is excluded from the ordinary pending loop for the same button press, avoiding a second write attempt. open() remembers a failed open request; after a successful recovery Retry it reopens that target only when there is still no current canvas. A later successful open supersedes the earlier navigation, so recovery cannot steal another canvas the user is browsing. No new notice view, timer, persistence format, or SwiftData schema was added.

The DS-6 load-error text remains exactly:
"Could not load this drawing. Its recovery data has been preserved. Retry to load it."
The existing notice mechanism supplies its Retry action.

DS-1: not started in this restart; durable acknowledgement/memory-only wording remains to implement.
DS-2: not started; store-wide refusal after failure and ownership of pre-admitted finite input/imports remain.
DS-3: not started; ordering all mutation routes after earlier page input remains.
DS-4: not started; round-5 projection changes need the requested verification and redesign integration.
DS-5: not started; refused-versus-pending operation identity/rename/delete handling remains.
DS-7: not started; journal read retry and conservative admission remain. This checkpoint enables only complete-canvas-load Retry, not unreadable-journal Retry.
DS-8: not started; swallowed final retirement errors still need a cleanup fence.
DS-9: not started; quit admission and final readiness check remain.
DS-10: not started; strict cap and offer expiration remain.
DS-11: not started; remove the cold-history byte ledger with DS-12 and document resident worst-case retention.
DS-12: not started; whole-history release on body eviction remains.
DS-13: not started; grouped partial progress and ordered Retry remain.
DS-14: not started; legacy tail drain and compatibility regressions remain.
DS-15: not started; round-5 flat-line resize must be verified, not claimed fixed by this work.
DS-16: not started; combined checkpoint/write/retirement and removal of continuation costs remain.
Composer CP-1 through CP-17 and carry findings: untouched.

## Files changed in this checkpoint

- Attic/Draw/Page/DrawPageModel.swift: existing notice capability, recovery-load Retry routing, failed-open navigation identity.
- RECOVERY.md.

The immediately preceding checkpoint added AtticTests/DrawR6RecoveryRetryTests.swift.
No existing test has been deleted yet. The prior DrawStore extraction remains unchanged: DrawStore.swift, DrawStore+Recovery.swift, DrawStore+Commands.swift, DrawStore+History.swift, DrawStore+HistoryBudget.swift, DrawStore+Rename.swift, DrawStore+AgentUndo.swift and DrawStepPins.swift. Its cross-file implementation members are module-internal. The tail, pin and ledger mechanisms still exist pending their specified findings.

## Regression candidates and verification status

- DrawR6RecoveryLoadTests.testDS6FailedCompleteLoadNeverSubstitutesARenamesEmptyObjectPatch (fac856c8, before the store correction).
- DrawR6RecoveryRetryTests.testDS6PageNoticeRetriesCompleteLoadAndRestoresOriginalCanvas (3fbd588e, before the page correction). Real disk store, unretired committed rename, deallocation without close, fresh container, repeated injected complete-load failures, exactly one load attempt per failed Retry, original journal bytes retained, complete object identities and exact image bytes restored, no replay/read on a settled Retry.
- DrawR6RecoveryRetryTests.testDS6RecoveryRetryKeepsAnotherCanvasOpen (3fbd588e, before the page correction). Recovery settles without taking over a different canvas opened after the error.

No executed red/green result exists. No Swift compilation, tests, app launches, performance measurements, CI dispatches, or real-store operations were performed. The owner's Mac runner must regenerate the Xcode project for all added Swift files and run the new tests in five fresh processes plus the required suites. Source inspection and GitHub SHA/readback verification are not compilation or behavioral testing. DS-6 is source-implemented, not an independently verified fix; Draw round 6 is unfinished.

## Exact next step

Read this log and verify phase-3/proimpl-draw-r6 still points to the source checkpoint reported at the end of the resumed turn. Record its full verified SHA in the next commit. Address any compiler/test feedback from the owner's Mac first if it is provided.

Otherwise begin DS-7: inspect DrawRecoveryJournal in Attic/Draw/DrawPersistentStore.swift and all page/store mutation admission routes. Author real-file regressions for a transient read failure that becomes readable again, malformed recovery whose original bytes must remain intact, and attempts to draw/type/switch with unreadable recovery. Implement explicit journal re-read without treating an error as absence, and refuse new input before the page discards its ownership. Keep the existing notice/Retry route, extend it for journal failures, and do not restart or overwrite unknown recovery. Commit DS-7 with the log and verify the branch SHA before DS-8 or any other finding.

Stop immediately on any GitHub write or SHA-verification failure. GitHub, not the temporary local files or conversation, is authoritative.
