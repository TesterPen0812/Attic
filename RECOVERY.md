# Draw round 6 recovery log

## Scope

Repository: TesterPen0812/Attic. Authorized write branch: phase-3/proimpl-draw-r6 only.
Base: 4ba1f012460c59f3e5cc23406ab52b2cf7a066d6.
Companion: phase-3/proimpl-composer-r2, base 8f54bc4f; Composer implementation waits for Draw.
No other branch writes, force pushes, pull requests, merges, builds, test runs, CI dispatches, or user-store access.

## Verified checkpoints

- Initial Draw recovery log: b5aa93fff7288e31cf4d698d9fc27bd61f53ee57; commit and branch head read back from GitHub.
- Initial Composer recovery log: ed3cd1c53a73e948c7f36762860a1f2805c0d045; commit and branch head read back from GitHub.
- Current checkpoint: DS-6 regression candidate, identified by this commit's message and branch head. Its SHA is recorded after publication, not embedded recursively in its own content.

## Finding status

- DS-6: regression authored before the fix. Implementation NOT yet changed. Expected baseline failure is inferred from source, not an executed red result.
- DS-1 through DS-5 and DS-7 through DS-16: not implemented in this restart.
- Parts of DS-4, DS-5, DS-15 and DS-16 were changed by the base; they still require targeted checks.

## Current files touched

- AtticTests/DrawR6RecoveryLoadTests.swift: testDS6FailedCompleteLoadNeverSubstitutesARenamesEmptyObjectPatch. It leaves a committed rename with failed journal retirement, drops the old store, opens a fresh file-backed container, injects complete-load failure, requires a retryable load error, then checks both object identities and exact image bytes after Retry. The fault adapter forwards real repository operations.
- RECOVERY.md: status, constraints, verification and next step.

## Verification and limitations

AGENTS.md was read at both bases; Draw README was read. No application source changed yet. Nothing compiled or tested. Five fresh-process reds/greens and all required area suites remain for the owner's Mac runner. The direct local Git clone was unavailable because this workspace could not resolve github.com; the desktop connectors were offline. GitHub connector reads and writes work. Those transport failures did not change repository source.

## Exact next step

Read back this commit and verify the authorized branch head matches. Then implement DS-6: keep each failed complete-canvas recovery load as an owned retryable error; do not substitute objectsBefore or an empty board. Retry must first obtain the complete saved base (or prove an originally absent canvas), then reconstruct and reconcile the same recovery record. Update this log in that source-change commit and read its SHA back before the next finding. Stop without further changes on any write or SHA-verification failure.

## Draw target and remaining sequence

Keep input batching and sparse physical replica validation. Implement retryable recovery reads/load errors (DS-6/7), global admission with finite already-admitted input (DS-2/3), explicit durability and cleanup states (DS-1/8/16), unified pending lifecycle and operation-owned notices (DS-4/5), Quit admission/final readiness (DS-9), strict resident-only 100-step histories and expiring offers with no byte ledger (DS-10/11/12), partial grouped retry (DS-13), ordered old-format recovery (DS-14), and preserve/test flat-axis agent resize (DS-15). Each finding needs its own verified completion checkpoint. Retire obsolete mechanism-only tests without weakening remaining user-visible assertions.
