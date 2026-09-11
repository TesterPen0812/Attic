# Hover + pinnable subtasks: fix-round verification ledger

Branch `codex/attic-hover-pinned-subtasks`, fix round on top of `1464ddb`
(the test-only compile fix over feature commit `23ede87`). This ledger covers
the R1–R7 review findings: cause, fix, regression coverage, actual check
result, and the residual native UAT that remains for macOS execution.

Legend: **UNRUN** = not executed in this environment (no macOS/Xcode on the
cloud VM); source-reviewed only. **SCRIPT-VERIFIED** = checked by a repo script
or static analysis run on this box. **NATIVE-UAT** = requires the installed
macOS build to confirm.

| # | Finding (cause) | Fix | Regression coverage | Actual result | Residual native UAT |
|---|-----------------|-----|--------------------|---------------|---------------------|
| R1 | `.subtaskComposer` was derived in `PanelUIState.interactionLockReasons` from *any* draft/focused entry — including drafts inside the independent pinned window and drafts retained after dismissal — so pinned/hidden work held the main panel against auto-hide. | Removed the derived reason; the controller now owns `.subtaskComposer` as a managed lock engaged only while the *transient* surface is open for the drafting/focused family (`syncComposerLock`, driven by `subtaskDrafts`/`focusedSubtaskParentID` sinks + `syncState`). Pin, close, focus loss, main hide/reopen and section switches all release it; pinned work never takes it. | `SubtaskPanelControllerTests`: transient draft locks while open, retained draft after dismissal does not, pinned surface draft/focus never locks, focus-open transient locks then releases on close, main hide releases, section switch with draft releases. `SubtaskTests.testSubtaskDraftSurvivesSurfaceDismissalWithoutLockingMain` updated to the new semantics. | SCRIPT-VERIFIED (regen + static); tests UNRUN | On device: draft in pinned window, move pointer away — main auto-hides; close pinned — stays hidden-normal; hide/reopen main — no stuck lock. |
| R2 | `openTransient` refused the pinned family silently; the controller still replaced the transient's hosted content, producing a window whose family disagreed with lifecycle state. | `openTransient` returns `Bool` and the controller never presents a transient for a pinned family; opens for the pinned family route to `raisePinned` (deminiaturize + order front + optional entry activation), leaving any other transient's family untouched. | `SubtaskPanelControllerTests`: open-for-pinned leaves transient family/state consistent; toggle-on-pinned raises without swapping. | SCRIPT-VERIFIED; UNRUN | Pin A, open B, invoke A's Show subtasks — A's pinned window raises and (when requested) its entry focuses; no duplicate A surface. |
| R3 | Child rename text lived only in a row's `@State`; promoting or swapping the surface rebuilt the row with an empty draft, and hover replacement ignored an in-flight edit. | Rename draft hoisted to `uiState.editingDraftTitle` (seeded by `beginEditing`, cleared by `endEditing`); the field binds it directly so host replacement resumes mid-edit. `surfaceInteractionBusy` (rename/confirmation in the family, or any tracked menu) defers hover-pending opens, explicit other-family opens, and same-family toggle-close. | `SubtaskPanelControllerTests`: hover switch deferred while a child is being renamed, explicit switch deferred during delete-confirmation, toggle-close deferred, draft survives pin→unpin round-trip. `SubtaskTests`: draft seeded/cleared and survives a failed save. | SCRIPT-VERIFIED; UNRUN | Type half a rename, pin/unpin and hover another family — text resumes; complete a rename after a failed save. |
| R4 | Every outside mousedown dismissed the latched surface, including clicks on the surface's own context menu (`.popUpMenu` windows), sheets, or while an in-family confirmation/menu was active. | `noteOutsideMouseDown` now returns early for clicks inside the frame, on the surface/its sheets, on menu/status-bar windows, and while `familyEditBusy` or `menuTrackingActive`. The toggle-suppression pairing is also narrowed from the whole row to the count control's own frame so a same-row dismissal can't swallow the next deliberate toggle. | `SubtaskPanelControllerTests`: menu-tracking sets the busy gate; `familyEditBusy` covers child/parent IDs. Event.window/menu-window branch coverage is native-only (no menu windows constructible in unit tests). | SCRIPT-VERIFIED; UNRUN | Right-click a child, choose from the menu; open delete confirmation and click its Cancel; click a truly unrelated window — surface dismisses only in the last case. |
| R5 | Growth resize applied `framePreservingTop` raw — a growing checklist could extend below the display, and header/error/entry changes weren't reliably re-measured. | `refreshSurfaceSizes` now handles transient (re-anchored `repositionTransient`) and pinned (`pinnedResizedFrame`: host screen by center→intersection→first, top-preserving, `constrainedFrame` clamp) paths; it's driven by store revisions, `lastErrorMessage`, and entry-activation sinks, so child/error/entry changes re-measure and re-clamp. | `SubtaskPanelControllerTests`: growth below a display edge clamps inside the safe area; growth taller than the display shrinks to fit. `SubtaskPanelTests` placement suite still covers initial-show clamping. | SCRIPT-VERIFIED; UNRUN | Near the bottom edge, add long children / trigger an error row / activate entry — every control stays reachable; check a second display. |
| R6 | The entry was a permanent text field; the plus was a disabled submit; Escape only defocused (keeping draft+focus, feeding R1); the transient surface had no Escape dismissal once not editing. | Deliberate entry state `subtaskEntryActiveIDs` on uiState: `+ Add subtask` affordance activates/focuses; Enter saves and stays open for chaining; `.onExitCommand` calls `cancelSubtaskEntry` (deactivates + drops draft). Focus loss, pin/unpin, hides preserve active entry + draft. `SubtaskSurfacePanel` now gives both surfaces a window-level `keyDown` Escape (`onEscape` → dismiss), deferred to the field editor while one is active. | `SubtaskTests.testSubtaskEntryStateLifecycle`; UI test rewrites: affordance appears after Escape-cancel, reopens/focuses on click, defocus+outside-click preserves draft. | SCRIPT-VERIFIED; UNRUN | Escape inside entry cancels; Escape with no field editing dismisses the window — both surfaces; focus loss keeps the draft; pin keeps entry state. |
| R7 | Pinning a second family silently replaced the existing pinned window — an unexplained swap of someone's live checklist. | The pin control is now explicit: when another family owns the pin it shows `pin.fill` in the accent color, help "Replace the currently pinned list", accessibility label "Replace pinned subtask list". Drafts and in-flight edits on both families survive (state in uiState); edit-busy blocks accidental swaps mid-interaction. | `SubtaskPanelControllerTests`: replacement keeps both families' drafts; pinned family moves with no transient for the new family. | SCRIPT-VERIFIED; UNRUN | With A pinned, open B and press pin — control advertises replace; confirm A's pinned window closes only on that deliberate press and A's draft persists. |

## Polish / docs

- Subtle presentation: surfaces fade in (`alphaValue` 0→1 via the window
  animator) unless Reduce Motion is on; pinned surface reuse keeps alpha at 1.
  No genie import — the separate main-panel animation branch is untouched.
- Count control now reports "Hide subtasks" while its family is presented and
  carries an `isSelected` trait for VoiceOver.
- README updated (chevron/collapsible wording removed; hover/pin/replace
  documented). Handoff spec remains the design source.

## Review round 2 — dedicated adversarial reviewer (session `dbe59721`)

A separate Devin reviewer audited `23ede87..c59e4e5` against the handoff and
the R1–R7 claims. All seven fixes verified; it filed 14 findings. Resolution:

| # | Severity | Verdict | Resolution |
|---|----------|---------|------------|
| 1 | P2 | Fixed | `openFamilyPanel` rejected-open path now raises the surface and honors `focusEntry` — repeated "Add subtask…" on an open family works. |
| 2 | P2 | Fixed | `releaseFamilyInteractionState(_:)` runs on every teardown (transient close, pinned close/unpin, Cmd-W, scroll-out, tearDown) — orphaned `taskEditing`/`taskConfirmation` locks can no longer hold the main panel. |
| 3 | P2 (suspicion) | Fixed proactively | Explicit opens now gate on `familyEditBusy` only — a menu's own tracking lock can never eat its menu command. menuTracking still defers pointer-driven paths only. |
| 4 | P3 | Fixed | Hover-enter always schedules; `commitPendingOpen` re-arms via `rearmPendingOpen` while busy — resting pointer opens once the interaction resolves. |
| 5 | P3 | Fixed (residual noted) | Suppression TTL tightened to the click's down→up span (0.3 s) and cleared on every successful open; a stale record can still only affect a same-family toggle inside 300 ms — native UAT to confirm no user-visible residue. |
| 6 | P3 | Fixed | Pointer-leave retry now consults `shouldDeferPointerClose` (surface-owned locks only) instead of global `isInteractionLocked`. |
| 7 | P3 | Fixed | `unpinPinned` skips the transient restore while another family is edit-busy (pinned simply dissolves); `pinFamily` refuses replacement while the displaced family is mid-edit and releases its state otherwise. |
| 8 | P3 | Fixed | `orderSurfaceFront` skips the fade when the surface is already visible. |
| 9 | P3 | Fixed | `setPinnedFrameProgrammatically` suppresses `windowDidMove` persistence during clamps/resizes — position memory only records user drags. |
| 10 | P3 | Fixed | One containment predicate (`containsTransientPoint`) shared by auto-hide coverage and outside-dismissal, extended with the panel↔surface corridor so gap travel counts inside for both. |
| 11 | P3 | Fixed | Count control announces "Reveal pinned subtasks" (no `.isSelected`) when the family's surface is the pinned window. |
| 12 | P3 (suspicion) | Fixed proactively | `pinFamily`/`unpinPinned` re-bump `focusSubtaskEntry` when the family was focused — refocus survives either resign/onAppear ordering. |
| 13 | P3 | Fixed | Removed duplicate didMove/didResize observers in `attach()`; the main panel's delegate path is canonical. |
| 14 | P3 | Partially fixed | Geometry caches now prune on store revisions. Acknowledged: surface error row reflects the global `lastErrorMessage` (store errors carry no provenance); very short displays (<~200 pt usable) can still clip header+entry — extreme edge, documented here rather than chased. |

New controller tests cover: same-family re-open activating the entry,
teardown lock release (transient/pinned/confirmation), unpin re-anchor keeping
the edit, hover re-arm while busy then open, unrelated locks not deferring
close, unpin not evicting a busy surface, pin-replace refusal while busy and
success when idle.

## Checks actually run in this environment

- `ruby Scripts/generate_project.rb` — project regenerated; new controller
  test file globbed into AtticTests.
- `ruby Scripts/verify_project_generation.rb` — reported current/repeatable.
- Static consistency sweep of all touched files (balanced delimiters,
  call-site/parameter agreement, stale references removed).

## UNRUN — macOS acceptance checklist (not passes)

- `xcodebuild -scheme Attic build` and `xcodebuild test` (AtticTests:
  `SubtaskPanelTests`, `SubtaskTests`, `SubtaskPanelControllerTests`,
  `PanelGeometryTests`; AtticUITests `testCompactComposerAndSubtaskPanels`).
- Hover dwell (300–400 ms) open; pointer travel across the row→panel gap;
  close-grace timing; anchor disappearance on scroll.
- Outside-click matrix: unrelated window dismisses; menu/sheet/count-control
  clicks do not; a second family switch is deferred while editing.
- Escape matrix: in-entry cancel vs. window dismissal, transient and pinned.
- VoiceOver/Full Keyboard Access over affordance, entry, pin/replace, unpin,
  close; Reduce Motion suppresses the fade.
- Pinned window across main hide/reopen/space changes; multi-display clamp.
