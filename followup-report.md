# Combined-build follow-ups · 4 Nov 2026

`phase-3/pd-followup`, from `25c2e223`; app source `d70badc1`.

| Item | Cause → change | Evidence |
|---|---|---|
| Island surface | Both surfaces already used the same recipe. The supplied bare-native diagnostic renders 27 pt regular glass dark and 90 pt glass bright. Candidate: crop a panel-sized native material into the island, keeping its backing, tint and rim (`AtticMaterials.swift:805`, `PanelIsland.swift:795`). | Replaying the supplied SCK capture samples panel `(186,186,188.7)`, island `(61,61,61)`, max difference **127.7/255** (`.build/red-island-surface.log`). New 12-case SCK matrix **pending**; native equality is not yet established. |
| Notes switch | `PanelUIState.swift:227` discarded Notes. Retain its ordinary editor after the first visit; suspend native input, tables, Find, slash/menu/keyboard callbacks and focus while hidden (`NoteEditorHost.swift:902`, `NotesEditorPage.swift:316`). Keep the existing save/refusal/rollback/fresh-context boundaries. A Notes-origin task route still unmounts its controls and reuses its existing warm host/lease (`NotesPageHost.swift:22`). | Committed regressions precede fixes: `.build/red-notes*.log`, `red-card-and-notes-rollback.log`. Save, rollback/refusal, imported-context replacement, input/agent-lock release, hidden Find/library/table/slash and warm task-route checks pass. Independent Notes review completed. **Paired frame measurement pending.** |
| Notes / Calendar room | These pages ignored the shared card height. Reserve its measured height minus the replaced 27 pt bar; follow the new end only when already at the end (`ComposerPanel.swift:112`, `CalendarPage.swift:95`, `NotesEditorPage.swift:124`). Wait for native insets before scrolling. | `red-card-end-following.log` → `followup-clearance-native-order.log`: **29/0**; five repeats each of Notes/Calendar: **10/0** (`followup-clearance-order-repeat.log`). |
| Calendar Event | Date, length and calendar were squeezed into the same 90 pt row/card. Separate rows reuse the existing pickers/writer; **152 pt timed / 121 pt all-day** before writing grows. Task/Note remain 90 pt (`ComposerCard.swift:383`). | `red-event.log` → geometry and measured overlay-room checks pass; Composer suite **51 tests, 7 skipped, 0 failures**. Kind changes close pickers at the persistent card root (`red-event-picker-lifecycle.log` → `green-event-picker-lifecycle.log`). |

**Verification:** final Air full suite: **4,381 tests, 163 skipped, 195 assertion failures (3 unexpected), 19 failing methods**, zero invisible-host violations (`.build/air-followup-verified-full.log`). Case-by-case `.build/followup-baseline-comparison.json`: 18 baseline methods retain identical counts/signatures (canonicalizing unordered entitlement sets); hidden-page AX is resolved. **One additional method**, `PanelIslandTests/testAGenieRevealInANewCornerSnapshotsTheIslandThere`, failed six assertions after two hide-completion timeouts. Three isolated repetitions pass at both head and exact base `25c2e223`; both island suites pass **29 tests, 4 skipped, 0 failures** (`air-followup-island-{base,head}-suite.log`). Classification remains open: the no-new-failures gate is **not met**. All 13 follow-up regressions and both generated Notes command/navigation tests pass. Two stale combined-base island fixtures were corrected without weakening assertions (both green). Project generation/repeatability, capture type-check and shell syntax pass; canceled runs are not passes.

**Native/open:** guarded checks repeatedly found Simulator frontmost; no preview was launched or simulator touched. Await Air availability for the dark/light-backdrop × Glass/Frosted/Solid × Light/Dark SCK matrix, paired 12-switch frame run, and Notes/Calendar card UAT. Optimized local-only preview built cleanly at `d70badc1`: **Attic Follow Up**, `com.taha.Attic.preview.followup`, executable `~/Projects/attic/attic-air/.build/island-plus-dd-after/Build/Products/Local/AtticFollowUp.app/Contents/MacOS/AtticFollowUp`; provenance/hash in `.build/followup-preview-manifest.txt`. Native equality and frame improvement remain unverified.

**Outside panel files:** `CalendarPage.swift`; `Composer{Card,Panel}.swift`; `AtticMaterials.swift`, design changelog; Notes `NoteFormatControls.swift`, `NoteEditorEngine{,+Tables}.swift`, `NoteEditorTextView.swift`, `NoteTable{CellEditor,View}.swift`, `NoteEditorHost.swift`, `NotesEditorPage.swift`, `NotesLibraryView.swift`; seven test files; four `capture_followup_surface` / `verify_followup_*` scripts. No Calendar contract, Canvas implementation, signing identity or owner-store changes.

## Verification, 4 Nov

Measured the requested optimized `d70badc1` preview against the preserved `25c2e223` build; both are `com.taha.Attic.preview.followup`. Native Notes “+” then exposed FUP-N1, fixed and pushed at `06d6834a` after the committed red regression. The fix routes both Notes buttons through the existing `panelComposer`, preserving the current writing/library and standalone behavior. Native writing/library recheck: **PASS**; final Air Genie comparison follows below.

**Surface: PASS, 12/12 after.** SCK, uniform 0.06/0.94 backdrops, inactive panel + continuously awake island. Values below are maximum absolute RGB-channel differences between 3×3 means, /255. The pre-existing **12/255** threshold permits small native gradients/noise and geometric sampling differences (~4.7% channel range); every case must pass and the sheet must look consistent. Actual maximum after is **5.44**.

| Mode | Surface | Dark backdrop, before → after | Light backdrop, before → after |
|---|---|---:|---:|
| Light | Glass | 113.44 → 0.56 | 2.22 → 0.22 |
| Light | Frosted | 5.44 → 5.44 | 2.00 → 2.00 |
| Light | Solid | 0.44 → 0.44 | 0.44 → 0.44 |
| Dark | Glass | 51.00 → 0.33 | 1.78 → 0.89 |
| Dark | Frosted | 2.44 → 2.44 | 0.33 → 0.33 |
| Dark | Solid | 0.00 → 0.00 | 0.00 → 0.00 |

**Switches:** one paired 60 Hz run, twelve SIGINFO switches, 0.6 s windows, 1.2 s trigger spacing, recording stopped: **131 → 57 missed frames**. Notes **52 → 22**; other nine **79 → 35**. Cold/warm Notes breakdown:

| Notes visit | Missed, before → after | Worst gap ms, before → after |
|---|---:|---:|
| 1 | 29 → 14 | 409.92 → 196.89 |
| 2 | 12 → 4 | 128.37 → 78.30 |
| 3 | 11 → 4 | 159.16 → 73.38 |

**Card clearance:** rendered Notes writing and library ends each lift **63 pt** for the 90 pt card replacing the 27 pt bar. Calendar’s final seven-day agenda tile (10 Nov) lifts **125 pt** for timed Event (152 pt), **94 pt** for all-day (121 pt), then follows the **31 pt** height difference. Last items remain clear. Timed Event visibly has separate **Tomorrow, 10:00 / 1 h / Calendar** rows. Patched native Notes writing and library both open **New Note** via the actual “+”. Writing’s full AX document is unchanged; its last line moves y435.482 →372.482. Library’s last row moves y408.5 →345.5. Both are visibly clear of the card. Red/green regression also protects library state and current note UUID.

**Genie:** exact base **10/10 pass**, original head **10/10 pass**, zero invisible-host violations. Final head `06d6834a`: **7 pass / 3 fail**, with nine assertions: each hide timeout followed by two stale-corner snapshot assertions. All ten invisible-host canaries are zero. Fresh exact-base repeat: **10/10 pass**, total base **20/20** and head **17/20**. Thus the observed failure is **head-only / treated as new**, not established baseline flakiness. Diagnosis is in progress; the earlier no-new-failures gate remains open.

**Evidence:** `/Users/taha/Projects/attic/attic-redesign-assets/phaseX/panel-design/improvements-build/followup-verification-4nov/`: `surface-before-after-sheet.png`, `surface-closeups.png`, per-case RGB/order/alpha JSON and originals; `frame-summary.json` + raw frame/trigger logs; `card-notes-fixed-sheet.png` + `card-fixed/`, `card-calendar-sheet.png` + `card-original/`; red/green logs and final manifest. The original d70 Notes clearance used the Task diagnostic toggle; the final sheet uses actual Notes + and the Note card. Harness corrections enabled UI-test/in-memory mode, kept the island awake through capture, and separated Aqua UI launch from SSH-authorized SCK. Physical window order was checked; the Dock overlay was proven transparent at every sample. Resting-island and interrupted attempts are excluded. No privacy settings, owner store, simulator or iPhone worktree/process was changed.

**Fix checks:** committed red regression at `a0e4c200` (five assertion failures) → `06d6834a` green; seven focused neighbors green. Full `PanelChromeTests`: **34 tests, one skipped, zero failures**, 34 zero-violation canaries. Optimized Air build succeeded via wrapper; no local DerivedData folder was added. Canceled queued broad-suite run is not a pass.

**Preview / cleanup:** branch `phase-3/pd-followup`, patched source `06d6834a`, optimized **Attic Follow Up**, bundle `com.taha.Attic.preview.followup`. Final executable on Air: `/Users/taha/Projects/attic/attic-air/.build/followup-fixed-products/AtticFollowUp.app/Contents/MacOS/AtticFollowUp`; SHA256 `e409fb6b443b985ae40ffc58e69054db58aa890a258d140964a961001e6bb259`. Both native fixture PIDs exited; our lock was released. No remaining manual UAT for surfaces, page switching, or Notes/Calendar card clearance. Genie diagnosis and final test-job cleanup are pending. These local-only checks make no deferred-platform or sync claim.
