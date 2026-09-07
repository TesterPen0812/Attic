# Attic recovery validation — 7 September 2026

Status, updated 8 September 2026: integrated implementation, automated gates and limited installed-app checks passed; unified preview is running for evaluation. Physical-input, full visual/accessibility and sustained performance acceptance remain open. This report supersedes historical readiness claims, not the historical evidence itself.

## Provenance and boundaries

- Baseline: `codex/attic-local-baseline`, `5a2b7ecbfd2fa8ac939d2adcee029d6ef0a2249a` (verified against GitHub).
- Lineage: `b0a6c41` → adaptive themes `e274ff9` → swipe `22521d1` → verification `6de87f8` → corrected direction `5a2b7ec`.
- Execution: `codex/attic-recovery-20260907`, `/Users/taha/Developer/attic-recovery-20260907`.
- The old dirty `squircle-panel` checkout is untouched. No discarded Pro branch is a parent. Synara and its skill remain retired.
- Three disjoint implementation/review owners share this integration checkout; the parent alone owns the generated project, builds and live UI. Changes are kept in separate commits, not claimed as separate worktrees.
- macOS Local only; official stores, iPhone target, CloudKit/APNs and production signing are outside scope. Preview identities and stores are separate.
- Settings reference `feature/settings-premium-redesign` at `3915af7012c64759ff5c7d33dfa437009b9a0254` was fetched and compared, not replaced. The existing premium hierarchy and theme chooser are retained.

## Current checks

All Xcode commands use `-project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS,arch=arm64'`, `.build/DerivedData`, ad-hoc signing (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`), and isolated host overrides:

```
ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.unithost
ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME=AtticRecoveryUnitHost
ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME=AtticRecoveryUnitHost
ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.tests
```

| Evidence | Result | Limits |
| --- | --- | --- |
| Baseline generation verification | Pass | Baseline only |
| Baseline focused tests | 73/73 | Panel geometry, Canvas session, Notes draft |
| Baseline full macOS units | 450/450 | No physical gesture claim |
| Repair focused checkpoint 5 | 271/271 | Before shutdown; code and evidence survived |
| Recovery focused checkpoint 6 | 277/277 | Post-restart; no failures/skips |
| Recovery full checkpoint 1 | 492/492 | One inherited unit-host exported-type warning |
| Recovery full checkpoint 2 | 496/496 | Zero failures, skips, runtime warnings; includes host declaration repair |
| Recovery full checkpoint 3 | 500/500 | Includes semantic draft conflict/page isolation and maximum escaped-text round trip; zero failures/skips/runtime warnings |
| Recovery full checkpoint 4 | 502/502 | Clean composer can auto-hide; pending input/control focus remain protected; zero failures/skips/runtime warnings |
| Recovery full checkpoint 5 | Build failed | New hosted test referenced a private fixture container; fixed by creating its own isolated in-memory container, no production API widening |
| Recovery full checkpoint 6 | 505/505 | Native mouse, off-center AX geometry and delivered-event resize/move regressions; zero failures/skips/runtime warnings |
| Recovery full checkpoint 7 | 505/505 | Single-owner responsive Canvas toolbar; zero failures/skips/runtime warnings |
| Real UI checkpoint 1 | 6/11 pass, 5 fail | Notes typing/navigation passed; four Canvas queries assumed an obsolete AX element type; consecutive-task helper toggled the now-open composer closed; corrections awaiting rerun |
| Real UI checkpoint 2 | 8/12 pass, 4 fail | Image manipulation/document management passed; drag tests used touch API, text object AX geometry was vertically mirrored; targeted corrections awaiting rerun |
| Focused real UI checkpoint 3 | 3/4 pass | Native task drag and both ink workflows passed; unprimed text-popover first click failed, not accepted via focus workaround |
| Focused real UI checkpoint 4 | 2/2 pass | Single-click text placement/editing, shapes/transforms/history/relaunch; native inward-side/free-corner resizing, stable dock edges/minimum size; zero failures/skips/runtime warnings |
| Full real UI checkpoint 5 | 13/13 pass | Zero failures/skips; two runtime priority-inversion warnings remain, not a performance clearance |
| Final macOS Local static analysis | Pass, exit 0 | `xcodebuild -quiet -jobs 2 ... analyze`, isolated `AtticRecoveryAnalyze` identity; rerun after final runtime corrections, no diagnostic output |
| `ruby Scripts/test_launch_local_preview.rb` | 7 tests, 54 assertions, pass | Dry-run identity/safety policy, not launch UAT |
| `ruby Scripts/test_run_local_ui_tests.rb` | 7 tests, 110 assertions, pass | Runner/generator policy, not real UI execution |
| `bundle exec ruby Scripts/generate_project.rb` and `bundle exec ruby Scripts/verify_project_generation.rb` | Pass | Repeated after source membership changes |

Ruby commands use `PATH=/opt/homebrew/opt/ruby/bin:$PATH`. Full test commands end in `test`; result bundles/logs are in `.build/evidence/`. Focused checkpoint 6 selects `PanelGeometryTests`, `PanelSquircleGeometryTests`, `CanvasDomainTests`, `CanvasSessionTests`, `NoteDraftControllerTests`, `NoteAttachmentTests`, `NoteStoreTests`, and `AppSettingsTests`. Subsequent edits require fresh results before final acceptance.

Final exact commands, run from `/Users/taha/Developer/attic-recovery-20260907`:

```sh
xcodebuild -quiet -jobs 2 -project Attic.xcodeproj -scheme Attic -configuration Local \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -resultBundlePath .build/evidence/recovery-full-7.xcresult \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ATTIC_MACOS_UNIT_HOST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.unithost \
  ATTIC_MACOS_UNIT_HOST_PRODUCT_NAME=AtticRecoveryUnitHost \
  ATTIC_MACOS_UNIT_HOST_EXECUTABLE_NAME=AtticRecoveryUnitHost \
  ATTIC_MACOS_UNIT_TEST_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.tests test

Scripts/run_local_ui_tests.zsh \
  --app-bundle-id com.taha.Attic.recovery20260907.ui \
  --ui-test-bundle-id com.taha.Attic.recovery20260907.uitests \
  --unit-test-bundle-id com.taha.Attic.recovery20260907.unituitests \
  --product-name AtticRecoveryUI --display-name 'Attic Recovery UI' \
  --derived-data /Users/taha/Developer/attic-recovery-20260907/.build/UI \
  --result-bundle /Users/taha/Developer/attic-recovery-20260907/.build/evidence/recovery-ui-5.xcresult

xcodebuild -quiet -jobs 2 -project Attic.xcodeproj -scheme Attic -configuration Local \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ATTIC_MACOS_BUNDLE_IDENTIFIER=com.taha.Attic.recovery20260907.analyze \
  ATTIC_MACOS_PRODUCT_NAME=AtticRecoveryAnalyze \
  ATTIC_MACOS_EXECUTABLE_NAME=AtticRecoveryAnalyze analyze

PATH=/opt/homebrew/opt/ruby/bin:$PATH bundle exec ruby Scripts/generate_project.rb
PATH=/opt/homebrew/opt/ruby/bin:$PATH bundle exec ruby Scripts/verify_project_generation.rb
ruby Scripts/test_launch_local_preview.rb
ruby Scripts/test_run_local_ui_tests.rb
git diff --check 5a2b7ec..HEAD
```

## Baseline preview

- Display: **Attic Recovery Baseline**
- Executable: `AtticRecoveryBaseline`
- Bundle: `com.taha.Attic.recovery20260907.baseline`
- Source: detached `5a2b7ec` at `/Users/taha/Developer/attic-baseline-5a2b7ec`
- App: `.build/BaselinePreview/Build/Products/Local/AtticRecoveryBaseline.app`
- Executable SHA-256: `04a4d9b4fcacf4f99543260914fac08f16970cd69399a3dee43c463b5a6ada4c`
- Ad-hoc signature verified; sandbox/network/debug entitlements only, no Cloud/APNs.
- Installed observations: Settings General/Appearance and original Tasks inspected through native UI. Opening task options reproduced two independent inputs/send buttons. Baseline preview was quit after inspection.
- Attempted compact Settings resize did not change the observed window; **not a resizing pass**.

## Findings ledger

“Automated pass” below means the implemented regression portion passed the current suite. It does not mean the entire historical finding, physical input, visual matrix, or performance criterion is closed. Historical details remain in `AuditFixResolutionLedger-2026-08-31.md`.

| Finding | Current classification / remaining proof |
| --- | --- |
| C-01 | Automated pass: bounded immutable import ownership; real Finder/provider delivery pending |
| C-02 | Automated pass: atomic mixed clear/restore; semantic editor review corrections verified |
| C-03 | Automated pass: object actions; native wrapper corrected; VoiceOver/installed traversal pending |
| C-04 | Automated pass for bounded decode/import; large-image latency, memory and long sessions unverified |
| C-05 | Approved and implemented additively; copied legacy fixture, editor review and semantic native UI workflow pass |
| C-06 | Automated pass: per-board viewport/tool preferences, no selection/history restoration; native relaunch UI passes |
| C-07 | Unverified: whole-table/main-thread scaling needs profiling, no speculative optimization accepted |
| C-08 | Automated pass: Local observer/activity suppression; actual wakeups unverified |
| C-09 | Automated pass: Canvas Undo routes and inline text ownership; installed shortcut precedence pending |
| C-10 | Automated pass: image retry/replacement rollback; actual recovery controls pending UI |
| C-11 | Unverified/manual: imported-object reachability at every size |
| C-12 | Automated pass: shell/content geometry; installed hit-testing matrix pending |
| C-13 | Automated pass: boundary no-op mutations; installed disabled controls pending |
| C-14 | Unverified: rapid/coalesced pointer sample fidelity; no unsupported API workaround added |
| C-15 | Automated pass: stale scroll/pinch ownership and cancellation; physical trackpad sequences pending |
| C-16 | Automated pass: batch progress/cancel ownership; native file-provider timing pending |
| C-17 | Documentation reconciled to semantic implementation; old non-editable labels superseded on macOS |
| C-18 | Automated pass: measured error-overlay layout; compact rendering pending |
| N-001 | Automated pass: import ownership, duplicate-safe persistence; native provider timing pending |
| N-002 | Automated pass plus direct native continuous typing/autosave/navigation check; IME and long-note UAT pending |
| N-003 | Automated pass: explicit interaction locks; actual menu/file-panel timing pending |
| N-004 | Automated pass: editor metadata and recovery checkpoint; installed caret/scroll relaunch pending |
| N-005 | Automated pass: test-store/attachment isolation; no official data touched |
| N-006 | Automated pass: five-second maximum typing checkpoint plus idle autosave |
| N-007 | Automated pass: recovery/navigation session fences; real rapid lifecycle UAT pending |
| N-008 | Broad competing monitor removed; native single-owner navigation/hide tests pass; physical swipe pending |
| N-009 | Automated pass: missing/corrupt recovery and metadata-matched Locate; UI action matrix pending |
| N-010 | Automated pass: generation-tagged maintenance and immutable promise origin; provider delays pending |
| N-011 | Automated pass: truthful saved/failed/Retry states and recovery warnings; installed status readability pending |
| N-012 | Local observer/task overhead reduced; full note/attachment snapshot scaling remains unprofiled |
| N-013 | Unverified/manual: VoiceOver announcements, Full Keyboard Access, contrast matrix |
| N-014 | Unverified/manual: compact long-note/attachment nested scrolling |
| N-015 | Native focus regressions pass; full run-loop/resource-growth evidence remains unverified |
| N-016 | Failed save retains draft and blocks destructive transition; physical hide/Retry UAT pending |
| PANEL-01 | Automated pass: locks and interrupted docking cleanup; transition timing pending |
| PANEL-02 | Automated pass: pre-hide flush checks; installed retry presentation pending |
| PANEL-03 | Automated pass: native visible-frame authority and usable-area constraints; multi-display pending |
| PANEL-04 | Shared backed-control halo removed and opaque setting obeyed; Clear surface unchanged; visual matrix pending |
| PANEL-05 | Automated pass: direction/phases/momentum/cancellation, pin unchanged; physical feel pending |
| PANEL-06 | Automated pass: resize lifecycle/anchor/lock cleanup; real event-loss and outside acquisition pending |
| PANEL-07 | Existing selected-trait tests pass; assistive speech pending |
| PANEL-08 | Source review retained correct monitor domains; CPU/wakeup/latency measurement pending |
| PANEL-09 | Unit, runner policy and full real UI suite pass; physical-input acceptance remains separate |
| PANEL-10 | Automated pass: outside halo and disabled dock edges; all physical corners/sizes pending |
| PANEL-11 | Automated pass: no new Local cloud activity; installed energy timing pending |
| PANEL-12 | Desktop Run delegates to isolated launcher; signed final build passes, direct child did not remain alive under this execution host, verified Launch Services fallback used; no unconditional launcher-success claim |
| PANEL-13 | Hosted input regression checks pass; assistive-client behavior pending |
| SYS-009 | Isolated test roots, signed runner and owned-root cleanup pass in full UI run |

## Review corrections

- Stale scroll ownership blocking new pinch: explicit gesture takeover/cancellation, with regression tests.
- Stale panel swipe after key loss/deactivation/changed target: lifecycle cancellation and late-tail tests (`9bb9474`).
- Notes unreadable recovery warning cleared by ordinary editing: separate persistent warning/Retry, inaccessible-file handling, preserve unread bytes (`756434e`).
- Locate using stale attachment context after asynchronous I/O: fresh metadata/payload verification and truthful Retry refresh (`756434e`).
- Recovery Retry completing on a different page: editor-session/section fence (`ad21140`).
- Composer priority controls disappearing during keyboard focus transfer: latch one composer open during editing; native UI test passes consecutive entry, Tab transfer, retained flags and selected priority.
- Canvas object accessibility hidden by SwiftUI wrapper: preserve macOS native children; installed AX tree and semantic UI test pass. Spoken VoiceOver behavior remains unverified.
- Canvas same-ID text refresh and cross-page draft identity: captured page/payload/version/generation fences, untouched editor refresh, and scoped preserved drafts; independent source review closed both findings and checkpoint 3 regressions passed.
- Maximum valid semantic text could exceed the JSON decoder byte cap after escaping: bounded worst-case encoded limit and maximum-size round-trip regression passed.
- Clean composer presentation blocked auto-hide indefinitely: presentation is now only a visual latch; actual pending content and title/submit/priority focus own visibility locks (`c430d3a` plus root integration). Real external-click behavior still pending.
- Recorded text was rendered at the clicked location, but custom AX child frames were vertically mirrored: correct bottom-left parent-space conversion, off-center regression.
- XCTest ink/task drag failures came from `XCUICoordinateTouchEvents.press(...)`. Installed `XCUICoordinate.h` provides native mouse `click(forDuration:thenDragTo:...)`; tests now use that API with unchanged coordinates, durations and assertions. Direct CUA mouse strokes and task reordering worked before this harness correction.
- Native panel resize/move classified acquisition using the delivered event but read deltas/release from the unrelated current global cursor. Direct handlers and the own-window release monitor now use delivered screen coordinates; watchdog/global recovery retains live cursor sampling. Hosted event tests prove movement with a stationary global pointer.
- Canvas first-click text popover was intermittent with two `ViewThatFits` toolbar candidates sharing presentation bindings. A single responsive instance now owns the actual button anchors; existing full/compact dimensions are preserved, with the shape menu held to its 32-point slot. Unprimed first-click, placement, editing, transforms/history and relaunch all passed UI checkpoint 4 without extra clicks or waits.

## Native preview observations before final corrections

Preview at runtime-code commit `d52ff9b` (working tree had UI-test/document edits only): display **Attic Recovery Preview**, executable `AtticRecoveryPreview`, bundle `com.taha.Attic.recovery20260907.preview`, binary SHA-256 `91ec3b6330f612404781bfb1216c11513c92649fc17488927c01249733daca81`. Launched through `./script/build_and_run.sh` with explicit isolated name/bundle/executable/DerivedData overrides; signed Local build passed. Quit verified by absence of its recorded PID after native Quit.

- Settings Appearance inspected in Dark/System and Light; premium grouping and all seven theme options remained present. Compact resize attempt did not change the window, so that is not a pass.
- Added two real preview-only tasks through the one composer; native CUA drag reordered Beta below Alpha and the order remained after Canvas → Tasks.
- Canvas native CUA mouse drag created a visible diagonal ink stroke and a matching one-stroke AX count. This distinguishes the earlier XCTest touch-event failure from the native pen behavior.
- Bottom resize trial did not change frame; external-point attempt was rejected by the automation surface (`windowNotFoundAtPosition`). Delivered-event correction above still needs installed recheck, and outside acquisition needs physical UAT.
- Native auto-hide/key-deactivation is not proven: CUA app-targeted observation/action can re-focus the panel. Escape trial did not visibly close options, while clicking X did; keep Escape and external-click behavior on the residual UAT list.
- One idle process snapshot roughly 20 seconds after launch showed 0.2% CPU and 97,920 KB RSS. This is a single debug-preview observation, not a sustained energy result or a before/after improvement claim.

## Commit ownership

All work is on the single integration branch above. Review agents did not create review branches; they reviewed disjoint commits in that checkout. Exact file membership is reproducible with `git show --format=fuller --stat <SHA>`; no agent branch or unverified merge is implied.

| Owner / boundary | Exact commit |
| --- | --- |
| Canvas gesture/viewport/image recovery | `5d00b7f3233f0bfccc56ee9949ed2b52d931ab63` |
| Panel geometry, resize, docking and gesture routing | `84a4d5c98b3e7ac948696334c53757951a612877` |
| Notes sessions, saving and attachment recovery | `6a126865294325c45eee784e63b90aafb2d1f1ac` |
| Local launcher and semantic-object decision | `f890f6090d3e15b052e07daf626a50b8c0db2f09` |
| Panel lifecycle review correction | `9bb9474baebb3c1ccb21536a8943f9d1daa4b593` |
| Notes recovery/file-repair review correction | `756434ea577840740abcbe3560b5bdeb5cebee49` |
| Notes asynchronous Retry session fence | `ad21140493bae6c5c10296300bfa2a86a2875df9` |
| Editable Canvas objects, persistence and conflict review corrections | `e44d64b7fbd3af30498f8125b1a338b77c7911dd` |
| Clean composer visibility-lock correction | `c430d3acd1ec3fb89193f16a942804a66bb7a493` |
| Root integration, one composer, shared controls and generated project | `d52ff9bf49c474f45dfb315e89943779de0f692e` |
| Delivered-event panel resize and move correction | `e9887e9a07ebc483856a13f01ffd37a88782d733` |
| Canvas AX geometry and single-owner responsive toolbar | `3525494cc08315fd3602e215cbe793ecbe43e3f0` |
| Native task-drag and panel-resize installed UI checks | `0e0ee46af18cda81ac9e152bb014cb310be4576d` |
| Verification ledger at final preview build | `647eb2bc4c7d4406fbce2030b6d4d38a08e40015` |

Changed files by workstream (all paths repository-relative):

- Canvas: `Attic/Canvas/{CanvasImageExportDocument,CanvasImageTypes,CanvasSemanticInteraction,CanvasSemanticObject,CanvasSemanticRenderer,CanvasSession,CanvasSurface,CanvasSurfaceMac,CanvasSurfaceMacHelpers,CanvasSurfaceRenderer,CanvasTypes}.swift`; `Attic/App/CanvasEditCommandRoute.swift`; `Attic/Models/CanvasSemanticObjectItem.swift`; `Attic/Services/{CanvasStore,CanvasStoreImages,CanvasStoreLifecycle,CanvasStorePersistence,CanvasStoreSemanticObjects}.swift`; `Attic/Views/Panel/CanvasPanelContent.swift`; `AtticTests/{CanvasDomainTests,CanvasSessionTests,CanvasStoreTests}.swift`; existing `AtticUITests/CanvasUITests.swift` under verification. Temporary introduced `CanvasViewState.swift` was removed and its types folded into existing `CanvasTypes.swift` to preserve mobile membership.
- Notes: `Attic/Services/{AttachmentFileStore,NoteAttachmentPlatformSupport,NoteDraftController,NoteStore}.swift`; `Attic/Views/Panel/{NoteAttachmentTray,NotesPanelContent}.swift`; `AtticTests/{NoteAttachmentTests,NoteDraftControllerTests,NoteStoreTests}.swift`.
- Panel: `Attic/Window/{AtticPanel,AtticPanelController,PanelUIState}.swift`; `Attic/Services/PanelGeometry.swift`; `AtticTests/{CornerHoverStateMachineTests,PanelGeometryTests,PanelSquircleGeometryTests}.swift`.
- Root: `Attic/App/AppCoordinator.swift`; `Attic/Services/PersistenceController.swift` (macOS lists only); `Attic/Views/Panel/AtticPanelView.swift`; removed `Attic/Views/Panel/TaskComposerView.swift`; `Attic/Design/AtticStyle.swift`; `Attic/Views/Settings/PanelSettingsView.swift`; `AtticTests/{AppSettingsTests,TaskStoreTests}.swift`; `AtticUITests/AtticUITests.swift`; `Scripts/{generate_project.rb,test_launch_local_preview.rb,test_run_local_ui_tests.rb}`; `script/build_and_run.sh`; generated `Attic.xcodeproj/project.pbxproj`; this report, historical ledger link and `Docs/CanvasSemanticObjectsDecision.md`.

## Final unified preview and direct checks

- Clean build source: `codex/attic-recovery-20260907`, **`647eb2bc4c7d4406fbce2030b6d4d38a08e40015`**. Subsequent report-only commit changes no runtime code. No commits pushed.
- Display **Attic Recovery Preview**, executable **AtticRecoveryPreview**, bundle **`com.taha.Attic.recovery20260907.preview`**.
- App: `/Users/taha/Developer/attic-recovery-20260907/.build/RecoveryPreview/Build/Products/Local/AtticRecoveryPreview.app`.
- Executable: app path above plus `/Contents/MacOS/AtticRecoveryPreview`.
- SHA-256: **`cae6f0332a1e9d5c6bc476e0f21fdcdd335110d88856dfed182d01f6e267036c`**.
- Final signed Local build: exit 0; `codesign --verify --deep --strict` passes. Entitlements are sandbox, client/server network, debug; no CloudKit/APNs. Full manifest/signature/entitlements are in `.build/RecoveryPreview/PreviewState/`.
- Build command:

```sh
./script/build_and_run.sh --display-name 'Attic Recovery Preview' \
  --bundle-id com.taha.Attic.recovery20260907.preview \
  --executable-name AtticRecoveryPreview \
  --derived-data /Users/taha/Developer/attic-recovery-20260907/.build/RecoveryPreview
```

An older same-preview PID remained after the initial launch attempt; it was closed through its native Quit menu and its exit verified. Direct child launch from the script exited under this execution host even after the old process quit. No cause or fix is claimed for that launcher/host behavior. The exact newly built app was then launched with:

```sh
/usr/bin/open -n /Users/taha/Developer/attic-recovery-20260907/.build/RecoveryPreview/Build/Products/Local/AtticRecoveryPreview.app
```

The resulting PID **19006**, started **8 September 00:13:08 local**, was checked against the exact executable path and remained alive across the following native checks. It differs from the script's short-lived recorded child PID; use this distinction when reading its manifest/logs.

- Pinned the actual preview for stable testing. Direct bottom-edge mouse drag changed panel screenshot bounds from approximately 344×494 to 344×634 while the top stayed anchored. Composer stayed accessible at the bottom. This final check resolves the earlier direct bottom-resize failure, not all external sides/corners.
- Notes: typed “Final preview: typing stays in one uninterrupted flow.” continuously into an isolated preview note. Body remained focused, status advanced from Unsaved to Saved automatically, and note count became 1. Browsing saved notes and returning preserved the exact body.
- Canvas: final native AX tree exposes the existing ink objects and compact toolbar. At this point new Canvas input was arriving from the user, so further cursor control was stopped to avoid interference. Full automated semantic text/shape editing, moving/resizing, history and relaunch passed separately in UI checkpoints 4 and 5.
- Previously observed Light/Dark Settings, seven themes and one-composer task creation/reordering remain recorded above. They are not upgraded to a full appearance/translucency/background matrix.
- Process samples during this final mixed-interaction session ranged from 0.8–3.8% CPU and 42,848–84,432 KB RSS at the sampled moments. They are not controlled before/after, peak memory, sustained-idle, GPU or energy measurements. Resource growth and perceptual latency remain unverified.
- Skill used: `build-macos-apps:build-run-debug`, to reuse the existing isolated launcher and separate build identity from installed-app proof.

## Unresolved choices and measurement boundaries

- The roadmap referenced three previously chosen save policies, but no exact trio exists in source or prior decision material. Automatic/On-exit/Hybrid was asked as an optional clarification; no answer received. Robust current automatic saving remains active. No speculative policy picker was added.
- No broad dimming, captured-background processing, opacity increase, blur increase, or weaker Clear transmission was introduced.
- Before shutdown the Mac had about 1.7 GB disk free and heavy swap; after restart about 10 GB was free. Test elapsed times across that boundary are not causal performance evidence.
- Unit counts, code review, snapshots and signed builds are not physical trackpad, VoiceOver, multi-display, energy, or release-readiness evidence.
- UI checkpoint 1 recorded two real priority-inversion warnings inside `AtticRecoveryUI`, not in the test runner. Independent symbol/UUID matching traced both through Foundation `NSConditionLock.lockWhenCondition:beforeDate` into AppKit `__getDataDetectorsScanner`: one from Services menu filtering, one from `NSSpellChecker`/`NSTextCheckingController`. No Attic persistence queue appeared in the resolved frames and no app-level causal fix was established. They are retained as framework/runtime performance observations; spelling, Services and other working features were not disabled to suppress them.
- Final full UI checkpoint 5 also records two priority-inversion warnings. They are not suppressed and the run is not described as warning-free or a full performance pass.
- Canvas failed-save text drafts are retained within the running Canvas session; unlike Notes recovery journaling, they are not crash-durable. This remains a reliability limit, not silently presented as solved.
- Still needed: physical pinch/swipe direction while pinned; all four corners and outside-edge acquisition at minimum/medium/large sizes; Dock/multi-display and external-app focus/auto-hide; compact/expanded Settings; all themes/appearances/glass modes on bright/dark/detailed backgrounds; VoiceOver/Full Keyboard Access/IME; real Finder/provider attachments and long-note/large-image/long-running resource profiling. The exact three save-policy options still need a product decision. Visual balance and motion feel require the user's judgment.
