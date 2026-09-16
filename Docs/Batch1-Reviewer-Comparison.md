# Batch 1 reviewer comparison: SWE vs DeepSeek

## Scope and evidence boundary

This comparison covers the three completed SWE reports, the completed DeepSeek verification report, the independent counterexample validation, and the recorded reviewer-session outcomes for Batch 1. It compares this review exercise only; it is not a general model ranking.

The DeepSeek lifecycle and interaction assignments produced no review reports. The lifecycle session ended with `OpenCode became idle before producing an assistant response` after 20 progress messages, and the interaction session ended `Aborted` with no assistant messages. Those are **missing reviews**, not reviews with zero findings. User `?` / `continue?` events, status discrepancies, and possible manual interruption make the cause ambiguous; the failures cannot be attributed to model ability from this evidence.

The completed reviews were not strictly blind. DeepSeek disclosed that a status-only check exposed a truncated SWE verifier verdict (`REVIEW_PASS`) before its own review finished. Its persistence counterexample remains independently substantive because it disagreed with that verdict and was reproduced with an injected failure, then independently validated.

## Valid unique results

| Result | Found by | Missed or incorrectly accepted by | Evidence strength |
|---|---|---|---|
| **P1: failed create/delete persistence can silently select another board, clear board-scoped undo, cancel imports, and bump the surface epoch** | DeepSeek verifier | All three SWE reports. The lifecycle reviewer inspected the pre-save selection mutation and explicitly accepted the rollback fallback as sound; the verifier and interaction reports likewise marked failed-operation gating correct. | Deterministic injected-persistence-failure probes plus source trace. Independently confirmed in `Batch1-Counterexample-Validation.md` from the reviewed source and surviving logs. Exact reconstruction of the original private probe binaries is unavailable because that private tree was later edited. |
| **Low: cancellation can clear suppression for a foreign in-flight scroll/pinch sequence, allowing its tail to pan/zoom** | SWE interaction reviewer | SWE lifecycle found no defect. SWE verifier noticed the suppressed-pinch resumption edge but classified it as benign. DeepSeek verifier did not report it. | Detailed source-level interleaving only. No executed discriminating test or physical-input reproduction yet. |
| **Documentation overreach: “refused board operations” coverage actually exercised validation refusals, not persistence failures** | DeepSeek verifier | SWE reports accepted the broader wording. | Valid documentation correction tied to the P1 coverage hole. Count this separately; it is not a third functional bug. |

The SWE interaction report also recorded an advisory iOS semantic change: iOS transient-looking callers still use lifecycle cancellation and now synchronously cancel imports because the new interruption bridge is macOS-only. This is a deferred-platform observation, not a validated Batch 1 macOS defect. Other residual notes in the reports are likewise limitations or follow-up risks, not additional confirmed Batch 1 bugs.

## Review quality comparison

### Correctness and counterexample search

DeepSeek produced the strongest CVD-02 challenge in this case. It moved beyond validation-refusal tests, injected persistence failure, observed the silent board change and teardown, and traced the cause through selection mutation before `save()` and rollback presentation resolution. This directly falsified the three SWE reports' acceptance. The SWE lifecycle transcript shows this was a reasoning error after inspecting the relevant mechanism, rather than a failure to look at the code.

The SWE set contributed the only distinct interaction-sequence finding. Its interaction reviewer followed ownership of the suppression flags across cancellation and found a narrow tail-resumption path. DeepSeek ran broader image-move, shape-drag, erase, pinch, and mutant probes, but did not exercise or identify cancellation in the middle of a suppressed sequence.

### Test depth and discrimination

The SWE verifier independently rebuilt the target, ran a focused 18-test set and the full 805-test suite, inspected the five-mutant/40-failure evidence, and checked the changed tests. That evidence strongly supports the intended happy paths and validation refusals. Its weakness is discrimination at the two discovered boundaries: no persistence-failure session test and no cancel-during-suppressed-sequence test. The lifecycle and interaction SWE reviews were source/artifact audits and did not run new tests; the interaction finding therefore remains source-only.

DeepSeek independently rebuilt and ran the full 805-test suite, reproduced the mutant profile, added private interaction probes covering image, shape, eraser, standalone wheel, and pinch paths, and added injected-failure probes for create/delete, history, epoch, and cancellation-aware imports. This was the deeper adversarial execution for CVD-02. The later counterexample validation strengthened the causal adjudication while clearly recording the private-probe provenance limit.

### Provenance and native gaps

Both completed verifier tracks were strong on source provenance: they reconstructed the dirty baseline, matched hashes and the owned diff, preserved unrelated work, and independently reproduced the full unit gate. DeepSeek also isolated its builds and probes in private paths. Neither track supplied live-app or physical-input proof. Real trackpad phase and momentum ordering, real magnification delivery, SwiftUI dismantle timing, live hide/section behavior, real file-promise providers, VoiceOver, and deferred iOS behavior remain outside the evidence. Passing windowless tests cannot close those native gaps.

### Suggested-fix safety

The SWE interaction fix—preserving existing foreign suppression when routing state resets—is plausible from source reasoning, but it has not been implemented or executed. It should be treated as a hypothesis until a focused sequence test proves that a suppressed `.began`, cancellation, and later `.changed` cannot move the viewport and that terminal/new-begin events still clear suppression.

DeepSeek deserves credit for self-correcting during its completed session: it explicitly determined that a session-only gate was insufficient and that store restoration was required, then reported private passing probes and an 80-test regression subset for a two-layer experiment. The final report nevertheless proposes narrowing the session guards to `created != nil` / `if succeeded`. The independent validation explains why removing the defensive final-selection check is unsafe if the previous board cannot be restored: old-board undo state could remain active while another board is selected. The safe direction from the combined evidence is transactional restoration of the prior selection at the store boundary while retaining the session's actual-final-selection guard, preserving the original persistence error, and testing the concurrent/external-loss fallback.

## Session outcomes

| Assignment | Recorded outcome | Approximate dispatch-to-terminal time | Report available |
|---|---:|---:|---:|
| SWE lifecycle | Completed | 57 min | Yes |
| SWE interaction | Completed | 39 min | Yes |
| SWE verification | Completed | 22 min | Yes |
| DeepSeek lifecycle | Error: idle before assistant response | 108 min | **Missing** |
| DeepSeek interaction | Aborted | 71 min | **Missing** |
| DeepSeek verification | Completed | 87 min | Yes |

These wall-clock intervals are operational observations, not clean latency benchmarks. No reliable token, cost, or active-work comparison is available. The DeepSeek report's stated active/review timing does not align cleanly with the recorded session timestamps, so it should not be used for comparative performance claims.

## Recommendation for this case

Do not accept Batch 1 from either completed verifier alone. Use the independently validated DeepSeek P1 as a blocking correctness finding, retain the SWE low-severity suppression-tail finding as an open source-level defect pending a focused test, and record the wording issue separately. For remediation, restore failed board operations transactionally in the store while keeping the session's defensive response to an actual final board change; then add persistence-failure and cancellation-tail regression tests. Finish with live native verification for the unresolved physical-input and lifecycle gaps.

For a similar review split, the evidence here favors pairing adversarial failure-injection verification with a dedicated interaction-state audit. In this case DeepSeek was stronger on transactional counterexamples and executed behavioral probes, while SWE supplied the only independent gesture-tail finding and three completed specialist reports. The missing DeepSeek specialist reports and the incidental verdict exposure prevent a clean head-to-head conclusion.
