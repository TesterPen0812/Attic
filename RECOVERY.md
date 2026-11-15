# Composer round 2 recovery log

## Scope and authority

- Repository: TesterPen0812/Attic.
- Authorized write branch: phase-3/proimpl-composer-r2 only.
- Base commit: 8f54bc4f (phase-3/composer-persistence).
- Draw must be implemented first on phase-3/proimpl-draw-r6, based on 4ba1f012.
- Verified initial Draw log commit: b5aa93fff7288e31cf4d698d9fc27bd61f53ee57.
- No main/other-branch writes, force pushes, pull requests, merges, build/test execution, CI dispatch, or user-store access.
- Source of truth: committed files on this branch. Local copies are disposable.
- User restart brief: 15 November 2026, supplied in this conversation as Pasted text(4).txt.

## Checkpoint state

Initial write-access checkpoint only. No source code has been changed.
This commit's SHA is obtained from GitHub after publication; it cannot be embedded in its own content. Subsequent checkpoints record earlier verified SHAs. The current checkpoint is always identified by the branch head and its commit message.

## Findings

CP-1 through CP-17: not implemented in this restart. No completed finding SHA yet.
Carry items Opus R-23, R-25, R-20, writing-line Undo, and the tautological render test: not implemented.
CP-16 requires documenting the unsupported downgrade-writing boundary, not implementing downgrade writes.
CP-17 requires a real-event regression test and reported failure before changing native composition handling.

## Files touched

- RECOVERY.md: this initial recovery log.

## Verification

- AGENTS.md read at 4ba1f012 and 8f54bc4f.
- Implemented: no findings yet.
- Saved: this log, pending read-back confirmation.
- Compiled: no.
- Tested: no. No build or test command has been run.
- Five fresh-process reds/greens, area suites, generated seeds, physical-row/exact-byte checks, and Return-path timing measurements remain for the owner's Mac test machine. No execution result is claimed.

## Exact next step

Read this commit and branch head back from GitHub and report the SHA. Both initial recovery checkpoints must be verified before source editing. Then implement Draw first, checkpointing each finding and verifying GitHub before the next. Composer code must wait for Draw. Stop without further changes if a write or SHA verification fails.

## Approved Composer target

One authoritative Composer owner per store with canonical independent draft sessions and per-panel shown/aside ID mappings; durable stable submission identities; prepared immutable attachment references in the existing Task/writing/association creation transaction; legacy committed-file recovery only for old records; canonical conversion and Calendar identities; conflict-safe docking transfer; opaque unsupported drafts; unique preservation of malformed legacy data; retryable reads; unresolved file ownership; no main-actor file-copy fallback; frozen understood dates. Remove copied-authority leases/editor tokens, keep provider/discard/settlement fences. No SwiftData schema or accepted look/motion/Undo-order change. Older builds writing after migration are unsupported (owner decision, 15 Nov).
