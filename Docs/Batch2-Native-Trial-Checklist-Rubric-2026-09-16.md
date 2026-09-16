# Batch 2 Native Computer-Use Trial — Frozen Checklist and Rubric

Frozen before any scored run (2026-09-16 ~04:28 local, after three unscored
recovery attempts: two Synara codex-provider tunnel runs and one Sol-direct
subagent run, all NATIVE_PARTIAL/unverified — context only, not scored runs).

## Trial design record

- Models under trial: ollama-cloud/deepseek-v4.1-flash (effort max) and
  gpt-5.6-sol (effort low), both as Codex collaboration subagents with the
  same direct computer-use tool surface (prefer cua_repl-style observation +
  interaction).
- Order randomization: `RANDOM % 2` = 1 -> **Sol (gpt-5.6-sol) runs first**,
  DeepSeek second. Sequential under /tmp/attic-native-ui.lock; never two
  controllers.
- Fixture isolation: each run builds+launches its own preview identity
  (distinct bundle id / executable / DerivedData), giving each a fresh empty
  isolated store = the SAME documented starting state (fresh store, Tasks
  section frontmost). No personal or prior store is cleared or copied; between
  runs no reset is needed because each run's store is new; disclosed here as
  the equivalence basis (binaries differ only in bundle identity).
- Shared fixture: /tmp/attic-b2trial-corrupt.png, sha256
  400550e9a647b49b1ba4e3517f5456a97d35f18a1cbc410771b6254cfb612162 (96 bytes,
  PNG signature + garbage), identical path+hash for both runs.
- Peer blindness: private output dirs /tmp/attic-b2trial-sol/ and
  /tmp/attic-b2trial-ds/; reports written there, NOT in the repository;
  prompts instruct both agents not to read the peer directory or any repo
  docs/source. Orchestrator publishes only the consolidated comparison.
- Budget: 20 minutes active interaction + >=3 minutes final-report reserve,
  identical for both. Orchestrator records spawn/completion wall-clock.
- Identity evidence: spawn configuration + agent self-reported runtime
  identity. Known anomaly to resolve by the trial's own identity check: the
  unscored Sol-direct attempt self-identified as glm-5.3-flash despite the
  pinned gpt-5.6-sol override (recorded as a trial-integrity finding either
  way; the orchestrator cannot independently verify runtime weights and will
  not silently substitute).
- Differing text between the two prompts is limited to: model identity line,
  private output/report paths, and the assigned preview fixture values
  (bundle id, executable name, derived-data path) required for store
  isolation. The checklist body is byte-identical.

## Frozen checklist (embedded verbatim in both prompts)

S1 (15) D1 chrome coherence: make canvas content exist so canvas history is
non-empty; focus a text object's editor so the editor undo stack is empty;
verify toolbar Undo disabled, Add-menu Edit>Undo disabled, and the app-level
Edit menu agrees; Redo likewise where nothing to redo; canvas history unchanged
(item count before/after).

S2 (20) D2 live enable while typing: on an empty-history disposable canvas,
insert text and type several characters; WITHOUT any other action verify the
toolbar Undo (and Add-menu Undo) becomes enabled; click toolbar Undo and
verify the typing reverts in the editor while the canvas item count is
unchanged; then verify Cmd-Z equivalence.

S3 (20) Undo/Redo routing: (7) toolbar Undo/Redo drives the focused editor;
(7) Add-menu Edit>Undo/Redo drives the focused editor; (6) keyboard Cmd-Z and
Cmd-Shift-Z drive the focused editor, and drive canvas history after commit.

S4 (15) Commit/cancel/focus: (5) commit the edit per app behavior so canvas
history gains exactly ONE entry for the whole edit (one undo restores
pre-edit); (5) Escape during editing cancels the draft; (5) switch focus
between objects/sections and back; controls reflect the actual target and the
app Edit menu agrees.

S5 (15) Text resize: create a multi-line text object on a disposable canvas;
narrow it by pointer drag; after commit the text is fully visible (not
clipped); evidence = before/after screenshots.

S6 (15) Image recovery: import the provided corrupt fixture; the failure
banner should appear; click Retry; observe recovery (or record the observed
behavior honestly if different).

Omitted (record as such; no credit or penalty): physical-only gestures
(trackpad pinch etc.); board deletion.

Evidence rules: every scored claim needs directly observed UI state
(accessibility state and/or screenshots) before AND after the interaction;
screenshot existence alone is not behavioral proof; describe observations in
words as well.

Stop rule: hard stop after 3 separate UNRESOLVABLE control failures.
Stale-element or target-change interruptions that you successfully recover
from do NOT count toward the stop threshold (they are scored as recoveries);
a transport-class outage (e.g. tunnel unavailable) is an infrastructure
outcome, not a model capability failure. Permission/physical limits are
blockers, not passes.

Scope: no source or repository-doc reading, no unit tests, no patching the
app, no permission changes, no deleting any board, no touching any store
other than your own preview's fresh isolated store, no reading peer output.

## Frozen scoring rubric

- Primary (100): S1 15, S2 20, S3 20 (7+7+6), S4 15 (5+5+5), S5 15, S6 15.
- Adjustments: -10 per claimed pass lacking concrete evidence; -5 per
  materially false claim; +2 per documented recovery from an ordinary UI
  mistake (max +6); safety/scope violations reported separately (a material
  violation can void the run); time/tool efficiency used only as tiebreak.
- Partial credit only with concrete interaction evidence.
- Scenarios infeasible for BOTH are unscored for both and weights are
  renormalized; scenarios harness-blocked for one agent are unscored for that
  agent with the cause attributed to infrastructure, and any asymmetry is
  disclosed without capability penalty.
- Harness failures, agent mistakes, and product defects are separated.
- Recorded per run: elapsed time, approximate tool calls, interventions,
  screenshots, end states, honest unverified cases.
