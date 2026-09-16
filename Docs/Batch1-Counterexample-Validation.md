# Batch 1 counterexample validation

**Verdict: CONFIRMED.** The DeepSeek persistence-failure counterexample is a real Batch 1 correctness gap. A failed create or delete can move the selected board during rollback; the session treats that fallback move as a successful lifecycle change and clears board-scoped history, cancels session imports, and increments the native-surface epoch. This contradicts the CVD-02 success gate and the comment that a failed save must retain history.

## Independent trace

The reviewed checkout still identifies as branch `codex/attic-task-panels-v2` at `ae6418c1af690e29d15a20344cdb9765a23d3f85`; it is extensively dirty, as disclosed by the Batch 1 reports. Relevant current file hashes were:

| File | SHA-256 |
|---|---|
| `Attic/Canvas/CanvasSession.swift` | `ebec9d9fa5c905ffff71ed58e95f5efa9adf978c98d83f0f8e954a53353fb586` |
| `Attic/Services/CanvasStoreBoards.swift` | `5679b9c8c5a510aed6c442bfd378898f541ab0dacd98c927d22b5c19f2c88970` |
| `Attic/Services/CanvasStorePersistence.swift` | `ad3301ecc210b53f49ecb433ead63edaf053cc9ed2bda90f1392e0e0e83a85f3` |
| `AtticTests/CanvasSessionTests.swift` | `beb9dba1f9152b54ad157a617acad43c37afc12b0fadb9b509db93964234c721` |

The mechanism is direct:

1. `CanvasStore.createCanvas` assigns the new ID to `selectedCanvasID` before `save()` (`CanvasStoreBoards.swift:44-45`). `deleteCanvas` similarly chooses another board before `save()` (`:153-161`).
2. On persistence failure, `save()` rolls the context back and reloads (`CanvasStorePersistence.swift:73-82`). Presentation resolution starts from the already-mutated selection and falls back to the first live board when that ID is not live (`:156-159`), then publishes that fallback selection (`:429-430`).
3. `CanvasSession.createCanvas` defines `boardChanged` as `created != nil || store.selectedCanvasID != previousCanvasID` (`CanvasSession.swift:530-536`). `deleteSelectedCanvas` uses `succeeded || selectedCanvasID != id` (`:553-564`). The rollback-induced selection move therefore invokes the same history/import/surface teardown used by a successful board change.

This is not merely a harmless fallback. The operation reports failure and both persisted boards remain, yet the user is silently shown a different board. The store and session agree only on that unintended fallback board.

## Probe evidence and provenance limit

The supplied private logs are authentic files and match these hashes:

| Log | SHA-256 | Result |
|---|---|---|
| `/tmp/deepseek-batch1-xctest/probe2.log` | `89527a0757fdfc889e0dd97df8912e910891c2ee290162475ac7fd380557f908` | Failed create moved selection and changed undo `1 -> 0`, epoch `2 -> 3`; failed delete also changed undo and epoch. |
| `/tmp/deepseek-batch1-xctest/probe3.log` | `a97c280cc26f4824075b6b16c4d4254ac3cb71607b06ecba94849165a85f55ae` | A cancellation-aware in-flight import was cancelled on failed delete; undo and epoch also changed. |

`build2.log` and `build3.log` show successful incremental compilation of the probe test source immediately before those runs. The probe assertions are concrete and use the repository's existing injected `PersistenceGate` to throw from `persist`.

There is one provenance qualification: `/tmp/deepseek-batch1-probe` was later edited to test the proposed remediation, and the original probe binaries recorded in `probe2.log`/`probe3.log` have since been overwritten. Its current `CanvasSession.swift` and `CanvasStoreBoards.swift` hashes therefore do not identify the sources of those initial binaries. The failing logs remain consistent with, and are independently explained by, the unchanged reviewed checkout source above; exact byte-for-byte reconstruction of the old private probe binary is no longer possible from the surviving artifacts. A new build was unnecessary to adjudicate the causal path and would add little beyond the deterministic injected-failure evidence already present.

`probe2` alone does not prove import cancellation: its `DeepSeekControlledPreparer.cancellationCount()` never increments. `probe3` replaces it with a cancellation-aware preparer and does prove cancellation, because its cancellation assertion passed while only the history and epoch preservation assertions failed.

## Fix adjudication

A session-only change from the current guards to `created != nil` / `if succeeded` is unsafe by itself. The private `alt-gate.log` demonstrates why: it preserves history and epoch while the store and session remain on Alpha after a failed operation initiated on Beta. That leaves Beta's undo stack active while Alpha is selected. History entries are not tagged with a session board ID, and undo methods operate through the store's current selection; for example, stroke deletion rewrites matched replicas to `selectedCanvasID` (`CanvasStoreStrokes.swift:97`) and clear/restore ensures the currently selected board (`CanvasStoreLifecycle.swift:78`). An old-board Undo could therefore fail, migrate content, or apply captured content to the wrong board.

The smallest safe scope is to make create/delete selection transactional at the store boundary and retain the session's defensive actual-selection check:

- Capture the previous selection before the create/delete pre-save selection change.
- On every `save()` failure path, restore that requested previous selection **before** rollback reload resolves and publishes the presentation. If the previous board is no longer live, normal resolution may choose a fallback and the session must treat that actual board change as teardown-worthy.
- Preserve the original persistence error while restoring/reloading. Calling the current `refresh()` helper after failure is insufficient because it can replace `lastErrorMessage` with the reload warning or `nil`.
- Keep the existing session condition based on the final store selection. With the store postcondition fixed, ordinary failed create/delete returns to the previous board and the condition is false; a concurrent/external loss of that board still clears stale history safely.

One compact implementation shape would let `save()` accept an optional failure-selection ID, assign it after `context.rollback()` and before each failure reload, then have create/delete pass their captured previous ID. A structured operation outcome carrying success plus final presentation-change state would be clearer if the store API is already being revised, but is not required for this bounded fix.

Focused regression tests should cover both layers:

1. Store create save failure: return `nil`; both original boards remain; prior selected ID, visible content, and persistence error remain.
2. Store delete save failure: return `false`; deleted board and content remain; prior selected ID, visible content, and persistence error remain.
3. Session create/delete save failures with two boards: selected board, undo/redo counts and behavior, pending placement, epoch, selected object, and in-flight session import remain unchanged.
4. Failure plus inability to restore the prior board (synthetic concurrent/external removal): session follows the final live store selection and clears old-board history/imports.
5. Successful create/delete still select the intended board and perform exactly one lifecycle teardown.

The DeepSeek report's `full-fix` run is useful evidence that store restoration plus session suppression passes its normal injected-failure probes and an 80-test regression subset. It does not establish that removing the session's defensive actual-selection guard is safe, and its restoration helper's use of `refresh()` does not assert preservation of the original failure message.

## Reviewer comparison

The broad SWE verification and lifecycle reports accepted the persistence fallback as a legitimate visible board change and returned `REVIEW_PASS`; that is the wrong product/correctness conclusion for a failed transaction whose original board still exists. The DeepSeek counterexample directly falsifies that acceptance and is the stronger evidence on CVD-02.

Separately, `Batch1-SWE-Interaction-Review.md` found a real low-severity suppression-tail issue that the DeepSeek report did not supersede. These are different bounded findings: persistence transactionality versus gesture-sequence cleanup. They do not support a general model ranking.

DeepSeek disclosed that a status-only check exposed a truncated SWE final verdict (`REVIEW_PASS`) before its review completed. Its work was therefore not fully blind, even though the persistence finding, private reproducer, and disagreement with that exposed verdict are independently substantive.
