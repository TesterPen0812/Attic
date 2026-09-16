# Batch 2 Native Computer-Use Trial — Results and Side-by-Side Comparison

Orchestrator evaluation of the Astra-steered matched trial. Frozen checklist
and rubric: Docs/Batch2-Native-Trial-Checklist-Rubric-2026-09-16.md. Order
(randomized, recorded): Sol first, DeepSeek second; sequential under
/tmp/attic-native-ui.lock; the three earlier differently-configured attempts
remain unscored context.

## Identity basis (corrected by post-acceptance audit; see Amendment 1)

- **Recorded harness configuration is authoritative; agent self-description
  is not.** The persisted turn_context records for the two exact trial
  agents record: 01a0a842-24b5-78e0-be17-8403b2f5c85b (Ampere) = model
  **gpt-5.6-sol, effort low** (2026-09-16T03:28:24.967Z); 01a0a84c-1ea3-
  7480-a590-4ceaac734c87 (Locke) = model **ollama-cloud/deepseek-v4.1-flash,
  effort max** (2026-09-16T03:39:18.261Z). Both legs ran under their pinned
  harness configurations.
- The earlier claim that the sol override "did not take effect" and that the
  leg "actually ran glm-5.3-flash" is RETRACTED (original text preserved in
  Amendment 1). Both agents carry identical base-instruction boilerplate
  ("You are a coding agent powered by the glm-5.3-flash"); Ampere echoed that
  boilerplate, while Locke echoed its brief's model line. Self-reports are
  instruction echoes, not runtime-identity evidence, and serving weights are
  not independently established for EITHER leg.

## Side-by-side results

| Dimension | Sol leg (pinned gpt-5.6-sol low) | DeepSeek leg (ollama-cloud/deepseek-v4.1-flash, max) |
|---|---|---|
| Recorded harness configuration (turn_context-verified) | gpt-5.6-sol, effort low (03:28:24.967Z) | ollama-cloud/deepseek-v4.1-flash, effort max (03:39:18.261Z); serving weights not established for either leg |
| Preflight (read-only cua check) | PASS | PASS |
| Agent id / nickname | 01a0a842-24b5-78e0-be17-8403b2f5c85b / Ampere | 01a0a84c-1ea3-7480-a590-4ceaac734c87 / Locke |
| Report | /tmp/attic-b2trial-sol/report.md (sha256 578c68153e5437fcf1306e351ebf7bd4c60a5a8a893bbbe90bbad47ade4c4988) | /tmp/attic-b2trial-ds/report.md (sha256 acd95b274bb1785cd5c6a933bce647100973523726d6d05a191d2666ef2c559b) |
| Active time / tool calls (transcript-exact) | 51 computer-use + 9 shell = 60 calls; 03:28:30Z→03:36:14Z (~7.7 min, within budget) | 91 computer-use + 12 shell = 103 calls; active UI 03:41:05Z→04:05:38Z (~24.6 min, ~4.6 min OVER the 20-min budget; agent self-declared stop 03:52:56Z then kept driving ~12.5 more min; last tool call 04:08:19Z) |
| Reaching Canvas through live UI | **Failed** (did not discover any navigation path; hovered dock hidden in AX, no Cmd+digit discovery) | **Solved** (discovered cmd+4 empirically via the section switcher) |
| S1 (15) D1 chrome coherence | BLOCKED (unreached) | **TESTED, PRODUCT CHECK FAILED** — confirms the disclosed R2b F1 residual live: enabled-but-inert toolbar at fresh-editor edit entry over non-empty history (setup + first observation ~25 s before cutoff); decisive inert-click controls landed 0.6–1 min PAST cutoff. Successful testing of a real D1 product failure — not an agent-capability zero |
| S2 (20) D2 live enable while typing | BLOCKED (unreached) | **20/20 PASS** — typing enabled toolbar Undo with no other action; toolbar Undo reverted typing; item count unchanged; Cmd-Z equivalence |
| S3 (20) Undo/Redo routing | BLOCKED (unreached) | **20/20 of EXECUTED sub-claims (all within budget)** — toolbar (7), Add-menu (7), keyboard-editor (6); keyboard-driven canvas history after commit NOT EXECUTED (never attempted; screen lock), so not scored |
| S4 (15) Commit/cancel/focus | BLOCKED (unreached) | Verified 1.5–2.5 min PAST cutoff — first commit (+1 history entry) ~64 s before cutoff; one-entry undo check, Escape cancel, app-menu agreement past cutoff; one unexplained plain-Redo divergence recorded (product observation); one clean recovery (+2) |
| S5 (15) Text resize | BLOCKED (unreached) | **NOT EXECUTED** — cua.computer.drag EXISTS in the documented control surface (post-audit doc inspection) but its usable call shape was never established in-run; the prior "no move-only pointer primitive / infeasible" claim is retracted (Amendment 1) |
| S6 (15) Image recovery | BLOCKED (unreached) | Tested 2.5–4.5 min PAST cutoff — corrupt import produced the exact failure banner + "Choose Failed Files Again..." affordance (AX evidence + screenshot 04:04:20); re-selection truncated by the screen lock |
| Primary score | NOT COMPARABLE — no quantitative winner | The prior "62/85 (~72.9%)" mixes within-budget and post-cutoff evidence and is superseded; see the corrected matched-budget conclusion below |
| Screenshots | none archived by the agent | none archived by the agent; **8 inline screenshot blocks preserved in the session transcript** (extracted post-audit to /tmp/attic-b2trial-ds/screenshots-amendment/, with timestamps incl. 03:56:11/03:56:22 S2 evidence and 04:04:20 S6 evidence); sol transcript holds 7 blocks (extracted likewise); AX transcriptions remain the primary behavioral evidence |
| Stop rule reached | No (3-failure threshold not its stop cause; navigation deemed unexposed) | Never reached; recoveries documented |
| Cleanup | Preview quit, lock released, nothing running | Preview quit, lock removed, nothing running |
| Interventions | None | None |

## Fairness notes (updated by Amendment 1)

- Identical brief except model identity line, private output paths, and
  assigned preview fixture values. No coaching, no hints from the other run,
  no source/docs reading (both instructed; peer dirs named generically).
- Cross-consistency check: both agents' AX descriptions independently match
  the orchestrator's own diagnostic observation of the same app surface
  (panel-section-picker exposing only the selected chip; identical Canvas
  element IDs and value formats), strengthening the reported evidence despite
  the missing archived screenshots.
- S5 was NOT EXECUTED by either leg. The ds leg found an undocumented
  Mac-wide target (cua.computer) mid-run but could not establish
  computer.click's accepted shape and never attempted drag. Post-audit
  read-only doc inspection (2026-09-16) confirms cua.computer exposes
  click, drag, scroll, select_text, set_value, type_text and more - i.e. a
  pointer-drag primitive exists in the documented surface. The prior
  "no move-only pointer primitive / infeasible for both legs" claim was an
  inference from failure-to-find and is RETRACTED.
- Budget compliance is NOT equal: the DeepSeek leg's active UI window was
  ~24.6 min against the identical 20-min budget (~4.6 min over), and every
  scenario observation came after the agent's own 03:52:56Z "time's up"
  declaration. Within-budget vs post-cutoff evidence is separated explicitly
  in the corrected conclusion; the sol leg finished within budget (~7.7 min).
- The screen lock (physical, end of DeepSeek's run) is a shared blocker for
  any further desktop work until manually unlocked; it is an infrastructure
  outcome, not a capability finding.

## Corrected matched-budget conclusion (Amendment 1)

- **No quantitative winner is drawn.** The prior 62/85-vs-0/85 comparison is
  invalid on two grounds: (a) the identity basis was wrong — recorded
  harness configurations are authoritative (gpt-5.6-sol low /
  ollama-cloud/deepseek-v4.1-flash max) and serving weights are
  unestablished for both legs; (b) the DeepSeek leg's scenario evidence was
  collected up to ~4.5 minutes past the identical 20-minute budget, so
  full-overtime evidence cannot be scored as an equal-budget result.
- **Within-budget (20-min) evidence, DeepSeek leg:** navigation gate SOLVED
  (Settings-close reveals the panel; cmd+4 section cycler reaches Canvas);
  S2 fully verified (typing → live toolbar enable; toolbar revert;
  Cmd-Z/Cmd-Shift-Z equivalence); S3 editor routing verified on all three
  paths (toolbar, Add-menu, keyboard); S1 state reached ~25 s before cutoff
  (fresh editor over non-empty history, toolbar rendered enabled); first
  commit (+1 history entry) ~64 s before cutoff.
- **Past-cutoff evidence (same leg, qualified, not equal-budget scored):**
  S1 decisive inert-click controls (04:01:15–04:02:05), S4 verification
  (04:02:31–04:03:39), S6 entire run (04:03:39–04:05:13, truncated by the
  screen lock).
- **Sol leg:** recorded config gpt-5.6-sol low; completed within budget
  (~7.7 min) but blocked at the navigation gate (agent-side; Canvas IS
  reachable via cmd+4 per the orchestrator diagnostic). Serving weights
  unestablished.
- What the trial DOES support, within this one app: the DeepSeek leg
  produced genuine interactive evidence for D2 (typing → live toolbar
  enable, toolbar revert, Cmd-Z equivalence), editor undo/redo routing
  (toolbar/Add-menu/keyboard), single-entry commit semantics, Escape
  cancellation, and the corrupt-import banner + retry affordance; and it
  observed the disclosed R2b F1 residual live — successful testing of a
  real product failure, kept separate from agent-capability scoring
  throughout this document.

## Amendment 1 — post-acceptance audit trail (2026-09-16)

Recorded by the orchestrator after Astra's acceptance audit, with the
original erroneous claims preserved verbatim:

1. ORIGINAL (retracted): "gpt-5.6-sol could not be pinned... it compares
   deepseek-v4.1-flash (max) against glm-5.3-flash (low) mislabeled as the
   sol leg." CORRECTION: the persisted turn_context records for the two
   exact agent IDs record gpt-5.6-sol/low (Ampere) and
   ollama-cloud/deepseek-v4.1-flash/max (Locke). Both agents carry the same
   glm-5.3-flash base-instruction boilerplate; self-reports are instruction
   echoes. Serving weights remain unestablished for either leg.
2. ORIGINAL (retracted): "S5 was infeasible on this surface for BOTH legs
   (no move-only pointer primitive)." CORRECTION: cua.computer.drag exists
   (read-only member enumeration of the documented control surface,
   2026-09-16; no UI driving was attempted while the screen is locked). S5
   status is NOT EXECUTED, not infeasible.
3. ORIGINAL (superseded): primary score "60/85 + 2 recovery = 62/85
   (~72.9%)" and the sol "0/85" side-by-side. CORRECTION: evidence-at-cutoff
   audit shows the DeepSeek leg's active UI window ran ~4.6 min past the
   20-min budget (timer 03:41:05.609Z; last UI call 04:05:38.672Z; 103
   exact tool calls = 91 computer-use + 12 shell vs prior estimate
   "~55-60 + ~12"), with all scenario evidence gathered after the agent's
   own 03:52:56Z budget-stop declaration; scenario rows now distinguish
   tested-within-budget, tested-past-cutoff, and not-executed.
4. ORIGINAL (rescored): S1 "0/15 — FAIL". CORRECTION: the rubric's S1
   expectation encoded the mission's intended D1 behavior; the observed
   enabled-but-inert state is a PRODUCT failure (the disclosed R2b F1
   residual) found by successful testing, not an agent-capability zero.
   S3's 2-point deduction is likewise reframed: the keyboard
   canvas-history-after-commit sub-claim was NOT EXECUTED (screen lock),
   not failed.
5. Screenshots: no archived assets exist for either leg (agent-side gap,
   disclosed). 15 inline screenshot blocks (7 sol + 8 ds) are preserved in
   the session transcripts and were extracted post-audit with a timestamp
   manifest to /tmp/attic-b2trial-{sol,ds}/screenshots-amendment/.
