# Bugs three

`phase-3/pd-bugs-3`; baseline `8975832c`, tested source `c2e11c39` (last production edit `97f70562`). Optimized local-only Air preview: `com.taha.Attic.preview.bugs3`, executable `/Users/taha/Projects/attic/attic-air/.build/bugs3-runtime-c2e11c39/AtticBugsThree.app/Contents/MacOS/AtticBugsThree`. Identity/hash: `.build/bugs3-runtime-manifest-find.json`; private DerivedData avoids the shared-path collision.

- **Notes** (`NotesPageController.swift:1421`): saved writing falls back to the library; recovery, explicit New, last-open, warning/save/refusal/lease priorities remain. Earlier controller tests: 105/0; native five-note library verified.
- **Input** (`LoginItemService.swift:44`, `TaskNoteConversion.swift:376`, `AtticPanelController.swift:517`): background/coalesced status reads (main reads 2→0), exact-byte writing predicate cache (decodes 6→1; lifecycle admission uncached), reveal transaction publication (first raw routing misses→none, forward/reverse scans).
- **Find** (`AtticControls.swift:1194`): discovery services the current pending request. Native async reproducer red→green, including cancellation with a stale wanted flag, foreign-editor ownership and preserved selection. Independent concurrency review found no material issue.
- **Hide/caret** (`CornerHoverMonitor.swift:196`, `TaskNoteComposedHost.swift:348`): completed-hide observation preserves the next-corner callback; accepted preservation retires queued writing-focus repairs. Focused tests: 11/0 and 2/0; native writing/hide/Back checked. Recording text is black beside a blue caret.
- **Small UI**: Later copy (`TasksPanelDesign.swift:249`); empty Today without a content card (`CalendarAgendaViews.swift:112`); matching weekday letters (`AtticPickers.swift:262`); retain spoken due dates while hiding grouped visual dates (`TasksPageModel.swift:744`). Native captures and focused tests checked.

Fixtures: skip-safe activation teardown; retained Draw-filter scenes; Accepted B3 helper removal, 3 Nov horizontal island and P4 kept-card behavior. RoundO3 establishes writing before hosting. Draw’s nested-run-loop wait sometimes never ran queued callbacks: identical async waits plus queue preconditions changed 3/24 failures→0/24. Focused affected suites: 51 passed/5 existing skips. Outside page files: `AtticPickers.swift`, `AtticTaskComponents.swift`, `AtticControls.swift`, CI workflow/harness. No protected Opus implementation or shared-motion test changed.

HID `CGEventPost(.cghidEventTap)`/SCK: 34 trials/build, 20 ms press, ~17 ms grain, first per control N=1; milliseconds after release (repeat medians):

| Target | Before→after |
|---|---|
| Now/Later/Done |303/181/136→302/187/152 (120→102)|
| Island Notes/Calendar/Draw/Tasks |702/596/533/696→865/384/251/332 (183→206)|
| After-switch Later / row / + |202/245/686→220/358/465 (row 127→127, +242→236)|

Mixed timings; no general speedup claim. Ten passive reveals retained backdrop focus. Native Find/typing passed on Now before Back and on Now/Later after it. One extended Search→task hide attempt timed out; preceding `602f05d7` and repeated current passed—cause unclassified.

**Protected/open:** cold Notes content 865/settled 1099 ms (`PanelUIState.swift:230`); Back remains covered by the card (`AtticPanelView.swift:505`), shared/inline ••• overlap (`PanelSharedChrome.swift:304`, `TaskNoteRegions.swift:75`). Back’s tab/scroll/selection UAT awaits that fix. F3’s earlier geometry failure did not recur in focused/final full runs; its diagnostic remains.

**Verification:** full CI [41839206831](https://github.com/TesterPen0812/Attic/actions/runs/41839206831) versus 41755663864 resolved 13 baseline failures; the sole newly failing method is the protected Back reproduction. Main: 4328 passed/44 skipped/9 failed; FKA 16/0, Canvas 6/0, generated 92/1 standing. UI2 reached 73 with 7 resolved/none new; UI1 reached 24/30. Supplement 41853416719 twice failed to acquire an arm64 runner, executing 0 tests: six remain unverified. Normal/strict builds, analyzer, project generation and 12 Python checks passed. Cost-reference compilation/seeded selection blocked usable metrics.

All 18 follow-up methods are accounted for: current CI 11 passed/7 same failures. Last completed Air full `a6165ea3`: 4391 methods, 4209 passed/163 skipped/19 failed (18 standing plus Back), signatures compared case by case. Latest Air XCTest attempts executed 0 tests, stalled at IDE-session setup. A shared-service restart exception to [`wave-common.md`](../attic-redesign-assets/phaseX/panel-design/improvements-build/wave-common.md)’s “Processes: quit nothing” remains unanswered; no reset performed. The no-new-failures gate is unmet. Evidence: `.build/red-*.log`, `ci-c2e-full.comparison.json`, `bugs3-followup18-accounting.json`, `bugs3-latency-comparison.md`.
