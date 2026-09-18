# Batch 1 Reviewer Remediation — Sol Native Final

**Overall native verdict: NATIVE_PARTIAL — no confirmed defect.** The rendered app passed the native scenarios the available computer-control surface could drive. The remediation's critical foreign scroll/pinch-tail sequence and physical-trackpad timing remain **UNVERIFIED**, so this report does not promote the remediation to a full native/physical-input pass.

## Provenance and isolation

- **Source:** frozen snapshot `/tmp/attic-b1rem-snapshot-20260915T130827Z`, reconstructed from `git archive ae6418c1af690e29d15a20344cdb9765a23d3f85` plus its `worktree/` overlay.
- **Manifest:** `MANIFEST.sha256` file sha256 `5d8ab5ef855d4e2f876da67db55417342698458ecc4f6c3d84d68777fd695e6f`; all manifest entries passed before reconstruction. The private reconstruction then matched all 327 overlay files: 0 missing, 0 mismatched.
- **Private reconstruction:** `/tmp/attic-b1rem-sol-native`; the private Git commit used only to satisfy build provenance is `bbaed27731474f67e936d6a26367d98862da81ad`.
- **Build command:** `Scripts/launch_local_preview.zsh --display-name 'Attic B1 Remediation Sol Native' --bundle-id com.taha.Attic.b1rem.solnative.20260915 --executable-name AtticB1RemSolNative --derived-data /tmp/attic-b1rem-sol-native-dd --appearance light`.
- **Built app:** `/tmp/attic-b1rem-sol-native-dd/Build/Products/Local/AtticB1RemSolNative.app`.
- **Identity:** display name `Attic B1 Remediation Sol Native`; bundle ID `com.taha.Attic.b1rem.solnative.20260915`; executable `AtticB1RemSolNative`; executable sha256 `e77d327f9154ea0f90f62382d171c10b209f5c50dcd2083cddef1cfc4d4548e3`; debug dylib sha256 `80f6e5540657424981937d08ce475b7f766eab068970a898464a0ae966b9de1d`.
- **Runtime identity:** launch and final verification tied PID `66922` and, after the intentional isolated relaunch, PID `71715` to the exact executable and debug-dylib inodes. Both were launchd-owned (`parent_pid=1`).
- **Local-only:** the signed entitlements contained app sandbox, user-selected file read/write, get-task-allow, and network client/server. They contained no CloudKit, ubiquity, or APNs entitlement. `com.taha.Attic` and its real user store were never launched or accessed.
- No source file was edited, no commit was made in the live repository, and nothing was pushed or released. This report is the only live-worktree file owned by this reviewer.

## Native actions and outcomes

| Scenario | Action and directly observed outcome | Result |
|---|---|---|
| App/build identity | Verified the running process immediately before interaction and again after the native run. The visible app name was `Attic B1 Remediation Sol Native`; the process mapped the exact built executable and debug dylib. | **PASS** |
| Canvas navigation | Opened the real Canvas workspace. Accessibility exposed the selected Canvas mode, tools, document menu, undo/redo, fit, zoom, and the native `canvas-surface`. | **PASS** |
| Draw | Activated the Pen and invoked the native canvas surface. The rendered/accessibility state changed from `0 strokes` to `1 stroke`, with a concrete `canvas-stroke-*` object. | **PASS** |
| Undo/redo integrity | Undo changed `Canvas · 1 item` to `Canvas · 0 items`, disabled Undo, and enabled Redo. Redo restored the same stroke and returned Undo/Redo availability to the expected state. | **PASS** |
| Ordinary scroll | Sent one computer-control scroll page to `canvas-surface`. Before/after screenshots differ (`27232d3b…` vs `82fe22db…`), while the board retained both strokes and no content/history corruption appeared. This is synthetic scroll input. | **PASS (synthetic)** |
| Zoom control | Opened the rendered Zoom menu and chose Zoom In. The visible control changed from `Zoom 100 percent` to `Zoom 125 percent`; board content remained intact. | **PASS** |
| Physical pinch | The available native control API has no physical trackpad pinch primitive. The Zoom menu result is supplemental and is not pinch evidence. | **UNVERIFIED** |
| Cancel then restart | Pressed Escape in the Pen workspace, then started a fresh surface gesture. After the first surface click had created one stroke, the post-cancel gesture created a second stroke; the board reported `2 strokes`. A transient automation interruption was handled by re-reading/raising the app before retrying. | **PASS (fresh gesture)** |
| Suppressed foreign tail after cancellation | The control API cannot hold a pointer interaction open, inject phased scroll or magnification into it, cancel it, then deliver the same sequence's tail. Therefore viewport non-jump/non-restart for the exact remediation case was not directly exercised. Source tests and independent reviews cover it, but they are not native evidence. | **UNVERIFIED** |
| Board creation | Used Canvas menu → New Canvas, entered `B1 Disposable Board`, and confirmed Create. The workspace switched to `B1 Disposable Board · 0 items`, with 100% zoom and empty undo/redo. | **PASS** |
| Board switching / isolation | Switched back to `Canvas`: both prior strokes and its 125% viewport returned. Switched again to `B1 Disposable Board`: it remained empty at 100%. History controls were empty after board transitions as expected. | **PASS** |
| Board deletion | Reached the real `Delete B1 Disposable Board?` confirmation. The computer-use policy requires a new action-time confirmation before any graphical deletion even when pre-authorized. The confirmation was cancelled; deletion was not claimed. | **BLOCKED** |
| Image import | Opened the real Import Image file picker. The transient unpinned panel dismissed while routing to a private fixture, so no import outcome was established without changing pin/moved persistence behavior. | **UNVERIFIED** |
| Main-panel no-swipe | With two disposable task fixtures visible, sent a synthetic horizontal scroll to the task list. The main panel returned with both tasks, section counts, and composer intact; it did not navigate or expose a swipe action. | **PASS (synthetic)** |
| Subpanel open/close | Created `B1 Native Fixture`, attempted ordinary row activation, followed the mandated manual double-click setup, then used Add Task to create `B1 Native Second`. The automation tree continued to expose only the main task surface; it did not expose a stable auxiliary subpanel for an open/close assertion. Pin/moved persistence semantics were not touched. | **UNVERIFIED** |
| Persistence save failure | No safe native injected-failure seam was available. The prior focused source tests cover this; this run makes no visual persistence-failure claim. | **UNVERIFIED** |

No speculative redesign or source fix was made. The only irregularity was the unpinned panel's occasional transient disappearance during computer-control actions; each time the app was re-read and raised, and the intended state remained intact. This was not sufficient evidence of a product defect.

## Screenshot evidence

Private screenshots are in `/tmp/attic-b1rem-sol-native-evidence/`:

| File | sha256 | Evidence |
|---|---|---|
| `01-empty-main-panel.png` | `b980778cbd3ddb1eaf9d36e640595768ce28839615ba823f7c9b5f134cc8e1fa` | Initial isolated task panel |
| `02-canvas-one-stroke.png` | `27a2d2dd35d68af9fcbba653a973d155b370a1dfddd128c9e2f1c1207b55ecc6` | Canvas after native draw |
| `03-canvas-after-undo.png` | `b2ff08203bb067a060831c85a52b447ed68e0a7d9a580ab6dd756af8fdd026fa` | Canvas after undo |
| `04-before-scroll.png` | `27232d3b7f04464a4c28c63cbf3a3807930853976c0b7718da8bc24d2b714458` | Canvas before synthetic scroll |
| `05-after-scroll.png` | `82fe22dbfb764c1374edf02f0b8145e0df5e873a24f890f5e670ebd06230d31a` | Canvas after synthetic scroll |
| `06-disposable-board.png` | `fe2f4dd6049a0b25e265452006c56fee7665f61d54d338147d2fe4d0748ee8b7` | Empty disposable board |
| `07-tasks-after-horizontal-scroll.png` | `a70b6929a4564aa158c64da19a02df7d867401b10455420d319c5929efa5efec` | Main tasks panel after synthetic horizontal scroll |

## Final assessment

**NATIVE_PARTIAL — no confirmed defect.** The app rendered correctly and the driveable flows passed. The most important remaining native gate is a real physical-trackpad run that starts ink, receives a foreign scroll/pinch sequence, cancels, delivers the tail, proves no viewport movement, and then proves a fresh gesture works. Board deletion also remains blocked at the action-time confirmation, while imports and a stable auxiliary-subpanel open/close observation remain unverified.
