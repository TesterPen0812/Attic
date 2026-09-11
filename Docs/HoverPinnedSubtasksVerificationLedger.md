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

## Review round 3 — local adversarial review of `7535d00`

The cloud reviewer's pass-2 over `7535d00` was cut off mid-analysis; a local
read-only reviewer completed it (report: `.build/LocalAdversarialReview.md`)
and the local implementer independently reached the same four findings plus
one test-proven defect the first native run exposed. Resolution:

| # | Severity | Verdict | Resolution |
|---|----------|---------|------------|
| F1 | P2 | Fixed | `releaseFamilyInteractionState` was host-over-scoped: `belongsToFamily` matched the parent's own id, but the parent's rename field and delete alert live on the MAIN-list row (the surface hosts only child rows + display-only title). Every unguarded teardown (`closePinned`, `windowWillClose`, `unpinPinned` dissolve, transient Escape/scroll-out/`mainPanelDidHide`) discarded a live parent rename or dismissed its alert. Release is now child-keyed (`parentID == familyID`) only; the parent-scope stays in `familyEditBusy`, where it is the correct deferral predicate. |
| F2 | P3 | Fixed | Dying-host focus race: the old host's `isEntryFocused → false` `.onChange` could nil `focusedSubtaskParentID` after the pin/unpin re-bump (AppKit resign isn't synchronous with `orderOut`). Resign now routes through `noteSubtaskEntryResigned` gated by `isLiveSurface(for:mode:)` — only a live host clears the pointer. Two residuals also handled: a same-click pin/unpin resigns the field before its action, so `entryFocusEngaged` treats a resign within `entryResignReuseWindow` (0.5 s) as still-engaged; and `releaseFamilyInteractionState` now clears a stale `focusedSubtaskParentID` when the family's last surface dies (entry row + draft still survive; focus is not grabbed unprompted on reopen). |
| F3 | P3 | Fixed | Replace-pinned refusal while the displaced family is edit-busy was a silent no-op. The pin affordance now disables + dims with "Finish the pinned list's current edit first" help / VoiceOver hint while `pinReplacementBlocked`. |
| F4 | P3 | Fixed | `commitPendingOpen`'s anchor-nil/not-hoverWorthy branch was the only transient teardown skipping `releaseFamilyInteractionState`; it now routes through `closeTransientSurface()`. |
| F5 | P2 | Fixed | First-ever native test run exposed a willSet lag: `@Published` sinks for `subtaskDrafts`/`focusedSubtaskParentID` called `syncComposerLock()` which read the OLD stored values, so the `.subtaskComposer` lock engaged one change late and released one change late — the R1 mechanism never actually worked. Sinks now hand the just-emitted values to `syncComposerLock(drafts:focusedParentID:)`; `refreshSurfaceSizes` triggers (`$lastErrorMessage`, `$subtaskEntryActiveIDs`, `reconcileStore`'s re-fit) defer one runloop turn so the hosting view has applied the change, matching the `noteMeasuredListHeight` precedent. |

New controller tests cover: parent rename surviving pinned close and
main-hide-with-transient, parent delete-confirmation surviving pinned close,
child edit still released on unpin-without-anchor, live-surface ownership
across pin/unpin/dismiss, same-click resign refocus, aged resign not
refocusing, teardown clearing the stale focus pointer, and anchor-nil
maturation releasing the family's state.

Round-3 review loop converged: the spawned adversarial reviewer verified
F1–F5, found N1 (duplicate `.id("subtask-entry-…")` on the `+ Add subtask`
Button and entry HStack — fixed by giving the affordance
`.id("subtask-add-…")`), and returned **CLEAN** on `b245308`.

## Checks actually run

Cloud environment (`7535d00` and earlier):

- `ruby Scripts/generate_project.rb` — project regenerated; new controller
  test file globbed into AtticTests.
- `ruby Scripts/verify_project_generation.rb` — reported current/repeatable.
- Static consistency sweep of all touched files (balanced delimiters,
  call-site/parameter agreement, stale references removed).

Local Mac (this checkout, round-3 fixes on top of `7535d00`):

- `bundle exec ruby Scripts/verify_project_generation.rb` — current and
  repeatable (no project-input changes this round; existing files only).
- `xcodebuild test -scheme Attic -destination 'platform=macOS'
  -only-testing:AtticTests CODE_SIGNING_ALLOWED=NO` — **637 tests, 0
  failures, 1 skipped** (includes all 37 `SubtaskPanelControllerTests`,
  `SubtaskTests`, `SubtaskPanelTests`, `PanelGeometryTests`,
  `PanelSquircleGeometryTests`). The first native run also exposed F5:
  five lock tests failed at `7535d00` before the fix, all pass after.
- `xcodebuild build -scheme Attic -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED** (Local configuration).
  Note: default Debug signing wants a `Mac Development` cert for team
  ZGZWS73268 that is absent from this keychain; `CODE_SIGNING_ALLOWED=NO`
  covers local verification only — preview installs keep using
  `Scripts/launch_local_preview.zsh`'s ad-hoc path.

## Review round 4 — real interaction layer (local Mac, 2026-09-11 evening)

The user's report that the pinned panel accepted button presses but not body
interaction, text entry, or dragging turned out to be three separate
event-delivery problems, all found and fixed on this worktree.

| # | Finding (cause) | Fix | Regression coverage | Actual result |
|---|-----------------|-----|--------------------|---------------|
| I1 | `NSHostingView.acceptsFirstMouse` returns false, so the first click on the nonactivating panel was consumed by key-making and never reached content — first-click focus into the entry looked dead. | `SubtaskHostingView` (both surfaces) answers `acceptsFirstMouse` true. | UI: entry click, child toggle, and controls all exercised by the passing class. | XCUITEST-PASS |
| I2 | The header drag handle was a SwiftUI `.background` representable (`SubtaskWindowDragHandle`); NSHostingView hit-testing never descends into it — presses on empty header space resolve to the hosting view itself — so `performDrag` never ran and the window could not be dragged at all. | `SubtaskHostingView.mouseDown` calls `window.performDrag(with:)` when a press hit-tests to the hosting view inside the top 44 pt header strip (`dragsWindowFromHeader`, pinned only). Controls/fields keep their own presses. `isMovableByWindowBackground` is off — the explicit path only drags the header strip. The representable stays as the AX landmark (`subtask-drag-<id>`, "Drag window"). | `testPinnedWindowDragsAndRemembersPosition` — real press-drag moves the window by the asserted delta and re-pin restores the remembered frame. | XCUITEST-PASS |
| I3 | Entry refocus after pin/unpin/raise asserted `.focused` while the surface wasn't key — no-op on nonactivating panels; a dying host's late resign could also clear `focusedSubtaskParentID` after the re-bump. | `makeKey()` before every entry-focus assertion (raisePinned, openFamilyPanel focusEntry, pin/unpin refocus); `onChange(isEntryFocused)` focus claim gated by `isLiveSurfaceKey`; stale `isEntryFocused` cleared on appear. | `testPinnedWindowSurvivesAppDeactivation`, entry-focus flows across pin/unpin in the class. | XCUITEST-PASS |
| I4 | `commitPendingOpen` re-armed only on `surfaceInteractionBusy` — a live context menu's tracking lock didn't defer the pending open, so ordering a surface front mid-menu could tear the menu down. | Re-arm when `menuTrackingActive`; the busy branch widened to `shouldDeferPointerClose`. | Unit-covered earlier; UI class green. | XCUITEST-PASS |

Environment note discovered during I2: XCUI press-drags starting past
x≈1292 on this desktop never reached the app — a desktop overlay
(Supaste, layer-25 window spanning x 508–1292 with an edge activation
region) claims the press outside its visible bounds. Pressing the handle's
left stretch (x≈1212) delivers the full down→drag→up stream. Real pointer
input is unaffected — the overlay only intercepts during automation.

## UNRUN — macOS acceptance checklist (not passes)

Unit coverage ran locally (see above). Remaining manual/native items:

Executed locally on this worktree (Local config, ad-hoc signed UI runner,
`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` against the real desktop):

- `AtticUITests/SubtaskHoverPinnedUITests` — **9/9 PASS**
  (`.build/DevinHoverUI-full.xcresult`): hover dwell open/brief-hover
  rejection, pointer-corridor persistence, rapid family switch, pinned
  survival across app deactivation, header drag + remembered position
  restore, pinned count-control announce, busy-family replace disabled,
  Escape matrix (entry-cancel vs window dismiss, both surfaces), bounded
  height on a 12-child family.
- `AtticTests` — **635 pass / 0 fail / 1 skip**
  (`.build/DevinHoverUI/Logs/Test/Test-Attic-2026.09.11_18-40-22-+0100.xcresult`).
- `verify_project_generation.rb` — project current and repeatable.

Still manual/native-only (human pointer, not automation):

- Physical-pointer hover feel: dwell timing, corridor breadth, close grace.
- VoiceOver rotor/FKA walk over affordance, entry, pin/replace, unpin,
  close; Reduce Motion suppressing the fade.
- Pinned window across real Space switches and multi-display clamps.
- AtticUITests outside this class (main-panel, canvas, notes suites) —
  untouched by this branch but unverified here.
