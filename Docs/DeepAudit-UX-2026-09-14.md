# Deep UX/UI Audit — Attic — 2026-09-14

**Domain:** all rendered UI and interaction state machines — main/subpanel open/close/pin/move/idle/scroll, titles/metadata/hover menus, composer/attachments/error messages, Notes drawer/editor, Settings, themes/translucency/Liquid Glass, keyboard/focus/accessibility/Reduce Motion, Canvas visible tool states, native pointer behavior.

**Method:** exhaustive read-only source audit of `Attic/{Window,Views,Design,Services (UI-adjacent),Models}` plus a bounded native pass against a live local preview. No implementation changes; no builds/tests run by this audit (read-only mandate).

**Preview provenance:** `AtticPERFA1Final` — `com.taha.Attic.perfa1final`, `/private/tmp/attic-perfa1-final-dd/Build/Products/Local/AtticPERFA1Final.app`, local-only (no CloudKit/APNs). First instance PID 28822 quit via ⌘Q mid-audit (see Dismissed, D-6); relaunched with `Scripts/launch_local_preview.zsh`, continued as PID 87404. Dark appearance, Original palette, Translucent + Clear glass.

**Native evidence:** `Docs/DeepAudit-UX-2026-09-14-screenshots/` (44 captures, numbered `NN-name.png`). AX tree was not inspectable (LSUIElement exposes no content tree to System Events) — noted under Limitations.

---

## 1. Coverage matrix

| Subsystem | Source traced | Native exercised | Result |
|---|---|---|---|
| Main panel reveal/hide/pin/move/auto-hide/outside-click | ✅ `AtticPanel`, `AtticPanelController`, `CornerHoverStateMachine`, `MainPanelAutoHidePolicy` | ✅ hotkey reveal, auto-hide, pin/unpin, outside-click hide | Pass (see D-1) |
| Subpanel lifecycle (open/pin/transient vs pinned/survival) | ✅ `SubtaskPanelController`, `SubtaskPanelContent`, `PanelSurfaceHostingView` | ✅ row-click open, pin promote, survives main-panel hide | Pass |
| Task rows/sections/family/status/menus/hover | ✅ `TaskRowView`, `TaskSectionView`, `TaskFamilyView`, `TaskStatusButton`, `TaskActionsMenu` | ✅ hover `•••`, context menu, status-circle complete, double-click start, subpanel open | Pass |
| Composer: input/draft/priority/submit | ✅ `AtticPanelView` composer + priority row + submit | ✅ text entry, draft persistence across sections/hide, priority row; submit hover | **UX-03** |
| Task attachments: import/drop/pending/display | ✅ `TaskComposerAttachments`, `TaskImageAttachments`, `TaskAttachmentDrop`, `TaskAttachmentPicker` | ⚠️ import path reviewed natively via picker (note attachment verified); real file drag not performed | Partial |
| Notes: empty/list/editor/drawer/tray/draft | ✅ `NotesPanelContent`, `NoteComposerView`, `NoteDraftController`, `NoteAttachmentTray`, `NoteInlineCards` | ✅ empty state, editor, autosave, drawer, row menus, delete alert, attach via picker, draft survives hide | **UX-01, UX-02** |
| Settings (all panes) | ✅ Settings views + `SettingsWindowController` + `AppSettings` | ✅ General/Panel/Appearance/Agent Access/About all rendered | Pass |
| Themes/translucency/Liquid Glass/contrast | ✅ `AtticPanelTheme/Style/Theme`, `AtticGlassControlModifier`, `Squircle` | ✅ clear-glass path live; material/opaque paths source-verified only | Pass + UX-03 |
| Keyboard/focus/accessibility | ✅ shortcuts ⌘1–4, `FocusState`, `accessibilityIdentifier`s throughout | ✅ ⌘1–⌘4 section switching, ⌘⇧L drawer; VoiceOver not runnable | Partial (limitation) |
| Reduce Motion / Reduce Transparency | ✅ `reduceMotion`/`reduceTransparency` gating everywhere | ⚠️ system prefs not toggled (would alter user machine) | Source-only |
| Canvas: tools/menus/zoom/draw/selection | ✅ `CanvasPanelContent`, controls, surface, interaction, input state machine, semantic editing, a11y | ✅ draw stroke, ink popover, undo/redo enable, tool dock, zoom label | **UX-01** |
| Native pointer/cursor (with UI lock) | — | ✅ CGEvent move/click/drag/right-click/keys; scroll events did not move panel ScrollViews | Partial (limitation) |

---

## 2. Confirmed findings

### UX-01 — Accent-tinted `•••`/glyphs on `borderlessButton` Menus outside task rows

- **Severity:** Medium-Low (cosmetic, but actively misleading in one case)
- **Confidence:** Confirmed — source + native
- **Domain:** rendered UI / visual consistency
- **Mechanism:** SwiftUI `Menu` + `.menuStyle(.borderlessButton)` renders an `Image` label through an AppKit pop-up button that paints the symbol as an **accent-tinted template**, ignoring the label's `foregroundStyle`. The codebase itself documents this at `Attic/Views/Panel/TaskRowView.swift:381-388` ("the blue '•••' visible on every resting row") and works around it with `TaskRowMenuAnchor`+`NSHostingMenu` (`TaskRowView.swift:389-398`, `:490-498`) — but the same pattern was left in place everywhere else.
- **Sites:**
  - `NotesPanelContent.swift:816-832` — `SavedNoteRow` `•••` (drawer rows). **Confirmed native:** accent-blue dots on every resting row — `32-drawer.png`, `38-drawer-2notes.png`, `47-drawer-7notes.png`.
  - `NotesPanelContent.swift:921-937` — `NoteRowView` `•••` (main list row). Same pattern; list is rarely reachable (see C-2) so the symptom is mostly latent.
  - `NoteAttachmentTray.swift:273-287` — attachment-card actions `•••`. **Confirmed native:** blue dots on the attachment card — `84-note-attach.png`.
  - `NoteAttachmentTray.swift:520-525` — compact tray-row `•••`. Same pattern.
  - `CanvasPanelContent.swift:583-607` — `shapeMenu` square. **Confirmed native:** accent-blue square outline — `63-toolbar-zoom.png`, `69-shape-hover.png`. Worse than cosmetic: when a shape IS pending placement the design *intentionally* fills the circle with `Color.accentColor` (`:601`), so the resting accent tint masks the idle→pending state distinction.
  - `CanvasPanelContent.swift:402-499` — `addMenu` `square.stack`. **Confirmed native:** accent-blue icon — `63-toolbar2-zoom.png`.
  - `CanvasPanelContent.swift:694-698` — failed-image recovery menu (conditional on `failedImageIDs`; same pattern, not exercised).
  - `CanvasPanelContent.swift:824-826` — selected-object style menu (needs a selected semantic object; same pattern, not exercised).
  - `TaskRowView.swift:399-409` — pre-macOS-14.4 fallback `Menu` keeps the bug on older systems (acceptable, gated).
- **Counter-examples (correctly styled):** composer `+` menu (`AtticPanelView.swift:524-550`) overrides `.tint`/`.accentColor`/`.foregroundStyle` → renders quiet white (native-verified). Zoom menu (`CanvasPanelContent.swift:365-377`) uses a `Text` label → unaffected (native-verified white).
- **Expected:** quiet secondary-colored glyphs, matching the documented design intent and the task-row treatment.
- **Actual:** system accent blue at rest on the listed surfaces.
- **Evidence:** screenshots above; source citations above.
- **Impact:** visual noise inconsistent with Attic's quiet chrome; in `shapeMenu` it also erases the pending-placement signal.
- **Smallest fix:** apply `.tint(palette.secondaryForegroundColor)` (proven by the composer `+`), or route these menus through the existing `TaskRowMenuAnchor`/`NSHostingMenu` path for uniformity.
- **Verify:** open each surface; glyphs should render secondary at rest; shape menu should only show accent when a shape is pending.

### UX-02 — Saved-notes drawer scrolls rows under overlaid chrome with no fade/legibility treatment

- **Severity:** Low-Medium
- **Confidence:** Confirmed — source + native
- **Mechanism:** `SavedNotesDrawer` (`NotesPanelContent.swift:716-762`) pads its `LazyVStack` 58pt top/bottom (`:740-741`) so rows scroll beneath the overlaid glass buttons (`:745-754`), but unlike the task list there is **no mask** — compare `taskScrollMask`/`TaskScrollMaskLayout` fade at `AtticPanelView.swift:476-491`.
- **Expected:** scrolled rows fade (or are otherwise treated) under the drawer's chrome, matching the task list's behavior.
- **Actual:** at the bottom edge the `←` "Return to writing" button permanently overlaps the lowest row's preview text; the last row hard-clips at the squircle edge with no fade — `47-drawer-7notes.png`, `49-drawer-scrollup.png`.
- **Evidence:** native screenshots; source citations above.
- **Impact:** illegible overlap and a visibly rougher scroll edge than the task list beside it.
- **Smallest fix:** apply a matching gradient mask (or a bottom `safeAreaInset`/blur underlay for the back button) inside `SavedNotesDrawer`.
- **Verify:** ≥8 notes, scroll to both extremes; rows should fade under chrome, button never overlaps text.

### UX-03 — Quick-submit button: dead hover/focus styling → no custom feedback

- **Severity:** Low
- **Confidence:** Confirmed (dead code) — native evidence inconclusive for native-glass path
- **Mechanism:** the submit `Button` (`AtticPanelView.swift:572-590`) renders with `.atticGlassControl(in: Circle())` only; `isQuickSubmitHovered` (`:25`, set at `:586`) and the emphasized colors `quickSubmitBackgroundColor`/`quickSubmitStrokeColor` (`:932-958`) are never consumed. `AtticGlassControlModifier` (`AtticStyle.swift:281-314`) provides no hover variant on `.material`/`.opaque` treatments; on `.nativeGlass` + `interactive: true` the system *may* supply a response.
- **Trigger:** type a task, hover or keyboard-focus the `↑` submit.
- **Expected:** the designed emphasis (accent fill/edge) on hover/focus.
- **Actual:** no custom feedback. Synthetic-pointer A/B produced a 0-pixel diff in the button region (`72-composer-text.png` vs `73-submit-hover.png`), and the same 0-diff on the pin button — i.e., synthetic events don't trigger native glass interactivity, so the real-pointer glass result is unverified. On material/opaque paths (Reduce Transparency, non-native-glass systems) the zero-feedback result is structurally certain.
- **Impact:** the panel's primary action lacks the affordance its own design specifies; focus state is equally invisible.
- **Smallest fix:** either delete the dead state, or restore emphasis — e.g., drive `quickSubmitBackgroundColor`/stroke (or an opacity/scale change) from `isQuickSubmitHovered || isQuickSubmitFocused`.
- **Verify:** hover + keyboard-focus the submit on Clear-glass, Frosted/material, and opaque (Reduce Transparency) appearances.

---

## 3. Measured performance findings

None. No timing/instrumentation was run (read-only audit; qualitative responsiveness only). No performance claims are made.

---

## 4. Plausible but unverified concerns

- **UX-04 — Motion barrier can strand the panel interaction-disabled (bounded).** `PanelMotionCompletionBarrier` (`AtticPanelController.swift:58-73`) requires BOTH `finishFrame` (`:1013-1017`) and `finishPresentation` (`:1004-1006`) before clearing `isPanelMotionActive`/`allowsContentInteraction` (`:987-999`). If either completion never fires, the panel stays interaction-disabled and `canBeginTrackpadSwipe` (`:541-548`) keeps rejecting swipes. Recovery exists — `stopPanelMotion()` (`:1020-1033`) is called by every subsequent programmatic show/hide and by `onDirectContentInteraction` (`:535-539`) — so a real click likely recovers; only swipe-start and content interaction are at risk meanwhile. Unlike the drag watchdog, this path has **no timeout**. Not reproduced natively. *Suggested hardening:* a short watchdog timer that force-resolves the barrier.
- **C-1 — `NoteAttachmentTray:520-525` compact-row `•••`** — same pattern as the confirmed card menu; the tray's compact layout wasn't reachable in this pass. Treat as UX-01's blast radius.
- **C-2 — `NoteRowView` list near-unreachable.** `openMostRecentNoteIfNeeded` (`AtticPanelView.swift:823-852`) auto-opens the most recent note on section entry, and deleting the open note re-opens the next (`854-868`); the list (notes non-empty ∧ `!isComposerPresented`) survives mainly via the conflict-discard path (`NotesPanelContent.swift:690`). Not a defect per se — but the `NoteRowView` accent bug (UX-01) is therefore mostly latent, and the designed list surface may be effectively dead UI. Flag for product intent.
- **C-3 — failed-image menu (`CanvasPanelContent:694-698`) and object-style menu (`:824-826`)** — same `borderlessButton`+`Image` pattern; need a failed image / selected semantic object to observe. Almost certainly tinted per UX-01.
- **C-4 — Synthetic scroll did not move panel-hosted ScrollViews** (settings window scrolled fine). Either my CGEvent scroll doesn't route into the nonactivating panel, or panel ScrollViews genuinely ignore posted wheels. Physical trackpad scroll is almost certainly fine; flagged as tooling limitation rather than defect — but worth one real-pointer check since the drawer's overflow depends on it.

---

## 5. Optional UX suggestions (not defects)

- **S-1 — Drawer has two identical close affordances:** top-right `xmark` ("Return to note") and bottom-left `arrow.left` ("Return to writing") both call `onClose` (`NotesPanelContent.swift:746-754`). Redundant; consider keeping one and using the space for a more useful control.
- **S-2 — Notes empty-state "New Note" renders accent blue** (`NotesPanelContent.swift:66-68`, `.buttonStyle(.bordered)`), the only accent-colored control in the panel's quiet chrome. Consider `.buttonStyle(.plain)` + glass treatment for consistency.
- **S-3 — Composer draft persistence asymmetry:** quick-entry text survives hide/show and section switches (verified: "hover test task" persisted) but is in-memory only — lost on relaunch — while note drafts are durable. Acceptable, but worth a conscious decision.
- **S-4 — To-do status circle discoverability:** circle click on a to-do row is a 22pt target inside a row whose single-click opens the subpanel; my synthetic clicks on the circle repeatedly produced row-opens instead. In-progress circles completed reliably. Consider a slightly larger hit area or confirming the exclusivity on real pointer.

---

## 6. Dismissed hypotheses

- **D-1 — "Panel never auto-hides":** the panel stayed visible for minutes — cause confirmed native: `isPanelPinned` was true (context menu showed "Unpin Panel", `55-ctx4.png`/earlier capture). After unpin, auto-hide worked (`19-after-unpin.png`). Correct behavior.
- **D-2 — "Malformed attachment thumbnails":** the green "TM"/rectangle artifacts under the translucent panel were a foreign window's toolbar bleeding through — dismissed after the same shapes persisted over unrelated content (`14-settled.png`, `24-note-typed2.png`).
- **D-3 — `confirmingTaskCompletionID` records the wrong task:** verified coherent — drop-confirmations store the dragged ID (`acceptTaskDrop`, `TaskRowView.swift:456-466`), status-button confirmations store the row's own ID (`:157-160`), and the subtask controller uses it only to keep the surface alive. Not a defect.
- **D-4 — About-pane repo URL:** `github.com/TesterPen0812/Attic` matches the actual `origin` remote — genuine.
- **D-5 — "Ask Siri" in the task context menu** (`54-ctx3.png`): macOS-injected menu item, not Attic code.
- **D-6 — Preview terminated mid-audit:** `performKeyEquivalent → terminate:` at 22:20:47 (unified log) = ⌘Q on `Quit Attic` (`MenuBarView.swift:47-50`). Cause: my earlier synthetic ⌘3 left the window-server Cmd modifier logically held; the next `q` keystroke became ⌘Q. Input-helper bug, fixed (modifiers now post real flagsChanged down/up). Not an app defect — but worth noting ⌘Q works while the panel is key, standard for menu-bar apps.
- **D-7 — Apparent to-do circle no-complete:** my clicks on to-do circles opened the family subpanel (row single-click wins outside the 22pt circle). In-progress circle click completed correctly (`91-complete-ip.png`). Not a defect; see S-4.
- **D-8 — "Second file picker":** the second file-list window visible during import (`79-picked.png` bottom) belonged to a different app, not Attic.

---

## 7. Native pass log (what was exercised)

| Action | Result | Evidence |
|---|---|---|
| ⌃⌥Space reveal | Panel reveals top-right, frosted | `01`, `25` |
| Row hover | Quiet gray `•••` + highlight | `04`, `88`, `93` |
| Row single-click | Family subpanel opens anchored left | `05`, `99` |
| Pin subpanel | Promotes to pinned window (✕ appears) | `06` |
| Main-panel hide while pinned | Pinned subpanel survives | `07` |
| Unpin main panel → idle | Auto-hides correctly | `19` |
| Outside click | Panel hides | `30` |
| ⌘3 Notes | Empty state; "New Note" accent-blue CTA | `26` |
| New note → type | Editor, autosave "Saved just now", spell-check underline | `29`, `37` |
| Drawer (⌘⇧L/button) | Rows + **accent `•••`**; Open/Copy/Delete menu works | `32`-`34`, `38` |
| Delete note | "Delete note?" alert, red Delete, removes row | `41`-`44` |
| 7-note drawer | Back-arrow overlaps row text; hard clip, no fade | `47`-`49` |
| Attach file (picker) | Import works; card renders + **accent `•••`** | `75`-`84` |
| Settings (5 panes) | All render correctly; scroll works | `57`-`62` |
| ⌘4 Canvas | Tool dock, ink popover, draw stroke, undo/redo, zoom % | `63`-`70`, `86` |
| Canvas menus | shapeMenu + addMenu glyphs **accent blue** at rest | `63`-`69` |
| Submit hover (A/B pixels) | 0-diff — no custom feedback | `72`/`73` |
| Status circle (in-progress) | Completes → Done | `91` |
| Double-click to-do | Starts → In Progress | `93` |
| Task row right-click | Context menu (Ask Siri, Attach, Subtask, Edit, Copy, Priority, Move) | `54` |
| Panel right-click | Settings…/Pin Panel menu | `55` |

---

## 8. Residual uncertainty & limitations

- **VoiceOver:** the LSUIElement panel exposes no AX tree to System Events; VO structure unverified. Source has thorough `accessibilityLabel`/`accessibilityIdentifier` coverage.
- **Reduce Motion / Reduce Transparency:** not toggled (system settings; would alter the user's machine). Source gating is uniform (`reduceMotion ? nil : AtticMotion.*`, treatment resolve in `AtticStyle.swift:277-302`).
- **Physical pointer/trackpad:** synthetic CGEvents don't trigger native `.glassEffect` interactivity or panel ScrollViews; real-pointer hover feedback and kinetic scroll unverified. Swipe-to-hide (documented in Settings/Panel) untested.
- **Pinned-subpanel across relaunch:** a pinned-looking window at the left edge post-relaunch was not fully attributed; runtime pin state isn't expected to persist — residual question whether pinned families restore at launch.
- **Shape menu open-state:** clicks on the accent square didn't visibly open its menu in two attempts (possible hit-target miss under synthetic pointer); sibling menus opened normally.
- **Coverage honesty:** this is not full UI acceptance — no large-store/perf testing, no real drag-and-drop file import, no multi-display/corner moves exercised, no stale-build catalog evidence treated as current.

## 9. Prioritized fixes

1. **UX-01** — unify menu styling: apply the proven `.tint`/`.accentColor` override (or the `NSHostingMenu` anchor) to the 8 affected `borderlessButton` sites; restores the shape menu's pending-state signal too.
2. **UX-02** — add the task-list-style fade mask (or back-button underlay) to `SavedNotesDrawer`.
3. **UX-03** — wire (or remove) the dead quick-submit hover/focus emphasis; verify on material/opaque paths.
4. **UX-04** — add a bounded watchdog to `PanelMotionCompletionBarrier` so a dropped AppKit completion can't freeze panel interaction until the next programmatic transition.
5. **C-2/S-1** — decide the intended notes-list reachability and the redundant drawer close controls.
