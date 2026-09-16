# Opus High Implementation Handoff

Date: 2026-09-14  
Checkout: `/Users/taha/Developer/attic-task-panels-v2`  
Baseline HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`  
Branch: `codex/attic-task-panels-v2`

## Ownership and safety boundary

Opus High is the next and sole source writer. The previous Sol Medium writer
stopped before changing the Agent API. Preserve the extensive dirty worktree
and edits from other owners. Do not commit, reset, push, merge, rebuild or
relaunch the running preview, or make unrelated edits.

The existing preview is:

```text
PID 14206
/tmp/attic-chrome-checkpoint-dd/Build/Products/Local/AtticChromeCheckpoint.app
bundle id: com.taha.Attic.chromecheckpoint
```

It was not rebuilt, relaunched, or used during the completed Notes work. There
were no build or test commands running at handoff. The visible
`xcodebuildmcp` processes are pre-existing MCP server processes, not test runs.

## Completed Notes implementation checkpoint

The current source carries an exact editor-edit batch from AppKit through the
draft save boundary into `NoteStore.update`. It captures proposed text edits
before `NSTextStorage` can coalesce a transaction, validates the batch against
the exact UTF-16 source and result, applies one edit list to every physical
attachment replica, and retains the batch across save rollback for retry.
Editor replacement, remote adoption, and successful save reset the ledger.

UTF-16 comparisons are code-unit exact, including canonically equivalent Swift
strings with different storage lengths. The body-only fallback derives once
per save. Duplicate paragraph identity is covered through the exact editor
batch; the body-only fallback cannot infer edit history from two snapshots.

Completed source and test hashes:

```text
4264bbe8dc2f9ebb2c9f8cad77534c77cf4ee7d3189f5706158885a0b75d127d  Attic/Models/NoteInlineAnchor.swift
c4536ee2ac22ca0c6fdc3a1cc46cf2742eb0a85e2f906b4a77374bf30c78b09d  Attic/Views/Panel/NoteInlineCards.swift
ac270a4f1c165cebf9b7d184923ec9ece645ca415168c116c9b77c65086f4f6d  Attic/Views/Panel/NoteAttachmentTray.swift
0936d8a0a3850ab96b1a7c9e4e80843e9a4e9a0a0df6445b8b1b9afda3a0e17a  Attic/Services/NoteStore.swift
53cd6296c949d5fe86a8b0c904099e2a2eff54ffcd90f1635180b802e1c171d2  Attic/Services/NoteDraftController.swift
d9606e2acae7d14fc64a1a519d427a285567b354c2b22a9b1c2c181cef71f37f  Attic/Views/Panel/NotesPanelContent.swift
a07e71b6a576d7c2a5bccf847a5023c597f1193cbd96a09136a6d6f5fbf70103  AtticTests/NoteInlineCardsTests.swift
b2892c16bdeaf699c876fa4c6a49286026e26197fc7602f327115c8f4964be0f  AtticTests/NoteDraftControllerTests.swift
4db80e2aa25d319a94ef670a638255b1437abd8e93e1d73d1c6ce539d88f9cd6  Docs/Direct-Sol-Implementation.md
```

`git diff --check` was clean at handoff.

## Verification already completed

- Build-for-testing succeeded with derived data at
  `/tmp/attic-direct-sol-fix-dd`.
- Focused Notes run: 126 tests, 0 failures. Log:
  `/tmp/attic-offline-xctest/direct-sol-fix-report-final.log`.
- Integration run: 273 tests, 2 existing environment-gated gesture skips,
  0 failures. Log:
  `/tmp/attic-offline-xctest/direct-sol-fix-final-integration.log`.

These results establish source and native test behavior only. They do not
establish live editor input, visual, gesture, accessibility, CloudKit, iPhone,
TestFlight, production, profiling, or performance magnitude.

## Outstanding reviewed issue: Agent `update_note`

`Attic/Services/AgentServer/AgentTaskTools.swift` remains unchanged. Its
`update_note` tool accepts a final body snapshot and calls `NoteStore.update`
without a `NoteBodyEditBatch`. A repeated-paragraph edit such as
`A\nA\nB` to `A\nA\nA\nB` has more than one valid insertion history. No
algorithm receiving only those two bodies can guarantee which physical
paragraph occurrence should keep an inline attachment.

One proposal is to add an optional `body_edits` field containing ordered
`location`, `old_length`, and replacement text in UTF-16 coordinates. The tool
would replay and validate the list against the current and requested bodies,
then pass a `NoteBodyEditBatch`. Calls without the field would retain the
existing contract.

This proposal requires review before implementation. In particular, do not
assume that rejecting every potentially ambiguous body-only update is the
right compatibility policy. A rejection could surprise existing agents and
may be avoidable through a conservative fallback, a surfaced warning, or a
more narrowly defined validation rule. The chosen behavior must preserve
attachment rows and identity as far as the available information permits,
must not silently drop anchors, and must not block title-only or otherwise
unrelated operations.

The paragraph fallback limit also needs an explicit correctness decision.
When old plus new paragraph counts exceed 8192, the current bounded fallback
uses one prefix/suffix replacement span. It protects runtime cost but can
collapse anchors inside unchanged regions between disjoint changes. Evaluate
data preservation as well as timing, and describe the limitation accurately.

Required Agent contract coverage includes:

- the existing `update_note` body-only call remains compatible;
- title-only and notes without inline anchors remain supported;
- an explicit exact batch preserves duplicate-paragraph placement and all
  physical attachment replicas;
- malformed types, negative or out-of-range UTF-16 ranges, overlapping or
  wrongly ordered edits, and replay/result mismatches are rejected without a
  partial save;
- canonical Unicode and surrogate-containing bodies use UTF-16 coordinates;
- the chosen ambiguous body-only and over-8192 behavior preserves data and is
  visible to the caller rather than silently claiming exact reconstruction.

## Review state and remaining workflow

The editor exact-batch path has a routed Luna re-review reported as sound. The
files `Docs/Direct-Luna-Correctness.md` and
`Docs/Direct-Luna-Regression.md` still contained their earlier
`CHANGES_REQUIRED` text at this checkpoint, so do not interpret their on-disk
ending as the newer routed verdict without reconciling it with root.

After the bounded Agent contract work, request independent re-review. Keep
PERF-A3 limited to the existing once-per-save derivation unless new evidence
shows a defect. Canvas PERF-A1 was inspected but not edited by Sol and should
only be changed when root routes a confirmed, bounded finding. Native UI
verification remains a separate final Sol Low step.

