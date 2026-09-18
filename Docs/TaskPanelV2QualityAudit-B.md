# Task Panel V2 — Quality Audit B (native/rendered, partial)

Audit date: 2026-09-13. Worktree `/Users/taha/Developer/attic-task-panels-v2`,
branch `codex/attic-task-panels-v2`, HEAD `ae6418c1`. Read-only pass: no
source/test/build changes. Evidence under `.build/quality-audit/b`.

This audit was stopped mid-pass at the user's request. Findings are separated
into confirmed native observations, hypotheses, interrupted/unreliable trials,
and untested states. Source support alone never earned a Pass.

## Preview identity (verified)

- `com.taha.Attic.taskpanels.v2` / `AtticTaskPanelsV2`, verified via
  `Scripts/launch_local_preview.zsh --verify` — launchd-owned (parent 1),
  mapped on-disk executable SHA-256 `aa400886…`, mapped debug dylib
  `dba63f07…`. Real current code, not a stale process.
- Original PID 38614; relaunched mid-audit to PID 27891 (identical binary
  hashes, verified again) after the app entered the degraded state in
  Finding B. "Fresh-state" results are from 27891.
- Input method: genuine CGEvent moves/clicks/scrolls at `.cghidEventTap`,
  phased continuous scroll for the two-finger gesture, AX queries,
  CGWindowList onscreen flags, `screencapture`. No synthetic test seams.
- Pointer contamination note: unexpected pointer movement observed during the
  session was the **user's own input** (confirmed), not another reviewer.
  Affected runs are marked below.

## A. Confirmed native observations

1. **Permanent blue ••• on every row at rest (visual defect).** Every task
   row — and every subtask row in a pinned panel — renders a blue ellipsis
   with no hover, pointer elsewhere, fresh process. AX shows zero
   `task-actions-*` elements at rest, so the affordance is functionally
   inert but its pixels render anyway. `TaskRowView.swift:368` gates the
   glyph with `.opacity(0)`; the `.menuStyle(.borderlessButton)` accent tint
   apparently renders through regardless.
   Evidence: `evidence/revealed-fresh.png`, `evidence/pinned-moved.png`,
   `evidence/panel-now.png`, `evidence/row-hover-now.png`.

2. **Neutral (childless) row hover highlights only.** Hovered "kjbkjk" 2.6 s:
   `task-actions-*` appeared (hover registers), no panel opened. Conforms to
   Section 13's stricter wording for neutral rows.

3. **Family rows still hover-open.** "Batch 3" (0/3 subtasks) opened a
   transient after ~0.44–0.55 s of resting hover (`openDwell=0.35` +
   presentation). Confirmed on both processes.

4. **Corridor travel works on a healthy process.** 250 ms and 700 ms
   row→panel pointer travel kept the transient alive; instant arrival kept
   it; leaving to empty space dismissed in 0.195 s.

5. **View switch works.** Real click on `subtask-view-switch-*` swapped
   Subtasks→Attachments instantly; panel refit 120→136 pt; controls became
   "Add attachment" + "Show subtasks". Evidence: `attachments-view.png`.

6. **Two-finger dismiss works.** A continuous horizontal phased scroll inside
   an unpinned transient dismissed it ~0.5 s after gesture end; the identical
   gesture on the pinned surface was ignored.

7. **Pin/drag/persist/raise work.** `subtask-pin-*` produced an independent
   window; native drag moved it (1186,276)→(836,176) and position held; the
   source row showed "Panel pinned"; pressing it raised the pinned panel;
   hover did not duplicate. Unpin produced a detached latched transient in
   place (per design).

8. **Phantom "Add Attachment" open panel (confirmed stuck).** An NSOpenPanel
   appeared in CGWindowList and AX (Cancel/Attach buttons enumerable) but was
   ordered offscreen/invisible and unresponsive to AXPress-Cancel and Escape.
   While present it held `taskAttachmentPickerOwnerID`, which disables every
   "Add attachment" affordance (`TaskImageAttachments.swift:65-69`) and
   injects `.taskConfirmation` into the interaction locks
   (`PanelUIState.swift:73-76`). A click on a subpanel's enabled-looking
   "Add attachment" produced no picker and the panel closed.

9. **Degraded interaction state (confirmed symptoms).** After the pin → drag
   → unpin → detach sequence on PID 38614: row hover stopped registering
   (no `task-actions`, no pending opens) while clicks still opened panels; the
   main panel's AX content tree intermittently showed only a stuck HelpTag
   while rows still rendered; a 272×246 surface flickered between
   onscreen/offscreen in CGWindowList and in/out of AX; a "Batch 4"
   attachments panel rendered on screen while absent from AX. All cleared on
   relaunch. Evidence: `ghost-panel.png`, `pinned-moved.png`,
   `after-hscroll.png`.

10. **Performance (bounded, active states).** Corner reveal: 0.405 / 0.321 /
    0.327 s. Hover-open: ~0.55 s. View switch: sub-frame. Leave-dismiss:
    0.195 s. Idle CPU with UI active: ~0.54 % avg / 0.60 % max; `sample`
    showed the main thread parked in `mach_msg` with the CornerHoverMonitor
    cadence timer — no hang.

## B. Hypotheses (observed + plausible mechanism, not fully proven)

- **H1 — detached zombie blocks hover-open.** While `isTransientDetached`
  stays set on a surface that is no longer visibly presented,
  `SubtaskPanelLayout.swift:520` (`guard !isTransientDetached`) rejects every
  `noteRowHover` enter — matching the observed "hover dead, clicks fine"
  state. Whether the zombie is cause or symptom of the wedge is unresolved.
- **H2 — picker deadlock root cause.** `panel.begin` presented while the app
  is non-activated appears to order out without completing, leaving
  `taskAttachmentPickerOwnerID` set forever: Add-attachment silently dead,
  panel held open. Reproduction path not isolated.
- **H3 — felt sluggishness.** The degraded state (hover silently dead,
  undismissable invisible picker, ghost surfaces) is a plausible source of
  the user-reported "laggy/broken" feel more than raw CPU/frame cost —
  measured idle CPU and per-action latencies were healthy.

## C. Interrupted / unreliable trials

- **Early corridor-travel failures** (~0.35–0.8 s closes, incl. a 5 pt in-row
  move) occurred during the degraded state AND overlapped the user's own
  pointer movement — not reliable as defect proof. Fresh-state travel passed.
- **Detached-panel gesture test** — the surface had already closed before the
  gesture ran; inconclusive.
- **Reveal first-attempt miss** — one corner entry produced no reveal within
  ~5 s; subsequent entries measured ~0.33–0.4 s. Idle cadence (1 s + 250 ms
  leeway) allows a worst-case ~1.45 s reveal; not re-tested.
- **AXPress on `subtask-view-switch`** returned -25205 (cannotComplete);
  only pointer clicks actuate it.
- **axwait/axchildren helpers** intermittently returned empty or trapped on
  deep AX elements; timing for the second hover-open was lost to this.
- **Scroll/picker/cards latency matrix** — interrupted before bounded
  numbers were collected; only qualitative "scroll works" is claimed.

## D. Untested states (no evidence collected)

- Composer paperclip picker, pending attachment cards, pending-card removal.
- Attachment card interactions: Quick Look, Open, Remove, drag-out; fresh-card
  entrance; import reveal.
- Task completion toggle, rename, context-menu actions, row reorder drag.
- Panel section switching (Tasks/Notes/etc.), composer text entry.
- Appearance settings variants; Reduce Motion; increased contrast; light
  theme; FKA/VoiceOver traversal; clipped-title keyboard-focus disclosure.
- Hardware-trackpad confirmation of the two-finger gesture (synthesized
  phased scroll exercised the real path, but physical verification remains).

## Section verdicts

| # | Section | Verdict | Note |
|---|---------|---------|------|
| 1 | Main task panel | Partial | Reveal/render/scroll/auto-hide verified; sections & edge cases untested |
| 2 | Task-row actions | Fail | ••• rendered permanently at rest; menu contents untested |
| 3 | Task subpanel | Partial | Opens/presents correctly; instability under degradation |
| 4 | Subtasks↔Attachments | Pass | One clean sample, instant refit |
| 5 | Dynamic sizing | Partial | Refits observed (120→136 pt, wrap); matrix untested |
| 6 | Attachments view | Partial | Layout matches reference; cards seen; interactions untested |
| 7 | Hover/interaction | Partial | Healthy-state correct; wedge + S13 wording conflict |
| 8 | Dragging/movement | Partial | Pinned-window drag verified; row reorder untested |
| 9 | Pinned subpanel | Pass* | All checks passed; *unpin→detach preceded the zombie state |
| 10 | Two-finger dismissal | Pass | Transient dismissed; pinned ignored; one inconclusive run |
| 11 | Composer attachments | Untested | Picker deadlocked; path never exercised |
| 12 | Appearance settings | Untested | Settings window exists; variants not run |
| 13 | Visual hierarchy/polish | Fail | Permanent •••; family hover-open vs literal S13 flagged |
| 14 | Regression | Partial | Real defects found (Finding B chain); no suite run |
| 15 | Evidence | Met | For tested items; untested items marked, not Passed |

## Section 13 conflict (flagged, not reinterpreted)

The checklist's "neutral task-row hover only highlights the row" is satisfied
by childless rows. Family rows with children still open a transient on
resting hover — intentional in source (`TaskFamilyView` gates on
children/drafts/entry, `openDwell=0.35`) but a literal reading of the newer
wording could forbid it. Needs a human decision on intent.

## Unrequested changes made by this audit

- Preview process relaunched once (identical verified binary; isolated store,
  official store and user data untouched).
- Created `.build/quality-audit/b/` (evidence + helper binaries) and this
  report. UI lock `/tmp/attic-exclusive-ui.lock` released at end.
- No source, test, project, or build-input modifications.
