# Draw round 6 recovery log

## Scope

Repository: TesterPen0812/Attic. Write only phase-3/proimpl-draw-r6.
Base: 4ba1f012460c59f3e5cc23406ab52b2cf7a066d6.
Composer branch: phase-3/proimpl-composer-r2, based on 8f54bc4f; do not implement Composer before Draw.
No other branch writes, force pushes, pull requests, merges, builds, tests, CI dispatches, or user-store access.

## Verified prior checkpoints

- Draw initial log: b5aa93fff7288e31cf4d698d9fc27bd61f53ee57.
- Composer initial log: ed3cd1c53a73e948c7f36762860a1f2805c0d045.
- DS-6 file-backed regression candidate: fac856c8adbd633f60447914f5acce87180180c3; its branch SHA was verified twice.
- This checkpoint: DS-6 store correction and source extraction; resolve its SHA from the branch head/commit message. A commit cannot contain its own final SHA; the next checkpoint records it.

## Current finding status

DS-6 store correction is implemented in source, not compiled or tested: recovery requires a complete saved canvas load; an error retains the original record and blocks admission rather than installing objectsBefore as a complete body. Only an originally absent, empty, never-saved canvas may reconstruct from an absent base. Explicit store Retry reloads the complete base, then reconciles the original operation. Query metadata can still expose the recovery without inventing an object body.

DS-6 remains PARTIAL at the UI integration boundary: DrawPageModel currently renders recoveryIssue without a Retry action. Next step below completes that route. Do not mark DS-6 complete yet.

DS-1 through DS-5 and DS-7 through DS-16: not implemented in this restart. Existing round-5 fixes remain to be verified. Composer CP-1 through CP-17 and carry findings: untouched.

## Files touched in this checkpoint

- Attic/Draw/DrawStore.swift: state/query/cache owner; new recoveryLoadFailures; reject open of a failed recovery load.
- Attic/Draw/DrawStore+Recovery.swift: recovery reconstruction, per-canvas full-load error and explicit store Retry; existing write/flush behavior retained for later findings.
- Attic/Draw/DrawStore+Commands.swift: extracted existing commands/typing/clipboard/thumbnail implementations.
- Attic/Draw/DrawStore+History.swift: extracted existing history behavior.
- Attic/Draw/DrawStore+HistoryBudget.swift: extracted existing ledger, pending its removal under DS-10/11/12.
- Attic/Draw/DrawStore+Rename.swift: extracted existing cancellation/rebasing, pending removal under DS-5.
- Attic/Draw/DrawStore+AgentUndo.swift: extracted existing exact physical agent inverse checks.
- Attic/Draw/DrawStepPins.swift: extracted existing token bookkeeping, pending removal of protection semantics.
- RECOVERY.md.

The extraction keeps the same class and stored state, but makes cross-file implementation members module-internal rather than file-private. It introduces no SwiftData schema or new storage format. Remaining mechanisms are not claimed removed by this checkpoint.

## Regression and verification

AtticTests/DrawR6RecoveryLoadTests.swift / testDS6FailedCompleteLoadNeverSubstitutesARenamesEmptyObjectPatch was committed before this source correction. It simulates an unretired committed rename, drops the store without close, reopens the same disk store with complete-load failure, asserts throwing open and retained ownership, then verifies full object identities and image bytes after Retry.

No executed red/green result exists. Nothing compiled, tested, launched, or measured. The owner's Mac runner must regenerate the project to include the new Swift files and execute all checks. No existing test has been deleted yet. GitHub is the source of truth; no local workspace is authoritative.

## Exact next step

Verify this commit and phase-3/proimpl-draw-r6 head on GitHub. Finish DS-6's user-visible load-error Retry route through the existing notice mechanism, with a page-level regression and log update; then checkpoint and verify again before DS-7. DS-7 must add retryable journal reads and conservative admission. DS-8 must still fix swallowed retirement failures; this checkpoint intentionally does not claim it.

Stop immediately on any GitHub write or SHA-verification failure. Never publish to any branch other than the two explicitly authorized branches.
