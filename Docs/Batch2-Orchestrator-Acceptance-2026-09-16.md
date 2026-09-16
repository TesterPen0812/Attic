# Batch 2 Editing Availability Fix — Orchestrator Acceptance Packet (2026-09-16)

Prepared for Astra by the delegated execution orchestrator (GLM-5.3-Flash,
child of task 01a0920b-4833-7e52-9c7a-83c2d5ba570c). **No promotion claim.**
Full evidence trail: Docs/Batch2-Orchestrator-Ledger-2026-09-16.md.

## 1. Candidate and source fingerprint

- Authoritative checkout: /Users/taha/Developer/attic-task-panels-v2, branch
  codex/attic-task-panels-v2, HEAD ae6418c1af690e29d15a20344cdb9765a23d3f85
  (not the candidate; the dirty tree is the candidate; 185 status entries now,
  all inherited work preserved; no commits anywhere).
- Frozen final candidate: /tmp/attic-b2fix-snapshot-20260916T023926Z,
  MANIFEST.sha256 file sha256
  c9ed8fa8ff0843859d9f95d22309b218c8d75bcaba79d344407b8d3b3d5a1924,
  391/391 entries OK (orchestrator-verified; both Synara reviewers verified
  independently; DeepSeek verified).
- Owned-file fingerprints (orchestrator-measured, reviewer-confirmed):
  - Attic/Views/Panel/CanvasPanelContent.swift 84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8
  - Attic/Canvas/CanvasSession.swift e9393be9fa8b3a1fed8ed6b814b9ccbf91d99bdbdc40d68f436b920788c542d3
  - Attic/App/CanvasEditCommandRoute.swift 4667608109c75c3b2731dac21bdc741f48296d74763b27c489354cdfd685b2bf (unchanged)
  - AtticTests/CanvasDomainTests.swift 262b7668fdc0fe87d41dc011f0fac489624497cdbd5fbafd1da76773ddf8ca96
  - AtticTests/CanvasSessionTests.swift f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd (unchanged)
  - Recovery surface byte-identical to the prior Batch 2 snapshot:
    CanvasSurfaceRenderer 48c81ecf…, CanvasImageTypes 40d1ff26…,
    CanvasSurfaceMac 67477ef5….

## 2. Workers (IDs, models, statuses)

| Role | Worker | Model | Status |
|---|---|---|---|
| Implementation (D1/D2) | agent-49e31b0e6a3902db729a7722a3e01747 (requestId b2-avail-fix-opus-5) | claudeAgent opus[1m], env local, full-access | completed, IMPLEMENTATION_READY |
| R1b correctness review | agent-e675bae1e88aa796f09c435310b875d7 (b2-avail-fix-rev-r1b-1) | devin swe-2-max | completed, REVIEW_PASS |
| R2b editing semantics | agent-867d4fa91240ba685c5fe156a08ea57f (b2-avail-fix-rev-r2b-1) | devin swe-2-max | completed, REVIEW_PASS |
| R4b general (DeepSeek) | 01a0a819-774b-7130-b07b-94228ac0ad53 (spawn_agent "Popper") | ollama-cloud/deepseek-v4.1-flash, effort max | completed, REVIEW_PASS |
| Native run 1 | agent-98efd5e2b595cad2bbd71e823fc989d0 (b2-avail-fix-native-sol-1) | codex gpt-5.6-sol, effort low | completed, NATIVE_PARTIAL (tunnel) |
| Native retry | agent-348575ed84c4ee9196e1cdc01d58dd8b (b2-avail-fix-native-sol-2) | codex gpt-5.6-sol, effort low | completed, NATIVE_PARTIAL (tunnel) |
| Trial run, sol leg | 01a0a842-24b5-78e0-be17-8403b2f5c85b (Ampere, spawn_agent) | gpt-5.6-sol, effort low (turn_context-verified; its "glm-5.3-flash" self-report was an instruction echo, not identity evidence; serving weights not established) | completed within budget (~7.7 min, 60 tool calls); S1-S6 blocked at navigation |
| Trial run, deepseek | 01a0a84c-1ea3-7480-a590-4ceaac734c87 (Locke, spawn_agent) | ollama-cloud/deepseek-v4.1-flash, effort max (turn_context-verified; self-report not used as identity evidence; serving weights not established) | completed; active UI ~24.6 min = ~4.6 min OVER the identical 20-min budget; S2 full + S3 executed parts within budget; S1 product-failure finding (R2b F1 residual, live) at cutoff boundary; S4/S6 verified past cutoff; S5 not executed; no equal-budget score drawn (results doc Amendment 1) |
| Seg-1 native characterization (post-audit) | 01a0aa0c-cbd2-7170-b048-ed8c3b64adc9 (Poincare, spawn_agent) | ollama-cloud/deepseek-v4.1-flash, effort max (turn_context-verified) | completed; ~10m56s of 20-min cap, no overrun; S-A D1 residual NOT reproduced (prior inert reading invalidated as index artifact); S-B Redo divergence not found; S-C keyboard history verified (stroke caveat); S-D drag inconclusive; S-E banner verified, retry leg blocked by GoTo-field input failures |
| Seg-1 implementation | Synara b2-avail-fix-opus-6 -> agent-d880c2fd430579b9e1a89c8459af311e | claudeAgent claude-opus-5[1m], effort max, autoCompactWindow 1m, local, full-access | completed, IMPLEMENTATION_READY (five measured root causes R1-R5; fixes F1-F6; 830/826/4/0; mutants M1-M6+A/B discriminate) |
| R1c correctness review | Synara b2-avail-fix-rev-r1c-1 -> agent-a008bd10a3f4b24f17656826ae1a53c3 | devin swe-2, modelVariant max, local, full-access | completed, REVIEW_PASS (independent build + delta + mutant spot-checks; suite numbers from the verified evidence-bundle logs - honest limit reported) |
| R2c editing-semantics review | Synara b2-avail-fix-rev-r2c-1 -> agent-97a31b223a9716aa57d560b0b6e5a1b5 | devin swe-2, modelVariant max, local, full-access | completed, REVIEW_PASS (source-level F1-F6 mapping; evidence-bundle logs confirmed; honest limits) |
| Seg-2 final native verification | 01a0aa65-09af-7003-92c3-edd0838742de (Schrodinger, spawn_agent) | ollama-cloud/deepseek-v4.1-flash, effort max (turn_context-verified) | completed; ~17.4 of 20 min; S1 changed-behavior PASS (core), S3 PASS, S4 PASS; S2 = orchestrator expectation error (not a defect); S5 not achieved; S6 not run (budget) |
| Seg-3 continuation | 01a0aa7c-4687-7dc2-ab3d-e11a006f1ad0 (Fermat, spawn_agent) | ollama-cloud/deepseek-v4.1-flash, effort max (turn_context-verified) | terminated by screen lock before any scenario; T1-T5 checkpointed (see §10); clean shutdown |

## 3. Confirmed fixes (both mission defects)

- D1 (enabled-but-inert): FIXED AND NATIVELY VERIFIED after the continued
  closeout (2026-09-16, user-authorized). The prior "one-cycle residual"
  characterization is SUPERSEDED by the measured root causes: canvas text
  editors shared the panel window's undo manager (closed editors' typing
  stayed armed and route-style undo mutated a CLOSED editor's detached
  text), focus was resolved through the key window only (the
  non-activating panel can lose key while its editor stays open), focus
  moves and reconcile history-resets published no availability refresh, and
  TextKit 2 editors never republished their own undo/redo. Fix F1-F6:
  editor-owned private UndoManager; editor answers plain undo:/redo:;
  deferred availability refresh on focus moves and reconcile resets;
  undo/redo history reporting in both text systems; route resolver falls
  back to a canvas editor focused in its visible window (key-window text
  view precedence preserved). NATIVE VERIFICATION (segment 2, live AX):
  fresh editor over non-empty history now renders toolbar Undo DISABLED
  and the app Edit menu verbatim "Undo Canvas Change (disabled), Redo
  Canvas Change (disabled), Undo (disabled), Redo (disabled)"; typing
  enables toolbar Undo; toolbar Undo with a draft reverts ONLY the draft
  (object intact - the draft-discarding misroute is gone); commit adds
  exactly one history entry; keyboard cmd+z/cmd+shift+z drive canvas
  history 1->0->1. Independent reviews R1c + R2c: REVIEW_PASS (see §10).
- D2 (stale-disabled while typing): fixed. `CanvasSession.editingAvailabilityToken`
  (@Published) bumps unconditionally in `preserveSemanticTextDraft`, covering
  typing, editor undo, and editor redo via the editor draft callback,
  including undo-back-to-baseline (nil draft) and teardown/suspend paths.
- Preserved: editor/session undo separation; commit-veto at all live switch
  sites; Batch 1 + Batch 2 fixes untouched (hash-verified); no canvas-history
  publish from typing.
- Regression coverage: before-fix (final test text) 5 executed / 4 failures
  (D1 lines 1368/1370, D2 1435/1445); after: 11/11 (4 new + 7 prior), focused
  Canvas 209/209, full Local suite 824 executed / 820 passed / 4 skipped /
  0 failed; stability 5/5 ×3; app build succeeded (not launched by the
  implementer); `git diff --check` clean. Mutants discriminate: restoring the
  session term fails the D1 test; removing the bump fails the D2 test.
- Test split (documented deviation): the combined toolbar/menu test was split
  after the offline host measurably freezes popup-menu enabled flags at first
  open; toolbar coverage retained, menu coverage moved to two dedicated tests
  with one fresh menu open each. M3-style misrouting is now discriminated by
  3 tests (was 1). Net Add-menu coverage unchanged or better.

## 4. Reviewer verdicts and applicability

- R1b correctness/regressions: REVIEW_PASS on the exact candidate (391/391
  manifest; 342/342 overlay hashes; delta-vs-prior-snapshot discipline:
  exactly 3 changed files + new docs; independent test execution; mutants A/B
  kill the fix with expected signatures; tree restored and re-verified).
- R2b editing/focus semantics: REVIEW_PASS on the exact candidate (both
  defects resolved as defined; coherence across toolbar/Add menu/app Edit on
  one publisher; commit-veto intact at all 10 call sites; before-fix signature
  reproduced independently; M3 discrimination tripled).
- R4b DeepSeek general: REVIEW_PASS on the exact candidate (patch fidelity
  hunk-for-hunk; route branch equivalence; token-bump coverage incl. no-op
  commit; no blocking findings; honest limits: no build/run/launch in its
  20-minute budget). Resolves the R4 mini-SWE INCONCLUSIVE without touching
  that runner.
- Carried forward (basis documented in ledger §5): prior R1/R2/R3/R5 verdicts
  remain applicable to unchanged surfaces (byte-identity verified by R1b;
  recovery files, route file, and all other inherited paths unchanged; full
  suite re-passed on the final candidate). Orchestration itself is not counted
  as any independent review.
- Remediation/recheck cycles used: 0 of 2 (no code findings; only actionable
  item is a disclosure-wording note, below).

## 5. Actual test results and warnings

- Full Local unit suite: 824 executed, 820 passed, 4 skipped, 0 failed
  (820 baseline + 4 new). Focused Canvas: 209/209. New+prior: 11/11.
  Skips are the 4 pre-existing UI-hosted skips, unchanged.
- Warnings: none in owned files. Pre-existing outside scope:
  PanelGeometryTests.swift:291 CGWindowListCreateImage deprecation,
  TaskStoreTests.swift:257 code-after-throw, and the
  appintentsmetadataprocessor AppIntents note.

## 6. Native verification (isolated local-only preview; updated after the Astra-steered trial)

- Verified (both runs, independently): source-hash match before launch;
  bundle com.taha.Attic.b2avail.solnative.20260916; executable sha256
  e635451ce6d4d2787a8e1beb5e1290e60e5419849b7dcf4e0efa4008c3c645dc; debug
  dylib sha256 320944869fb29ac6e181bf46dfb6457959e4cf7c3048dcb2f355e07d8e6734f4;
  launchd-owned PIDs mapped to the exact binaries (28751, then 30570);
  local-only entitlements (no CloudKit/ubiquity/APNs); Daily (com.taha.Attic)
  and all stores untouched; physical-desktop lock held/released cleanly.
- Native evidence established by the Astra-steered computer-use trial
  (Locke leg; recorded harness config ollama-cloud/deepseek-v4.1-flash, max,
  turn_context-verified — serving weights not independently established for
  either leg, and the earlier "override ineffective / ran glm-5.3-flash"
  identity claim is RETRACTED per results-doc Amendment 1. Budget caveat:
  the leg's active UI window ran ~4.6 min past the identical 20-min budget;
  within-budget vs past-cutoff evidence is separated below and no
  equal-budget score is drawn. Full detail in
  Docs/Batch2-Native-Trial-Results-2026-09-16.md):
  - **D2 (mission issue 2) VERIFIED natively (S2 PASS)**: on a fresh
    disposable canvas, typing enabled the toolbar Undo with no other action;
    toolbar Undo reverted the typing with the canvas item count unchanged;
    Cmd-Z / Cmd-Shift-Z equivalence verified.
  - **Focused-editor routing VERIFIED natively (S3)**: toolbar Undo/Redo,
    Add-menu Edit>Undo/Redo, and keyboard Cmd-Z/Cmd-Shift-Z each drove the
    focused editor (before/after values transcribed live).
  - **Commit/cancel VERIFIED natively (S4 PASS)**: commit produced exactly one
    history entry (one undo restored pre-edit text); Escape cancelled the
    draft; app Edit menu matched the toolbar for canvas-history items.
  - **Corrupt-import failure banner + retry affordance VERIFIED (S6 partial)**:
    importing /tmp/attic-b2trial-corrupt.png produced "Import complete 1/1 -
    not a supported image or is corrupt" plus the "Choose Failed Files
    Again..." affordance.
- NOT established natively (recorded precisely, not a pass):
  - D1's disabled-at-edit-entry state was NOT observed in the trial's edit
    entry over non-empty canvas history: the toolbar rendered enabled and the
    click was inert with history intact - i.e. the disclosed R2b F1
    one-cycle residual window, observed live. Whether it settles on the first
    keystroke was not captured before the screen locked. The pre-fix
    destructive misfire was not observed.
  - Text resize by pointer drag (S5): NOT EXECUTED — a pointer-drag
    primitive exists in the documented control surface (cua.computer.drag,
    doc-verified post-audit) but its usable call shape was never established
    in-run; the prior "no move-only pointer primitive" claim is retracted.
  - Keyboard-driven canvas history after commit (S3 sub-claim): cut short by
    the screen lock.
  - S6 recovery re-import: cut short by the screen lock; the retry affordance
    itself is verified actionable.
  - Physical-only gestures: omitted, unscored for both legs.
- Provenance for the trial run (per-run identity com.taha.Attic.b2trial.ds.20260916,
  executable 12c058b4…, debug dylib 6c5f597e…, launchd-owned PID verified,
  local-only entitlements, Daily and all stores untouched; lock held and
  released cleanly). Persisted screenshots: none (screen locked before
  archiving; AX transcriptions are the evidence, cross-consistent with the
  orchestrator's own diagnostic observation of the identical app surface).
- The Mac's screen LOCKED at the end of the DeepSeek leg and cannot be
  unlocked automatically: **user must unlock it manually** before any further
  desktop work.

## 7. Unresolved issues and required user actions

1. **Unlock the Mac (required user action).** The screen locked during the
   DeepSeek trial leg's final minutes; automatic unlock failed. No desktop
   control is possible until it is manually unlocked.
2. **Native items still unverified after the trial (explicit, not a pass):**
   text resize by pointer drag (S5 - not executed; a pointer-drag primitive
   exists in the documented surface and was never established in-run),
   keyboard-driven canvas history after commit (S3
   sub-claim), and the S6 recovery re-import. These need either a control
   surface with pointer-drag (e.g., the established cua-driver registration)
   or a manual run per Docs/Native-Verification-Playbook.md, and the screen
   unlocked. Disposition (continued closeout, section 10): the S3 sub-claim
   was subsequently verified natively; S5 and S6 remain unverified.
3. **R2b F1 wording corrected here (this packet).** Precise residual state
   (replaces any absolute all-states claim): route-only availability gives
   app-menu parity in publish-coherent states; on non-publishing
   focus/insertion-spawn paths and external reconcile stack-clears the chrome
   can render one cycle stale-enabled (inert-only, history intact,
   self-healing). This residual was OBSERVED live in the trial (S1: toolbar
   enabled-but-inert at fresh-editor edit entry over non-empty history). No
   source change was made for this nonblocking disclosure. SUPERSEDED in the
   continued closeout (section 10): the mechanism was re-measured (shared
   window undo manager, not a publish-cycle lag) and fixed in source
   (F1-F6) with segment-2 native verification; the "no source change"
   statement above no longer applies.
4. R4 mini-SWE remains INCONCLUSIVE/superseded by R4b. Identity discipline
   (amended post-audit): recorded harness configuration is authoritative and
   agent self-description is not - R4b's self-report is an instruction echo
   and serving weights are not independently established for any delegated
   leg (trial or review). See Amendment 1 in
   Docs/Batch2-Native-Trial-Results-2026-09-16.md.

## 8. Boundaries respected

No push, merge, release, install-over-Daily, permission/TCC change, user-store
deletion/reset/migration, or unrelated refactoring. No commits (including
private review copies). No new audit batch started. Daily never launched or
read. All inherited dirty/untracked work preserved (verified by hashes).
Transport/harness events counted from evidence: 2 capabilities timeouts, 3
create dispatch failures (+1 idempotency replay refusal), 2 Synara wait MCP
timeouts, 5 desktop-control tunnel failures across 2 native runs.

## 9. Amendment trail (post-acceptance audit, 2026-09-16)

Astra's acceptance audit corrected this packet (full detail and preserved
original wording: Amendment 1 in Docs/Batch2-Native-Trial-Results-2026-09-16.md):
(a) recorded harness configuration is authoritative - the turn_context
records verify gpt-5.6-sol/low (Ampere) and
ollama-cloud/deepseek-v4.1-flash/max (Locke); the "sol override ineffective /
actually ran glm-5.3-flash" claim is RETRACTED; self-reports are instruction
echoes and serving weights are unestablished for both legs; (b) the DeepSeek
trial leg exceeded the identical 20-minute budget (~24.6 min active UI,
~4.6 min over; 103 exact tool calls = 91 computer-use + 12 shell), so no
equal-budget score or quantitative winner is drawn - within-budget vs
past-cutoff evidence is separated explicitly; (c) S1's 0/15 is rescored as a
product-failure finding (the disclosed R2b F1 residual confirmed live by
successful testing), not agent capability, and S3's keyboard sub-claim is
not-executed, not failed; (d) S5's "no pointer-drag primitive" claim is
retracted - cua.computer.drag exists in the documented surface; S5 is not
executed; (e) 15 inline screenshots preserved in the session transcripts were
extracted with a timestamp manifest. The ledger carries the same amendment
entries.

## 10. Continued closeout (user authorization, 2026-09-16)

After the acceptance audit, Astra authorized a continued closeout:
DeepSeek (ollama-cloud/deepseek-v4.1-flash, effort max, harness
turn_context-verified) for all live-test work, Opus for implementation,
independent SWE-2-max reviewers for review. Full trail: ledger section 10.

Implementation (Synara b2-avail-fix-opus-6 ->
agent-d880c2fd430579b9e1a89c8459af311e, claude-opus-5[1m] max): report
Docs/Batch2-D1-Residual-Fix-Opus-2026-09-16.md. FIVE measured root causes -
R1 shared window undo manager across canvas editors (the true D1 mechanism,
superseding the one-cycle-lag characterization), R2 key-window-only focus
resolution, R3 no publish after focus moves, R4 reconcile history-reset
without publish, R5 TextKit 2 never republishing its own undo/redo - fixed
by F1-F6 (editor-owned UndoManager; plain undo:/redo: responders; deferred
RunLoop-common availability refresh; reconcile refresh; DidUndo/DidRedo
observation; visible-window resolver fallback). Verification: 17/17
availability, 215/215 focused, 830 executed / 826 passed / 4 skipped /
0 failed, stability 11/11 x3, before-fix 6 executed / 30 failures, mutants
M1-M6+A/B all discriminate, app build ok (not launched by the implementer).
Evidence bundle /tmp/attic-b2-d1fix-evidence-20260916/ (MANIFEST.sha256 file
sha256 d789797c69358c95d7c59ea9b044cdb1cd90a7fe1c47f2a97c8ac8d62b8b4b7b).
Frozen post-fix candidate /tmp/attic-b2fix2-snapshot-20260916T131900Z
(MANIFEST.sha256 file sha256
069e5ba29c1989a3338a8a63505a642894b917c37cea6edfe2531e9a6c1e6084; 488
files). Owned post-fix fingerprints (snapshot re-hashed by the
orchestrator; unchanged files noted):
- Attic/App/CanvasEditCommandRoute.swift
  9c19f2e426d665fc5b18523247285d2865a3c1da7cbf0d8985b5dc963bd4c2ba
- Attic/Canvas/CanvasSemanticInteraction.swift
  0da5cc84d5a13bb0a8be8d9c4465a799180e4cb002d8bffdc5fe493f518fcd94
- Attic/Canvas/CanvasSurfaceMac.swift
  b1fa3d8f3a5e9771811bdfaf37a19499554309ed8a9b1f25025da201c8f624e6
- Attic/Canvas/CanvasSession.swift
  467505742dbff69b70a317b9f013408cd3f362dfb0405671fe5982139d2a3e84
- Attic/Views/Panel/CanvasPanelContent.swift
  84a0b642b0afec625bafba83fa3e3093cb98a87801b7f2f99adbf753f295f1f8
  (unchanged)
- AtticTests/CanvasDomainTests.swift
  a4386aff8b9ff2bd6accf8f11aeadc4e16d33dc51f6a78ca4eff9adb40e00db5
- AtticTests/CanvasSessionTests.swift
  f5f8cdd34897ba633f62277a88f3dbad1ca18adf1653eaa6248223d7eba2b0dd
  (unchanged)

Reviews: R1c (agent-a008bd10a3f4b24f17656826ae1a53c3, report
/tmp/attic-b2fix2-r1c/report-r1c.md, file sha256
da4b3f0cd842b220a6d74548f4d85efd523730da379a6663ca8a66eda9eba1a9) and R2c
(agent-97a31b223a9716aa57d560b0b6e5a1b5, report
/tmp/attic-b2fix2-review-r2c/report-r2c.md, file sha256
467b3aa55fa44ba494b36aa38caa20256f0034db891e629483899143571d6ef9) both
REVIEW_PASS on the post-fix candidate. Honest limits recorded: R1c could
not independently run the full suite and relied on the verified
evidence-bundle logs; its report's self-stated hash is a benign
self-reference artifact (the orchestrator-measured hash above is
authoritative). R2c's report contains one minor inaccuracy: it calls
CanvasSemanticInteraction a "new file" although that file is tracked at
HEAD ae6418c; its substantive source mapping is unaffected.

Native verification (DeepSeek legs, harness turn_context-verified):
- Segment 1 (Poincare, ~10m56s of 20 min, no overrun): S-A D1 residual NOT
  reproduced (the prior trial's "inert" reading invalidated as an index
  artifact); S-B Redo divergence not found; S-C keyboard history verified
  (stroke caveat); S-D drag inconclusive; S-E banner verified, retry leg
  blocked by GoTo-field input failures. Report
  /tmp/attic-b2fix-ds/report-seg1.md (file sha256
  14c24d0c70dda3877795bdc97ab3e411c12093268696847845778115b697fd26); 32
  screenshots in /tmp/attic-b2fix-ds/screenshots/.
- Segment 2 (Schrodinger, ~17.4 of 20 min): S1 changed-behavior PASS
  (verbatim chrome states in section 3); S3 PASS; S4 PASS; S2 "deviation"
  = orchestrator expectation error, not a product defect (cmd+z inert in a
  REOPENED UNMODIFIED editor is the designed behavior - reopened drafts
  start empty; the brief described the typed-draft case); S5 NOT ACHIEVED
  (app.drag accepted but acted as deselect; 4 cua.computer.drag shapes
  rejected verbatim); S6 not run (budget). Report
  /tmp/attic-b2fix2-ds/report-seg2.md (file sha256
  d4d51dac1b85f53e53271fb469509f06cc1a11561703cc973dd422eca003ccb7); 8
  screenshots in /tmp/attic-b2fix2-ds/screenshots/ (seg2-01..08).
- Redo divergence: mechanism measured, the canvas channel removed,
  remaining channel (other panel-window text views) not reproduced - no
  code change absent a natively reproduced defect.
- Segment 3 (Fermat): terminated by a NEW screen lock ~13:53Z (cua
  listApps lock message; ioreg IOConsoleLocked:true at 13:53:48Z) before
  any scenario; T1-T5 UNVERIFIED, blocked-before-start; continuation
  checkpoint list preserved in /tmp/attic-b2fix2-ds/report-seg3.md (file
  sha256 27ddfc699b1d70d565855bd32b70888e49423a7fbae493bcf856f8332127ab27).
  No automatic unlock attempted; clean shutdown (LOCK_ABSENT,
  PROCESS_ABSENT).

Remaining unverified (explicit, not a pass):
a. S5 text resize by pointer drag - NOT ACHIEVED across 3 segments
   (multi-approach evidence recorded); resize semantics unmeasured.
b. S6 valid-import retry through the retry affordance (GoTo-field route
   failed on input; recents-row route planned, not run).
c. Segment-3 checkpoints T1-T5 (continuation list in report-seg3).
d. Other panel-window text views' window-manager redo channel - no code
   change without a natively reproduced defect.

Transport/harness events (continued closeout): one screen lock ~13:53Z
(segment 3; no unlock attempt); segment 2: 4 transient noWindowsAvailable
(recovered), one stuck Edit menu (recovered via Cancel), 4 rejected
cua.computer.drag shapes; segment 3: one display-name resolution failure
("Invalid app" while the app ran as PID 66018), then the lock.

Disk-space disclosure: the data volume hit 100%; ~7.6GB of OUR OWN
prior-batch /tmp build intermediates were deleted (69 explicit paths,
inventory-first, documented in ledger [disk-space-unblock]); both frozen
snapshots, all reports, fixtures, /tmp/attic-b2-opus-scratch, and all
stores verified intact.

REQUIRED USER ACTION: the Mac's screen locked again at ~13:53Z; unlock it
manually before any further desktop work (no automatic unlock was
attempted).

Boundaries maintained: no commits, push, merge, release, or security/TCC
changes; Daily (com.taha.Attic) and all stores untouched; inherited dirty
work preserved (191 entries); **no promotion claim** - D1 is fixed with
one native verification segment behind it; the remaining items above are
open.

## 11. Final closeout (segments 4-5 + user manual UAT, 2026-09-16)

Batch 2 closeout is CLOSED with the three evidence classes separated.
Status correction carried explicitly: an earlier interim message labeled
this closeout "COMPLETE" while S5/S6 and the segment-3 checkpoints were
still open; the corrected final status is recorded here.

AGENT-NATIVE (DeepSeek live tester, harness turn_context-verified; no
rebuild - the verified seg3 bundle was relaunched with pre/post binary
and dylib hash matches in both segments):
- Segment 4 (Boyle, 17m24s of the 20-min cap): T1 PASS - fresh 0-item
  canvas: toolbar Undo DISABLED; the inert click produced no error and
  zero changes anywhere (AX-verified; per-process history semantics
  observed). T5/S6 PASS - corrupt import produced the verbatim banner
  ("Import complete 1/1" + "Image 1: The dropped item is not a supported
  image or is corrupt." + "Choose Failed Files Again...") with the canvas
  unchanged at 1 item; the retry affordance reopened the Open panel in
  /tmp; the valid fixture was imported via the recents-row route (no
  GoTo); canvas 2 items, image object "160 by 160, center 0, 0" added,
  banner cleared. Report /tmp/attic-b2fix2-ds/report-seg4.md (sha256
  eed6184740f481157ad3f34e37f0acb8dc3db9298ee439c012d1e468d9da03ff); 8
  screenshots archived (seg4-01..08).
- Segment 5 (Feynman, ~7m45s active UI; DISCLOSED: the user-requested
  5-minute cap was exceeded by ~2m45s because the pass was already in
  flight; no hard-kill control): T3 PASS - reopened editor: typing " x"
  enables Undo; cmd+z reverts the draft one step (Undo disabled, Redo
  enabled); cmd+shift+z restores the draft; object intact. T2 DEVIATION
  (verbatim AX): with a confirmed live focused draft the app Edit menu's
  plain Undo/Redo items read disabled twice ("4 (disabled) Undo, ID:
  undo:" / "5 (disabled) Redo, ID: redo:"); the plain-menu route is not
  reachable for draft undo/redo. Draft undo/redo IS verified via
  cmd+z/cmd+shift+z (T3) and the toolbar (segments 2-3). A
  draft-commit-between-calls harness quirk was logged; NO defect claim.
  Report /tmp/attic-b2fix2-ds/report-seg5.md (sha256
  0fa3e17b800f7615de073395e9f1d48c01b752698ecb1ca04d28a2f4c37abb24) +
  seg5-ax-evidence.txt (sha256
  a72bbd9603a84c3bcb6b7b872c3ba30a8aac8574af44811738a1c0f7d07819dd); 3
  screenshots archived (seg5-01..03).
- S5 pointer-drag: automated pointer routes NOT ACHIEVED across segments
  1-4, reclassified per delegation as a HARNESS TARGETING LIMITATION, not
  an app defect: app.drag proven window-local (harness error evidence);
  an interior drag moved the object exactly (control -60,-30); all four
  corner-handle presses hit-tested as background for the observed text
  object; only 4 corner circles render (no edge handles to try);
  positional-array cua.computer.drag rejected at harness level verbatim.
  Resize semantics WERE measured agent-side via the labeled AX proxy:
  "Make larger" grew the frame 166.0x47.5 -> 182.5x51.4 pt (center
  unchanged) and one undo restored exactly (seg4-t4c-before/after/undo
  evidence).

USER-MANUAL (separate class; NOT agent-captured): the user reports
personally resizing the text box. Exact-build provenance is QUALIFIED -
the foreground app/bundle of the user's manual action cannot be
established from existing evidence. Recorded as user-reported manual UAT.

TECHNICAL (unchanged, source-applicable): Opus fixes F1-F6 with
verification numbers and reviews R1c/R2c REVIEW_PASS (section 10) remain
applicable - no source changes occurred, verified by unchanged 7-file
fingerprints across segments 3-5.

DISCLOSED RESIDUALS (recorded as closeout decisions, not passes):
a. Plain Edit-menu Undo/Redo enablement with live drafts: items observed
   disabled twice with a live draft (T2 DEVIATION, verbatim AX evidence);
   keyboard cmd+z/cmd+shift+z and toolbar routes verified working; NOT
   routed to implementation absent a concrete defect decision by Astra.
b. User-manual resize UAT exact-build provenance not established.

CLOSEOUT STATUS: Batch 2 closeout CLOSED. All segment-3 checkpoint items
are addressed: T1 PASS, T3 PASS, T5 PASS, T2 deviation recorded, T4/S5
resolved via user-manual UAT + agent-side AX proxy + harness-limitation
disclosure. **No promotion claim**; release readiness remains Astra's
decision.
